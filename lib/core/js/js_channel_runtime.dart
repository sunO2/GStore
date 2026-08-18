import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/http/github/dio_client.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

/// JS 渠道运行时异常（JS 抛错 / 脚本加载失败 / Promise 超时）
class JsChannelException implements Exception {
  final String message;

  JsChannelException(this.message);

  @override
  String toString() => 'JsChannelException: $message';
}

/// JS 渠道运行时：封装 QuickJS 引擎，提供 Dart↔JS 双向桥 + host API 注册。
///
/// 一个 runtime 实例 = 一个 JS 渠道（独立 context，渠道间隔离）。
///
/// ## host API（JS 侧通过 `host.xxx` 调用，返回 Promise）
/// - `host.network.get(url, {params, headers})` / `host.network.post(url, {body, json, headers})`
///   → 走项目 Dio（继承代理/超时配置），统一返回 `{ok, status, data}` 包装
/// - `host.database.getAppsByChannel()` / `host.database.getApp(appId)` /
///   `host.database.insertApps(list)` → 全部强制 channelKey = 当前渠道（数据隔离核心）
/// - `host.config.get(key)` → ConfigService 读取渠道配置，无则 null
/// - `host.env.get(name)` / `host.env.all()` / `host.env.has(name)` → 渠道隔离的
///   环境变量（`{ok, data}` 包装；用户名/密码等凭据由用户配置，不硬编码进脚本）。
///   env 是**只读快照**：initialize 时从 [envReader] 快照一次，脚本运行中不变；
///   需改环境变量时由 JSChannel.setEnv 持久化后调用 [updateEnv] 热更新快照
///   （无需重建引擎，脚本下次读取即生效）。
/// - `host.log.info(msg)` / `host.log.error(msg)` → appLog
/// - `host.ui.showVersionPicker(options)` → 弹 Flutter 版本/环境选择框（Hybrid：
///   runtime 不依赖 UI，由调用方注入 [uiShowVersionPicker] 实现）；
///   options: `{title, envs:[], versions:[{version, envs, buildCount}], currentEnv, currentVersion}`，
///   Promise → `{ok, data}`，data 为 `{env, version}` 或 null（用户取消）：
///   `const sel = await host.ui.showVersionPicker({...}); sel.data`
/// - `host.ui.refreshDetail(params)` → 刷新详情页（params: `{appId, env, version}`，
///   由调用方注入 [uiRefreshDetail] 实现）→ `{ok}`
///
/// ## 异常处理
/// - JS 抛错 → [call] 抛 [JsChannelException]（不崩应用）
/// - host 回调异常 → 捕获 + 日志，返回 `{ok: false, error}` 给 JS
///
/// ## 类型转换
/// - Dart→JS：参数经 jsonEncode 注入；host 返回值经引擎桥转换（Future 自动转 JS Promise）
/// - JS→Dart：`evaluate` 的 rawResult 已由引擎转换为 Map/List/String/num/bool/Future
class JsChannelRuntime {
  /// 渠道唯一标识（如 'js.vivo'），用于数据隔离
  final String channelKey;

  /// JS 渠道脚本源码
  final String script;

  // ==================== 可注入依赖（测试用；默认走项目单例） ====================

  final Dio? _dioOverride;
  final ChannelAddedAppDao? _appDaoOverride;
  final Future<Object?> Function(String key)? _configGetterOverride;
  final Map<String, String> Function()? _envReaderOverride;
  final void Function(String message)? _logInfoOverride;
  final void Function(String message)? _logErrorOverride;

  /// host.ui 能力：由调用方（JSChannel/详情页）注入 Flutter 实现
  /// （runtime 不直接依赖 UI/context，保持可测试）
  final Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
      _uiShowVersionPickerOverride;

  /// 刷新详情页（JS 调，参数含 appId/env/version）
  final Future<void> Function(Map<String, dynamic> params)?
      _uiRefreshDetailOverride;

  JavascriptRuntime? _engine;
  bool _initialized = false;
  bool _disposed = false;

  /// 当前 env 快照（渠道隔离；initialize 时从 [envReader] 快照，[updateEnv] 热更新）
  Map<String, String> _env = const {};

  JsChannelRuntime({
    required this.channelKey,
    required this.script,
    Dio? dio,
    ChannelAddedAppDao? appDao,
    Future<Object?> Function(String key)? configGetter,
    Map<String, String> Function()? envReader,
    void Function(String message)? logInfo,
    void Function(String message)? logError,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowVersionPicker,
    Future<void> Function(Map<String, dynamic> params)? uiRefreshDetail,
  })  : _dioOverride = dio,
        _appDaoOverride = appDao,
        _configGetterOverride = configGetter,
        _envReaderOverride = envReader,
        _logInfoOverride = logInfo,
        _logErrorOverride = logError,
        _uiShowVersionPickerOverride = uiShowVersionPicker,
        _uiRefreshDetailOverride = uiRefreshDetail;

  bool get isInitialized => _initialized;
  bool get isDisposed => _disposed;

  /// 热更新 env 快照（JSChannel.setEnv/removeEnv 持久化后调用）。
  ///
  /// 无需重建引擎：host.env 回调读的就是快照，脚本下次调用立即看到新值。
  /// 传入的 map 会被拷贝，后续外部修改不影响快照。
  void updateEnv(Map<String, String> env) {
    _env = Map<String, String>.of(env);
  }

  /// 建引擎、注册 host API、注入 host 前缀、加载脚本
  Future<void> initialize() async {
    if (_initialized) return;
    if (_disposed) {
      throw JsChannelException('runtime 已释放，无法重新初始化');
    }

    // 初始化时快照 env（只读快照：脚本运行中 env 不变，改环境变量需 updateEnv）
    _env = _readEnv();

    final engine = getJavascriptRuntime(xhr: false);
    _engine = engine;

    _registerHostApis(engine);

    final prefixResult = engine.evaluate(_hostPrefixJs);
    if (prefixResult.isError) {
      throw JsChannelException('host 前缀注入失败: ${prefixResult.stringResult}');
    }

    final scriptResult = engine.evaluate(script);
    if (scriptResult.isError) {
      throw JsChannelException('脚本加载失败: ${scriptResult.stringResult}');
    }

    _initialized = true;
  }

  /// 调用 JS 导出的全局函数，返回 JSON 可序列化值。
  ///
  /// - 同步导出函数：直接返回返回值
  /// - async 导出函数（返回 Promise）：驱动事件循环并 await 结果（5s 超时）
  /// - JS 抛错：抛 [JsChannelException]
  Future<dynamic> call(String fn, [List<dynamic> args = const []]) async {
    _ensureReady();

    final argStr = args.map((a) => jsonEncode(a)).join(', ');
    final result = _engine!.evaluate('$fn($argStr)');
    if (result.isError) {
      throw JsChannelException(result.stringResult);
    }

    final raw = result.rawResult;
    if (raw is Future) {
      return _awaitJsFuture(raw);
    }
    return raw;
  }

  /// 直接求值表达式（读取脚本全局常量，如 `CHANNEL_META`）。
  ///
  /// 与 [call] 同语义：表达式抛错抛 [JsChannelException]；
  /// 表达式结果为 Promise 时自动 await（5s 超时）。
  Future<dynamic> evaluate(String expression) async {
    _ensureReady();

    final result = _engine!.evaluate(expression);
    if (result.isError) {
      throw JsChannelException(result.stringResult);
    }

    final raw = result.rawResult;
    if (raw is Future) {
      return _awaitJsFuture(raw);
    }
    return raw;
  }

  /// 释放引擎资源
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _initialized = false;
    _engine?.dispose();
    _engine = null;
  }

  // ==================== host API 注册 ====================

  void _registerHostApis(JavascriptRuntime engine) {
    _registerNetworkHost(engine);
    _registerDatabaseHost(engine);
    _registerConfigHost(engine);
    _registerEnvHost(engine);
    _registerLogHost(engine);
    _registerUiHost(engine);
  }

  void _registerNetworkHost(JavascriptRuntime engine) {
    engine.onMessage('host.network.get', (dynamic args) async {
      try {
        final map = _asMap(args);
        final url = map['url']?.toString() ?? '';
        final opts = _asMap(map['opts']);
        final response = await _getDio().get(
          url,
          queryParameters: _asMap(opts['params']),
          options: Options(headers: _asMap(opts['headers'])),
        );
        return _wrapResponse(response);
      } catch (e) {
        _logError('host.network.get 失败: $e');
        return {'ok': false, 'error': e.toString()};
      }
    });

    engine.onMessage('host.network.post', (dynamic args) async {
      try {
        final map = _asMap(args);
        final url = map['url']?.toString() ?? '';
        final opts = _asMap(map['opts']);
        final response = await _getDio().post(
          url,
          queryParameters: _asMap(opts['params']),
          data: opts['body'] ?? opts['json'],
          options: Options(headers: _asMap(opts['headers'])),
        );
        return _wrapResponse(response);
      } catch (e) {
        _logError('host.network.post 失败: $e');
        return {'ok': false, 'error': e.toString()};
      }
    });
  }

  void _registerDatabaseHost(JavascriptRuntime engine) {
    engine.onMessage('host.database.getAppsByChannel', (dynamic args) async {
      try {
        final dao = await _getAppDao();
        final apps = await dao.getAppsByChannel(channelKey);
        return {'ok': true, 'data': apps.map(_channelAppToJson).toList()};
      } catch (e) {
        _logError('host.database.getAppsByChannel 失败: $e');
        return {'ok': false, 'error': e.toString()};
      }
    });

    engine.onMessage('host.database.getApp', (dynamic args) async {
      try {
        final appId = _asMap(args)['appId']?.toString() ?? '';
        // 强制 channelKey = 当前渠道，脚本无法访问其他渠道数据
        final dao = await _getAppDao();
        final app = await dao.getApp(appId, channelKey);
        return {'ok': true, 'data': app == null ? null : _channelAppToJson(app)};
      } catch (e) {
        _logError('host.database.getApp 失败: $e');
        return {'ok': false, 'error': e.toString()};
      }
    });

    engine.onMessage('host.database.insertApps', (dynamic args) async {
      try {
        final apps = _asList(_asMap(args)['apps']);
        // 强制 channelKey = 当前渠道（忽略脚本传入的 channelCode）
        final entities = apps.map(_toChannelAddedApp).toList();
        final dao = await _getAppDao();
        await dao.insertApps(entities);
        return {'ok': true, 'data': entities.length};
      } catch (e) {
        _logError('host.database.insertApps 失败: $e');
        return {'ok': false, 'error': e.toString()};
      }
    });
  }

  void _registerConfigHost(JavascriptRuntime engine) {
    engine.onMessage('host.config.get', (dynamic args) async {
      try {
        final key = _asMap(args)['key']?.toString() ?? '';
        final value = await _getConfigGetter()(key);
        return {'ok': true, 'data': value};
      } catch (e) {
        _logError('host.config.get 失败: $e');
        return {'ok': false, 'error': e.toString()};
      }
    });
  }

  /// host.env：渠道隔离的环境变量只读快照（get/all/has，同步回调无需 await）
  void _registerEnvHost(JavascriptRuntime engine) {
    engine.onMessage('host.env.get', (dynamic args) {
      final name = _asMap(args)['name']?.toString() ?? '';
      return {'ok': true, 'data': _env[name]};
    });

    engine.onMessage('host.env.all', (dynamic args) {
      return {'ok': true, 'data': Map<String, dynamic>.of(_env)};
    });

    engine.onMessage('host.env.has', (dynamic args) {
      final name = _asMap(args)['name']?.toString() ?? '';
      return {'ok': true, 'data': _env.containsKey(name)};
    });
  }

  void _registerLogHost(JavascriptRuntime engine) {
    engine.onMessage('host.log.info', (dynamic args) {
      _logInfo(_asMap(args)['msg']?.toString() ?? '');
      return {'ok': true};
    });
    engine.onMessage('host.log.error', (dynamic args) {
      _logError(_asMap(args)['msg']?.toString() ?? '');
      return {'ok': true};
    });
  }

  /// host.ui：Flutter UI 能力注入（Hybrid 架构，runtime 不依赖 UI/context）。
  /// 实现由调用方（JSChannel/详情页）通过构造注入，未注入 → {ok:false} 提示。
  void _registerUiHost(JavascriptRuntime engine) {
    // host.ui.showVersionPicker(options) → Promise<{env, version} | null>
    // options: {title, envs:[], versions:[{version, envs, buildCount}], currentEnv, currentVersion}
    engine.onMessage('host.ui.showVersionPicker', (dynamic args) async {
      try {
        final opts = _asMap(args['options'] ?? args);
        final cb = _uiShowVersionPickerOverride;
        if (cb == null) {
          return {'ok': false, 'error': 'host.ui.showVersionPicker 未注册'};
        }
        final sel = await cb(opts);
        return {'ok': true, 'data': sel};
      } catch (e) {
        _logError('host.ui.showVersionPicker 失败: $e');
        return {'ok': false, 'error': e.toString()};
      }
    });
    // host.ui.refreshDetail(params) → 刷新详情页
    // params: {appId, env, version}
    engine.onMessage('host.ui.refreshDetail', (dynamic args) async {
      try {
        final params = _asMap(args['params'] ?? args);
        final cb = _uiRefreshDetailOverride;
        if (cb == null) {
          return {'ok': false, 'error': 'host.ui.refreshDetail 未注册'};
        }
        await cb(params);
        return {'ok': true};
      } catch (e) {
        _logError('host.ui.refreshDetail 失败: $e');
        return {'ok': false, 'error': e.toString()};
      }
    });
  }

  // ==================== 依赖解析 ====================

  Dio _getDio() => _dioOverride ?? DioClient().get();

  Future<ChannelAddedAppDao> _getAppDao() async =>
      _appDaoOverride ?? (await ChannelDatabaseManager.instance).dao;

  Future<Object?> Function(String key) _getConfigGetter() =>
      _configGetterOverride ?? ConfigService.instance.get;

  /// 从 envReader 快照 env（未注入 → 空 map）
  Map<String, String> _readEnv() =>
      _envReaderOverride?.call() ?? const <String, String>{};

  void _logInfo(String message) {
    final override = _logInfoOverride;
    if (override != null) {
      override(message);
    } else {
      appLog.info('[js:$channelKey] $message');
    }
  }

  void _logError(String message) {
    final override = _logErrorOverride;
    if (override != null) {
      override(message);
    } else {
      appLog.error('[js:$channelKey] $message');
    }
  }

  // ==================== 工具 ====================

  void _ensureReady() {
    if (_disposed) {
      throw JsChannelException('runtime 已释放');
    }
    if (!_initialized) {
      throw JsChannelException('runtime 未初始化，请先调用 initialize()');
    }
  }

  /// 驱动 QuickJS 事件循环直到 JS Promise 完成（5s 超时保护）
  ///
  /// 注意：外层 completer 的 future 必须先挂 no-op 错误监听——
  /// JS Promise reject 后错误经微任务传播，而事件循环驱动中有
  /// `Future.delayed`（timer 间隙会让微任务先排空），若 await 尚未挂上
  /// 监听，错误会被 zone 报为 unhandled（flutter_test 直接判测试失败），
  /// 尽管调用方随后能 catch 到。先挂 catchError 可保证错误始终有监听。
  Future<dynamic> _awaitJsFuture(Future<dynamic> future) async {
    final completer = Completer<dynamic>();
    // 立即挂 no-op 错误监听（防 unhandled 误报），不影响后续 await 重新抛出
    completer.future.catchError((_) {});
    future.then(completer.complete, onError: completer.completeError);

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!completer.isCompleted) {
      if (DateTime.now().isAfter(deadline)) {
        throw JsChannelException('JS Promise 超时（5s）未完成');
      }
      _engine?.executePendingJob();
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return completer.future;
  }

  Map<String, dynamic> _wrapResponse(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    return {
      'ok': status >= 200 && status < 300,
      'status': status,
      'data': _decodeData(response.data),
    };
  }

  dynamic _decodeData(dynamic data) {
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return data;
      }
    }
    return data;
  }

  Map<String, dynamic> _channelAppToJson(ChannelAddedApp app) {
    return {
      'appId': app.appId,
      'name': app.name,
      'user': app.user,
      'repositories': app.repositories,
      'apprepo': app.apprepo,
      'icon': app.icon,
      'description': app.description,
      'category': app.category,
      'addTime': app.addTime,
      'channelCode': app.channelCode,
      'extra': app.getExtraData(),
    };
  }

  /// 从 JS 传入的 map 构造 [ChannelAddedApp]，强制 channelCode = 当前渠道
  ChannelAddedApp _toChannelAddedApp(dynamic raw) {
    final map = _asMap(raw);
    return ChannelAddedApp(
      appId: map['appId']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      user: map['user']?.toString() ?? '',
      repositories: map['repositories']?.toString() ?? '',
      apprepo: map['apprepo']?.toString(),
      icon: map['icon']?.toString() ?? '',
      description: map['description']?.toString() ?? '',
      category: map['category']?.toString(),
      addTime: (map['addTime'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      channelCode: channelKey, // 强制当前渠道（数据隔离核心）
      extra: map['extra'] != null ? jsonEncode(map['extra']) : null,
    );
  }

  Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  List<dynamic> _asList(dynamic value) {
    if (value is List) return value;
    return const [];
  }

  /// JS 侧 host 包装层：把 sendMessage 桥封装成友好的 host.xxx API
  static const String _hostPrefixJs = '''
var host = {
  network: {
    get: function(url, opts) {
      return sendMessage('host.network.get', JSON.stringify({url: url, opts: opts || {}}));
    },
    post: function(url, opts) {
      return sendMessage('host.network.post', JSON.stringify({url: url, opts: opts || {}}));
    }
  },
  database: {
    getAppsByChannel: function() {
      return sendMessage('host.database.getAppsByChannel', '{}');
    },
    getApp: function(appId) {
      return sendMessage('host.database.getApp', JSON.stringify({appId: appId}));
    },
    insertApps: function(apps) {
      return sendMessage('host.database.insertApps', JSON.stringify({apps: apps}));
    }
  },
  config: {
    get: function(key) {
      return sendMessage('host.config.get', JSON.stringify({key: key}));
    }
  },
  env: {
    get: function(name) {
      return sendMessage('host.env.get', JSON.stringify({name: name}));
    },
    all: function() {
      return sendMessage('host.env.all', '{}');
    },
    has: function(name) {
      return sendMessage('host.env.has', JSON.stringify({name: name}));
    }
  },
  log: {
    info: function(msg) {
      return sendMessage('host.log.info', JSON.stringify({msg: msg}));
    },
    error: function(msg) {
      return sendMessage('host.log.error', JSON.stringify({msg: msg}));
    }
  },
  ui: {
    showVersionPicker: function(options) {
      return sendMessage('host.ui.showVersionPicker', JSON.stringify({options: options || {}}));
    },
    refreshDetail: function(params) {
      return sendMessage('host.ui.refreshDetail', JSON.stringify({params: params || {}}));
    }
  }
};
''';
}
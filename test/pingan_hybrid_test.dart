import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';

/// pingan.js Hybrid 详情页测试（Wave C，zip 渠道包 detail.js）：detailMenu 声明 Actions +
/// jsswitchVersion 用 host.ui 驱动版本选择/刷新 + jsBuildHistory 用 host.ui 驱动构建历史选择。
///
/// 与 pingan_script_test.dart 同款假网络/Dao 注入；本文件聚焦 host.ui：
/// uiShowVersionPicker / uiRefreshDetail / uiShowBuildHistory 回调捕获参数断言，不发真实网络。
///
/// 注意：Hybrid 详情方法（detailMenu/jsswitchVersion/jsBuildHistory）由页面级
/// JsDetailChannel 消费 → 本测试读取 scripts/channels/pingan.zip 解出的 detail.js
/// （flutter test 以项目根为 cwd）。
///
/// 契约（脚本侧）：
/// - main('detailMenu', {appId}) → {ok, data:[{action, jscall, clickIsDimiss}]}
/// - main('jsswitchVersion', {appId}) → 拉版本选项 → showVersionPicker →
///   用户选 {env, version} → refreshDetail({appId, env, version}) → {ok:true, data:true}
///   取消/能力未注册 → 静默 {ok:true, data:null}
/// - main('jsBuildHistory', {appId}) → 拉最新版本 builds → showBuildHistory →
///   用户选 build → refreshDetail({appId, env, version, build}) → {ok:true, data:true}
///   取消/能力未注册/失败 → 静默 {ok:true, data:null}；无版本/无构建 → {ok:false, error}

const String _channelKey = 'js_pingan_hybrid_test';

/// 内存版 ChannelAddedAppDao（测试用；resolveAppName 查库，空库 → appId 原样）
class _FakeAppDao implements ChannelAddedAppDao {
  final List<ChannelAddedApp> _apps = [];

  @override
  Future<void> insertApp(ChannelAddedApp app) async {
    _apps.removeWhere(
        (a) => a.channelCode == app.channelCode && a.appId == app.appId);
    _apps.add(app);
  }

  @override
  Future<void> insertApps(List<ChannelAddedApp> apps) async {
    for (final app in apps) {
      await insertApp(app);
    }
  }

  @override
  Future<List<ChannelAddedApp>> getAppsByChannel(String channelCode) async =>
      _apps.where((a) => a.channelCode == channelCode).toList();

  @override
  Future<ChannelAddedApp?> getApp(String appId, String channelCode) async {
    for (final a in _apps) {
      if (a.appId == appId && a.channelCode == channelCode) return a;
    }
    return null;
  }

  @override
  Future<void> removeApp(String appId, String channelCode) async {
    _apps.removeWhere((a) => a.appId == appId && a.channelCode == channelCode);
  }

  @override
  Future<int?> getCountByChannel(String channelCode) async =>
      _apps.where((a) => a.channelCode == channelCode).length;

  @override
  Future<void> clearChannel(String channelCode) async {
    _apps.removeWhere((a) => a.channelCode == channelCode);
  }

  @override
  Future<List<ChannelAddedApp>> getAllApps() async => List.of(_apps);

  @override
  Future<int?> getTotalCount() async => _apps.length;
}

/// 固定响应 Dio adapter（测试用，按 path 路由，记录请求）
class _FakeDioAdapter implements HttpClientAdapter {
  final Map<String, dynamic> Function(RequestOptions options) handler;
  final List<String> requestLog;

  _FakeDioAdapter(this.handler, this.requestLog);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestLog.add('${options.method} ${options.path}'
        '&appname=${options.queryParameters['appname'] ?? '-'}'
        '&version=${options.queryParameters['version'] ?? '-'}'
        '&env=${options.queryParameters['env'] ?? '-'}');
    final data = handler(options);
    if (data['__status'] != null) {
      final status = data.remove('__status') as int;
      return ResponseBody.fromString(
        jsonEncode(data),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// build-list 假响应：按请求 env 返回一个 android 版本组（version 8.9.0）
Map<String, dynamic> buildListForEnv(String env) {
  return {
    'appLogo': '/logo/app.png',
    'buildList': [
      {
        '_id': 'bg-$env',
        'version': '8.9.0',
        'platform': 'android',
        'env': env,
        'publishedAt': 1700000000000,
        'builds': [
          {
            'identifier': 'com.pingan.app',
            'versionname': '8.9.0',
            'num': 1,
            'size': 100,
            'fileurl': ['/apk/com.pingan.app-8.9.0.apk'],
          },
        ],
      },
    ],
  };
}

/// 默认 handler：build-list 按 env 返回；其余 path 未命中
Map<String, dynamic> defaultHandler(RequestOptions options) {
  if (options.path.contains('/sunflower/i/build-list')) {
    final env = options.queryParameters['env']?.toString() ?? 'sit';
    return buildListForEnv(env);
  }
  return {'code': -1};
}

void main() {
  late _FakeAppDao appDao;
  late List<String> requestLog;
  late List<String> logMessages;

  setUp(() {
    appDao = _FakeAppDao();
    requestLog = [];
    logMessages = [];
  });

  late String script;
  setUpAll(() {
    final zipBytes = File('scripts/channels/pingan.zip').readAsBytesSync();
    final pkg = ChannelPackage.decode(zipBytes);
    expect(pkg, isNotNull, reason: 'pingan.zip 应可解析（entry.js 必须）');
    script = pkg!.detailScript!;
    expect(script, contains('getDetailMenu'), reason: 'detail.js 应包含 Hybrid detailMenu');
  });

  JsChannelRuntime buildRuntime({
    Map<String, dynamic> Function(RequestOptions options)? handler,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowVersionPicker,
    Future<void> Function(Map<String, dynamic> params)? uiRefreshDetail,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic> options)?
        uiShowBuildHistory,
  }) {
    final dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter(handler ?? defaultHandler, requestLog);
    return JsChannelRuntime(
      channelKey: _channelKey,
      script: script,
      dio: dio,
      appDao: appDao,
      logInfo: (msg) => logMessages.add('info: $msg'),
      logError: (msg) => logMessages.add('error: $msg'),
      uiShowVersionPicker: uiShowVersionPicker,
      uiRefreshDetail: uiRefreshDetail,
      uiShowBuildHistory: uiShowBuildHistory,
    );
  }

  group('pingan.js Hybrid 详情页', () {
    test('① detailMenu 返回 Actions 声明（切换版本/历史构建，clickIsDimiss=true）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', ['detailMenu', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final actions = result['data'] as List;
      expect(actions.length, 2);

      final switchAction = actions[0] as Map;
      expect(switchAction['action'], '切换版本');
      expect(switchAction['jscall'], 'jsswitchVersion');
      expect(switchAction['clickIsDimiss'], isTrue);

      final historyAction = actions[1] as Map;
      expect(historyAction['action'], '历史构建');
      expect(historyAction['jscall'], 'jsBuildHistory');
      expect(historyAction['clickIsDimiss'], isTrue);

      // 纯声明：不发任何网络请求
      expect(requestLog, isEmpty);

      await runtime.dispose();
    });

    test('② jsswitchVersion：用户选 {env:uat, version:8.9.0} → refreshDetail 参数正确 + ok:true', () async {
      Map<String, dynamic>? pickerOptions;
      Map<String, dynamic>? refreshParams;
      final runtime = buildRuntime(
        uiShowVersionPicker: (options) async {
          pickerOptions = options;
          return {'env': 'uat', 'version': '8.9.0'};
        },
        uiRefreshDetail: (params) async {
          refreshParams = params;
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['jsswitchVersion', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isTrue);

      // 选择框收到的 options 正确（来自 getVersionOptions：envs 全量 5 个，当前 uat）
      expect(pickerOptions, isNotNull);
      expect(pickerOptions!['title'], '切换版本');
      expect(pickerOptions!['envs'], ['sit', 'uat', 'prd', 'rge', 'tmp']);
      expect(pickerOptions!['currentEnv'], 'uat');
      expect(pickerOptions!['currentVersion'], '8.9.0');
      final versions = pickerOptions!['versions'] as List;
      expect(versions.length, 1);
      expect((versions.first as Map)['version'], '8.9.0');

      // refreshDetail 收到用户选择的 env+version（Flutter 侧据此拉单版本数据更新）
      expect(refreshParams, isNotNull);
      expect(refreshParams!['appId'], 'app-1');
      expect(refreshParams!['env'], 'uat');
      expect(refreshParams!['version'], '8.9.0');

      // 只拉了一次 build-list（当前 env=uat 单次，Wave 拉取优化）
      final buildRequests = requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('env=uat'));

      await runtime.dispose();
    });

    test('③ jsswitchVersion：用户取消（data:null）→ refreshDetail 不被调 + 静默 ok:true', () async {
      var refreshCalled = false;
      final runtime = buildRuntime(
        uiShowVersionPicker: (options) async => null,
        uiRefreshDetail: (params) async => refreshCalled = true,
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['jsswitchVersion', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(refreshCalled, isFalse);

      await runtime.dispose();
    });

    test('④ jsswitchVersion：showVersionPicker 失败（回调抛异常）→ 静默 ok:true 不崩', () async {
      var refreshCalled = false;
      final runtime = buildRuntime(
        uiShowVersionPicker: (options) async => throw Exception('picker broken'),
        uiRefreshDetail: (params) async => refreshCalled = true,
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['jsswitchVersion', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(refreshCalled, isFalse);
      // 异常被 runtime 捕获记日志，脚本不抛
      expect(logMessages.any((m) => m.contains('showVersionPicker 失败')), isTrue);

      await runtime.dispose();
    });

    test('⑤ jsswitchVersion：能力未注册（未注入回调）→ 静默 ok:true', () async {
      final runtime = buildRuntime(); // 未注入 uiShowVersionPicker
      await runtime.initialize();

      final result = await runtime.call('main', ['jsswitchVersion', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);

      await runtime.dispose();
    });

    test('⑥ jsswitchVersion：getVersionOptions 失败 → {ok:false, error} 不弹框', () async {
      var pickerCalled = false;
      final runtime = buildRuntime(
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return {'__status': 500, 'msg': 'boom'};
          }
          return defaultHandler(options);
        },
        uiShowVersionPicker: (options) async {
          pickerCalled = true;
          return {'env': 'sit', 'version': '8.9.0'};
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['jsswitchVersion', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], '获取版本选项失败');
      expect(pickerCalled, isFalse);

      await runtime.dispose();
    });

    test('⑦ jsBuildHistory：用户选中构建 → showBuildHistory 收到 options（builds）→ refreshDetail 收到 {appId, env, version, build}', () async {
      Map<String, dynamic>? historyOptions;
      Map<String, dynamic>? refreshParams;
      final runtime = buildRuntime(
        uiShowBuildHistory: (options) async {
          historyOptions = options;
          return {'num': 1, 'ipaName': '8.9.0.apk'};
        },
        uiRefreshDetail: (params) async {
          refreshParams = params;
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['jsBuildHistory', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isTrue);

      // 选择器收到的 options 正确：最新版本（8.9.0）+ 凭证默认 env（无 PINGAN_ENV → uat）+ builds
      expect(historyOptions, isNotNull);
      expect(historyOptions!['version'], '8.9.0');
      expect(historyOptions!['env'], 'uat');
      final builds = historyOptions!['builds'] as List;
      expect(builds.length, 1);
      final build0 = builds.first as Map;
      expect(build0['num'], 1);
      expect(build0['ipaName'], '8.9.0.apk');
      expect(build0['size'], 100);

      // refreshDetail 收到选中构建（Flutter 侧据此切换到该构建的 APK）
      expect(refreshParams, isNotNull);
      expect(refreshParams!['appId'], 'app-1');
      expect(refreshParams!['env'], 'uat');
      expect(refreshParams!['version'], '8.9.0');
      final build = refreshParams!['build'] as Map;
      expect(build['num'], 1);
      expect(build['ipaName'], '8.9.0.apk');

      // 两次 build-list：getVersionOptions（env=uat）+ getBuildHistory（version=8.9.0）
      final buildRequests = requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 2);
      expect(buildRequests[0], contains('env=uat'));
      expect(buildRequests[1], contains('version=8.9.0'));

      await runtime.dispose();
    });

    test('⑧ jsBuildHistory：用户取消（data:null）→ refreshDetail 不被调 + 静默 ok:true', () async {
      var refreshCalled = false;
      final runtime = buildRuntime(
        uiShowBuildHistory: (options) async => null,
        uiRefreshDetail: (params) async => refreshCalled = true,
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['jsBuildHistory', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(refreshCalled, isFalse);

      await runtime.dispose();
    });

    test('⑨ jsBuildHistory：showBuildHistory 失败（回调抛异常）→ 静默 ok:true 不崩', () async {
      var refreshCalled = false;
      final runtime = buildRuntime(
        uiShowBuildHistory: (options) async => throw Exception('sheet broken'),
        uiRefreshDetail: (params) async => refreshCalled = true,
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['jsBuildHistory', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(refreshCalled, isFalse);
      // 异常被 runtime 捕获记日志，脚本不抛
      expect(logMessages.any((m) => m.contains('showBuildHistory 失败')), isTrue);

      await runtime.dispose();
    });

    test('⑩ jsBuildHistory：能力未注册（未注入回调）→ 静默 ok:true', () async {
      final runtime = buildRuntime(); // 未注入 uiShowBuildHistory
      await runtime.initialize();

      final result = await runtime.call('main', ['jsBuildHistory', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);

      await runtime.dispose();
    });

    test('⑪ jsBuildHistory：无版本数据（buildList 空）→ {ok:false, error: 无版本数据}', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {'appLogo': '', 'buildList': <Object>[]};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['jsBuildHistory', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], '无版本数据');

      await runtime.dispose();
    });

    test('⑫ jsBuildHistory：无构建记录（builds 空）→ {ok:false, error: 无构建记录}', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-empty',
                'version': '8.9.0',
                'platform': 'android',
                'env': 'uat',
                'publishedAt': 1700000000000,
                'builds': <Object>[],
              },
            ],
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['jsBuildHistory', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], '无构建记录');

      await runtime.dispose();
    });
  });
}

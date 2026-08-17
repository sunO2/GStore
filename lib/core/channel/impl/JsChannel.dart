import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/proxy/ChannelDetailProxy.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;

/// 脚本渠道 meta（脚本可选 `const CHANNEL_META = { name, description, icon }`）
class _ChannelMeta {
  final String? name;
  final String? description;
  final String? icon;

  const _ChannelMeta({this.name, this.description, this.icon});
}

/// 脚本化渠道：一个 JS 脚本 = 一个渠道，实现 [IChannel] 语义。
///
/// ## 脚本契约
/// 脚本导出统一分发器 `main(method, params)` → 返回 `{ ok, data }` 或直接数据：
/// - `searchApps({keyword})` / `getAllApps()` → AppInfo JSON 数组
/// - `getAppInfo({appId})` / `getAppDetail({appId})` / `checkAppUpdate({appId})` → AppInfo JSON 对象 或 null
/// - `checkUpdate()` / `doUpdate()` → bool
/// - `getConfig()` → `{ version, proxy }`
/// - 可选 `const CHANNEL_META = { name, description, icon }`
///
/// AppInfo JSON 字段（与 db.AppInfo 同构）：appId/name/user/repositories/icon/des/readme/category/extra；
/// user/repositories 脚本可不提供，JSChannel 兜底填 channelKey；extra 透传（渠道特性数据零限制）。
///
/// ## 数据隔离
/// 所有落库/查库均以 [channelKey]（channelCode 字段）为界；host.database 侧已由
/// [JsChannelRuntime] 强制当前渠道，脚本无法读写其他渠道数据。
///
/// ## 降级策略
/// 脚本未实现某方法（main 无对应 case 返回 null）时：
/// - getAllApps / getAppInfo → 查本渠道库（channelKey）
/// - doUpdate → 从脚本拉全量 → insertApps 落库（channelKey）
/// - checkUpdate / checkAppUpdate → 无更新 / 查库
/// - searchApps / getAppDetail / getConfig → failure
///
/// ## 环境变量（host.env）
/// 脚本可用 `host.env.get(name)` / `host.env.all()` / `host.env.has(name)` 读取
/// 环境变量（如 PINGAN_USER / PINGAN_PASS 用户名密码）。env 由用户配置，
/// 不进脚本硬编码、不进应用二进制；按渠道隔离持久化到 ConfigStore
/// （键 `channel_env_<channelKey>`，默认敏感路由到加密存储）。
/// [setEnv] / [removeEnv] 持久化后热更新 runtime 快照（[JsChannelRuntime.updateEnv]），
/// 脚本下次读取即生效，无需重建引擎。
class JsChannel extends IChannel implements DynamicChannel {
  /// 渠道唯一标识（如 'js.vivo'），数据隔离键 + AppInfo.channelCode
  @override
  final String channelKey;

  /// 脚本源码（只读，供加载器幂等比对脚本是否变更）
  String get scriptSource => _runtime.script;

  final int? _priority;
  final bool _enabled;
  final ChannelAddedAppDao? _appDaoOverride;

  /// 环境变量持久化存储（渠道隔离；默认 ConfigStore 实现）
  final JsChannelEnvStore _envStore;

  late ChannelInfo _info;
  _ChannelMeta? _meta;

  final JsChannelRuntime _runtime;

  @override
  bool isInitialized = false;

  JsChannel({
    required this.channelKey,
    required String script,
    Dio? dio,
    ChannelAddedAppDao? appDao,
    Future<Object?> Function(String key)? configGetter,
    JsChannelEnvStore? envStore,
    void Function(String message)? logInfo,
    void Function(String message)? logError,
    int? priority,
    bool enabled = true,
  })  : _priority = priority,
        _enabled = enabled,
        _appDaoOverride = appDao,
        _envStore = envStore ?? ConfigJsChannelEnvStore(channelKey),
        _runtime = JsChannelRuntime(
          channelKey: channelKey,
          script: script,
          dio: dio,
          appDao: appDao,
          configGetter: configGetter,
          logInfo: logInfo,
          logError: logError,
        ) {
    _info = ChannelInfo(
      type: ChannelType.custom,
      name: channelKey,
      description: '脚本化渠道',
      priority: priority,
      enabled: enabled,
    );
  }

  // ==================== 元信息 ====================

  /// ChannelInfo 无 code 字段，渠道标识由 [channelKey] 承担（DynamicChannel 暴露）
  @override
  ChannelInfo get info => _info;

  // ==================== 生命周期 ====================

  @override
  Future<void> initialize() async {
    if (isInitialized) return;
    // 把持久化的渠道 env 注入 runtime 快照（渠道隔离；脚本经 host.env 读取）。
    // env 读取失败不阻塞渠道初始化（降级为空 env，脚本 host.env 读到 null/空）。
    try {
      _runtime.updateEnv(await _envStore.load());
    } catch (e) {
      _logError('读取渠道 env 失败，降级为空: $e');
      _runtime.updateEnv(const {});
    }
    await _runtime.initialize();
    await _readMeta();
    _rebuildInfo();
    isInitialized = true;
    _logInfo('初始化完成（${_info.name}）');
  }

  /// 读取脚本可选 `CHANNEL_META` 常量（失败静默降级为 channelKey 命名）
  Future<void> _readMeta() async {
    try {
      final raw = await _runtime.evaluate(
        "typeof CHANNEL_META !== 'undefined' ? CHANNEL_META : null",
      );
      if (raw is Map) {
        final map = _stringKeyedMap(raw);
        _meta = _ChannelMeta(
          name: map['name']?.toString(),
          description: map['description']?.toString(),
          icon: map['icon']?.toString(),
        );
      }
    } on JsChannelException catch (e) {
      _logError('读取 CHANNEL_META 失败: $e');
    }
  }

  void _rebuildInfo() {
    final meta = _meta;
    final name = (meta?.name?.isNotEmpty ?? false) ? meta!.name! : channelKey;
    final description = (meta?.description?.isNotEmpty ?? false)
        ? meta!.description!
        : '脚本化渠道';
    _info = ChannelInfo(
      type: ChannelType.custom,
      name: name,
      description: description,
      priority: _priority,
      enabled: _enabled,
    );
  }

  @override
  Future<void> dispose() async {
    await _runtime.dispose();
    isInitialized = false;
  }

  // ==================== 基础 ====================

  @override
  Future<bool> checkAvailable() async {
    try {
      if (!isInitialized) {
        await initialize();
      }
      return isInitialized;
    } catch (e) {
      _logError('checkAvailable 失败: $e');
      return false;
    }
  }

  @override
  Widget? getAddAppWidget(BuildContext context, Function(AppSummary) onAppAdded,
          {VoidCallback? onAppSaved}) =>
      null;

  // ==================== 应用信息查询 ====================

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({
    bool forceRefresh = false,
  }) async {
    try {
      final data = await _callMain('getAllApps');
      final apps = _appsFromScript(data);
      if (apps != null) {
        return ChannelResult.success(
          data: apps,
          from: ChannelType.custom,
          fromCache: false,
          metadata: {'count': apps.length},
        );
      }
      // 脚本未实现 → 查本渠道库（channelKey 隔离）
      final saved = await (await _getAppDao()).getAppsByChannel(channelKey);
      return ChannelResult.success(
        data: saved.map(AppSummary.fromChannelAddedApp).toList(),
        from: ChannelType.custom,
        fromCache: true,
      );
    } catch (e) {
      _logError('getAllApps 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async {
    try {
      final data = await _callMain('getAppInfo', {'appId': appId});
      final app = _appFromJson(data);
      if (app != null) {
        return ChannelResult.success(
          data: app,
          from: ChannelType.custom,
          fromCache: false,
        );
      }
      // 脚本无结果/未实现 → 查本渠道库
      final saved = await (await _getAppDao()).getApp(appId, channelKey);
      return ChannelResult.success(
        data: saved == null ? null : AppSummary.fromChannelAddedApp(saved),
        from: ChannelType.custom,
        fromCache: true,
      );
    } catch (e) {
      _logError('getAppInfo 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async {
    try {
      final data = await _callMain('getAppDetail', {'appId': appId});
      if (data is Map) {
        return ChannelResult.success(
          data: JsChannelDetailProxy(_stringKeyedMap(data)),
          from: ChannelType.custom,
          fromCache: false,
        );
      }
      return ChannelResult.failure(
        from: ChannelType.custom,
        error: '脚本未实现 getAppDetail',
      );
    } catch (e) {
      _logError('getAppDetail 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async {
    try {
      final data = await _callMain('searchApps', {'keyword': keyword});
      final apps = _appsFromScript(data);
      if (apps != null) {
        return ChannelResult.success(
          data: apps,
          from: ChannelType.custom,
          fromCache: false,
          metadata: {'keyword': keyword, 'count': apps.length},
        );
      }
      return ChannelResult.failure(
        from: ChannelType.custom,
        error: '脚本未实现 searchApps 或调用失败',
      );
    } catch (e) {
      _logError('searchApps 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async {
    // 脚本渠道按分类搜索语义由 searchApps 承担
    return ChannelResult.success(
      data: [],
      from: ChannelType.custom,
      metadata: {'message': '脚本渠道不支持按分类搜索，请使用搜索功能'},
    );
  }

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async {
    return ChannelResult.success(data: [], from: ChannelType.custom);
  }

  // ==================== 更新 ====================

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(String appId) async {
    try {
      final data = await _callMain('checkAppUpdate', {'appId': appId});
      if (data is Map) {
        final map = _stringKeyedMap(data);
        final id = map['appId']?.toString() ?? appId;
        final name = map['name']?.toString() ?? id;
        return ChannelResult.success(
          data: AppUpdateCheckResult(
            appId: id,
            packageName: map['packageName']?.toString() ?? id,
            name: name,
            icon: map['icon']?.toString(),
            latestVersion: map['version']?.toString(),
            latestDownload: null,
            detail: JsChannelDetailProxy(map),
          ),
          from: ChannelType.custom,
        );
      }
      // 脚本未实现 → 查本渠道库（无版本信息视为无更新）
      final saved = await (await _getAppDao()).getApp(appId, channelKey);
      if (saved == null) {
        return ChannelResult.failure(
          from: ChannelType.custom,
          error: '脚本未实现 checkAppUpdate 且渠道库无该应用',
        );
      }
      final summary = AppSummary.fromChannelAddedApp(saved);
      return ChannelResult.success(
        data: AppUpdateCheckResult(
          appId: appId,
          packageName: summary.packageName ?? appId,
          name: summary.name,
          icon: summary.icon,
          detail: _detailFromSummary(summary),
        ),
        from: ChannelType.custom,
      );
    } catch (e) {
      _logError('checkAppUpdate 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  @override
  Future<ChannelResult<bool>> checkUpdate() async {
    try {
      final data = await _callMain('checkUpdate');
      if (data is bool) {
        return ChannelResult.success(data: data, from: ChannelType.custom);
      }
      // 脚本未实现 → 视为无更新
      return ChannelResult.success(data: false, from: ChannelType.custom);
    } catch (e) {
      _logError('checkUpdate 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async {
    try {
      final data = await _callMain('doUpdate');
      if (data is bool) {
        return ChannelResult.success(data: data, from: ChannelType.custom);
      }
      // 脚本未实现 doUpdate → 从脚本拉全量 → insertApps 落库（channelKey）
      final all = await _callMain('getAllApps');
      final apps = _appsFromScript(all);
      if (apps == null) {
        return ChannelResult.failure(
          from: ChannelType.custom,
          error: '脚本未实现 doUpdate/getAllApps',
        );
      }
      await _persistApps(apps, onProgress: onProgress);
      return ChannelResult.success(data: true, from: ChannelType.custom);
    } catch (e) {
      _logError('doUpdate 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => appInfo.appId;

  // ==================== 渠道库操作（channelKey 隔离） ====================

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async {
    try {
      await _persistApps([app]);
      return ChannelResult.success(data: null, from: ChannelType.custom);
    } catch (e) {
      _logError('addApp 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  @override
  Future<ChannelResult<void>> removeApp(String appId) async {
    try {
      await (await _getAppDao()).removeApp(appId, channelKey);
      return ChannelResult.success(data: null, from: ChannelType.custom);
    } catch (e) {
      _logError('removeApp 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  // ==================== 配置与缓存 ====================

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async {
    try {
      final data = await _callMain('getConfig');
      if (data is Map) {
        final map = _stringKeyedMap(data);
        return ChannelResult.success(
          data: db.AppInfoConfig(
            map['version']?.toString() ?? '',
            map['proxy']?.toString(),
          ),
          from: ChannelType.custom,
        );
      }
      return ChannelResult.failure(
        from: ChannelType.custom,
        error: '脚本未实现 getConfig',
      );
    } catch (e) {
      _logError('getConfig 失败: $e');
      return ChannelResult.failure(from: ChannelType.custom, error: e.toString());
    }
  }

  @override
  Future<void> clearCache() async {
    // 脚本渠道无缓存
  }

  @override
  Future<int> getCacheSize() async => 0;

  // ==================== 环境变量（host.env，按渠道持久化） ====================

  /// 设置环境变量：持久化到 [JsChannelEnvStore] + 热更新 runtime 快照。
  ///
  /// 脚本下次 `host.env.get(name)` 立即读到新值，无需重建引擎。
  /// 环境变量不进脚本、不进应用二进制，由用户配置（如 PINGAN_USER/PINGAN_PASS）。
  Future<void> setEnv(String name, String value) async {
    final env = Map<String, String>.from(await _envStore.load());
    env[name] = value;
    await _envStore.save(env);
    _runtime.updateEnv(env);
  }

  /// 删除环境变量（持久化 + 热更新 runtime 快照）
  Future<void> removeEnv(String name) async {
    final env = Map<String, String>.from(await _envStore.load());
    env.remove(name);
    await _envStore.save(env);
    _runtime.updateEnv(env);
  }

  /// 读取当前渠道的全部环境变量（持久化层最新值）
  Future<Map<String, String>> getAllEnv() => _envStore.load();

  // ==================== 脚本调用 ====================

  /// 调用脚本 `main(method, params)`，返回脚本结果 data：
  /// - 返回 `{ok: true, data}` → data
  /// - 返回 `{ok: false}` → null（失败，走调用方兜底）
  /// - 返回其他值 → 原值（null = 未实现）
  /// - JS 抛错（同步/异步 reject）→ null + 日志（不崩）
  Future<dynamic> _callMain(String method, [Map<String, dynamic>? params]) async {
    try {
      final raw = await _runtime.call('main', [
        method,
        params ?? const <String, dynamic>{},
      ]);
      if (raw is Map && raw['ok'] is bool) {
        final ok = raw['ok'] as bool;
        if (ok) return raw['data'];
        _logError('脚本 $method 返回 ok: false');
        return null;
      }
      return raw;
    } catch (e) {
      _logError('脚本 $method 调用失败: $e');
      return null;
    }
  }

  /// 脚本 data → AppSummary 列表；data 非列表 → null（未实现/无效）
  List<AppSummary>? _appsFromScript(dynamic data) {
    if (data is! List) return null;
    final apps = <AppSummary>[];
    for (final item in data) {
      final app = _appFromJson(item);
      if (app != null) {
        apps.add(app);
      } else {
        // 映射校验失败：跳过该条 + 日志
        _logError('脚本返回的 AppInfo 校验失败，已跳过: $item');
      }
    }
    return apps;
  }

  /// AppInfo JSON → AppSummary；user/repositories 缺省兜底 channelKey；校验失败 → null
  AppSummary? _appFromJson(dynamic raw) {
    if (raw is! Map) return null;
    final map = _stringKeyedMap(raw);

    final appId = map['appId']?.toString() ?? '';
    final name = map['name']?.toString() ?? '';
    if (appId.isEmpty || name.isEmpty) return null;

    List<String>? category;
    final categoryRaw = map['category'];
    if (categoryRaw is List) {
      final items = categoryRaw
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      if (items.isNotEmpty) category = items;
    } else if (categoryRaw is String && categoryRaw.trim().isNotEmpty) {
      category = [categoryRaw.trim()];
    }

    Map<String, dynamic>? extra;
    final extraRaw = map['extra'];
    if (extraRaw is Map) {
      extra = _stringKeyedMap(extraRaw);
    }

    final packageName = map['packageName']?.toString() ??
        extra?['packageName']?.toString();

    return AppSummary(
      appId: appId,
      packageName: (packageName != null && packageName.isNotEmpty)
          ? packageName
          : null,
      name: name,
      user: map['user']?.toString() ?? channelKey, // 兜底 channelKey
      repositories: map['repositories']?.toString() ?? channelKey,
      icon: map['icon']?.toString() ?? '',
      des: map['des']?.toString() ?? map['description']?.toString() ?? '',
      readme: map['readme']?.toString(),
      category: category,
      extra: extra,
    );
  }

  /// 落库到本渠道（强制 channelCode = channelKey）
  Future<void> _persistApps(
    List<AppSummary> apps, {
    Function(int current, int total)? onProgress,
  }) async {
    final dao = await _getAppDao();
    final entities = <ChannelAddedApp>[];
    for (var i = 0; i < apps.length; i++) {
      final app = apps[i];
      entities.add(ChannelAddedApp(
        appId: app.appId,
        name: app.name,
        user: app.user,
        repositories: app.repositories,
        icon: app.icon,
        description: app.des,
        category: app.category?.join(','),
        addTime: DateTime.now().millisecondsSinceEpoch,
        channelCode: channelKey, // 强制当前渠道（数据隔离核心）
        extra: app.extra != null ? jsonEncode(app.extra) : null,
      ));
      onProgress?.call(i + 1, apps.length);
    }
    if (entities.isNotEmpty) {
      await dao.insertApps(entities);
    }
  }

  IDetailInfo _detailFromSummary(AppSummary app) {
    return JsChannelDetailProxy(<String, dynamic>{
      'appId': app.appId,
      'name': app.name,
      'icon': app.icon,
      'description': app.des,
      'packageName': app.packageName ?? app.appId,
      'developer': app.user,
      'readme': app.readme,
    });
  }

  Future<ChannelAddedAppDao> _getAppDao() async =>
      _appDaoOverride ?? (await ChannelDatabaseManager.instance).dao;

  Map<String, dynamic> _stringKeyedMap(dynamic value) {
    if (value is! Map) return <String, dynamic>{};
    return value.map((k, v) => MapEntry(k.toString(), v));
  }

  void _logInfo(String message) => appLog.info('[js:$channelKey] $message');

  void _logError(String message) => appLog.error('[js:$channelKey] $message');
}

/// 脚本渠道详情代理：包装脚本 getAppDetail 返回的原始 Map，实现 [IDetailInfo]
class JsChannelDetailProxy extends ChannelDetailProxy {
  JsChannelDetailProxy(super.data);

  @override
  ChannelType get channelType => ChannelType.custom;

  @override
  String get appId => data['appId']?.toString() ?? '';

  @override
  String get name => data['name']?.toString() ?? '';

  @override
  String get appName => name;

  @override
  String get icon => data['icon']?.toString() ?? '';

  @override
  String get description =>
      data['description']?.toString() ?? data['des']?.toString() ?? '';

  @override
  String? get version => data['version']?.toString();

  @override
  String? get developer =>
      data['developer']?.toString() ?? data['user']?.toString();

  @override
  String get packageName =>
      data['packageName']?.toString() ?? (appId.isEmpty ? '' : appId);

  @override
  String? get projectUrl => data['projectUrl']?.toString();

  @override
  String? get readme => data['readme']?.toString() ?? super.readme;

  @override
  List<DownloadInfo> get downloads {
    final raw = data['downloads'];
    if (raw is List) {
      return raw.map((e) {
        if (e is DownloadInfo) return e;
        if (e is Map) {
          return DownloadInfo(
            url: e['url']?.toString() ?? '',
            name: e['name']?.toString() ?? '',
            size: (e['size'] as num?)?.toInt(),
            version: e['version']?.toString(),
            platform: e['platform']?.toString(),
          );
        }
        return DownloadInfo(url: e.toString(), name: e.toString());
      }).toList();
    }
    return const [];
  }

  @override
  List<DetailSection> get sections {
    final raw = data['sections'];
    if (raw is List) {
      final sections = <DetailSection>[];
      for (final e in raw) {
        final label = e.toString();
        for (final section in DetailSection.values) {
          if (section.name == label) {
            sections.add(section);
            break;
          }
        }
      }
      return sections;
    }
    return const [];
  }
}

/// 脚本渠道环境变量存储抽象（渠道隔离：每个渠道独立存储键，env 不串）
abstract class JsChannelEnvStore {
  /// 读取该渠道全部环境变量（无配置 → 空 map）
  Future<Map<String, String>> load();

  /// 全量覆盖保存该渠道环境变量
  Future<void> save(Map<String, String> env);
}

/// 默认实现：ConfigStore 持久化，键 `channel_env_<channelKey>`，值为 JSON map。
///
/// env 可能含凭据（用户名/密码），键默认标记敏感 → 自动路由加密存储。
class ConfigJsChannelEnvStore implements JsChannelEnvStore {
  ConfigJsChannelEnvStore(this.channelKey) {
    ConfigStore.instance.markSensitive(_storageKey);
  }

  /// 渠道唯一标识（如 'js.pingan'），隔离键
  final String channelKey;

  String get _storageKey => 'channel_env_$channelKey';

  @override
  Future<Map<String, String>> load() async {
    final raw = await ConfigStore.instance.readString(_storageKey);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      // 损坏数据：视为空，下次 save 覆盖
    }
    return const {};
  }

  @override
  Future<void> save(Map<String, String> env) async {
    await ConfigStore.instance.writeString(_storageKey, jsonEncode(env));
  }
}

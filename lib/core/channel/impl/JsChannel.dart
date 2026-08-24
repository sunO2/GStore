import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';
import 'package:gstore/core/channel/impl/js_detail_channel.dart';
import 'package:gstore/core/channel/impl/js_script_utils.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';
import 'package:gstore/core/js/js_native_host.dart';
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
/// - `versionOptions({appId})` → `{ envs: [], versions: [{version, envs, buildCount}], currentEnv, currentVersion }`
/// - `switchVersion({appId, env, version})` → 同 getAppDetail 的详情数据
/// - `buildHistory({appId, version, env})` → `{ builds: [{num, publishedAt, size, changelog, installTimes, builtBy, ipaName}] }`
/// - 脚本未实现 → 返回 null（调用方降级）
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

  /// 详情页脚本源码（zip 渠道包 detail.js，可选；缺失 → 详情走原路径/降级）。
  /// 本波仅存储，detail 分发逻辑 Wave 2 使用。
  final String? detailScript;

  /// 渠道包元信息（zip 渠道包 meta.json，可选：name/description/icon）。
  /// 本波仅存储备用；脚本侧 `CHANNEL_META` 仍优先用于命名（见 [_readMeta]）。
  final Map<String, dynamic>? meta;

  /// 渠道包（供 iconBytes 等资源访问；null = 内置渠道无包）
  final ChannelPackage? _pkg;

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
    this.detailScript,
    this.meta,
    ChannelPackage? pkg,
    Dio? dio,
    ChannelAddedAppDao? appDao,
    Future<Object?> Function(String key)? configGetter,
    JsChannelEnvStore? envStore,
    void Function(String message)? logInfo,
    void Function(String message)? logError,
    JSNativeHost? nativeHost,
    int? priority,
    bool enabled = true,
  })  : _pkg = pkg,
        _priority = priority,
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
          nativeHost: nativeHost,
        ) {
    _info = ChannelInfo(
      type: ChannelType.custom,
      name: channelKey,
      description: '脚本化渠道',
      priority: priority,
      enabled: enabled,
    );
  }

  // ==================== host.ui 运行时注入 ====================

  /// 运行时注入 host.native 实现（Hybrid：脚本 `host.native.call(...)` 的
  /// Flutter 实现侧，含 showVersionPicker / showBuildHistory / refreshDetail /
  /// updateDownloadList / showUAPicker 能力）。
  ///
  /// ChannelLoader 创建渠道时无 UI context，由详情页使用渠道时注入
  /// （showMoreActions 内调用），避免改 ChannelLoader 构造。
  /// 转发到 runtime，脚本下次调用立即生效。
  void setNativeHost(JSNativeHost host) => _runtime.setNativeHost(host);

  /// 获取 zip 渠道包内置图标字节。
  /// [path] zip 内相对路径如 'icons/version.png'。
  /// 由 [ChannelPackage.icons] 提供，渠道包无该图标 → null。
  /// 详情页 more actions 的图标渲染经此方法获取。
  Uint8List? iconBytes(String path) => _pkg?.iconBytes(path);

  // ==================== 元信息 ====================

  /// ChannelInfo 无 code 字段，渠道标识由 [channelKey] 承担（DynamicChannel 暴露）
  @override
  ChannelInfo get info => _info;

  // ==================== 生命周期 ====================

  @override
  Future<void> initialize() async {
    if (isInitialized) return;
    await _runtime.initialize();
    // 把持久化的渠道 env 注入 runtime 快照（渠道隔离；脚本经 host.env 读取）。
    // 必须在 _runtime.initialize() 之后：initialize 内部会以 _readEnv() 覆盖快照
    // （entry runtime 无 envReader → 空 map），此处再以持久化 env 覆盖，
    // 否则重启后（新实例 initialize）runtime 快照恒为空 → 脚本 host.env 读不到
    // 已配置的 PINGAN_USER/PINGAN_PASS（详情页"需配置后才能下载"根因）。
    // env 读取失败不阻塞渠道初始化（降级为空 env，脚本 host.env 读到 null/空）。
    try {
      _runtime.updateEnv(await _envStore.load());
    } catch (e) {
      _logError('读取渠道 env 失败，降级为空: $e');
      _runtime.updateEnv(const {});
    }
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
        final map = stringKeyedMap(raw);
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
    // 渠道下线：释放全部 detail runtime（数据/缓存随实例释放）
    for (final detail in _detailChannels.values.toList()) {
      await detail.dispose();
    }
    _detailChannels.clear();
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
      // 只读本地已添加库（和 GitHubChannel 等标准渠道一致）；
      // 脚本 getAllApps 仅供 doUpdate（数据库更新）场景调用，不走发现页。
      final saved = await (await _getAppDao()).getAppsByChannel(channelKey);
      return ChannelResult.success(
        data: saved.map(AppSummary.fromChannelAddedApp).toList(),
        from: ChannelType.custom,
        fromCache: !forceRefresh,
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
    String? version,
  }) async {
    try {
      // 非强制刷新时优先查本地数据库（避免首页加载时对每个应用发起网络请求）
      if (!forceRefresh) {
        try {
          final saved = await (await _getAppDao()).getApp(appId, channelKey);
          if (saved != null) {
            return ChannelResult.success(
              data: AppSummary.fromChannelAddedApp(saved),
              from: ChannelType.custom,
              fromCache: true,
            );
          }
        } catch (_) {
          // 查库失败不阻塞，继续走脚本路径
        }
      }

      // 本地无缓存或强制刷新 → 调脚本获取
      final data = await _callMain('getAppInfo', {
        'appId': appId,
        if (version != null) 'version': version,
      });
      final app = appSummaryFromScript(data, channelKey: channelKey);
      if (app != null) {
        return ChannelResult.success(
          data: app,
          from: ChannelType.custom,
          fromCache: false,
        );
      }
      // 脚本无结果/未实现 → 查本渠道库（兜底）
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
    String? version,
  }) async {
    try {
      final data = await _callMain('getAppDetail', {
        'appId': appId,
        if (version != null) 'version': version,
      });
      if (data is Map) {
        return ChannelResult.success(
          data: JsChannelDetailProxy(stringKeyedMap(data)),
          from: ChannelType.custom,
          fromCache: false,
        );
      }
      return ChannelResult.failure(
        from: ChannelType.custom,
        error: '脚本未返回详情数据（脚本未实现或数据获取失败）',
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
      // 脚本未实现 searchApps → 降级：调脚本 getAllApps 获取全量后本地过滤
      final allData = await _callMain('getAllApps');
      final allApps = _appsFromScript(allData);
      if (allApps != null) {
        final kw = keyword.toLowerCase();
        final filtered = allApps.where((app) {
          final name = app.name.toLowerCase();
          final des = app.des.toLowerCase();
          final appId = app.appId.toLowerCase();
          return name.contains(kw) || des.contains(kw) || appId.contains(kw);
        }).toList();
        return ChannelResult.success(
          data: filtered,
          from: ChannelType.custom,
          fromCache: false,
          metadata: {'keyword': keyword, 'count': filtered.length, 'fallback': true},
        );
      }
      return ChannelResult.failure(
        from: ChannelType.custom,
        error: '脚本未实现 searchApps 和 getAllApps',
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
        final map = stringKeyedMap(data);
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
          error: '脚本未返回更新信息且渠道库无该应用',
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
          error: '脚本未返回更新数据（脚本未实现或数据获取失败）',
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
        final map = stringKeyedMap(data);
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
        error: '脚本未返回配置数据（脚本未实现或数据获取失败）',
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

  // ==================== 版本切换 ====================

  /// 获取版本/环境切换选项（脚本 main('versionOptions')）
  /// 返回原始 Map：`{ envs: List, versions: [{version, envs, buildCount}], currentEnv, currentVersion }`
  /// [env] 可选：指定环境 → 脚本只拉该 env 的版本列表（按需单 env，避免 5 env 全量）；
  /// 不传 → 脚本按凭证默认 env。脚本未实现/失败 → null（调用方降级）
  Future<Map<String, dynamic>?> versionOptions(
    String appId, {
    String? env,
  }) async {
    final data = await _callMain('versionOptions', {
      'appId': appId,
      if (env != null) 'env': env,
    });
    if (data == null) return null;
    return stringKeyedMap(data);
  }

  /// 切换版本/环境（脚本 main('switchVersion')）→ 返回该 env+version 的详情数据（同 getAppDetail 结构）
  /// [build] 可选：历史构建选中项 `{num, ipaName}` → 脚本切换到该构建（downloads 为该构建单条）；
  /// 不传 → 版本最新构建。脚本未实现/失败 → null（调用方降级）
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) async {
    final data = await _callMain('switchVersion', {
      'appId': appId,
      'env': env,
      'version': version,
      if (build != null) 'build': build,
    });
    if (data == null) return null;
    return stringKeyedMap(data);
  }

  /// 获取指定版本历史构建（脚本 main('buildHistory')）
  /// 返回 `{ builds: [{num, publishedAt, size, changelog, installTimes, builtBy, ipaName}] }`
  /// 脚本未实现/失败 → null（调用方降级）
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async {
    final data = await _callMain('buildHistory', {
      'appId': appId,
      'version': version,
      'env': env,
    });
    if (data == null) return null;
    return stringKeyedMap(data);
  }

  /// 获取脚本声明的详情页操作（main('detailMenu')，Hybrid Wave B）。
  ///
  /// 返回 `[{action, jscall, icon?, clickIsDimiss?}]` 动作数组：
  /// - [action]：动作标签（宫格文案）
  /// - [jscall]：点击后调用的脚本方法（经 [invokeScriptMethod]）
  /// - [icon]：图标（暂不解析，Flutter 侧用默认图标）
  /// - [clickIsDimiss]：点击后是否关闭更多面板
  /// 脚本未实现/失败/返回非列表 → null（调用方维持现状兜底）。
  Future<List<Map<String, dynamic>>?> detailMenu(String appId) async {
    final data = await _callMain('detailMenu', {'appId': appId});
    if (data is! List) return null;
    return data.map((e) => stringKeyedMap(e)).toList();
  }

  /// 通用脚本方法调用（供详情页执行脚本声明的动作 jscall）。
  ///
  /// 语义与 [_callMain] 一致：`{ok:true,data}` → data；`{ok:false}` /
  /// JS 抛错 → null + 日志。返回不处理（JS 全权，交互由 host.ui 驱动）。
  Future<dynamic> invokeScriptMethod(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    return _callMain(method, params);
  }

  // ==================== 详情通道工厂（detail.js 页面级 runtime） ====================

  /// 详情通道缓存（appId 级；页面存活期间复用，退出 release 释放 → 数据免缓存管理）
  final Map<String, IDetailChannel> _detailChannels = {};

  /// 工厂：懒创建 detail 通道（appId 级缓存，存活期间复用同一实例）。
  ///
  /// 详情通道为**页面级 runtime**：独立 QuickJS context 加载 detail.js，
  /// 状态与 entry 及其他 appId 互相隔离；页面退出 [releaseDetailChannel] 释放。
  /// 依赖（dio/appDao/configGetter/env/log/ui 回调）透传本渠道注入值，
  /// host.database / host.env 数据隔离与 entry 一致（同 channelKey）。
  /// 渠道包无 detail.js → null（详情走原路径）。
  @override
  IDetailChannel? getDetailChannel(String appId) {
    final ds = detailScript;
    if (ds == null) return null;
    return _detailChannels.putIfAbsent(appId, () => JsDetailChannel(
          appId: appId,
          channelKey: channelKey,
          detailScript: ds,
          dio: _runtime.dioOverride,
          appDao: _appDaoOverride,
          configGetter: _runtime.configGetterOverride,
          envReader: () => _runtime.envSnapshot,
          logInfo: _runtime.logInfoOverride,
          logError: _runtime.logErrorOverride,
          nativeHost: _runtime.nativeHost,
        ));
  }

  /// 页面退出释放：销毁 detail runtime（数据/缓存随实例释放，再取 → 新实例）。
  /// 未创建过该 appId 的 detail 通道 → 无操作（幂等）。
  @override
  void releaseDetailChannel(String appId) {
    unawaited(_detailChannels.remove(appId)?.dispose());
  }

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
      final app = appSummaryFromScript(item, channelKey: channelKey);
      if (app != null) {
        apps.add(app);
      } else {
        // 映射校验失败：跳过该条 + 日志
        _logError('脚本返回的 AppInfo 校验失败，已跳过: $item');
      }
    }
    return apps;
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
            // 脚本 downloads 契约：downloadable 默认 true（可下载），
            // 仅脚本显式设 false 时才禁止（如未配置凭证/认证失败 → url 空 + note 提示）
            downloadable: (e['downloadable'] as bool?) ?? true,
            note: e['note']?.toString(),
            publishedAt: _parseJsUpdateTime(e),
            // 保留原始 extra（含 updateTime 等）供 UI 标签展示
            extra: _parseJsExtra(e['extra']),
          );
        }
        return DownloadInfo(url: e.toString(), name: e.toString());
      }).toList();
    }
    return const [];
  }

  /// 统一解析 JS 各渠道的更新时间 → DateTime（null=无）
  /// 优先 e['publishedAt']（脚本显式提供），其次 e['updateTime'] / e['extra']['updateTime']
  static DateTime? _parseJsUpdateTime(Map e) {
    final raw = e['publishedAt']?.toString() ??
        e['updateTime']?.toString() ??
        ((e['extra'] is Map)
            ? (e['extra'] as Map)['updateTime']?.toString()
            : null);
    if (raw == null || raw.isEmpty) return null;
    // 数字字符串（时间戳）
    final asNum = num.tryParse(raw);
    if (asNum != null && asNum > 100000000000) {
      // 毫秒时间戳（13位）
      return DateTime.fromMillisecondsSinceEpoch(asNum.toInt());
    }
    if (asNum != null && asNum > 1000000000) {
      // 秒时间戳（10位）
      return DateTime.fromMillisecondsSinceEpoch(asNum.toInt() * 1000);
    }
    // ISO8601 / "yyyy-MM-dd HH:mm:ss" → 把空格替换为 T 后 tryParse
    return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  }

  /// 解析 JS 传入的 extra 映射（支持 {icon,text} map 格式，向后兼容纯字符串）
  static Map<String, DownloadTag>? _parseJsExtra(dynamic raw) {
    if (raw is! Map) return null;
    final result = <String, DownloadTag>{};
    raw.forEach((key, value) {
      final k = key.toString();
      if (value is Map) {
        result[k] = DownloadTag(
          text: value['text']?.toString() ?? '',
          iconName: value['icon']?.toString(),
        );
      } else {
        result[k] = DownloadTag(text: value?.toString() ?? '');
      }
    });
    return result.isEmpty ? null : result;
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

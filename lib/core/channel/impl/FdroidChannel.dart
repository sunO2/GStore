import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/agent/platform_arch.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/detail_extra_keys.dart';
import 'package:gstore/core/model/proxy/FdroidChannelDetailProxy.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/core/channel/AppUpdateCheckMixin.dart';

/// F-Droid 应用市场渠道实现
/// 架构：
/// - 使用 Rust RepoManager 搜索应用
/// - 使用 ChannelDatabase 存储用户添加的应用
/// 仓库内相对路径归一化（**纯函数**，便于单测；见 FdroidChannel._absoluteIconUrl）
///
/// 真机踩坑：库里存下来的 icon 形态很杂 —— `/repo/repo/com.x/en-US/icon_….png`、
/// `/fdroid/repo/icons/x.png`、`/icons/x.png`、`x.png`，而**源地址本身已带 `/repo`**。
/// 规则：取**最后一个 `/repo/` 之后**的部分作为仓库内相对路径。
@visibleForTesting
String normalizeRepoAssetPath(String iconKey) {
  if (iconKey.isEmpty) return '';
  if (iconKey.startsWith('http://') || iconKey.startsWith('https://')) return iconKey;
  var path = iconKey.split('?').first;
  final m = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+(.*)$').firstMatch(path);
  if (m != null) path = m.group(1) ?? path;
  final idx = path.lastIndexOf('/repo/');
  if (idx >= 0) path = path.substring(idx + '/repo/'.length);
  return path.replaceAll(RegExp(r'^/+'), '');
}

/// 源地址 + 仓库内相对路径（**纯函数**）：两边斜杠归一，避免 `…/repo//x` 或 `…/repo/repo/repo/x`
@visibleForTesting
String joinRepoUrl(String base, String path) {
  final p = path.trim();
  // ★ 契约：path 若**已是绝对地址** → 原样返回。
  //   必须与 normalizeRepoAssetPath（同样保留绝对地址）保持一致；
  //   两者契约不一致会出现 `https://镜像/https://第三方源/…` 的二次拼接（真机：图标 404）。
  if (p.startsWith('http://') || p.startsWith('https://')) return p;
  final b = base.replaceAll(RegExp(r'/+$'), '');
  final q = p.replaceAll(RegExp(r'^/+'), '');
  return q.isEmpty ? b : '$b/$q';
}

/// 入库用的资源键（**写侧**，与读侧的 [normalizeRepoAssetPath] 分工不同，别混用）
///
/// - **属于本仓库**的地址（源地址或它的镜像 → host 与 [baseHost] 相同）：
///   取*仓库内相对路径*。这样换镜像/换域名后，读侧按"记录所属源"重拼即可跟着变
///   （存完整 URL 会把图标写死在某个旧镜像上，永久失效）。
/// - **非同源**的绝对地址（索引里指向外部 CDN 的资源）：原样保留——它本来就不随镜像变化，
///   强行取相对键会被错误地拼到源地址上。
///
/// [baseHost] 传"该记录所属源实际生效基址"的 host（见 `_assetBaseFor`）。
@visibleForTesting
String repoAssetKey(String raw, {String baseHost = ''}) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  final uri = Uri.tryParse(v);
  if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
    final own = baseHost.isNotEmpty && uri.host.toLowerCase() == baseHost.toLowerCase();
    // 外部资源：保留完整地址；本仓库资源：取其路径再归一为仓库内相对路径
    return own ? normalizeRepoAssetPath(uri.path) : v;
  }
  return normalizeRepoAssetPath(v);
}

class FdroidChannel extends IChannel with AppUpdateCheckMixin {

  /// 图标地址归一化（**唯一入口**，别再在调用点特判形态）
  ///
  /// 真机踩到的坑：索引/库里存下来的 icon 形态很杂——
  /// `/repo/repo/com.x/en-US/icon_….png`、`/fdroid/repo/icons/x.png`、`/icons/x.png`、`x.png`，
  /// 而**源地址本身已经带 `/repo`**。旧实现只特判前两种，遇到 `/repo/repo/…` 就落到
  /// "补个 / 再拼" → 结果 `https://f-droid.org/repo/repo/repo/…`（必然 404）。
  ///
  /// 规则：取**最后一个 `/repo/` 之后**的部分作为仓库内相对路径，再与源地址拼接。
  String _absoluteIconUrl(String iconKey, {String? appId, String? sourceId}) {
    if (iconKey.isEmpty) {
      return appId == null
          ? _assetBaseFor(sourceId)
          : joinRepoUrl(_assetBaseFor(sourceId), 'icons/$appId.png');
    }
    // 纯逻辑在 normalizeRepoAssetPath / joinRepoUrl（有单测）
    return joinRepoUrl(_assetBaseFor(sourceId), normalizeRepoAssetPath(iconKey));
  }

  final Dio _dio;

  /// F-Droid 仓库服务（注册表注入：fdroid 模块下线时为 null → 软降级）
  IFdroidRepoService? get _repoService =>
      ModuleManager.instance.get<IFdroidRepoService>();

  /// 具体管理器（模块上线时绑定的实现为 FdroidRepoManager，承载响应式源状态）
  FdroidRepoManager? get _repoManager =>
      _repoService is FdroidRepoManager ? _repoService as FdroidRepoManager : null;

  /// Channel 数据库（存储用户添加的应用）
  ChannelDatabase? _database;

  @override
  ChannelInfo info;

  @override
  bool isInitialized = false;

  /// API 基础地址（固定）
  static const String _apiBaseUrl = 'https://f-droid.org/api';

  /// 兜底资源基地址：**仅在确实不知道记录所属源时**使用（例如网络兜底详情）。
  ///
  /// 真机：国内直连 f-droid.org 会连接超时（详情/图片都拉不到），
  /// 所以图片等静态资源**同样要走镜像**——不是只有索引/diff 才走镜像。
  ///
  /// ⚠️ 已知归属的场合一律走 [_assetBaseFor]（按记录所属源），不要用这里——
  /// 否则第三方源的应用会继承"当前选中源"的镜像前缀（真机 Bitwarden 图标事故）。
  String get _fallbackRepoUrl {
    final src = _repoManager?.currentSource;
    if (src == null) return 'https://f-droid.org/repo';
    final resolved = _repoService?.cachedBaseFor(src);
    if (resolved != null && resolved.isNotEmpty) return resolved;
    return _mirrorFirstUrlOf(src);
  }

  /// 按源的镜像配置取地址：**只作为 resolved_url 未知时的兜底**。
  ///
  /// 别把它当主规则——它不知道镜像当前是否可用，而模块的 `resolved_url` 是
  /// "镜像回退后真正下载成功"的那个地址。两套规则并存会出现：
  /// 搜索（模块基址）图标正常、列表/详情（这里）图标 404。
  static String _mirrorFirstUrlOf(FdroidSource s) {
    if (s.useMirrors) {
      for (final m in s.mirrors) {
        if (m.enabled && m.url.isNotEmpty) return m.url;
      }
    }
    return s.repoUrl;
  }

  FdroidChannel({
    required Dio dio,
    String? name,
    String? description,
    int? priority,
    bool enabled = true,
  })  : _dio = dio,
        info = ChannelInfo(
          type: ChannelType.fdroid,
          name: name ?? 'F-Droid',
          description: description ?? 'F-Droid 开源应用市场',
          priority: priority,
          enabled: enabled,
          supportOffline: false,
        );

  @override
  Future<void> initialize() async {
    // 初始化 Channel 数据库
    _database = await ChannelDatabaseManager.instance;
    isInitialized = true;
    appLog.info('FdroidChannel: 初始化完成');
  }

  @override
  Future<bool> checkAvailable() async {
    try {
      final response = await _dio.get(
        '$_apiBaseUrl/v1/packages/org.fdroid.fdroid',
      );
      return response.statusCode == 200;
    } catch (e) {
      appLog.error('FdroidChannel: 检查可用性失败 - $e');
      return false;
    }
  }

  @override
  Widget? getAddAppWidget(
    BuildContext context,
    Function(AppSummary) onAppAdded, {
    VoidCallback? onAppSaved,
  }) {
    // F-Droid 渠道通过搜索添加应用
    return _FdroidSearchWidget(
      channel: this,
      onAppAdded: onAppAdded,
      onAppSaved: onAppSaved,
    );
  }

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({
    bool forceRefresh = false,
  }) async {
    try {
      debugPrint('FdroidChannel: 从 Channel 数据库获取已添加应用');

      if (_database == null) {
        throw Exception('Database not initialized');
      }

      // 从 Channel 数据库获取 F-Droid 渠道的应用
      final channelApps = await _database!.dao.getAppsByChannel(ChannelType.fdroid.code);

      // 先把这批记录各自所属源的"实际生效基址"备好（冷启动首次为本地库读取）
      await _ensureBases(channelApps.map((e) => e.sourceIdentity));

      // 转换为 AppInfo，构造完整的图标URL
      final apps = channelApps.map((channelApp) {
        final categories = channelApp.category?.split(',') ?? [];

        // 处理图标 URL
        // 图标地址统一归一化（见 _absoluteIconUrl 注释）
        final iconUrl = _absoluteIconUrl(channelApp.icon,
            appId: channelApp.appId,
            // ★ 必须传"记录所属源"：否则基址退回当前源 → 第三方源图标拼上官方镜像 → 404
            sourceId: channelApp.sourceIdentity);

        debugPrint('FdroidChannel: 图标处理 - 原始=${channelApp.icon}, 最终=$iconUrl');

        return AppSummary(
          appId: channelApp.appId,
          name: channelApp.name,
          user: channelApp.user,
          repositories: channelApp.repositories,
          icon: iconUrl,
          des: channelApp.description,
          category: categories,
        );
      }).toList();

      appLog.info('FdroidChannel: 获取到 ${apps.length} 个已添加应用');
      return ChannelResult.success(
        data: apps,
        from: ChannelType.fdroid,
        fromCache: true,
      );
    } catch (e) {
      appLog.error('FdroidChannel: 获取应用列表失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: e.toString(),
      );
    }
  }

  /// 从仓库搜索应用（调用 Rust）
  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async {
    final service = _repoService;
    // fdroid 模块下线 → 软降级为不可用
    if (service == null) {
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: 'F-Droid 模块未启用',
      );
    }
    try {
      debugPrint('FdroidChannel: 搜索应用 - $keyword');

      // 调用 Rust RepoManager 搜索
      final results = await service.searchApps(keyword, limit: 50);

      // 转换为 AppInfo
      final apps = await Future.wait(results.map((appMap) async {
        final categories = appMap['categories'] as List<dynamic>? ?? [];
        final packageName = appMap['packageName'] ?? '';

        // 处理图标 URL（统一归一化，见 _absoluteIconUrl）
        final iconUrl =
            _absoluteIconUrl(appMap['icon']?.toString() ?? '', appId: packageName);

        // 【搜索结果取证】一次看清"为什么没图标"：模块原始值 vs 我们交给 UI 的最终值
        //  - rawIcon 为空          → 索引/模块侧就没给图标
        //  - finalIcon 含 '/https://' → 拼接把绝对地址二次前缀了（拼接契约问题）
        //  - 两者都正常但图不出     → 该地址本身取不到（镜像/路径问题），需实地取一次
        debugPrint('FdroidChannel: 搜索结果 - {packageName: $packageName, '
            'name: ${appMap['name']}, rawIcon: ${appMap['icon']}, '
            'finalIcon: $iconUrl, sourceId: ${appMap['sourceId'] ?? _currentSourceKey()}, '
            'keys: ${appMap.keys.join(",")}}');
        debugPrint('FdroidChannel: 搜索结果字段 - 原始 map = $appMap');
        debugPrint('FdroidChannel: 图标处理 - packageName=$packageName, 最终=$iconUrl');

        return AppSummary(
          appId: packageName,
          packageName: (packageName as String).isNotEmpty ? packageName : null,
          name: appMap['name'] ?? '',
          user: appMap['authorName'] ?? '',
          repositories: packageName,
          icon: iconUrl,
          // ① 携带"结果所属源"：服务层带了就用它（跨源查询场景），否则用当前源
          //    （这批结果正是从当前源查出来的）。写入侧据此落库，避免"猜源"。
          extra: {
            if ((appMap['sourceId'] ?? _currentSourceKey()) != null)
              'sourceId': (appMap['sourceId'] ?? _currentSourceKey()).toString(),
          },
          des: appMap['summary'] ?? '',
          category: categories.cast<String>(),
        );
      }).toList());

      appLog.info('FdroidChannel: 搜索到 ${apps.length} 个结果');
      return ChannelResult.success(
        data: apps,
        from: ChannelType.fdroid,
        fromCache: false, // 搜索结果
      );
    } catch (e) {
      appLog.error('FdroidChannel: 搜索失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: e.toString(),
      );
    }
  }

  /// appId 即包名（F-Droid 语义），无需规范化
  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => appInfo.appId;

  /// 添加应用到已添加列表
  Future<ChannelResult<void>> addApp(AppSummary app) async {
    try {
      debugPrint('FdroidChannel: 添加应用 - ${app.appId}');

      if (_database == null) {
        throw Exception('Database not initialized');
      }

      final categoryStr = app.category?.join(',');

      // ① 源标识随记录落库：**存在渠道自己的库**（聚合库只存记录 id，不承担域语义）。
      //    用仓库身份键（指纹优先）——换域名/换镜像都不影响；详情时据此精确定位源。
      //    只认应用**自己携带**的源（搜索结果/渠道库读回都已打标）；确实没有时宁可留空，
      //    也不写"当前选中源"——写错源比不写更糟（详情会静默查到别的源上）。
      final carried = app.extra?['sourceId']?.toString();
      final sourceKey = (carried != null && carried.isNotEmpty) ? carried : null;
      if (sourceKey == null) {
        appLog.warning('添加应用：记录未携带源标识 → 不再猜测源，详情走跨源兜底', data: {
          'appId': app.appId,
        });
      }

      // 图标**只存仓库内相对路径**（不是完整 URL）：镜像/域名变化时读侧用
      // "该记录的源 → 基址"重新拼一次，地址自动跟着变（不会写死某个旧镜像）。
      // 判定"是否本仓库地址"用该源实际生效基址的 host（同一个产出方，见 _assetBaseFor）。
      final baseHost = Uri.tryParse(_assetBaseFor(sourceKey))?.host ?? '';
      var iconPath = repoAssetKey(app.icon, baseHost: baseHost);
      if (iconPath.isEmpty) iconPath = 'icons/${app.appId}.png';

      debugPrint('FdroidChannel: 添加应用，归一化图标路径 = $iconPath');

      final channelApp = ChannelAddedApp.withChannel(
        appId: app.appId,
        name: app.name,
        user: app.user,
        repositories: app.repositories,
        icon: iconPath,  // 存储归一化的路径（不包含 /icons 前缀）
        description: app.des,
        category: categoryStr,
        addTime: DateTime.now().millisecondsSinceEpoch,
        channel: ChannelType.fdroid,
        sourceId: sourceKey,
      );

      await _database!.dao.insertApp(channelApp);

      appLog.info('FdroidChannel: 应用添加成功');
      return ChannelResult.success(
        data: null,
        from: ChannelType.fdroid,
        fromCache: true,
      );
    } catch (e) {
      appLog.error('FdroidChannel: 添加应用失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: e.toString(),
      );
    }
  }

  /// 从已添加列表移除应用
  Future<ChannelResult<void>> removeApp(String appId) async {
    try {
      debugPrint('FdroidChannel: 移除应用 - $appId');

      if (_database == null) {
        throw Exception('Database not initialized');
      }

      await _database!.dao.removeApp(appId, ChannelType.fdroid.code);

      appLog.info('FdroidChannel: 应用移除成功');
      return ChannelResult.success(
        data: null,
        from: ChannelType.fdroid,
        fromCache: true,
      );
    } catch (e) {
      appLog.error('FdroidChannel: 移除应用失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async {
    try {
      // 1. 优先从 ChannelDatabase 读取
      if (!forceRefresh && _database != null) {
        try {
          final channelApps = await _database!.dao.getAppsByChannel(ChannelType.fdroid.code);
          ChannelAddedApp? app;
          for (final item in channelApps) {
            if (item.appId == appId) {
              app = item;
              break;
            }
          }

          if (app != null) {
            // 从数据库构造 AppInfo，图标需要构造完整URL
            final categories = app.category?.split(',') ?? [];
            final sourceId = app.sourceIdentity;
            await _ensureBases([sourceId]);

            // 处理图标 URL（使用与 searchApps 相同的逻辑）
            final iconUrl = _absoluteIconUrl(app.icon,
            appId: app.appId, sourceId: sourceId);
            debugPrint('FdroidChannel: 从数据库读取应用信息，图标处理 - 原始=${app.icon}, 最终=$iconUrl');
            final appInfo = AppSummary(
              appId: app.appId,
              name: app.name,
              user: app.user,
              repositories: app.repositories,
              icon: iconUrl,
              des: app.description,
              category: categories,
              // ★ 源标识随应用回传：聚合层再落渠道库时靠它路由，不依赖"当前选中源"
              extra: {if (sourceId != null) 'sourceId': sourceId},
            );

            debugPrint('FdroidChannel: 从数据库读取应用信息 - ${app.name}');
            return ChannelResult.success(
              data: appInfo,
              from: ChannelType.fdroid,
              fromCache: true,
            );
          }
        } catch (e) {
          appLog.error('FdroidChannel: 从数据库读取失败，尝试网络请求 - $e');
        }
      }

      // 2. 数据库没有或 forceRefresh，通过网络 API 获取
      final response = await _dio.get(
        '$_apiBaseUrl/v1/packages/$appId',
      );

      if (response.statusCode != 200) {
        return ChannelResult.failure(
          from: ChannelType.fdroid,
          error: 'Failed to fetch app info: ${response.statusCode}',
        );
      }

      final data = response.data;
      final packageName = data['packageName'] as String?;
      if (packageName == null) {
        return ChannelResult.failure(
          from: ChannelType.fdroid,
          error: 'Invalid response: missing packageName',
        );
      }

      // 构造完整的图标URL（API 返回的常是相对路径；统一归一化 + 镜像优先）
      final iconUrl =
          _absoluteIconUrl(data['icon']?.toString() ?? '', appId: packageName);
      final app = AppSummary(
        appId: packageName,
        packageName: packageName,
        name: data['name'] ?? packageName,
        user: data['authorName'] ?? '',
        repositories: packageName,
        icon: iconUrl, // 构造完整的图标URL
        des: data['summary'] ?? '',
        category: null,
      );

      return ChannelResult.success(
        data: app,
        from: ChannelType.fdroid,
        fromCache: false,
      );
    } catch (e) {
      appLog.error('FdroidChannel: 获取应用信息失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: e.toString(),
      );
    }
  }

  /// 资源基址：**按记录所属源**取（镜像优先），而不是"当前选中源"
  ///
  /// 真机问题：Bitwarden 的应用图标被拼上了 f-droid 官方源的镜像前缀 ——
  /// 因为基址取的是"当前选中源"。资源必须与**它所属的源**走同一地址。
  ///
  /// 地址本身有**唯一产出方**：模块下载时记录的 `resolved_url`（镜像回退后真正
  /// 可用的地址）。宿主只在它未知时用镜像配置兜底——否则会出现"搜索图标正常、
  /// 列表图标 404"这种同一应用两套地址的情况。
  String _assetBaseFor(String? sourceId) {
    final svc = _repoService;
    if (svc != null && sourceId != null && sourceId.isNotEmpty) {
      for (final s in svc.sources) {
        // 接受：现用存储身份（源 id）/ 原始指纹 / 旧逻辑身份（fp:/url:，历史记录）
        if (FdroidRustRepoManager.identityMatches(s, sourceId)) {
          final resolved = svc.cachedBaseFor(s);
          if (resolved != null && resolved.isNotEmpty) return resolved;
          return _mirrorFirstUrlOf(s);
        }
      }
      appLog.warning('资源基址：记录里的源标识未匹配到任何源，退回当前源',
          data: {'sourceId': sourceId});
    }
    if (sourceId == null || sourceId.isEmpty) {
      appLog.warning('资源基址：记录未携带源标识 → 退回当前源（第三方源图标会拼错）',
          data: {'currentSource': _repoService?.currentSource?.name});
    }
    return _fallbackRepoUrl;
  }

  /// 确保这些源标识对应的源，其"实际生效基址"已就绪（冷启动首次读取时为本地库补读）
  Future<void> _ensureBases(Iterable<String?> sourceIds) async {
    final svc = _repoService;
    if (svc == null) return;
    for (final id in sourceIds.whereType<String>().where((e) => e.isNotEmpty).toSet()) {
      for (final s in svc.sources) {
        if (FdroidRustRepoManager.identityMatches(s, id)) {
          await svc.ensureBaseFor(s);
          break;
        }
      }
    }
  }

  /// 仓库内相对路径 / 已绝对化的地址 → 可直接访问的绝对地址。
  ///
  /// 模块出口已把 icon / metadata 资源 / versions 文件名绝对化（见 repo.rs），
  /// 所以这里对绝对地址是**幂等透传**；只有网络兜底拿到的旧格式相对路径才真正拼接。
  String _absoluteRepoAsset(String path, String? sourceId) =>
      joinRepoUrl(_assetBaseFor(sourceId), normalizeRepoAssetPath(path));

  /// 某应用记录的**所属源标识**（渠道库是该记录的唯一归属地）
  Future<String?> _sourceIdForApp(String appId) async {
    final db = _database;
    if (db == null) return null;
    try {
      final rec = await db.dao.getApp(appId, ChannelType.fdroid.code);
      return rec?.sourceIdentity;
    } catch (e) {
      appLog.error('查询记录所属源失败 - $e');
      return null;
    }
  }

  /// 当前源的**存储身份键**（源 id）——与模块的库/实例选择同一套键。
  ///
  /// 注意：不再是"指纹优先"（指纹下载后才学到，不能作槽位键）；读取侧由
  /// [FdroidRustRepoManager.identityMatches] 兼容历史 `fp:`/`url:` 标识。
  String? _currentSourceKey() {
    final src = _repoService?.currentSource;
    if (src == null) return null;
    return _repoService!.identityKeyFor(src);
  }

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async {
    try {
      appLog.info('FdroidChannel: ========== 开始获取应用详情 ==========');
      debugPrint('FdroidChannel: appId = $appId');

      // 步骤 1: 尝试从 Rust 数据库精确查询应用数据（包含 metadata 和 versions）
      final service = _repoService;
      // ② 源标识来自**本渠道记录**（不依赖"当前选中源"这个全局状态）
      final recordSourceId = await _sourceIdForApp(appId);
      await _ensureBases([recordSourceId]);
      if (!forceRefresh && service != null) {
        appLog.info('详情查询定位源', data: {
          'appId': appId,
          'sourceId': recordSourceId ?? '(记录无源标识→跨源兜底)',
        });
        try {
          final appData =
              await service.getAppByPackageName(appId, sourceId: recordSourceId);
          if (appData != null) {
            final metadataJson = appData['metadata'] as String?;
            final versionsJson = appData['versions'] as String?;
            // 服务层回带的"实际命中源"优先：记录里的标识可能缺失/过期
            final effectiveSourceId =
                appData['sourceId']?.toString() ?? recordSourceId;

            if (metadataJson != null && versionsJson != null) {
              debugPrint('FdroidChannel: 从数据库精确获取到 metadata 和 versions');
              return await _parseDetailFromJson(
                appId,
                appData,
                metadataJson,
                versionsJson,
                sourceId: effectiveSourceId,
              );
            }
          } else {
            debugPrint('FdroidChannel: 数据库中未找到精确匹配的应用');
          }
        } catch (e) {
          appLog.error('FdroidChannel: 从数据库获取失败，尝试网络请求 - $e');
        }
      }

      // 步骤 2: 数据库没有或 forceRefresh，通过网络 API 获取（降级方案）
      debugPrint('FdroidChannel: 使用网络 API 获取详情');
      return await _fetchDetailFromApi(appId, sourceId: recordSourceId);
    } catch (e) {
      appLog.error('FdroidChannel: ✗ 获取应用详情失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: e.toString(),
      );
    }
  }

  /// 更新检测：仅使用本地 Rust 索引，避免触发网络请求
  /// F-Droid 数据已由仓库索引定期同步到本地，无需实时联网
  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(
    String appId,
  ) async {
    final service = _repoService;
    // fdroid 模块下线 → 软降级为不可用
    if (service == null) {
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: 'F-Droid 模块未启用',
      );
    }
    try {
      // 更新检测同样要按**记录所属源**查（多源下不同源的版本可能不同）
      final sourceId = await _sourceIdForApp(appId);
      final appData = await service.getAppByPackageName(appId, sourceId: sourceId);
      if (appData != null) {
        final metadataJson = appData['metadata'] as String?;
        final versionsJson = appData['versions'] as String?;
        if (metadataJson != null && versionsJson != null) {
          final result = await _parseDetailFromJson(
            appId,
            appData,
            metadataJson,
            versionsJson,
            sourceId: appData['sourceId']?.toString() ?? sourceId,
          );
          if (result.success && result.data != null) {
            final detail = result.data!;
            // 按设备架构选择最佳下载包
            final bestDownload =
                await PlatformArch.selectBestDownload(detail.downloads);
            return ChannelResult.success(
              data: AppUpdateCheckResult(
                appId: appId,
                packageName: detail.packageName,
                name: detail.name,
                icon: detail.icon,
                latestVersion: detail.version,
                latestDownload: bestDownload,
                detail: detail,
              ),
              from: ChannelType.fdroid,
            );
          }
        }
      }
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: '本地仓库索引中未找到 $appId，请先同步仓库数据',
      );
    } catch (e) {
      appLog.error('FdroidChannel: 本地检查更新失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: e.toString(),
      );
    }
  }

  /// 从 JSON 字符串解析详情信息（使用 Rust 数据库的 metadata 和 versions）
  ///
  /// [sourceId] 是**该记录所属源**的标识：下载地址/截图都必须与它走同一地址，
  /// 不能用"当前选中源"（否则第三方源的应用会拿到官方源的镜像地址）。
  Future<ChannelResult<IDetailInfo>> _parseDetailFromJson(
    String appId,
    Map<String, dynamic> appData,
    String metadataJson,
    String versionsJson, {
    String? sourceId,
  }) async {
    try {
      // 解析 metadata
      final metadata = jsonDecode(metadataJson) as Map<String, dynamic>;

      // 解析 versions
      final versions = jsonDecode(versionsJson) as Map<String, dynamic>;

      // 提取基本信息
      final name = appData['name'] as String? ?? appId;
      final summary = appData['summary'] as String? ?? '';
      final license = appData['license'] as String?;
      final sourceCode = appData['sourceCode'] as String?;
      final webSite = appData['webSite'] as String?;
      final authorName = appData['authorName'] as String?;
      final categories = appData['categories'] as List<dynamic>?;

      // 解析 icon
      final iconKey = appData['icon'] as String? ?? '$appId.png';
      String iconUrl = _constructIconUrl(iconKey, appId, sourceId: sourceId);

      // 解析 versions 构建下载列表
      final downloads = <DownloadInfo>[];
      final versionEntries = versions.entries.toList();

      // 按 added 时间戳排序（最新的在前）
      versionEntries.sort((a, b) {
        final aTime = a.value['added'] as int? ?? 0;
        final bTime = b.value['added'] as int? ?? 0;
        return bTime.compareTo(aTime);
      });

      for (final entry in versionEntries) {
        final versionData = entry.value as Map<String, dynamic>?;
        if (versionData == null) continue;

        final file = versionData['file'] as Map<String, dynamic>?;
        if (file == null) continue;

        final fileName = file['name'] as String?;
        if (fileName == null) continue;

        final manifest = versionData['manifest'] as Map<String, dynamic>?;
        final versionName = manifest?['versionName'] as String?;
        final versionCode = manifest?['versionCode'] as int?;
        final size = file['size'] as int?;
        final hash = file['sha256'] as String?;

        // 构造下载 URL：模块出口已绝对化（幂等透传），旧格式相对路径按所属源拼接
        final downloadUrl = _absoluteRepoAsset(fileName, sourceId);

        final platform = _extractArch(fileName);
        downloads.add(DownloadInfo(
          url: downloadUrl,
          name: fileName,
          size: size,
          version: versionName,
          versionCode: versionCode,
          hash: hash,
          hashType: 'sha256',
          // 功能数据（hash/hashType/versionCode/platform 等）保留为顶层字段
          platform: platform,
          // extra 仅承载展示标签（带 Material 图标名）
          extra: {
            if (size != null)
              DownloadItemExtra.size:
                  DownloadTag(text: formatFileSize(size), iconName: 'sd_card'),
            if (platform != null && platform.isNotEmpty)
              DownloadItemExtra.platform:
                  DownloadTag(text: platform, iconName: 'phone_android'),
            if (versionName != null && versionName.isNotEmpty)
              DownloadItemExtra.version:
                  DownloadTag(text: versionName, iconName: 'label'),
          },
        ));
      }

      // 解析截图：统一走 FdroidAppMeta（兼容 LocalizedFile / 多语言 / 顶层列表等形态），
      // 再按**所属源**绝对化（模块出口已改写为绝对地址时幂等透传）
      final screenshots = <ScreenshotInfo>[
        for (final shotPath in FdroidAppMeta.parse(metadataJson).screenshots)
          ScreenshotInfo(url: _absoluteRepoAsset(shotPath, sourceId)),
      ];

      // 提取描述（优先使用 en-US）
      String description = summary;
      final descriptionData = metadata['description'] as Map<String, dynamic>?;
      if (descriptionData != null) {
        description = descriptionData['en-US'] as String? ??
                      descriptionData.values.firstOrNull as String? ??
                      summary;
      }

      // 提取多语言 name 和 summary
      final nameData = metadata['name'] as Map<String, dynamic>?;
      final localizedName = nameData?['en-US'] as String? ??
                          nameData?.values.firstOrNull as String? ??
                          name;

      final summaryData = metadata['summary'] as Map<String, dynamic>?;
      final localizedSummary = summaryData?['en-US'] as String? ??
                              summaryData?.values.firstOrNull as String? ??
                              summary;

      appLog.info('FdroidChannel: ========== 构建详情信息完成 ==========');
      debugPrint('FdroidChannel: name = $localizedName');
      debugPrint('FdroidChannel: downloads 数量 = ${downloads.length}');
      debugPrint('FdroidChannel: screenshots 数量 = ${screenshots.length}');

      // 构建原始数据 Map
      final rawData = <String, dynamic>{
        'appId': appId,
        'name': localizedName,
        'icon': iconUrl,
        'description': description,
        'readme': description,
        'summary': localizedSummary,
        'version': downloads.firstOrNull?.version,
        'developer': authorName ?? '',
        'packageName': appId,
        'projectUrl': sourceCode,
        'webSite': webSite,
        'license': license,
        'categories': categories ?? [],
        'downloads': downloads,
        'screenshots': screenshots,
        'metadata': metadata,
        'versions': versions,
      };

      // 使用代理类包装原始数据
      final detailData = FdroidChannelDetailProxy(rawData);

      return ChannelResult.success(
        data: detailData,
        from: ChannelType.fdroid,
        fromCache: true,
      );
    } catch (e) {
      appLog.error('FdroidChannel: 解析 JSON 详情失败 - $e');
      rethrow;
    }
  }

  /// 从网络 API 获取详情（降级方案）
  ///
  /// [sourceId] 已知时按**该记录所属源**取索引/资源（镜像优先），未知才退回当前源。
  Future<ChannelResult<IDetailInfo>> _fetchDetailFromApi(
    String appId, {
    String? sourceId,
  }) async {
    final base = _assetBaseFor(sourceId);

    // 获取单个包的详细信息
    final packageResponse = await _dio.get(
      '$_apiBaseUrl/v1/packages/$appId',
    );

    if (packageResponse.statusCode != 200) {
      throw Exception('Failed to fetch package: ${packageResponse.statusCode}');
    }

    final packageData = packageResponse.data;
    final packageName = packageData['packageName'] as String?;
    if (packageName == null) {
      throw Exception('Invalid response: missing packageName');
    }

    // 完整仓库索引也在**该记录所属源**上取（镜像优先），与详情/图标同址
    final indexResponse = await _dio.get('$base/index-v1.json');
    final indexData = indexResponse.data as Map<String, dynamic>;
    final appsMap = indexData['apps'] as Map<String, dynamic>?;
    final appData = appsMap?[appId] as Map<String, dynamic>?;

    if (appData == null) {
      throw Exception('App not found in index');
    }

    // 解析应用信息
    final name = appData['name'] as String? ?? appId;
    final summary = appData['summary'] as String? ?? '';
    final iconKey = appData['icon'] as String? ?? '$appId.png';
    final iconUrl = _constructIconUrl(iconKey, appId, sourceId: sourceId);
    final sourceCode = appData['sourceCode'] as String?;
    final license = appData['license'] as String?;
    final category = appData['categories'] as List?;
    final categories = category?.map((e) => e.toString()).toList();

    // 获取所有可用的包版本
    final packagesMap = appData['packages'] as Map<String, dynamic>?;
    final packagesList = packagesMap?.values.toList() ?? [];

    // 按版本号排序（最新的在前）
    packagesList.sort((a, b) {
      final aVersion = (a['versionCode'] as int?) ?? 0;
      final bVersion = (b['versionCode'] as int?) ?? 0;
      return bVersion.compareTo(aVersion);
    });

    // 构建下载信息列表
    final downloads = <DownloadInfo>[];
    for (final pkg in packagesList) {
      if (pkg is Map) {
        final apkName = pkg['apkName'] as String?;
        final versionCode = pkg['versionCode'] as int?;
        final versionName = pkg['versionName'] as String?;
        final size = pkg['size'] as int?;
        final hash = pkg['hash'] as String?;
        final hashType = pkg['hashType'] as String?;

        if (apkName != null) {
          final platform = _extractArch(apkName);
          downloads.add(DownloadInfo(
            url: _absoluteRepoAsset(apkName, sourceId),
            name: apkName,
            size: size,
            version: versionName,
            versionCode: versionCode,
            hash: hash,
            hashType: hashType,
            // 功能数据保留顶层；extra 仅承载展示标签
            platform: platform,
            extra: {
              if (size != null)
                DownloadItemExtra.size:
                    DownloadTag(text: formatFileSize(size), iconName: 'sd_card'),
              if (platform != null && platform.isNotEmpty)
                DownloadItemExtra.platform:
                    DownloadTag(text: platform, iconName: 'phone_android'),
              if (versionName != null && versionName.isNotEmpty)
                DownloadItemExtra.version:
                    DownloadTag(text: versionName, iconName: 'label'),
            },
          ));
        }
      }
    }

    // 获取截图（如果有）——按所属源绝对化
    final screenshotsData = appData['screenshots'] as Map?;
    final screenshots = <ScreenshotInfo>[];
    if (screenshotsData != null) {
      screenshotsData.forEach((locale, shots) {
        if (shots is List) {
          for (final shot in shots) {
            if (shot is String) {
              screenshots.add(ScreenshotInfo(url: _absoluteRepoAsset(shot, sourceId)));
            } else if (shot is Map && shot['url'] is String) {
              screenshots.add(ScreenshotInfo(
                url: _absoluteRepoAsset(shot['url'] as String, sourceId),
                description: shot['description']?.toString(),
              ));
            }
          }
        }
      });
    }

    appLog.info('FdroidChannel: ========== 构建详情信息完成 ==========');
    debugPrint('FdroidChannel: name = $name');
    debugPrint('FdroidChannel: downloads 数量 = ${downloads.length}');

    // 构建原始数据 Map
    final rawData = <String, dynamic>{
      'appId': appId,
      'name': name,
      'icon': iconUrl,
      'description': summary,
      'readme': summary,
      'version': packageData['suggestedVersionCode']?.toString(),
      'developer': appData['authorName'] ?? '',
      'packageName': appId,
      'projectUrl': sourceCode,
      'license': license,
      'categories': categories ?? [],
      'downloads': downloads,
      'screenshots': screenshots,
      'metadata': appData,
      'packageData': packageData,
    };

    // 使用代理类包装原始数据
    final detailData = FdroidChannelDetailProxy(rawData);

    return ChannelResult.success(
      data: detailData,
      from: ChannelType.fdroid,
      fromCache: false,
    );
  }

  /// 构造图标 URL（与 [_absoluteIconUrl] 同一套规则：所属源 + 镜像优先 + 路径归一）
  String _constructIconUrl(String iconKey, String appId, {String? sourceId}) =>
      _absoluteIconUrl(iconKey, appId: appId, sourceId: sourceId);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async {
    // F-Droid 不支持分类搜索，返回空列表
    return ChannelResult.success(
      data: [],
      from: ChannelType.fdroid,
      fromCache: !forceRefresh,
    );
  }

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async {
    // F-Droid 分类是硬编码的
    final categories = <db.AppCategory>[
      db.AppCategory('1', 'Games', ''),
      db.AppCategory('2', 'Communication', ''),
      db.AppCategory('3', 'Development', ''),
      db.AppCategory('4', 'Money', ''),
      db.AppCategory('5', 'Multimedia', ''),
      db.AppCategory('6', 'Navigation', ''),
      db.AppCategory('7', 'Phone & SMS', ''),
      db.AppCategory('8', 'Reading', ''),
      db.AppCategory('9', 'Science & Education', ''),
      db.AppCategory('10', 'Security', ''),
      db.AppCategory('11', 'Sports & Health', ''),
      db.AppCategory('12', 'System', ''),
      db.AppCategory('13', 'Time', ''),
      db.AppCategory('14', 'Writing', ''),
      db.AppCategory('15', 'Internet', ''),
      db.AppCategory('16', 'Connectivity', ''),
      db.AppCategory('17', 'Theming', ''),
    ];

    return ChannelResult.success(
      data: categories,
      from: ChannelType.fdroid,
      fromCache: !forceRefresh,
    );
  }

  @override
  Future<ChannelResult<bool>> checkUpdate() async {
    try {
      // 检查仓库索引是否有更新
      final response = await _dio.head('$_fallbackRepoUrl/index-v1.json');
      final lastModified = response.headers['last-modified'];
      final hasUpdate = lastModified != null;

      return ChannelResult.success(
        data: hasUpdate,
        from: ChannelType.fdroid,
        metadata: {'lastModified': lastModified},
      );
    } catch (e) {
      appLog.error('FdroidChannel: 检查更新失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.fdroid,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async {
    // F-Droid 是远程仓库，不需要本地更新
    return ChannelResult.success(
      data: true,
      from: ChannelType.fdroid,
    );
  }

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async {
    // F-Droid 不需要配置
    return ChannelResult.success(
      data: null,
      from: ChannelType.fdroid,
      fromCache: !forceRefresh,
    );
  }

  @override
  Future<void> clearCache() async {
    // F-Droid 是远程 API，缓存由 Dio 管理
    appLog.info('FdroidChannel: 缓存已清除');
  }

  @override
  Future<int> getCacheSize() async {
    // F-Droid 是远程 API，不计算缓存大小
    return 0;
  }

  @override
  Future<void> dispose() async {
    isInitialized = false;
    appLog.info('FdroidChannel: 已释放');
  }

  /// 从 APK 文件名提取架构信息
  String? _extractArch(String apkName) {
    final lower = apkName.toLowerCase();
    if (lower.contains('_arm64-v8a')) return 'arm64-v8a';
    if (lower.contains('_armeabi-v7a')) return 'armeabi-v7a';
    if (lower.contains('_x86_64')) return 'x86_64';
    if (lower.contains('_x86')) return 'x86';
    if (lower.contains('_universal')) return 'universal';
    return null;
  }
}

/// F-Droid 搜索组件
class _FdroidSearchWidget extends StatefulWidget {
  final FdroidChannel channel;
  final Function(AppSummary) onAppAdded;
  final VoidCallback? onAppSaved;

  const _FdroidSearchWidget({
    required this.channel,
    required this.onAppAdded,
    this.onAppSaved,
  });

  @override
  State<_FdroidSearchWidget> createState() => _FdroidSearchWidgetState();
}

class _FdroidSearchWidgetState extends State<_FdroidSearchWidget> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<AppSummary> _searchResults = [];
  bool _isSearching = false;
  String? _errorMessage;
  Set<String> _addedApps = {};  // 已添加的应用包名

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _loadAddedApps();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 加载已添加的应用
  Future<void> _loadAddedApps() async {
    try {
      final result = await widget.channel.getAllApps();
      if (result.success && result.data != null) {
        setState(() {
          _addedApps = result.data!.map((app) => app.appId).toSet();
        });
      }
    } catch (e) {
      appLog.error('加载已添加应用失败: $e');
    }
  }

  /// 执行搜索
  Future<void> _performSearch(String keyword) async {
    if (keyword.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
        _errorMessage = null;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _errorMessage = null;
    });

    try {
      final result = await widget.channel.searchApps(keyword);

      if (result.success && result.data != null) {
        setState(() {
          _searchResults = result.data!;
          _isSearching = false;
        });
      } else {
        setState(() {
          _errorMessage = result.error ?? '搜索失败';
          _isSearching = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '搜索出错: $e';
        _isSearching = false;
      });
    }
  }

  /// 添加应用
  Future<void> _addApp(AppSummary app) async {
    try {
      // 保存到 ChannelDatabase（渠道数据库）
      final result = await widget.channel.addApp(app);

      if (result.success) {
        setState(() {
          _addedApps.add(app.appId);
        });

        // 通知父组件刷新
        widget.onAppSaved?.call();

        AppDialogs.showSuccess(
          '已添加 ${app.name}',
          title: '成功',
          duration: const Duration(seconds: 1),
        );
      } else {
        AppDialogs.showError(result.error ?? '添加失败', title: '失败');
      }
    } catch (e) {
      AppDialogs.showError('添加出错: $e', title: '失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 搜索栏
        Container(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            focusNode: _focusNode,
            decoration: InputDecoration(
              hintText: '搜索 F-Droid 应用...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _searchResults = [];
                          _errorMessage = null;
                        });
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (value) {
              _performSearch(value);
            },
            onChanged: (value) {
              setState(() {});
            },
          ),
        ),

        // 搜索按钮
        if (_searchController.text.isNotEmpty && !_isSearching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _performSearch(_searchController.text),
                child: const Text('搜索'),
              ),
            ),
          ),

        // 搜索状态
        Expanded(
          child: _buildSearchResults(),
        ),
      ],
    );
  }

  Widget _buildSearchResults() {
    if (_isSearching) {
      return const Center(
        child: AppLoading(size: AppLoadingSize.medium),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              _searchController.text.isEmpty ? '输入关键词搜索应用' : '未找到相关应用',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final app = _searchResults[index];
        final isAdded = _addedApps.contains(app.appId);

        return ListTile(
          leading: CircleAvatar(
            backgroundImage: NetworkImage(
              () {
                // app.icon 现在已经是完整URL（由 searchApps 构造）
                // 如果为空字符串，使用默认
                final icon = app.icon.isEmpty
                    ? widget.channel._absoluteIconUrl('', appId: app.appId)
                    : app.icon;
                return icon;
              }(),
            ),
          ),
          title: Text(app.name),
          subtitle: Text(
            app.des,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            icon: Icon(
              isAdded ? Icons.check_circle : Icons.add_circle,
              color: isAdded ? Colors.green : Colors.grey,
            ),
            onPressed: isAdded ? null : () => _addApp(app),
          ),
        );
      },
    );
  }
}

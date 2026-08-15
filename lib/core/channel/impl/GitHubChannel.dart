import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/proxy/GitHubChannelDetailProxy.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/http/github/github_client.dart';
import 'package:http/http.dart' as http;
import 'package:gstore/core/channel/AppUpdateCheckMixin.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/cache/ReadmeCache.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/data/metadata_repository.dart';

/// GitHub API 渠道实现
/// 通过 GitHub API 获取应用数据
class GitHubChannel extends IChannel with AppUpdateCheckMixin {
  final GithubRestClient _githubApi;
  final String _user;
  final String _repository;

  /// HTTP 客户端（可注入用于测试；默认全局 http）
  final http.Client _httpClient;

  /// 渠道数据库（已添加应用存储）
  ChannelDatabase? _database;

  @override
  ChannelInfo info;

  @override
  bool isInitialized = false;

  // 缓存数据
  List<AppSummary>? _cachedApps;
  List<db.AppCategory>? _cachedCategories;
  db.AppInfoConfig? _cachedConfig;

  GitHubChannel({
    required GithubRestClient githubApi,
    String? name,
    String? description,
    int? priority,
    bool enabled = true,
    String? user,
    String? repository,
    http.Client? httpClient,
  })  : _githubApi = githubApi,
        _httpClient = httpClient ?? http.Client(),
        _user = user ?? 'sunO2',
        _repository = repository ?? 'GStore-Repositorys',
        info = ChannelInfo(
          type: ChannelType.github,
          name: name ?? 'GitHubAPI',
          description: description ?? 'GitHub API 渠道',
          priority: priority ?? 2,
          enabled: enabled,
          supportOffline: false,
        );

  @override
  Future<void> initialize() async {
    // 初始化渠道数据库（已添加应用存储）
    _database = await ChannelDatabaseManager.instance;
    isInitialized = true;
    appLog.info('GitHubChannel: 初始化完成');
  }

  @override
  Future<bool> checkAvailable() async {
    try {
      // 尝试获取 releases 来检查 API 是否可用
      await _githubApi.releases(_user, _repository, 1, CancelToken());
      return true;
    } catch (e) {
      appLog.error('GitHubChannel: API 不可用 - $e');
      return false;
    }
  }

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({
    bool forceRefresh = false,
  }) async {
    try {
      if (!forceRefresh && _cachedApps != null) {
        return ChannelResult.success(
          data: _cachedApps!,
          from: ChannelType.github,
          fromCache: true,
        );
      }

      // 从渠道数据库读取已添加应用（读取边界做脏数据自愈）
      if (_database == null) {
        throw Exception('数据库未初始化');
      }
      final channelApps = await _loadChannelApps();
      final apps = channelApps
          .map(AppSummary.fromChannelAddedApp)
          .toList();

      _cachedApps = apps;
      return ChannelResult.success(
        data: apps,
        from: ChannelType.github,
        fromCache: false,
      );
    } catch (e) {
      appLog.error('GitHubChannel: 获取应用列表失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
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
      // 先从渠道数据库查找
      if (_database != null) {
        final stored = await _database!.dao.getApp(
          appId,
          ChannelType.github.code,
        );
        if (stored != null) {
          // 命中渠道库：优先 metadata 覆盖真实图标/应用名/包名，未收录回退数据库记录
          return ChannelResult.success(
            data: await _buildStoredAppInfo(stored),
            from: ChannelType.github,
            fromCache: true,
          );
        }
      }

      // appId 格式为 owner/repo，拆分后从 GitHub API 获取
      final parts = appId.split('/');
      if (parts.length != 2) {
        // 真实包名 appId（无 '/'，如 metadata 收录/下载替换后的记录）：
        // 渠道数据库未命中时，按 extra.packageName / apprepo 反查 owner/repo
        if (_database != null) {
          try {
            final all = await _database!.dao
                .getAppsByChannel(ChannelType.github.code);
            for (final record in all) {
              if (record.extra != null && record.extra!.contains(appId)) {
                final matched = await _buildStoredAppInfo(record);
                if (matched.appId.isNotEmpty || matched.user.isNotEmpty) {
                  return ChannelResult.success(
                    data: matched,
                    from: ChannelType.github,
                    fromCache: true,
                  );
                }
                break;
              }
            }
          } catch (e) {
            appLog.error('GitHubChannel: 包名反查渠道记录失败 - $e');
          }
        }
        return ChannelResult.success(data: null, from: ChannelType.github);
      }
      final user = parts[0];
      final repo = parts[1];

      final apiList = await _githubApi.apiList(
        user,
        repo,
        CancelToken(),
      );
      final name = apiList.full_name?.split('/').last.isNotEmpty == true
          ? apiList.full_name!.split('/').last
          : repo;
      final description = apiList.description?.isNotEmpty == true
          ? apiList.description!
          : '';

      // 优先读取仓库元数据（真实图标 / 包名 / 应用名），未收录时回退 GitHub API 数据
      String icon = '';
      String packageName = '';
      String appName = '';
      final metadata = await MetadataRepository.instance.fetchInfo(user, repo);
      if (metadata != null) {
        icon = await MetadataRepository.instance.resolveIconUrl(user, repo) ?? '';
        packageName = _validPackageName(metadata['packageName']?.toString());
        appName = metadata['appName']?.toString() ?? '';
      }

      final displayName = appName.isNotEmpty ? appName : name;

      return ChannelResult.success(
        data: AppSummary(
          appId: appId,
          packageName: packageName.isNotEmpty ? packageName : null,
          name: displayName,
          user: user,
          repositories: repo,
          icon: icon,
          des: description,
          category: null,
        ),
        from: ChannelType.github,
        fromCache: false,
      );
    } catch (e) {
      appLog.error('GitHubChannel: 获取应用信息失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async {
    try {
      // 走代理搜索 GitHub 仓库（宽松搜索，用户自选）
      final proxy = getProxy();
      final query = Uri.encodeComponent('$keyword in:name,description,readme');
      final searchUrl =
          'https://api.github.com/search/repositories?q=$query&per_page=30';
      final url = proxy.isNotEmpty ? '$proxy$searchUrl' : searchUrl;

      final response = await _httpClient
          .get(
            Uri.parse(url),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'GStore-App/1.0',
            },
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        return ChannelResult.failure(
          from: ChannelType.github,
          error: '搜索失败: HTTP ${response.statusCode}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? []);
      final apps = items.map((item) {
        final map = item as Map<String, dynamic>;
        final fullName = map['full_name']?.toString() ?? '';
        final owner = map['owner'] as Map<String, dynamic>?;
        final avatar = owner?['avatar_url']?.toString() ?? '';
        return AppSummary(
          appId: fullName, // appId = owner/repo
          name: map['name']?.toString() ?? fullName,
          user: owner?['login']?.toString() ?? '',
          // repositories 存仓库名（full_name 末段），而非完整名——完整名由 appId/apprepo 承载，
          // 存完整名会在聚合层 canonical 成包名后经 addApp 落成脏记录（repositories 含 '/'）
          repositories: fullName.split('/').last,
          icon: avatar, // 临时图标：仓库 owner 头像
          des: map['description']?.toString() ?? '',
          category: null,
        );
      }).toList();

      return ChannelResult.success(
        data: apps,
        from: ChannelType.github,
        fromCache: false,
      );
    } catch (e) {
      appLog.error('GitHubChannel: 搜索应用失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  /// 规范化应用 ID：metadata 已收录时返回真实包名（替换 owner/repo 占位）
  @override
  Future<String> canonicalAppId(AppSummary appInfo) async {
    // 解析 owner/repo：优先 user/repositories（已收录场景 appId 可能是包名）
    String? owner;
    String? repo;
    final parts = appInfo.appId.split('/');
    if (parts.length == 2) {
      owner = parts[0];
      repo = parts[1];
    } else if (appInfo.user.isNotEmpty && appInfo.repositories.isNotEmpty) {
      owner = appInfo.user;
      repo = appInfo.repositories;
    }
    if (owner == null || repo == null) return appInfo.appId;

    final metadata = await MetadataRepository.instance.fetchInfo(owner, repo);
    if (metadata == null) return appInfo.appId;
    final packageName = _validPackageName(metadata['packageName']?.toString());
    return packageName.isNotEmpty ? packageName : appInfo.appId;
  }

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async {
    try {
      if (_database == null) {
        throw Exception('数据库未初始化');
      }
      // 拆分 owner/repo：app.user 存 owner，repositories 存 repo
      // （聚合层已通过 canonicalAppId 规范化 appId，可能为真实包名，owner/repo 从 user/repositories 解析）
      final parts = app.appId.split('/');
      final owner = app.user.isNotEmpty ? app.user : (parts.isNotEmpty ? parts[0] : '');
      final repo = parts.length == 2 ? parts[1] : app.repositories;

      // 优先读取仓库元数据：已收录时用真实图标/包名/应用名（列表即时显示）
      String icon = app.icon;
      String? packageName;
      String appName = app.name;
      if (owner.isNotEmpty && repo.isNotEmpty) {
        final metadata = await MetadataRepository.instance.fetchInfo(owner, repo);
        if (metadata != null) {
          icon = await MetadataRepository.instance.resolveIconUrl(owner, repo) ?? icon;
          packageName = _validPackageName(metadata['packageName']?.toString());
          final metaAppName = metadata['appName']?.toString();
          if (metaAppName != null && metaAppName.isNotEmpty) {
            appName = metaAppName;
          }
        }
      }

      final channelApp = ChannelAddedApp.withChannel(
        appId: app.appId, // 规范化后的 appId（收录时真实包名，否则 owner/repo 占位）
        name: appName,
        user: owner,
        repositories: repo,
        apprepo: parts.length == 2 ? app.appId : (app.appId.contains('/') ? app.appId : null),
        icon: icon,
        description: app.des,
        addTime: DateTime.now().millisecondsSinceEpoch,
        channel: ChannelType.github,
        extra: packageName != null ? jsonEncode({'packageName': packageName}) : null,
      );
      await _database!.dao.insertApp(channelApp);
      appLog.info('GitHubChannel: 添加应用成功 - ${app.appId}');
      return ChannelResult.success(data: null, from: ChannelType.github);
    } catch (e) {
      appLog.error('GitHubChannel: 添加应用失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<void>> removeApp(String appId) async {
    try {
      if (_database == null) {
        throw Exception('数据库未初始化');
      }
      await _database!.dao.removeApp(appId, ChannelType.github.code);
      _cachedApps = null;
      return ChannelResult.success(data: null, from: ChannelType.github);
    } catch (e) {
      appLog.error('GitHubChannel: 移除应用失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async {
    try {
      var allAppsResult = await getAllApps(forceRefresh: forceRefresh);
      if (!allAppsResult.success) {
        return ChannelResult.failure(
          from: ChannelType.github,
          error: allAppsResult.error ?? '搜索失败',
        );
      }

      var apps = allAppsResult.data!.where((app) {
        return app.category?.any((c) => c == categoryId) ?? false;
      }).toList();

      return ChannelResult.success(
        data: apps,
        from: ChannelType.github,
        fromCache: allAppsResult.fromCache,
      );
    } catch (e) {
      appLog.error('GitHubChannel: 按分类搜索失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async {
    try {
      if (!forceRefresh && _cachedCategories != null) {
        return ChannelResult.success(
          data: _cachedCategories!,
          from: ChannelType.github,
          fromCache: true,
        );
      }

      // TODO: 从 GitHub 获取分类数据
      // 这里可以返回默认分类或从文件/配置中读取
      var categories = <db.AppCategory>[];

      _cachedCategories = categories;

      return ChannelResult.success(
        data: categories,
        from: ChannelType.github,
        fromCache: false,
      );
    } catch (e) {
      appLog.error('GitHubChannel: 获取分类失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<bool>> checkUpdate() async {
    try {
      // 检查 GitHub releases 是否有新版本
      var releasesJson = await _githubApi.releases(_user, _repository, 1, CancelToken());
      var releases = List<dynamic>.from(
        jsonDecode(releasesJson) as List,
      );

      if (releases.isEmpty) {
        return ChannelResult.success(
          data: false,
          from: ChannelType.github,
        );
      }

      var latestRelease = releases[0] as Map<String, dynamic>;
      var latestVersion = latestRelease['name'] as String? ?? '';

      // TODO: 与当前版本比较
      bool hasUpdate = false; // 需要实现版本比较逻辑

      return ChannelResult.success(
        data: hasUpdate,
        from: ChannelType.github,
        metadata: {'latestVersion': latestVersion},
      );
    } catch (e) {
      appLog.error('GitHubChannel: 检查更新失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async {
    // GitHub API 渠道不需要更新操作（数据总是最新的）
    return ChannelResult.success(
      data: true,
      from: ChannelType.github,
    );
  }

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async {
    try {
      if (!forceRefresh && _cachedConfig != null) {
        return ChannelResult.success(
          data: _cachedConfig,
          from: ChannelType.github,
          fromCache: true,
        );
      }

      // TODO: 从 GitHub 获取配置
      // 这里可以返回默认配置或从仓库读取
      var config = db.AppInfoConfig('0.0.0', null);

      _cachedConfig = config;

      return ChannelResult.success(
        data: config,
        from: ChannelType.github,
        fromCache: false,
      );
    } catch (e) {
      appLog.error('GitHubChannel: 获取配置失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  @override
  Future<void> clearCache() async {
    _cachedApps = null;
    _cachedCategories = null;
    _cachedConfig = null;
    appLog.info('GitHubChannel: 缓存已清除');
  }

  @override
  Future<int> getCacheSize() async {
    // 内存缓存，计算对象大小较为复杂
    return 0;
  }

  @override
  Future<void> dispose() async {
    await clearCache();
    isInitialized = false;
    appLog.info('GitHubChannel: 已释放');
  }

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async {
    try {
      // 先获取基本应用信息
      final appInfoResult = await getAppInfo(appId, forceRefresh: forceRefresh);
      if (!appInfoResult.success || appInfoResult.data == null) {
        return ChannelResult.failure(
          from: ChannelType.github,
          error: appInfoResult.error ?? '应用不存在',
        );
      }

      final appInfo = appInfoResult.data!;

      // 并发获取 API 信息和 Releases
      final results = await Future.wait([
        _githubApi.apiList(appInfo.user, appInfo.repositories, CancelToken()),
        _githubApi.releases(appInfo.user, appInfo.repositories, 1, CancelToken()),
      ]);

      // 优先读取仓库元数据（真实图标 / 包名 / 版本），未收录时回退默认数据
      // 负缓存命中（此前未收录）时绕过一次重试——应用可能刚被收录（如刚提交 issue）
      var metadata = await MetadataRepository.instance
          .fetchInfo(appInfo.user, appInfo.repositories);
      if (metadata == null) {
        metadata = await MetadataRepository.instance.fetchInfo(
          appInfo.user,
          appInfo.repositories,
          ignoreNegativeCache: true,
        );
      }
      final metadataIcon =
          metadata != null ? await MetadataRepository.instance.resolveIconUrl(appInfo.user, appInfo.repositories) : null;

      // apiList 返回 ApiList 对象（非 JSON 字符串）
      final ApiList apiList = results[0] as ApiList;

      // 解析 Releases（下载列表 + 最新版本 + 原始 release Map，与 fetchDownloads 共用解析）
      final releases = await _fetchReleasesFor(
        appInfo,
        releasesJson: results[1] as String,
      );
      final downloads = releases.downloads;
      final latestVersion = releases.latestVersion;

      // 获取 README（contents API + ETag 条件缓存 + README.MD 回退 + 图片绝对化，
      // 与 fetchReadme 共用逻辑；分支从 contents 响应 download_url 提取）
      final readme = await _fetchReadmeInternal(appInfo);

      // 构建原始数据 Map（保持原始格式）
      final rawData = <String, dynamic>{
        'appId': appInfo.appId,
        // 优先使用元数据仓库的真实应用名，未收录时回退仓库名
        'name': metadata?['appName']?.toString().isNotEmpty == true
            ? metadata!['appName'].toString()
            : appInfo.name,
        // 优先使用元数据仓库的真实图标，未收录时回退 owner 头像
        'icon': metadataIcon ?? appInfo.icon,
        'description': appInfo.des,
        // 优先使用元数据的版本信息（versionName）
        'version': metadata?['versionName']?.toString() ?? latestVersion,
        'developer': appInfo.user,
        // 优先使用元数据的真实包名；否则回退 AppSummary.packageName（渠道显式提供的真实包名）；
        // 未收录时不用仓库名占位（repo 名不是包名，避免误用于安装检测）
        'packageName': _validPackageName(metadata?['packageName']?.toString()).isNotEmpty
            ? _validPackageName(metadata?['packageName']?.toString())
            : _validPackageName(appInfo.packageName),
        'projectUrl': apiList.html_url?.toString(),
        'sections': _buildSections(downloads, readme, apiList),
        'downloads': downloads,
        'readme': readme,
        'imageBuilder': (Uri uri, String? title, String? alt) {
          final url = uri.toString();
          if (url.endsWith('.svg')) {
            return null; // 使用默认的 SVG 处理
          }
          return null; // 使用默认的网络图片处理
        },
        // apiData 用 Map 存储（GitHubChannelDetailProxy.buildStatTags 按 Map 读取；
        // 与 fetchStatistics 共用转换）
        'apiData': _apiListToMap(apiList),
        'releaseData': releases.latestRelease,
        // 元数据（versionCode 等扩展信息，供更新检测/展示使用）
        if (metadata != null) 'metadata': metadata,
      };

      // 使用代理类包装原始数据
      final detailData = GitHubChannelDetailProxy(rawData);

      return ChannelResult.success(
        data: detailData,
        from: ChannelType.github,
        fromCache: false,
      );
    } catch (e) {
      appLog.error('GitHubChannel: 获取应用详情失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  /// 支持分块渐进加载（详情页走三路独立渐进渲染）
  @override
  bool get supportsProgressiveLoading => true;

  /// 分块加载：仅下载列表（不拉 README/统计）。
  /// getAppInfo → 最新 release 解析（与 getAppDetail 共用 _fetchReleasesFor）
  @override
  Future<ChannelResult<List<DownloadInfo>>> fetchDownloads(String appId) async {
    try {
      final appInfoResult = await getAppInfo(appId);
      if (!appInfoResult.success || appInfoResult.data == null) {
        return ChannelResult.failure(
          from: ChannelType.github,
          error: appInfoResult.error ?? '应用不存在',
        );
      }
      final result = await _fetchReleasesFor(appInfoResult.data!);
      return ChannelResult.success(
        data: result.downloads,
        from: ChannelType.github,
      );
    } catch (e) {
      appLog.error('GitHubChannel: 获取下载列表失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  /// 分块加载：仅 README（读缓存 / 条件请求）。
  /// getAppInfo → contents API + ETag 缓存（与 getAppDetail 共用；不再依赖
  /// apiList 取分支，分支由 contents 响应 download_url 提取，省 1 次 apiList
  /// 请求降低限流概率）。
  /// getAppInfo 失败（如离线/限流）时按 appId（owner/repo 格式）拆 owner/repo
  /// 纯缓存兜底：ReadmeCache 命中直接返回缓存文本，不再整路 failure。
  @override
  Future<ChannelResult<String?>> fetchReadme(String appId) async {
    try {
      final appInfoResult = await getAppInfo(appId);
      if (!appInfoResult.success || appInfoResult.data == null) {
        // getAppInfo 失败（如离线/限流）：按 appId（owner/repo 格式）拆 owner/repo，纯缓存兜底
        final parts = appId.split('/');
        if (parts.length == 2) {
          final cached = await ReadmeCache.instance.get(parts[0], parts[1]);
          if (cached != null) {
            return ChannelResult.success(
              data: cached.readme,
              from: ChannelType.github,
            );
          }
        }
        return ChannelResult.failure(
          from: ChannelType.github,
          error: appInfoResult.error ?? '应用不存在',
        );
      }
      final readme = await _fetchReadmeInternal(appInfoResult.data!);
      return ChannelResult.success(data: readme, from: ChannelType.github);
    } catch (e) {
      appLog.error('GitHubChannel: 获取 README 失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  /// 分块加载：仅统计/版本/开发者（apiList 原始 Map，供 buildStatTags 解析）
  @override
  Future<ChannelResult<Map<String, dynamic>?>> fetchStatistics(
    String appId,
  ) async {
    try {
      final appInfoResult = await getAppInfo(appId);
      if (!appInfoResult.success || appInfoResult.data == null) {
        return ChannelResult.failure(
          from: ChannelType.github,
          error: appInfoResult.error ?? '应用不存在',
        );
      }
      final appInfo = appInfoResult.data!;
      // 并行：仓库统计 + 元数据（fetchInfo 有缓存，成本低；metadata 含 APK 提取的
      // versionName/versionCode，fetchInfo 内部兜底异常/未收录 → null，不阻塞统计）
      final results = await Future.wait<Object?>([
        _githubApi.apiList(
          appInfo.user,
          appInfo.repositories,
          CancelToken(),
        ),
        MetadataRepository.instance.fetchInfo(appInfo.user, appInfo.repositories),
      ]);
      final apiList = results[0] as ApiList;
      final metadata = results[1] as Map<String, dynamic>?;
      return ChannelResult.success(
        data: {
          ..._apiListToMap(apiList),
          if (metadata != null) ...{
            'versionName': metadata['versionName']?.toString(),
            'versionCode': metadata['versionCode'],
            'metadata': metadata,
          },
        },
        from: ChannelType.github,
      );
    } catch (e) {
      appLog.error('GitHubChannel: 获取统计信息失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.github,
        error: e.toString(),
      );
    }
  }

  /// 拉取最新 release 并解析为下载列表 + 最新版本 + 原始 release Map。
  ///
  /// getAppDetail 与 fetchDownloads 共用解析逻辑；[releasesJson] 由
  /// getAppDetail 并发预取后传入（避免重复请求），null 时内部拉取。
  /// 解析失败抛异常（getAppDetail 由外层兜底；fetchDownloads 转为 failure）。
  Future<
      ({
        List<DownloadInfo> downloads,
        Map<String, dynamic>? latestRelease,
        String? latestVersion,
      })> _fetchReleasesFor(AppSummary appInfo, {String? releasesJson}) async {
    final json = releasesJson ??
        await _githubApi.releases(
          appInfo.user,
          appInfo.repositories,
          1,
          CancelToken(),
        );
    final List<dynamic> releases = List<dynamic>.from(
      jsonDecode(json) as List,
    );

    // 构建下载列表
    final downloads = <DownloadInfo>[];
    String? latestVersion;
    DateTime? publishedAt;
    Map<String, dynamic>? latestRelease;

    debugPrint('GitHubChannel: releases 数量 = ${releases.length}');

    if (releases.isNotEmpty) {
      latestRelease = releases[0] as Map<String, dynamic>;
      latestVersion = latestRelease['name']?.toString() ??
          latestRelease['tag_name']?.toString();
      publishedAt = latestRelease['published_at'] != null
          ? DateTime.parse(latestRelease['published_at'].toString())
          : null;

      final assets = latestRelease['assets'] as List<dynamic>? ?? [];
      debugPrint('GitHubChannel: assets 数量 = ${assets.length}');

      for (var asset in assets) {
        if (asset is Map<String, dynamic>) {
          final downloadInfo = DownloadInfo(
            url: asset['browser_download_url']?.toString() ?? '',
            name: asset['name']?.toString() ?? '',
            size: asset['size'] as int?,
            downloadCount: asset['download_count'] as int?,
            version: latestVersion,
            publishedAt: publishedAt,
            platform: _parsePlatformFromAssetName(asset['name']?.toString() ?? ''),
          );
          downloads.add(downloadInfo);
          debugPrint('GitHubChannel: 添加下载文件 - ${downloadInfo.name}');
        }
      }
    }

    debugPrint('GitHubChannel: 最终下载列表数量 = ${downloads.length}');
    return (
      downloads: downloads,
      latestRelease: latestRelease,
      latestVersion: latestVersion,
    );
  }

  /// 获取 README（contents API + ETag 条件缓存 + README.MD 回退 + 图片绝对化）。
  ///
  /// getAppDetail 与 fetchReadme 共用。请求**不带 ?ref=**（GitHub 默认分支语义），
  /// 图片绝对化基准分支从 200 响应 JSON 的 download_url 提取（失败兜底 'main'），
  /// 不再依赖 apiList（省 1 次限流配额）。缓存存绝对化后文本（304 命中直接渲染，
  /// 无需重复 resolve）；请求失败（网络/限流/离线）时兜底返回缓存文本，
  /// 避免 README 区随 apiList 限流凭空消失。
  Future<String?> _fetchReadmeInternal(AppSummary appInfo) async {
    try {
      final cached =
          await ReadmeCache.instance.get(appInfo.user, appInfo.repositories);
      final headers = cached != null ? {'If-None-Match': cached.etag} : null;
      final apiBase =
          'https://api.github.com/repos/${appInfo.user}/${appInfo.repositories}/contents';
      appLog.info('GitHubChannel: README 请求', data: {
        'url': '$apiBase/README.md',
        'proxy': getProxy(),
        '缓存': cached != null,
      });
      // 直连 api.github.com（与 _githubApi 一致）：gh-proxy 不支持 contents API（403）
      final readmeResp = await _httpClient
          .get(
            Uri.parse('$apiBase/README.md'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      appLog.info('GitHubChannel: README 响应', data: {
        'statusCode': readmeResp.statusCode,
        'etag': readmeResp.headers['etag'],
        '分支': 'README.md',
      });
      if (readmeResp.statusCode == 304 && cached != null) {
        // 条件命中：直接用缓存（已绝对化）
        return cached.readme;
      }
      if (readmeResp.statusCode == 200 && readmeResp.body.isNotEmpty) {
        final branch = _extractBranchFromContentsJson(readmeResp.body, appInfo);
        final rawBaseUrl =
            'https://raw.githubusercontent.com/${appInfo.user}/${appInfo.repositories}/refs/heads/${branch ?? 'main'}/';
        final readme = decodeContentsReadme(readmeResp.body);
        final etag = readmeResp.headers['etag'];
        if (readme != null) {
          final resolved = resolveReadmeImageUrls(readme, rawBaseUrl);
          if (etag != null && etag.isNotEmpty) {
            await ReadmeCache.instance.put(appInfo.user,
                appInfo.repositories,
                etag: etag, readme: resolved);
            appLog.info('GitHubChannel: README 缓存写入', data: {
              'etag': etag,
              '长度': resolved.length,
            });
          }
          return resolved;
        }
      }
      // 非 200/304：缓存兜底（403 代理拒绝/限流/404 等），不静默 null 丢弃
      if (readmeResp.statusCode != 200 && readmeResp.statusCode != 304) {
        appLog.warning('GitHubChannel: README 获取非 200', data: {
          'statusCode': readmeResp.statusCode,
          '缓存兜底': cached != null,
        });
        if (cached != null) return cached.readme;
      }
      // fallback README.MD（同样不带 ref；同 key 复用主 etag 条件请求；同结构缓存兜底）
      appLog.info('GitHubChannel: README 请求', data: {
        'url': '$apiBase/README.MD',
        'proxy': getProxy(),
        '缓存': cached != null,
      });
      final upperResp = await _httpClient
          .get(
            Uri.parse('$apiBase/README.MD'),
            headers: headers,
          )
          .timeout(const Duration(seconds: 10));
      appLog.info('GitHubChannel: README 响应', data: {
        'statusCode': upperResp.statusCode,
        'etag': upperResp.headers['etag'],
        '分支': 'README.MD',
      });
      if (upperResp.statusCode == 304 && cached != null) {
        return cached.readme;
      }
      if (upperResp.statusCode == 200 && upperResp.body.isNotEmpty) {
        final branch =
            _extractBranchFromContentsJson(upperResp.body, appInfo);
        final rawBaseUrl =
            'https://raw.githubusercontent.com/${appInfo.user}/${appInfo.repositories}/refs/heads/${branch ?? 'main'}/';
        final readme = decodeContentsReadme(upperResp.body);
        final etag = upperResp.headers['etag'];
        if (readme != null) {
          final resolved = resolveReadmeImageUrls(readme, rawBaseUrl);
          if (etag != null && etag.isNotEmpty) {
            await ReadmeCache.instance.put(appInfo.user,
                appInfo.repositories,
                etag: etag, readme: resolved);
            appLog.info('GitHubChannel: README 缓存写入', data: {
              'etag': etag,
              '长度': resolved.length,
            });
          }
          return resolved;
        }
      }
      if (upperResp.statusCode != 200 && upperResp.statusCode != 304) {
        appLog.warning('GitHubChannel: README 获取非 200', data: {
          'statusCode': upperResp.statusCode,
          '缓存兜底': cached != null,
        });
        if (cached != null) return cached.readme;
      }
      return null;
    } catch (e) {
      appLog.error('GitHubChannel: 获取 README 失败 - $e');
      // 请求失败（网络/限流/离线）：缓存仍显示，不随失败消失
      try {
        final cached = await ReadmeCache.instance
            .get(appInfo.user, appInfo.repositories);
        if (cached != null) {
          appLog.info('GitHubChannel: README 缓存兜底', data: {
            '原因': '请求异常',
            '缓存': true,
          });
          return cached.readme;
        }
      } catch (_) {}
      return null;
    }
  }

  /// 从 contents API 响应 JSON 的 download_url 提取分支名（图片绝对化基准）。
  /// 格式 https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{file}
  /// 提取失败返回 null（调用方兜底 'main'）。
  String? _extractBranchFromContentsJson(String body, AppSummary appInfo) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['download_url'] is String) {
        final segs = Uri.parse(decoded['download_url'] as String).pathSegments;
        if (segs.length >= 3 &&
            segs[0] == appInfo.user &&
            segs[1] == appInfo.repositories) {
          return segs[2];
        }
      }
    } catch (_) {}
    return null;
  }

  /// ApiList → Map（buildStatTags 按 'stargazers_count'/'forks_count' 读取；
  /// ApiList.toJson 的 key 为 'forks'，不可直接复用）
  Map<String, dynamic> _apiListToMap(ApiList apiList) => {
        'stargazers_count': apiList.stargazers_count,
        'forks_count': apiList.forks,
        'default_branch': apiList.default_branch,
        'html_url': apiList.html_url,
        'full_name': apiList.full_name,
        'description': apiList.description,
        'created_at': apiList.created_at,
      };

  /// 规范化渠道记录：repositories 被误存为完整名（owner/repo，历史安装迁移 bug 产物）
  /// 时拆分为 user/repositories，apprepo 保留完整名；其余字段原样。
  /// 非脏数据（repositories 无 '/'）原样返回。GitHub 仓库名不可能含 '/'，误判面为零。
  @visibleForTesting
  static ChannelAddedApp normalizeStoredRecord(ChannelAddedApp record) {
    if (!record.repositories.contains('/')) return record;
    final parts = record.repositories.split('/');
    if (parts.length != 2) return record;
    return ChannelAddedApp(
      appId: record.appId,
      name: record.name,
      user: parts[0],
      repositories: parts[1],
      apprepo: record.apprepo ?? record.repositories,
      icon: record.icon,
      description: record.description,
      category: record.category,
      addTime: record.addTime,
      channelCode: record.channelCode,
      extra: record.extra,
    );
  }

  /// 读取渠道记录并做脏数据自愈（读取边界统一入口）
  /// 历史脏记录（repositories 含完整名）拆分修正后回写，一次后即净
  Future<List<ChannelAddedApp>> _loadChannelApps() async {
    if (_database == null) {
      throw Exception('数据库未初始化');
    }
    final apps = await _database!.dao
        .getAppsByChannel(ChannelType.github.code);
    final corrected = <ChannelAddedApp>[];
    for (final record in apps) {
      final normalized = normalizeStoredRecord(record);
      if (!identical(normalized, record)) {
        try {
          await _database!.dao.insertApp(normalized);
        } catch (e) {
          appLog.error('GitHubChannel: 自愈脏记录失败 - $e');
        }
      }
      corrected.add(normalized);
    }
    return corrected;
  }

  /// 渠道记录 appId 迁移：owner/repo → 真实包名（下载解析 APK 后调用）
  ///
  /// 语义：appId 是唯一需要变化的标识，user/repositories（owner/repo）必须保留，
  /// apprepo 兜底记录完整名，extra.packageName 同步为新包名（APK 解析是 ground truth）。
  /// 未匹配记录（appId 或 apprepo 均不等于 oldAppId）返回 null，不做任何修改。
  ///
  /// 注意：本方法只动渠道库，聚合层（AppAggregatorManager）的 appId 同步由调用方编排。
  Future<ChannelAddedApp?> migrateAppId({
    required String oldAppId,
    required String newPackageName,
    String? name,
    String? icon,
  }) async {
    if (oldAppId == newPackageName || newPackageName.isEmpty) return null;
    final db = _database ?? await ChannelDatabaseManager.instance;

    // 精确 PK 匹配优先，未命中再按 apprepo 兜底（兼容重复下载/历史记录）
    var matched = await db.dao.getApp(oldAppId, ChannelType.github.code);
    if (matched == null) {
      final byApprepo = await db.dao
          .getAppsByChannel(ChannelType.github.code)
          .then((list) => list.where((r) => r.apprepo == oldAppId));
      if (byApprepo.isEmpty) return null;
      matched = byApprepo.first;
    }
    if (matched.appId == newPackageName) return matched;
    final record = matched;

    // 注：floor 1.4.2 生成的 DAO 无事务支持，沿用项目既有 insert+remove 模式；
    // 若 insert 成功而 remove 失败残留双记录，REPLACE(同 PK)/下次迁移可覆盖自愈
    final updated = ChannelAddedApp(
      appId: newPackageName,
      name: name ?? record.name,
      user: record.user,
      repositories: record.repositories,
      apprepo: record.apprepo ?? oldAppId,
      icon: icon ?? record.icon,
      description: record.description,
      category: record.category,
      addTime: record.addTime,
      channelCode: ChannelType.github.code,
      extra: _mergePackageName(record.extra, newPackageName),
    );
    await db.dao.insertApp(updated);
    // 复合主键 (channelCode, appId)：新 appId 插入后旧行残留，需删除
    await db.dao.removeApp(record.appId, ChannelType.github.code);

    await clearCache();
    appLog.info('GitHubChannel: 渠道记录 appId 迁移 $oldAppId -> $newPackageName');
    return updated;
  }

  /// 合并包名到 extra（保留既有字段，packageName 覆盖为新值）
  String? _mergePackageName(String? extra, String packageName) {
    Map<String, dynamic> data;
    if (extra != null && extra.isNotEmpty) {
      try {
        data = jsonDecode(extra) as Map<String, dynamic>;
      } catch (_) {
        data = {};
      }
    } else {
      data = {};
    }
    data['packageName'] = packageName;
    return jsonEncode(data);
  }

  /// 从渠道数据库记录构建 AppSummary
  /// 优先用 metadata 覆盖真实图标/应用名/包名；未收录回退数据库记录；
  /// 数据有变化时同步回写渠道数据库（保持最新）
  Future<AppSummary> _buildStoredAppInfo(ChannelAddedApp stored) async {
    // 历史脏数据自愈：repositories 误存完整名时拆分修正并回写
    // （须在 early-return 之前——脏记录 user 非空会绕过下方 guard；
    //   也须在 metadata fetch 之前——后续用修正后的 owner/repo 查询）
    final normalized = normalizeStoredRecord(stored);
    if (!identical(normalized, stored)) {
      try {
        await _database!.dao.insertApp(normalized);
      } catch (e) {
        appLog.error('GitHubChannel: 自愈脏记录失败 - $e');
      }
      stored = normalized;
    }

    // 缺少 user/repositories（无法解析仓库）时直接返回记录
    if (stored.user.isEmpty || stored.repositories.isEmpty) {
      return AppSummary.fromChannelAddedApp(stored);
    }

    final metadata = await MetadataRepository.instance
        .fetchInfo(stored.user, stored.repositories);
    if (metadata == null) {
      // 未收录：回退渠道数据库记录
      return AppSummary.fromChannelAddedApp(stored);
    }

    final packageName = _validPackageName(metadata['packageName']?.toString());
    final metadataName = metadata['appName']?.toString() ?? '';
    final metadataIcon = await MetadataRepository.instance
        .resolveIconUrl(stored.user, stored.repositories);
    final displayName = metadataName.isNotEmpty ? metadataName : stored.name;
    final icon = (metadataIcon?.isNotEmpty ?? false) ? metadataIcon! : stored.icon;

    // 数据有变化：同步回写渠道数据库（避免每次覆盖，仅变化时写）
    if (icon != stored.icon || displayName != stored.name) {
      try {
        await _database!.dao.insertApp(ChannelAddedApp(
          appId: stored.appId,
          name: displayName,
          user: stored.user,
          repositories: stored.repositories,
          apprepo: stored.apprepo,
          icon: icon,
          description: stored.description,
          category: stored.category,
          addTime: stored.addTime,
          channelCode: stored.channelCode,
          extra: packageName.isNotEmpty
              ? jsonEncode({'packageName': packageName})
              : stored.extra,
        ));
        appLog.info('GitHubChannel: 渠道记录已同步 metadata - ${stored.user}/${stored.repositories}');
      } catch (e) {
        appLog.error('GitHubChannel: 同步渠道记录失败 - $e');
      }
    }

    final fromStored = AppSummary.fromChannelAddedApp(stored);
    return AppSummary(
      appId: stored.appId,
      packageName: packageName.isNotEmpty ? packageName : fromStored.packageName,
      name: displayName,
      user: stored.user,
      repositories: stored.repositories,
      icon: icon,
      des: stored.description,
      readme: fromStored.readme,
      category: stored.category?.split(','),
      extra: fromStored.extra,
    );
  }

  /// 校验元数据中的包名：Android 包名必须含至少一个 '.'，
  /// 过滤掉脏数据（如误存的应用名/仓库名），无效返回空串
  String _validPackageName(String? packageName) {
    final value = packageName?.trim() ?? '';
    if (value.isEmpty || !value.contains('.')) return '';
    return value;
  }

  /// 从文件名解析平台信息
  String? _parsePlatformFromAssetName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.contains('universal')) return 'universal';
    if (lower.contains('arm64') || lower.contains('arm64-v8a')) return 'arm64-v8a';
    if (lower.contains('armeabi-v7a')) return 'armeabi-v7a';
    if (lower.contains('x86_64')) return 'x86_64';
    if (lower.contains('x86')) return 'x86';
    if (lower.contains('windows')) return 'windows';
    if (lower.contains('linux')) return 'linux';
    if (lower.contains('macos') || lower.contains('darwin')) return 'macos';
    return null;
  }

  /// 根据可用数据构建 sections 列表
  List<DetailSection> _buildSections(
    List<DownloadInfo> downloads,
    String? readme,
    ApiList apiList,
  ) {
    final sections = <DetailSection>[];

    // 统计数据（GitHub 特有）
    if (apiList.stargazers_count != null || apiList.forks != null) {
      sections.add(DetailSection.statistics);
    }

    // 版本信息 - 只在有下载时显示
    if (downloads.isNotEmpty) {
      sections.add(DetailSection.version);
    }

    // 下载列表 - 始终添加，显示可用文件或"无可用文件"消息
    sections.add(DetailSection.downloads);

    // README
    if (readme != null && readme.isNotEmpty) {
      sections.add(DetailSection.readme);
    }

    return sections;
  }

  @override
  Widget? getAddAppWidget(
    BuildContext context,
    Function(AppSummary) onAppAdded, {
    VoidCallback? onAppSaved,
  }) {
    // GitHub 渠道暂不支持通过 UI 添加应用
    // 需要通过修改 GitHub 仓库来添加应用
    return null;
  }

  AppSummary _createNotFoundApp(String appId) {
    return AppSummary(
      appId: appId,
      name: '',
      user: '',
      repositories: '',
      icon: '',
      des: '应用不存在',
      category: null,
    );
  }
}

/// 解析 GitHub contents API 响应（JSON: {content: base64, encoding}）→ markdown 文本
/// JSON 解析失败/无 content → 原样返回 body（兼容 raw 文本响应）；空/解码失败 → null
String? decodeContentsReadme(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['content'] is String) {
      final b64 = (decoded['content'] as String).replaceAll(RegExp(r'\s'), '');
      return utf8.decode(base64Decode(b64));
    }
    return body; // 无 content（如 raw 文本）→ 原样
  } catch (_) {
    try {
      return utf8.decode(base64Decode(body)); // 兼容：body 直接是 base64
    } catch (_) {
      return body;
    }
  }
}

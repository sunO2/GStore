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
import 'package:gstore/core/core.dart';
import 'package:gstore/core/data/metadata_repository.dart';

/// GitHub API 渠道实现
/// 通过 GitHub API 获取应用数据
class GitHubChannel with AppUpdateCheckMixin implements IChannel {
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

      // 从渠道数据库读取已添加应用
      if (_database == null) {
        throw Exception('数据库未初始化');
      }
      final channelApps = await _database!.dao
          .getAppsByChannel(ChannelType.github.code);
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
          repositories: fullName, // repositories = full_name
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
      final String releasesJson = results[1] as String;

      // 解析 Releases
      final List<dynamic> releases = List<dynamic>.from(
        jsonDecode(releasesJson) as List,
      );

      // 构建下载列表
      final downloads = <DownloadInfo>[];
      String? latestVersion;
      DateTime? publishedAt;

      debugPrint('GitHubChannel: releases 数量 = ${releases.length}');

      if (releases.isNotEmpty) {
        final latestRelease = releases[0] as Map<String, dynamic>;
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

      // 获取 README（添加超时控制）
      String? readme;
      if (apiList.default_branch != null &&
          apiList.default_branch!.isNotEmpty) {
        final branch = apiList.default_branch!;
        final rawBaseUrl = 'https://raw.githubusercontent.com/${appInfo.user}/${appInfo.repositories}/refs/heads/$branch/';
        try {
          // raw.githubusercontent.com 需走代理（与 MetadataRepository 一致）
          final readmeMdResp = await _httpClient
              .get(Uri.parse(applyProxyIfNeeded('${rawBaseUrl}README.md', getProxy())))
              .timeout(const Duration(seconds: 10));
          if (readmeMdResp.statusCode == 200 && readmeMdResp.body.isNotEmpty) {
            readme = readmeMdResp.body;
          } else {
            final readmeMdUpperResp = await _httpClient
                .get(Uri.parse(applyProxyIfNeeded('${rawBaseUrl}README.MD', getProxy())))
                .timeout(const Duration(seconds: 10));
            if (readmeMdUpperResp.statusCode == 200 && readmeMdUpperResp.body.isNotEmpty) {
              readme = readmeMdUpperResp.body;
            }
          }
        } catch (e) {
          appLog.error('GitHubChannel: 获取 README 失败 - $e');
        }
      }

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
        // 优先使用元数据的真实包名；否则仅当 appId 已是真实包名（下载后替换，含 '.'）时使用；
        // 未收录时不用仓库名占位（repo 名不是包名，避免误用于安装检测）
        'packageName': _validPackageName(metadata?['packageName']?.toString()).isNotEmpty
            ? _validPackageName(metadata?['packageName']?.toString())
            : (appId.contains('.') ? appId : ''),
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
        // apiData 用 Map 存储（GitHubChannelDetailProxy.buildStatTags 按 Map 读取）
        'apiData': {
          'stargazers_count': apiList.stargazers_count,
          'forks_count': apiList.forks,
        },
        'releaseData': releases.isNotEmpty ? releases[0] : null,
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

  /// 从渠道数据库记录构建 AppSummary
  /// 优先用 metadata 覆盖真实图标/应用名/包名；未收录回退数据库记录；
  /// 数据有变化时同步回写渠道数据库（保持最新）
  Future<AppSummary> _buildStoredAppInfo(ChannelAddedApp stored) async {
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

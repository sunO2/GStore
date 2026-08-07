import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/proxy/GitHubChannelDetailProxy.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/http/github/github_client.dart';
import 'package:http/http.dart' as http;
import 'package:gstore/core/channel/AppUpdateCheckMixin.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/core.dart';

/// GitHub API 渠道实现
/// 通过 GitHub API 获取应用数据
class GitHubChannel with AppUpdateCheckMixin implements IChannel {
  final GithubRestClient _githubApi;
  final String _user;
  final String _repository;

  /// 渠道数据库（已添加应用存储）
  ChannelDatabase? _database;

  @override
  ChannelInfo info;

  @override
  bool isInitialized = false;

  // 缓存数据
  List<AppInfo>? _cachedApps;
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
  })  : _githubApi = githubApi,
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
  Future<ChannelResult<List<AppInfo>>> getAllApps({
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
      final apps = channelApps.map((c) {
        return AppInfo(
          c.appId,
          c.name,
          c.user,
          c.repositories,
          c.icon,
          c.description,
          c.category?.split(','),
        );
      }).toList();

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
  Future<ChannelResult<AppInfo?>> getAppInfo(
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
          return ChannelResult.success(
            data: AppInfo(
              stored.appId,
              stored.name,
              stored.user,
              stored.repositories,
              stored.icon,
              stored.description,
              stored.category?.split(','),
            ),
            from: ChannelType.github,
            fromCache: true,
          );
        }
      }

      // appId 格式为 owner/repo，拆分后从 GitHub API 获取
      final parts = appId.split('/');
      if (parts.length != 2) {
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

      return ChannelResult.success(
        data: AppInfo(
          appId,
          name,
          user,
          repo,
          '',
          description,
          null,
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
  Future<ChannelResult<List<AppInfo>>> searchApps(
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

      final response = await http
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
        return AppInfo(
          fullName, // appId = owner/repo
          map['name']?.toString() ?? fullName,
          owner?['login']?.toString() ?? '',
          fullName, // repositories = full_name
          avatar, // 临时图标：仓库 owner 头像
          map['description']?.toString() ?? '',
          null,
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

  @override
  Future<ChannelResult<void>> addApp(AppInfo app) async {
    try {
      if (_database == null) {
        throw Exception('数据库未初始化');
      }
      // 拆分 owner/repo：app.user 存 owner，repositories 存 repo
      final parts = app.appId.split('/');
      final owner = app.user.isNotEmpty ? app.user : (parts.isNotEmpty ? parts[0] : '');
      final repo = parts.length == 2 ? parts[1] : app.repositories;

      final channelApp = ChannelAddedApp.withChannel(
        appId: app.appId, // 暂用 owner/repo
        name: app.name,
        user: owner,
        repositories: repo,
        apprepo: app.appId, // 仓库完整名
        icon: app.icon,
        description: app.des,
        addTime: DateTime.now().millisecondsSinceEpoch,
        channel: ChannelType.github,
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
  Future<ChannelResult<List<AppInfo>>> searchByCategory(
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
          final readmeMdResp = await http
              .get(Uri.parse('${rawBaseUrl}README.md'))
              .timeout(const Duration(seconds: 10));
          if (readmeMdResp.statusCode == 200 && readmeMdResp.body.isNotEmpty) {
            readme = readmeMdResp.body;
          } else {
            final readmeMdUpperResp = await http
                .get(Uri.parse('${rawBaseUrl}README.MD'))
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
        'name': appInfo.name,
        'icon': appInfo.icon,
        'description': appInfo.des,
        'version': latestVersion,
        'developer': appInfo.user,
        // GitHub 应用真实包名在下载解析后存于 appId（含 '.'）；未更新时用仓库名
        'packageName': appId.contains('.') ? appId : appInfo.repositories,
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
    Function(AppInfo) onAppAdded, {
    VoidCallback? onAppSaved,
  }) {
    // GitHub 渠道暂不支持通过 UI 添加应用
    // 需要通过修改 GitHub 仓库来添加应用
    return null;
  }

  AppInfo _createNotFoundApp(String appId) {
    return AppInfo(
      '',
      '',
      '',
      '',
      '',
      '应用不存在',
      null,
    );
  }
}

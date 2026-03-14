import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailData.dart';
import 'package:gstore/core/model/proxy/GitHubChannelDetailProxy.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/http/github/github_client.dart';
import 'package:http/http.dart' as http;

/// GitHub API 渠道实现
/// 通过 GitHub API 获取应用数据
class GitHubChannel implements IChannel {
  final GithubRestClient _githubApi;
  final String _user;
  final String _repository;

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
    // GitHub API 无需特殊初始化
    isInitialized = true;
    debugPrint('GitHubChannel: 初始化完成');
  }

  @override
  Future<bool> checkAvailable() async {
    try {
      // 尝试获取 releases 来检查 API 是否可用
      await _githubApi.releases(_user, _repository, 1, CancelToken());
      return true;
    } catch (e) {
      debugPrint('GitHubChannel: API 不可用 - $e');
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

      // 从 GitHub releases 获取数据
      // 注意: 这里需要根据实际的 GitHub 数据结构进行解析
      // 当前实现返回空列表，需要根据实际情况调整

      var apps = <AppInfo>[];
      // TODO: 实现从 GitHub API 获取应用列表的逻辑
      // 例如解析 releases 或其他数据源

      _cachedApps = apps;

      return ChannelResult.success(
        data: apps,
        from: ChannelType.github,
        fromCache: false,
      );
    } catch (e) {
      debugPrint('GitHubChannel: 获取应用列表失败 - $e');
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
      // 先从缓存中查找
      if (_cachedApps != null) {
        var app = _cachedApps!.firstWhere(
          (a) => a.appId == appId,
          orElse: () => _createNotFoundApp(appId),
        );
        return ChannelResult.success(
          data: app.appId.isEmpty ? null : app,
          from: ChannelType.github,
          fromCache: true,
        );
      }

      // 从 API 获取
      // TODO: 实现从 GitHub API 获取单个应用信息的逻辑
      return ChannelResult.success(
        data: null,
        from: ChannelType.github,
      );
    } catch (e) {
      debugPrint('GitHubChannel: 获取应用信息失败 - $e');
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
      var allAppsResult = await getAllApps(forceRefresh: forceRefresh);
      if (!allAppsResult.success) {
        return ChannelResult.failure(
          from: ChannelType.github,
          error: allAppsResult.error ?? '搜索失败',
        );
      }

      var apps = allAppsResult.data!.where((app) {
        return app.name.toLowerCase().contains(keyword.toLowerCase()) ||
            app.des.toLowerCase().contains(keyword.toLowerCase());
      }).toList();

      return ChannelResult.success(
        data: apps,
        from: ChannelType.github,
        fromCache: allAppsResult.fromCache,
      );
    } catch (e) {
      debugPrint('GitHubChannel: 搜索应用失败 - $e');
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
      debugPrint('GitHubChannel: 按分类搜索失败 - $e');
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
      debugPrint('GitHubChannel: 获取分类失败 - $e');
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
      debugPrint('GitHubChannel: 检查更新失败 - $e');
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
      debugPrint('GitHubChannel: 获取配置失败 - $e');
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
    debugPrint('GitHubChannel: 缓存已清除');
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
    debugPrint('GitHubChannel: 已释放');
  }

  @override
  Future<ChannelResult<IDetailData>> getAppDetail(
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

      final apiListJson = results[0];
      final releasesJson = results[1];

      // 解析 API 信息
      final apiList = jsonDecode(apiListJson as String) as Map<String, dynamic>;

      // 解析 Releases
      final List<dynamic> releases = List<dynamic>.from(
        jsonDecode(releasesJson as String) as List,
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

      // 获取 README
      String? readme;
      if (apiList is Map && apiList['default_branch'] != null) {
        final branch = apiList['default_branch'].toString();
        final rawBaseUrl = 'https://raw.githubusercontent.com/${appInfo.user}/${appInfo.repositories}/refs/heads/$branch/';
        try {
          final readmeMdResp = await http.get(Uri.parse('${rawBaseUrl}README.md'));
          if (readmeMdResp.statusCode == 200 && readmeMdResp.body.isNotEmpty) {
            readme = readmeMdResp.body;
          } else {
            final readmeMdUpperResp = await http.get(Uri.parse('${rawBaseUrl}README.MD'));
            if (readmeMdUpperResp.statusCode == 200 && readmeMdUpperResp.body.isNotEmpty) {
              readme = readmeMdUpperResp.body;
            }
          }
        } catch (e) {
          debugPrint('GitHubChannel: 获取 README 失败 - $e');
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
        'packageName': appInfo.repositories,
        'projectUrl': apiList is Map ? apiList['html_url']?.toString() : null,
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
        'apiData': apiList,
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
      debugPrint('GitHubChannel: 获取应用详情失败 - $e');
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
    dynamic apiList,
  ) {
    final sections = <DetailSection>[];

    // 统计数据（GitHub 特有）
    if (apiList is Map) {
      if (apiList['stargazers_count'] != null ||
          apiList['forks_count'] != null) {
        sections.add(DetailSection.statistics);
      }
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

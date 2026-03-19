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
import 'package:gstore/core/model/proxy/HttpChannelDetailProxy.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;

/// HTTP API 渠道实现
/// 通过 HTTP API 获取应用数据
class HttpChannel implements IChannel {
  final Dio _dio;
  final String _baseUrl;

  @override
  ChannelInfo info;

  @override
  bool isInitialized = false;

  // 缓存数据
  List<AppInfo>? _cachedApps;
  List<db.AppCategory>? _cachedCategories;
  db.AppInfoConfig? _cachedConfig;

  HttpChannel({
    required Dio dio,
    required String baseUrl,
    String? name,
    String? description,
    int? priority,
    bool enabled = true,
  })  : _dio = dio,
        _baseUrl = baseUrl,
        info = ChannelInfo(
          type: ChannelType.http,
          name: name ?? 'HttpAPI',
          description: description ?? 'HTTP API 渠道',
          priority: priority ?? 3,
          enabled: enabled,
          supportOffline: false,
        );

  @override
  Future<void> initialize() async {
    // 测试连接
    try {
      await _dio.get('$_baseUrl/health');
    } catch (_) {
      // 如果没有 health 接口，忽略错误
    }
    isInitialized = true;
    debugPrint('HttpChannel: 初始化完成 - $_baseUrl');
  }

  @override
  Future<bool> checkAvailable() async {
    try {
      final response = await _dio.get(
        '$_baseUrl/apps',
        options: Options(sendTimeout: const Duration(seconds: 5)),
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('HttpChannel: API 不可用 - $e');
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
          from: ChannelType.http,
          fromCache: true,
        );
      }

      final response = await _dio.get('$_baseUrl/apps');

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      List<dynamic> data = response.data is String
          ? jsonDecode(response.data)
          : response.data;

      var apps = data.map((json) {
        return AppInfo(
          json['appId'] as String,
          json['name'] as String,
          json['user'] as String,
          json['repositories'] as String,
          json['icon'] as String,
          json['des'] as String,
          (json['category'] as List<dynamic>?)?.cast<String>(),
        );
      }).toList();

      _cachedApps = apps;

      return ChannelResult.success(
        data: apps,
        from: ChannelType.http,
        fromCache: false,
        metadata: {'count': apps.length},
      );
    } catch (e) {
      debugPrint('HttpChannel: 获取应用列表失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.http,
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
      final response = await _dio.get('$_baseUrl/apps/$appId');

      if (response.statusCode == 404) {
        return ChannelResult.success(
          data: null,
          from: ChannelType.http,
        );
      }

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      var json = response.data is String
          ? jsonDecode(response.data)
          : response.data;

      var app = AppInfo(
        json['appId'] as String,
        json['name'] as String,
        json['user'] as String,
        json['repositories'] as String,
        json['icon'] as String,
        json['des'] as String,
        (json['category'] as List<dynamic>?)?.cast<String>(),
      );

      return ChannelResult.success(
        data: app,
        from: ChannelType.http,
        fromCache: false,
      );
    } catch (e) {
      debugPrint('HttpChannel: 获取应用信息失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.http,
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
      final response = await _dio.get(
        '$_baseUrl/apps/search',
        queryParameters: {'q': keyword},
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      List<dynamic> data = response.data is String
          ? jsonDecode(response.data)
          : response.data;

      var apps = data.map((json) {
        return AppInfo(
          json['appId'] as String,
          json['name'] as String,
          json['user'] as String,
          json['repositories'] as String,
          json['icon'] as String,
          json['des'] as String,
          (json['category'] as List<dynamic>?)?.cast<String>(),
        );
      }).toList();

      return ChannelResult.success(
        data: apps,
        from: ChannelType.http,
        fromCache: false,
      );
    } catch (e) {
      debugPrint('HttpChannel: 搜索应用失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.http,
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
      final response = await _dio.get(
        '$_baseUrl/apps/category/$categoryId',
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      List<dynamic> data = response.data is String
          ? jsonDecode(response.data)
          : response.data;

      var apps = data.map((json) {
        return AppInfo(
          json['appId'] as String,
          json['name'] as String,
          json['user'] as String,
          json['repositories'] as String,
          json['icon'] as String,
          json['des'] as String,
          (json['category'] as List<dynamic>?)?.cast<String>(),
        );
      }).toList();

      return ChannelResult.success(
        data: apps,
        from: ChannelType.http,
        fromCache: false,
      );
    } catch (e) {
      debugPrint('HttpChannel: 按分类搜索失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.http,
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
          from: ChannelType.http,
          fromCache: true,
        );
      }

      final response = await _dio.get('$_baseUrl/categories');

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      List<dynamic> data = response.data is String
          ? jsonDecode(response.data)
          : response.data;

      var categories = data.map((json) {
        return db.AppCategory(
          json['id'] as String,
          json['description'] as String,
          json['icon'] as String,
        );
      }).toList();

      _cachedCategories = categories;

      return ChannelResult.success(
        data: categories,
        from: ChannelType.http,
        fromCache: false,
      );
    } catch (e) {
      debugPrint('HttpChannel: 获取分类失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.http,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<bool>> checkUpdate() async {
    try {
      final response = await _dio.get('$_baseUrl/config/version');

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      var json = response.data is String
          ? jsonDecode(response.data)
          : response.data;

      String remoteVersion = json['version'] as String;
      String? currentVersion = _cachedConfig?.version;

      bool hasUpdate = _compareVersions(currentVersion ?? '0.0.0', remoteVersion) < 0;

      return ChannelResult.success(
        data: hasUpdate,
        from: ChannelType.http,
        metadata: {
          'currentVersion': currentVersion,
          'remoteVersion': remoteVersion,
        },
      );
    } catch (e) {
      debugPrint('HttpChannel: 检查更新失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.http,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async {
    try {
      // 对于 HTTP API 渠道，更新就是重新获取数据
      onProgress?.call(0, 100);

      await clearCache();

      onProgress?.call(50, 100);

      await getAllApps(forceRefresh: true);
      await getAllCategories(forceRefresh: true);
      await getConfig(forceRefresh: true);

      onProgress?.call(100, 100);

      return ChannelResult.success(
        data: true,
        from: ChannelType.http,
      );
    } catch (e) {
      debugPrint('HttpChannel: 执行更新失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.http,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async {
    try {
      if (!forceRefresh && _cachedConfig != null) {
        return ChannelResult.success(
          data: _cachedConfig,
          from: ChannelType.http,
          fromCache: true,
        );
      }

      final response = await _dio.get('$_baseUrl/config');

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      var json = response.data is String
          ? jsonDecode(response.data)
          : response.data;

      var config = db.AppInfoConfig(
        json['version'] as String,
        json['proxy'] as String?,
      );

      _cachedConfig = config;

      return ChannelResult.success(
        data: config,
        from: ChannelType.http,
        fromCache: false,
      );
    } catch (e) {
      debugPrint('HttpChannel: 获取配置失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.http,
        error: e.toString(),
      );
    }
  }

  @override
  Future<void> clearCache() async {
    _cachedApps = null;
    _cachedCategories = null;
    _cachedConfig = null;
    debugPrint('HttpChannel: 缓存已清除');
  }

  @override
  Future<int> getCacheSize() async {
    return 0;
  }

  @override
  Future<void> dispose() async {
    await clearCache();
    isInitialized = false;
    debugPrint('HttpChannel: 已释放');
  }

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async {
    try {
      // 获取应用信息
      final appInfoResult = await getAppInfo(appId, forceRefresh: forceRefresh);
      if (!appInfoResult.success || appInfoResult.data == null) {
        return ChannelResult.failure(
          from: ChannelType.http,
          error: appInfoResult.error ?? '应用不存在',
        );
      }

      final appInfo = appInfoResult.data!;

      // 尝试获取详情信息
      final response = await _dio.get('$_baseUrl/apps/$appId/detail');

      if (response.statusCode == 404) {
        // 如果没有专门的详情接口，返回基本信息
        return _buildBasicDetail(appInfo);
      }

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final json = response.data is String ? jsonDecode(response.data) : response.data;

      // 解析详细信息
      final version = json['version']?.toString();
      final developer = json['developer']?.toString() ?? appInfo.user;
      final projectUrl = json['projectUrl']?.toString();

      // 解析下载信息
      final downloads = <DownloadInfo>[];
      final downloadsData = json['downloads'];
      if (downloadsData is List) {
        for (var item in downloadsData) {
          if (item is Map) {
            downloads.add(DownloadInfo(
              url: item['url']?.toString() ?? '',
              name: item['name']?.toString() ?? 'unknown',
              size: item['size'] as int?,
              version: version,
              platform: item['platform']?.toString(),
            ));
          }
        }
      }

      // 解析 README
      final readme = json['readme']?.toString() ?? json['description']?.toString();

      // 构建原始数据 Map
      final rawData = <String, dynamic>{
        'appId': appInfo.appId,
        'name': appInfo.name,
        'icon': appInfo.icon,
        'description': appInfo.des,
        'version': version,
        'developer': developer,
        'packageName': appInfo.repositories,
        'projectUrl': projectUrl,
        'sections': _buildSections(downloads, readme),
        'downloads': downloads,
        'readme': readme,
      };

      return ChannelResult.success(
        data: HttpChannelDetailProxy(rawData),
        from: ChannelType.http,
        fromCache: false,
      );
    } catch (e) {
      // 出错时返回基本信息
      final appInfoResult = await getAppInfo(appId);
      if (appInfoResult.success && appInfoResult.data != null) {
        return _buildBasicDetail(appInfoResult.data!);
      }
      debugPrint('HttpChannel: 获取应用详情失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.http,
        error: e.toString(),
      );
    }
  }

  /// 构建基本信息（当没有详细数据时）
  ChannelResult<IDetailInfo> _buildBasicDetail(AppInfo appInfo) {
    // 构建原始数据 Map
    final rawData = <String, dynamic>{
      'appId': appInfo.appId,
      'name': appInfo.name,
      'icon': appInfo.icon,
      'description': appInfo.des,
      'developer': appInfo.user,
      'packageName': appInfo.repositories,
      'sections': const <DetailSection>[],
      'downloads': const <DownloadInfo>[],
    };

    return ChannelResult.success(
      data: HttpChannelDetailProxy(rawData),
      from: ChannelType.http,
    );
  }

  /// 根据可用数据构建 sections 列表
  List<DetailSection> _buildSections(
    List<DownloadInfo> downloads,
    String? readme,
  ) {
    final sections = <DetailSection>[];

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
    // HTTP API 渠道暂不支持通过 UI 添加应用
    // 需要通过 API 提供者来添加应用
    return null;
  }

  /// 版本比较
  /// 返回 -1 如果 v1 < v2，0 如果相等，1 如果 v1 > v2
  int _compareVersions(String v1, String v2) {
    var parts1 = v1.split('.').map(int.parse).toList();
    var parts2 = v2.split('.').map(int.parse).toList();

    for (int i = 0; i < 3; i++) {
      var p1 = i < parts1.length ? parts1[i] : 0;
      var p2 = i < parts2.length ? parts2[i] : 0;

      if (p1 < p2) return -1;
      if (p1 > p2) return 1;
    }

    return 0;
  }
}

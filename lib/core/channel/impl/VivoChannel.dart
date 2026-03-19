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
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/proxy/VivoChannelDetailProxy.dart';
import 'package:gstore/db/apps/AppInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;

/// vivo 应用市场渠道实现
/// 通过 vivo 应用市场 API 获取应用数据
class VivoChannel implements IChannel {
  final Dio _dio;

  @override
  ChannelInfo info;

  @override
  bool isInitialized = false;

  // 缓存数据
  List<AppInfo>? _cachedApps;
  List<db.AppCategory>? _cachedCategories;

  // 数据库
  ChannelDatabase? _database;

  // API 基础地址
  static const String _baseUrl = 'https://h5-api.appstore.vivo.com.cn';
  static const String _searchUrl = '$_baseUrl/h5appstore/search/result-list';
  static const String _detailUrl = '$_baseUrl/detailInfo';

  // 默认参数
  static const Map<String, dynamic> _defaultParams = {
    'imei': '1234567890',
    'av': '18',
    'app_version': '2100',
    'pictype': 'webp',
    'h5_websource': 'h5appstore',
    'target': 'local',
    'cfrom': '2',
  };

  VivoChannel({
    required Dio dio,
    String? name,
    String? description,
    int? priority,
    bool enabled = true,
  })  : _dio = dio,
        info = ChannelInfo(
          type: ChannelType.vivo,
          name: name ?? 'vivo',
          description: description ?? 'vivo 应用市场',
          priority: priority ?? 4,
          enabled: enabled,
          supportOffline: false,
        );

  @override
  Future<void> initialize() async {
    // 初始化数据库
    _database = await ChannelDatabaseManager.instance;
    // vivo API 无需特殊初始化
    isInitialized = true;
    debugPrint('VivoChannel: 初始化完成');
  }

  @override
  Future<bool> checkAvailable() async {
    try {
      // 尝试搜索来测试 API 是否可用
      final response = await searchApps('汽车', forceRefresh: true);
      return response.success;
    } catch (e) {
      debugPrint('VivoChannel: API 不可用 - $e');
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
          from: ChannelType.vivo,
          fromCache: true,
        );
      }

      // vivo 没有获取所有应用的接口，返回渠道数据库中保存的应用列表
      // 这些应用是通过搜索保存下来的
      final channelAppsList = await getChannelApps();
      _cachedApps = channelAppsList;

      return ChannelResult.success(
        data: _cachedApps!,
        from: ChannelType.vivo,
        fromCache: false,
        metadata: {
          'message': 'vivo 渠道显示保存的搜索结果',
          'savedCount': channelAppsList.length,
        },
      );
    } catch (e) {
      debugPrint('VivoChannel: 获取应用列表失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.vivo,
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
      debugPrint('VivoChannel: getAppInfo 开始 - appId=$appId, forceRefresh=$forceRefresh, _database=$_database');

      // 优先从渠道数据库中查询已保存的应用
      if (!forceRefresh && _database != null) {
        final channelApp = await _database!.dao.getApp(appId, ChannelType.vivo.code);
        if (channelApp != null) {
          debugPrint('VivoChannel: 从渠道数据库找到应用 - ${channelApp.name}, extra=${channelApp.extra}');
          // 从数据库中找到了应用信息
          final app = AppInfo.withExtra(
            channelApp.appId,
            channelApp.name,
            channelApp.user,
            channelApp.repositories,
            channelApp.icon,
            channelApp.description,
            channelApp.category?.split(','),
            channelApp.extra,
          );
          return ChannelResult.success(
            data: app,
            from: ChannelType.vivo,
            fromCache: true,
          );
        } else {
          debugPrint('VivoChannel: 渠道数据库中未找到应用 - appId=$appId');
        }
      }

      // 数据库中没有，调用 API 获取详情
      debugPrint('VivoChannel: 渠道数据库中没有数据，调用 API 获取详情');
      // 需要从 extra 中获取 vivoId
      String vivoId = appId; // 默认使用 appId
      debugPrint('VivoChannel: 使用 appId 作为 vivoId - $vivoId');

      final response = await _dio.get(
        _detailUrl,
        queryParameters: {
          ..._defaultParams,
          'appId': vivoId,
          'frompage': 'messageh5',
        },
      );

      debugPrint('VivoChannel: API 响应状态码 - ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = response.data is String ? jsonDecode(response.data) : response.data;
        final app = _parseAppDetail(data, appId);

        debugPrint('VivoChannel: API 获取成功 - ${app?.name ?? "null"}');
        return ChannelResult.success(
          data: app,
          from: ChannelType.vivo,
          fromCache: false,
        );
      } else {
        debugPrint('VivoChannel: API 返回错误状态码 - ${response.statusCode}');
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('VivoChannel: 获取应用信息失败 - appId=$appId, error=$e');
      return ChannelResult.failure(
        from: ChannelType.vivo,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async {
    try {
      // 先获取基本应用信息（从数据库，获取 extra）
      String? vivoId;
      AppInfo? appInfo;

      if (_database != null) {
        final channelApp = await _database!.dao.getApp(appId, ChannelType.vivo.code);
        if (channelApp != null && !forceRefresh) {
          // 从数据库中找到了应用信息
          appInfo = AppInfo.withExtra(
            channelApp.appId,
            channelApp.name,
            channelApp.user,
            channelApp.repositories,
            channelApp.icon,
            channelApp.description,
            channelApp.category?.split(','),
            channelApp.extra,
          );

          // 从 extra 中获取 vivoId
          if (channelApp.extra != null) {
            try {
              final extraData = jsonDecode(channelApp.extra!) as Map<String, dynamic>;
              vivoId = extraData['vivoId']?.toString();
            } catch (e) {
              debugPrint('VivoChannel: 解析 extra 失败 - $e');
            }
          }
        }
      }

      // 如果没有找到 vivoId，使用 repositories 字段（保存的是 vivoId）
      vivoId ??= appInfo?.repositories;

      // 如果还是没有，使用 appId
      vivoId ??= appId;

      debugPrint('VivoChannel: getAppDetail - appId=$appId, vivoId=$vivoId');

      // 获取详细信息
      final response = await _dio.get(
        _detailUrl,
        queryParameters: {
          ..._defaultParams,
          'appId': vivoId,
          'frompage': 'messageh5',
        },
      );

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final data = response.data is String ? jsonDecode(response.data) : response.data;
      if (data == null || data is! Map) {
        throw Exception('Invalid response data');
      }

      final detail = data as Map<String, dynamic>;

      // 解析详细信息
      final version = detail['versionName']?.toString() ?? detail['version']?.toString();
      final versionCode = detail['versionCode']?.toString() ?? detail['version_code']?.toString();
      final size = detail['apkSize'] as int?;
      final developer = detail['developerName']?.toString() ?? appInfo?.user ?? '';
      final packageName = detail['package_name']?.toString() ?? detail['packageName']?.toString() ?? appInfo?.appId ?? appId;

      debugPrint('VivoChannel: 原始数据中的 package_name = ${detail['package_name']}');
      debugPrint('VivoChannel: 原始数据中的 packageName = ${detail['packageName']}');
      debugPrint('VivoChannel: appInfo?.appId = ${appInfo?.appId}');
      debugPrint('VivoChannel: 最终使用的 packageName = $packageName');

      // 解析下载量、评分等统计信息
      final downloads = detail['downloadCount'] as int?;
      final rating = detail['score']?.toDouble();
      final ratingCount = detail['scoreCount'] as int?;
      final favorites = detail['favoriteCount'] as int?;

      // 解析应用截图
      final screenshotsData = detail['screenShots'];
      final screenshots = <ScreenshotInfo>[];
      if (screenshotsData is List) {
        for (var item in screenshotsData) {
          final url = item?.toString() ?? '';
          if (url.isNotEmpty) {
            screenshots.add(ScreenshotInfo(url: url));
          }
        }
      }

      // 解析权限列表
      final permissionsData = detail['permissions'];
      final permissions = <String>[];
      if (permissionsData is List) {
        for (var item in permissionsData) {
          if (item is Map) {
            final perm = item['permissionName']?.toString() ?? item['name']?.toString();
            if (perm != null && perm.isNotEmpty) {
              permissions.add(perm);
            }
          } else if (item is String && item.isNotEmpty) {
            permissions.add(item);
          }
        }
      }

      // 应用详细介绍
      final description = detail['introduction']?.toString() ??
          detail['shortIntroduction']?.toString() ??
          appInfo?.des ?? '';

      // 构建下载信息
      final downloadUrl = detail['download_url']?.toString() ?? detail['downloadUrl']?.toString();
      final downloadsList = <DownloadInfo>[];

      debugPrint('VivoChannel: packageName = $packageName, versionCode = $versionCode, downloadUrl = $downloadUrl');

      if (downloadUrl != null && downloadUrl.isNotEmpty) {
        // 文件名格式: package_name_version_code.apk
        final fileName = versionCode != null && versionCode.isNotEmpty
            ? '${packageName}_$versionCode.apk'
            : '${packageName}_${version ?? 'latest'}.apk';

        final downloadInfo = DownloadInfo(
          url: downloadUrl,
          name: fileName,
          size: size,
          version: version,
          platform: 'android',
        );
        downloadsList.add(downloadInfo);
        debugPrint('VivoChannel: 添加下载文件 - ${downloadInfo.name}');
      }

      debugPrint('VivoChannel: 最终下载列表数量 = ${downloadsList.length}');

      // 构建原始数据 Map（保持原始格式）
      final rawData = <String, dynamic>{
        'appId': appInfo?.appId ?? appId,
        'name': appInfo?.name ?? '',
        'icon': appInfo?.icon ?? '',
        'description': appInfo?.des ?? '',
        'version': version,
        'developer': developer,
        'packageName': packageName,
        'sections': _buildSections(
          hasDownloads: downloadsList.isNotEmpty,
          hasScreenshots: screenshots.isNotEmpty,
          hasReadme: description.isNotEmpty,
          hasRating: rating != null,
          hasStatistics: downloads != null || favorites != null,
          hasPermissions: permissions.isNotEmpty,
        ),
        'downloads': downloadsList, // 下载文件列表
        'downloadCount': downloads, // 下载量（统计）
        'screenshots': screenshots,
        'readme': description,
        'permissions': permissions,
        'detailData': detail,
        'rating': rating,
        'ratingCount': ratingCount,
        'favorites': favorites,
      };

      // 使用代理类包装原始数据
      final detailData = VivoChannelDetailProxy(rawData);

      return ChannelResult.success(
        data: detailData,
        from: ChannelType.vivo,
        fromCache: false,
      );
    } catch (e) {
      debugPrint('VivoChannel: 获取应用详情失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.vivo,
        error: e.toString(),
      );
    }
  }

  /// 根据可用数据构建 sections 列表
  List<DetailSection> _buildSections({
    required bool hasDownloads,
    required bool hasScreenshots,
    required bool hasReadme,
    required bool hasRating,
    required bool hasStatistics,
    required bool hasPermissions,
  }) {
    final sections = <DetailSection>[];

    // 版本信息
    sections.add(DetailSection.version);

    // 应用截图
    if (hasScreenshots) {
      sections.add(DetailSection.screenshots);
    }

    // 统计数据（下载量、评分等）
    if (hasStatistics || hasRating) {
      sections.add(DetailSection.statistics);
    }

    // 评分单独展示
    if (hasRating) {
      sections.add(DetailSection.rating);
    }

    // 下载列表 - 始终添加，显示可用文件或"无可用文件"消息
    sections.add(DetailSection.downloads);

    // 详细介绍
    if (hasReadme) {
      sections.add(DetailSection.readme);
    }

    // 权限说明
    if (hasPermissions) {
      sections.add(DetailSection.permissions);
    }

    return sections;
  }

  @override
  Future<ChannelResult<List<AppInfo>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async {
    try {
      if (keyword.isEmpty) {
        return ChannelResult.success(
          data: [],
          from: ChannelType.vivo,
        );
      }

      final response = await _dio.post(
        _searchUrl,
        queryParameters: {
          ..._defaultParams,
          'key': keyword,
          'page_index': 1,
          'apps_per_page': 20,
        },
        options: Options(
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'Accept-Language': 'zh-CN,zh;q=0.9',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data is String ? jsonDecode(response.data) : response.data;
        final apps = _parseSearchResults(data);

        return ChannelResult.success(
          data: apps,
          from: ChannelType.vivo,
          fromCache: false,
          metadata: {'keyword': keyword, 'count': apps.length},
        );
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('VivoChannel: 搜索应用失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.vivo,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<List<AppInfo>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async {
    // vivo API 可能不支持按分类搜索，返回空列表
    // 可以通过 searchApps 来搜索
    return ChannelResult.success(
      data: [],
      from: ChannelType.vivo,
      metadata: {'message': 'vivo 渠道不支持按分类搜索，请使用搜索功能'},
    );
  }

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async {
    // vivo 没有分类接口，返回空列表
    return ChannelResult.success(
      data: [],
      from: ChannelType.vivo,
    );
  }

  @override
  Future<ChannelResult<bool>> checkUpdate() async {
    // vivo 渠道不需要更新检查
    return ChannelResult.success(
      data: false,
      from: ChannelType.vivo,
    );
  }

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async {
    // vivo 渠道不需要更新
    return ChannelResult.success(
      data: true,
      from: ChannelType.vivo,
    );
  }

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async {
    // vivo 渠道没有配置
    return ChannelResult.success(
      data: null,
      from: ChannelType.vivo,
    );
  }

  // ==================== 渠道数据库操作（搜索结果存储）====================

  /// 保存搜索结果到渠道数据库
  Future<void> saveSearchResult(AppInfo app) async {
    if (_database == null) {
      debugPrint('VivoChannel: 数据库未初始化');
      return;
    }

    final channelApp = ChannelAddedApp.withChannel(
      appId: app.appId,
      name: app.name,
      user: app.user,
      repositories: app.repositories,
      icon: app.icon,
      description: app.des,
      category: app.category?.join(','),
      addTime: DateTime.now().millisecondsSinceEpoch,
      channel: ChannelType.vivo,
      extra: app.extra, // 保存 extra 字段
    );

    await _database!.dao.insertApp(channelApp);
    debugPrint('VivoChannel: 已保存搜索结果 ${app.name}，extra=${app.extra}');
  }

  /// 从渠道数据库删除搜索结果
  Future<void> deleteSearchResult(String appId) async {
    if (_database == null) {
      debugPrint('VivoChannel: 数据库未初始化');
      return;
    }

    await _database!.dao.removeApp(appId, ChannelType.vivo.code);
    debugPrint('VivoChannel: 已删除搜索结果 $appId');
  }

  /// 获取渠道数据库中的所有应用（搜索结果）
  Future<List<AppInfo>> getChannelApps() async {
    if (_database == null) {
      debugPrint('VivoChannel: 数据库未初始化');
      return [];
    }

    final channelApps = await _database!.dao.getAppsByChannel(ChannelType.vivo.code);

    return channelApps.map((app) {
      return AppInfo(
        app.appId,
        app.name,
        app.user,
        app.repositories,
        app.icon,
        app.description,
        app.category?.split(','),
      );
    }).toList();
  }

  /// 检查应用是否在渠道数据库中
  Future<bool> isInChannel(String appId) async {
    if (_database == null) {
      debugPrint('VivoChannel: 数据库未初始化');
      return false;
    }

    final app = await _database!.dao.getApp(appId, ChannelType.vivo.code);
    return app != null;
  }

  // ==================== 聚合管理器操作（首页显示）====================

  /// 添加应用到聚合管理器（用于首页显示）
  Future<void> addToAggregator(AppInfo app) async {
    // 这个方法会由发现页面的逻辑调用
    // 实际的添加逻辑在 AppAggregatorManager 中处理
    debugPrint('VivoChannel: 请求添加应用到聚合管理器 ${app.name}');
  }

  /// 从聚合管理器移除应用
  Future<void> removeFromAggregator(String appId) async {
    // 这个方法会由发现页面的逻辑调用
    // 实际的移除逻辑在 AppAggregatorManager 中处理
    debugPrint('VivoChannel: 请求从聚合管理器移除应用 $appId');
  }

  @override
  Future<void> clearCache() async {
    _cachedApps = null;
    _cachedCategories = null;
    debugPrint('VivoChannel: 缓存已清除');
  }

  @override
  Future<int> getCacheSize() async {
    return 0;
  }

  @override
  Future<void> dispose() async {
    await clearCache();
    isInitialized = false;
    debugPrint('VivoChannel: 已释放');
  }

  @override
  Widget? getAddAppWidget(BuildContext context, Function(AppInfo) onAppAdded, {VoidCallback? onAppSaved}) {
    return _VivoAddAppWidget(
      channel: this,
      onAppAdded: onAppAdded,
      onAppSaved: onAppSaved,
    );
  }

  /// 解析应用详情
  AppInfo? _parseAppDetail(dynamic data, String appId) {
    try {
      if (data == null || data is! Map) {
        return null;
      }

      final map = data as Map<String, dynamic>;

      // 解析图标
      String icon = '';
      if (map['icon'] != null) {
        icon = map['icon'].toString();
      }

      // 解析名称
      String name = map['appName']?.toString() ?? '';

      // 解析包名
      String packageName = map['packageName']?.toString() ?? appId;

      // 解析描述
      String description = map['introduction']?.toString() ?? '';
      if (description.isEmpty) {
        description = map['shortIntroduction']?.toString() ?? '';
      }

      // 解析开发者
      String developer = map['developerName']?.toString() ?? '';

      // 解析分类
      List<String> categories = [];
      if (map['categoryName'] != null) {
        categories = [map['categoryName'].toString()];
      }

      // 构造下载 URL
      String downloadUrl = '';
      if (map['downloadUrl'] != null) {
        downloadUrl = map['downloadUrl'].toString();
      }

      return AppInfo(
        packageName, // 使用包名作为 appId
        name,
        developer,
        packageName, // repositories 使用包名
        icon,
        description,
        categories.isNotEmpty ? categories : null,
      );
    } catch (e) {
      debugPrint('VivoChannel: 解析应用详情失败 - $e');
      return null;
    }
  }

  /// 解析搜索结果
  List<AppInfo> _parseSearchResults(dynamic data) {
    try {
      if (data == null) {
        return [];
      }

      // 检查响应是否成功
      if (data is Map && data['code'] != 0) {
        debugPrint('VivoChannel: API 返回错误 - ${data['code']}');
        return [];
      }

      List<dynamic> results = [];

      // vivo API 返回格式: {code: 0, data: {appSearchResponse: {value: [...]}}}
      if (data is Map && data['data'] != null) {
        final dataObj = data['data'];
        if (dataObj is Map && dataObj['appSearchResponse'] != null) {
          final searchResponse = dataObj['appSearchResponse'];
          if (searchResponse is Map && searchResponse['value'] != null) {
            results = searchResponse['value'] as List<dynamic>;
          }
        } else if (dataObj is List) {
          results = dataObj as List<dynamic>;
        }
      } else if (data is List) {
        results = data as List<dynamic>;
      } else {
        return [];
      }

      final apps = <AppInfo>[];

      for (var item in results) {
        if (item is! Map) continue;

        final map = item as Map<String, dynamic>;

        // 解析关键字段
        final id = map['id']?.toString() ?? '';
        final title = map['title_zh']?.toString() ?? map['title']?.toString() ?? '';
        final icon = map['icon_url']?.toString() ?? map['icon']?.toString() ?? '';
        final packageName = map['package_name']?.toString() ?? map['packageName']?.toString() ?? '';
        final developer = map['developer']?.toString() ?? map['developerName']?.toString() ?? '';
        final remark = map['remark']?.toString() ?? map['introduction']?.toString() ?? map['shortIntroduction']?.toString() ?? '';

        // 使用 packageName 作为 appId（这样详情页可以用 packageName 检测安装）
        final appId = packageName.isNotEmpty ? packageName : id;

        // 构建扩展数据，保存所有原始信息
        final extraData = <String, dynamic>{
          'vivoId': id, // vivo 的应用 ID
          'packageName': packageName,
          'title': title,
          'developer': developer,
          'iconUrl': icon,
          'remark': remark,
        };
        final extraJson = jsonEncode(extraData);

        debugPrint('VivoChannel: 搜索结果 - id=$id, packageName=$packageName, appId=$appId');

        apps.add(AppInfo.withExtra(
          appId,
          title,
          developer,
          id, // repositories 存放 vivoId
          icon,
          remark,
          null, // vivo 搜索结果中没有分类信息
          extraJson,
        ));
      }

      return apps;
    } catch (e) {
      debugPrint('VivoChannel: 解析搜索结果失败 - $e');
      return [];
    }
  }
}

/// vivo 渠道添加应用 Widget
class _VivoAddAppWidget extends StatefulWidget {
  final VivoChannel channel;
  final Function(AppInfo) onAppAdded;
  final VoidCallback? onAppSaved;

  const _VivoAddAppWidget({
    Key? key,
    required this.channel,
    required this.onAppAdded,
    this.onAppSaved,
  }) : super(key: key);

  @override
  State<_VivoAddAppWidget> createState() => _VivoAddAppState();
}

class _VivoAddAppState extends State<_VivoAddAppWidget> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  List<AppInfo> _searchResults = [];
  bool _isSearching = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    // 自动聚焦搜索框
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

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
        });
      } else {
        setState(() {
          _errorMessage = result.error ?? '搜索失败';
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = '搜索失败: $e';
      });
    } finally {
      setState(() {
        _isSearching = false;
      });
    }
  }

  /// 保存搜索结果到渠道数据库
  Future<void> _saveToChannel(AppInfo app) async {
    try {
      await widget.channel.saveSearchResult(app);
      setState(() {
        // 更新 UI 显示已保存
      });

      // 通知父组件刷新渠道列表
      widget.onAppSaved?.call();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存 ${app.name}'),
          duration: const Duration(seconds: 1),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 搜索框
          TextField(
            controller: _searchController,
            focusNode: _focusNode,
            decoration: InputDecoration(
              hintText: '搜索应用（如：微信、抖音等）',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _performSearch('');
                      },
                    )
                  : null,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
            ),
            onChanged: (value) {
              // 防抖搜索
              Future.delayed(const Duration(milliseconds: 500), () {
                if (_searchController.text == value) {
                  _performSearch(value);
                }
              });
            },
          ),
          const SizedBox(height: 16),

          // 搜索结果
          Expanded(
            child: _buildSearchResults(context),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults(BuildContext context) {
    if (_isSearching) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Colors.red),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                style: TextStyle(color: Colors.red[700]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    if (_searchController.text.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search,
                size: 48,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                '搜索 vivo 应用市场中的应用',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                '搜索后点击"保存"将应用保存到渠道',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey[500],
                    ),
              ),
            ],
          ),
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off,
                size: 48,
                color: Colors.grey[400],
              ),
              const SizedBox(height: 16),
              Text(
                '未找到相关应用',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final app = _searchResults[index];

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: app.icon.isNotEmpty
                ? CircleAvatar(
                    backgroundImage: NetworkImage(app.icon),
                  )
                : CircleAvatar(
                    child: Icon(Icons.apps, size: 20),
                  ),
            title: Text(app.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  app.appId,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (app.des.isNotEmpty)
                  Text(
                    app.des,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            trailing: ElevatedButton(
              onPressed: () => _saveToChannel(app),
              child: const Text('保存'),
            ),
          ),
        );
      },
    );
  }
}

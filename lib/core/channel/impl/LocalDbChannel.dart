import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/data/metadata_repository.dart';
import 'package:gstore/core/model/proxy/LocalDbChannelDetailProxy.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/db/apps/AppInfoDatabase.dart';
import 'package:gstore/core/service/db_manager.dart';
import 'package:gstore/http/github/github_client.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/core/channel/AppUpdateCheckMixin.dart';
import 'package:gstore/core/core.dart';

/// 本地数据库渠道实现
/// 基于 SQLite 本地数据库提供数据
/// 支持 GitHub API 查询 releases 信息
class LocalDbChannel with AppUpdateCheckMixin implements IChannel {
  AppInfoDatabase _database;
  final GithubRestClient? _githubApi;

  @override
  ChannelInfo info;

  @override
  bool isInitialized = false;

  LocalDbChannel({
    required AppInfoDatabase database,
    GithubRestClient? githubApi,
    String? name,
    String? description,
    int? priority,
    bool enabled = true,
  })  : _database = database,
        _githubApi = githubApi,
        info = ChannelInfo(
          type: ChannelType.localDb,
          name: name ?? 'LocalDB',
          description: description ?? '本地数据库渠道',
          priority: priority,
          enabled: enabled,
          supportOffline: true,
        );

  /// 更新数据库引用（数据库更新后调用，避免使用已关闭的旧数据库）
  void updateDatabase(AppInfoDatabase database) {
    _database = database;
    appLog.info('LocalDbChannel: 数据库引用已更新');
  }

  @override
  Future<void> initialize() async {
    // 数据库已由 DbManager 初始化，这里只做标记
    isInitialized = true;
    appLog.info('LocalDbChannel: 初始化完成');
  }

  @override
  Future<bool> checkAvailable() async {
    try {
      // 尝试查询配置来检查数据库是否可用
      await _database.dao.getVersion();
      return true;
    } catch (e) {
      appLog.error('LocalDbChannel: 数据库不可用 - $e');
      return false;
    }
  }

  /// GitHub 仓库类型应用：优先用 metadata 覆盖真实图标/应用名/包名（未收录回退数据库记录）。
  /// [keepExistingPackageName] 为 true 时，metadata 缺少合法包名则保留原 packageName
  /// （getAppDetail 语义）；为 false 时置 null（getAppInfo 语义，保持各调用点现状不变）。
  Future<AppSummary> _applyMetadataOverride(
    AppSummary app, {
    required bool keepExistingPackageName,
  }) async {
    if (app.user.isEmpty || app.repositories.isEmpty) {
      return app;
    }
    final metadata =
        await MetadataRepository.instance.fetchInfo(app.user, app.repositories);
    if (metadata == null) {
      return app;
    }
    // Android 包名必须含 '.'，过滤脏数据（误存的应用名等）
    final rawPackage = metadata['packageName']?.toString() ?? '';
    final overridePackage =
        (rawPackage.trim().isNotEmpty && rawPackage.contains('.')) ? rawPackage : '';
    final metadataName = metadata['appName']?.toString() ?? '';
    final overrideIcon = await MetadataRepository.instance
        .resolveIconUrl(app.user, app.repositories);
    final displayName = metadataName.isNotEmpty ? metadataName : app.name;
    final icon = (overrideIcon?.isNotEmpty ?? false) ? overrideIcon! : app.icon;

    return AppSummary(
      appId: app.appId,
      packageName: overridePackage.isNotEmpty
          ? overridePackage
          : (keepExistingPackageName ? app.packageName : null),
      name: displayName,
      user: app.user,
      repositories: app.repositories,
      icon: icon,
      des: app.des,
      readme: app.readme,
      category: app.category,
      extra: app.extra,
    );
  }

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({
    bool forceRefresh = false,
  }) async {
    try {
      var apps = await _database.dao.getAllApps();
      return ChannelResult.success(
        data: apps.map(AppSummary.fromDbAppInfo).toList(),
        from: ChannelType.localDb,
        fromCache: !forceRefresh,
      );
    } catch (e) {
      appLog.error('LocalDbChannel: 获取应用列表失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.localDb,
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
      var entity = await _database.dao.getAppInfo(appId);
      if (entity == null) {
        return ChannelResult.success(
          data: null,
          from: ChannelType.localDb,
          fromCache: !forceRefresh,
        );
      }

      var appInfo = AppSummary.fromDbAppInfo(entity);
      appInfo = await _applyMetadataOverride(
        appInfo,
        keepExistingPackageName: false,
      );

      return ChannelResult.success(
        data: appInfo,
        from: ChannelType.localDb,
        fromCache: !forceRefresh,
      );
    } catch (e) {
      appLog.error('LocalDbChannel: 获取应用信息失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.localDb,
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
      appLog.info('LocalDbChannel: ========== 开始获取应用详情 ==========');
      debugPrint('LocalDbChannel: appId = $appId');

      // 直接查询数据库实体（readme/字段完整），不走 getAppInfo（该路径的 metadata 覆盖逻辑已移入下方详情路径）
      final entity = await _database.dao.getAppInfo(appId);
      if (entity == null) {
        return ChannelResult.failure(
          from: ChannelType.localDb,
          error: '应用不存在',
        );
      }

      var appInfo = AppSummary.fromDbAppInfo(entity);
      appInfo = await _applyMetadataOverride(
        appInfo,
        keepExistingPackageName: true,
      );

      debugPrint('LocalDbChannel: appInfo.name = ${appInfo.name}');
      debugPrint('LocalDbChannel: appInfo.user = ${appInfo.user}');
      debugPrint('LocalDbChannel: appInfo.repositories = ${appInfo.repositories}');
      debugPrint('LocalDbChannel: appInfo.appId = ${appInfo.appId}');

      // 获取包名
      // 直接使用 AppSummary.packageName（渠道显式提供的真实包名），不再用 appId 猜测
      String? packageName = appInfo.packageName;
      if (packageName != null && packageName.isNotEmpty) {
        debugPrint('LocalDbChannel: 使用 packageName = $packageName');
      } else {
        debugPrint('LocalDbChannel: 无 packageName，不显示包名');
      }

      // 优先读取仓库元数据（真实图标 / 包名 / 版本 / 应用名），未收录时回退默认数据
      // 负缓存命中（此前未收录）时绕过一次重试——应用可能刚被收录（如刚提交 issue）
      String? metadataIcon;
      String? metadataVersionName;
      String? metadataAppName;
      if (appInfo.user.isNotEmpty && appInfo.repositories.isNotEmpty) {
        var metadata = await MetadataRepository.instance
            .fetchInfo(appInfo.user, appInfo.repositories);
        if (metadata == null) {
          metadata = await MetadataRepository.instance.fetchInfo(
            appInfo.user,
            appInfo.repositories,
            ignoreNegativeCache: true,
          );
        }
        if (metadata != null) {
          metadataIcon = await MetadataRepository.instance
              .resolveIconUrl(appInfo.user, appInfo.repositories);
          final metaPackage = metadata['packageName']?.toString();
          if (metaPackage != null &&
              metaPackage.trim().isNotEmpty &&
              metaPackage.contains('.')) {
            packageName = metaPackage;
            debugPrint('LocalDbChannel: 使用元数据 packageName = $packageName');
          }
          metadataVersionName = metadata['versionName']?.toString();
          final metaAppName = metadata['appName']?.toString();
          if (metaAppName != null && metaAppName.isNotEmpty) {
            metadataAppName = metaAppName;
          }
        }
      }

      // 尝试从 GitHub API 获取 releases
      final downloads = <DownloadInfo>[];
      String? latestVersion;
      Map<String, dynamic>? apiList; // 声明 apiList 变量以便后续使用
      String? readme; // 声明 readme 变量以便后续使用

      // 检查是否是 GitHub 仓库类型（有 user 和 repositories）
      final isGitHubRepo = appInfo.user.isNotEmpty && appInfo.repositories.isNotEmpty;
      debugPrint('LocalDbChannel: isGitHubRepo = $isGitHubRepo');
      debugPrint('LocalDbChannel: _githubApi = ${_githubApi != null ? "已注入" : "未注入"}');

      if (isGitHubRepo && _githubApi != null) {
        try {
          debugPrint('LocalDbChannel: >>> 正在调用 GitHub API 获取 releases 和统计信息 - ${appInfo.user}/${appInfo.repositories}');

          // 并发获取 releases、API 统计信息和 README
          final results = await Future.wait([
            _githubApi!.releases(
              appInfo.user,
              appInfo.repositories,
              1,
              CancelToken(),
            ),
            _githubApi!.apiList(
              appInfo.user,
              appInfo.repositories,
              CancelToken(),
            ),
            _githubApi!.readme(
              appInfo.user,
              appInfo.repositories,
              CancelToken(),
            ),
          ]);

          // releases 返回的是 JSON String
          final releasesJson = results[0] as String;
          final List<dynamic> releases = List<dynamic>.from(
            jsonDecode(releasesJson) as List,
          );

          // apiList 返回的是 ApiList 对象，转换为 Map
          final apiListObject = results[1] as dynamic;
          apiList = apiListObject is Map
              ? apiListObject as Map<String, dynamic>
              : (apiListObject.toString().startsWith('{')
                  ? jsonDecode(apiListObject.toString()) as Map<String, dynamic>?
                  : null);

          debugPrint('LocalDbChannel: apiList=${apiList != null ? "有值(stars=${apiList['stargazers_count']}, forks=${apiList['forks_count']})" : "null(未获取到 GitHub 统计)"}');

          // README 返回的是 JSON String，需要解码
          Map<String, dynamic>? readmeData;
          final readmeResult = results[2] as String;
          if (readmeResult.isNotEmpty) {
            try {
              readmeData = jsonDecode(readmeResult) as Map<String, dynamic>;
              debugPrint('LocalDbChannel: README JSON 解码成功');
            } catch (e) {
              appLog.error('LocalDbChannel: README JSON 解码失败 - $e');
            }
          } else {
            debugPrint('LocalDbChannel: README 返回空字符串');
          }

          debugPrint('LocalDbChannel: <<< GitHub API 返回 releases 数量 = ${releases.length}');

          if (releases.isNotEmpty) {
            final latestRelease = releases[0] as Map<String, dynamic>;
            latestVersion = latestRelease['name']?.toString() ??
                latestRelease['tag_name']?.toString();
            debugPrint('LocalDbChannel: latestVersion = $latestVersion');

            final publishedAt = latestRelease['published_at'] != null
                ? DateTime.parse(latestRelease['published_at'].toString())
                : null;

            final assets = latestRelease['assets'] as List<dynamic>? ?? [];
            debugPrint('LocalDbChannel: assets 数量 = ${assets.length}');

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
                debugPrint('LocalDbChannel: ✓ 添加下载文件 - ${downloadInfo.name} (${downloadInfo.formattedSize})');
              }
            }
          }

          debugPrint('LocalDbChannel: >>> 最终下载列表数量 = ${downloads.length}');

          // 处理 README - Base64 解码（使用 GitHub API 返回的数据）
          if (readmeData != null && readmeData['content'] != null) {
            try {
              final content = readmeData['content'] as String;
              final encoding = readmeData['encoding'] as String? ?? 'base64';
              final name = readmeData['name']?.toString() ?? 'README';

              debugPrint('LocalDbChannel: GitHub API 返回 README - $name, 编码=$encoding, 内容长度=${content.length}');

              if (encoding == 'base64') {
                // Base64 解码 - 需要先清理换行符和空格
                var cleanContent = content.replaceAll(RegExp(r'\s+'), '');
                debugPrint('LocalDbChannel: 清理后 Base64 内容长度 = ${cleanContent.length}');

                // GitHub API 可能返回 URL 安全的 Base64，需要转换
                // URL 安全: - (代替 +), _ (代替 /)
                // 标准: +, /
                cleanContent = cleanContent
                    .replaceAll('-', '+')
                    .replaceAll('_', '/');

                // 添加必要的填充
                while (cleanContent.length % 4 != 0) {
                  cleanContent += '=';
                }

                debugPrint('LocalDbChannel: 标准化后 Base64 长度 = ${cleanContent.length}');
                final decodedBytes = base64.decode(cleanContent);
                readme = utf8.decode(decodedBytes);
                debugPrint('LocalDbChannel: ✓ README Base64 解码成功，长度 = ${readme.length}');
              } else if (encoding == null || encoding == 'none') {
                // 直接使用（未编码）
                readme = content;
                debugPrint('LocalDbChannel: ✓ README 直接使用，长度 = ${readme.length}');
              } else {
                debugPrint('LocalDbChannel: ⚠ 未知编码 $encoding，尝试直接使用');
                readme = content;
              }
            } catch (e) {
              appLog.error('LocalDbChannel: ✗ README 解码失败 - $e');
            }
          } else {
            debugPrint('LocalDbChannel: ⚠ GitHub API 返回 README 数据为空');
          }
        } catch (e, stackTrace) {
          // GitHub API 调用失败不影响整体流程，使用空下载列表
          appLog.error('LocalDbChannel: ✗ 获取 GitHub releases 失败: $e');
          debugPrint('LocalDbChannel: stackTrace: $stackTrace');
        }
      } else {
        debugPrint('LocalDbChannel: ⚠ 跳过 GitHub releases 查询 - isGitHubRepo: $isGitHubRepo, hasApi: ${_githubApi != null}');
      }

      // 如果没有从 GitHub 获取到 README，使用数据库中的内容
      if (readme == null) {
        readme = (appInfo.readme != null && appInfo.readme!.isNotEmpty)
            ? appInfo.readme!
            : (appInfo.des.isNotEmpty ? appInfo.des : null);
        debugPrint('LocalDbChannel: 使用数据库 README/des，长度 = ${readme?.length ?? 0}');
      }

      // 将 README 中的相对路径图片替换为完整 raw URL
      // （代理仅用于下载/图片加速，不改变资源地址语义）
      final defaultBranch = apiList?['default_branch']?.toString();
      final rawBaseUrl =
          'https://raw.githubusercontent.com/${appInfo.user}/${appInfo.repositories}/refs/heads/'
          '${defaultBranch != null && defaultBranch.isNotEmpty ? defaultBranch : 'main'}/';
      if (readme != null) {
        readme = resolveReadmeImageUrls(readme, rawBaseUrl);
      }

      appLog.info('LocalDbChannel: ========== 构建详情信息完成 ==========');
      debugPrint('LocalDbChannel: downloads 列表长度 = ${downloads.length}');
      debugPrint('LocalDbChannel: README 最终长度 = ${readme?.length ?? 0}');
      debugPrint('LocalDbChannel: README 预览 = ${readme != null && readme.length > 0 ? readme.substring(0, readme.length > 100 ? 100 : readme.length) : "null"}');

      // 构建原始数据 Map（保持原始格式）
      final rawData = <String, dynamic>{
        'appId': appInfo.appId,
        // 优先使用元数据仓库的真实应用名，未收录时回退数据库名称
        'name': metadataAppName ?? appInfo.name,
        // 优先使用元数据仓库的真实图标，未收录时回退数据库图标
        'icon': metadataIcon ?? appInfo.icon,
        'description': appInfo.des,
        // 优先使用元数据的版本信息（versionName），否则用 GitHub release 版本
        'version': metadataVersionName ?? latestVersion,
        'developer': appInfo.user,
        'packageName': packageName,
        // 项目主页始终为 github.com 地址（代理仅用于下载/图片加速，不改变主页语义）
        'projectUrl': 'https://github.com/${appInfo.user}/${appInfo.repositories}',
        'sections': _buildSections(
          downloads,
          readme,
          ApiList.fromJson(apiList ?? const <String, dynamic>{}),
        ),
        'downloads': downloads,
        'readme': readme,
        'proxy': getProxy(),
        'repositoryName': appInfo.repositories,
        'apiData': apiList,
      };

      // 使用代理类包装原始数据
      final detailData = LocalDbChannelDetailProxy(rawData);

      return ChannelResult.success(
        data: detailData,
        from: ChannelType.localDb,
        fromCache: !forceRefresh,
      );
    } catch (e) {
      appLog.error('LocalDbChannel: ✗ 获取应用详情失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.localDb,
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
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async {
    try {
      var apps = await _database.dao.search(keyword);
      return ChannelResult.success(
        data: apps.map(AppSummary.fromDbAppInfo).toList(),
        from: ChannelType.localDb,
        fromCache: !forceRefresh,
      );
    } catch (e) {
      appLog.error('LocalDbChannel: 搜索应用失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.localDb,
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
      var apps = await _database.dao.queryCategory(categoryId);
      return ChannelResult.success(
        data: apps.map(AppSummary.fromDbAppInfo).toList(),
        from: ChannelType.localDb,
        fromCache: !forceRefresh,
      );
    } catch (e) {
      appLog.error('LocalDbChannel: 按分类搜索失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.localDb,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async {
    try {
      var categories = await _database.dao.getAllCategory();
      return ChannelResult.success(
        data: categories,
        from: ChannelType.localDb,
        fromCache: !forceRefresh,
      );
    } catch (e) {
      appLog.error('LocalDbChannel: 获取分类失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.localDb,
        error: e.toString(),
      );
    }
  }

  /// appId 即包名（本地数据库语义），无需规范化
  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => appInfo.appId;

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async {
    return ChannelResult.failure(
      from: ChannelType.localDb,
      error: '本地数据库渠道不支持手动添加应用',
    );
  }

  @override
  Future<ChannelResult<void>> removeApp(String appId) async {
    return ChannelResult.failure(
      from: ChannelType.localDb,
      error: '本地数据库渠道不支持移除应用',
    );
  }

  @override
  Future<ChannelResult<bool>> checkUpdate() async {
    try {
      var config = await _database.dao.getVersion();
      if (config == null) {
        return ChannelResult.success(
          data: true,
          from: ChannelType.localDb,
          metadata: {'reason': 'no_version'},
        );
      }
      // 通过 DbManager 检查更新
      var updateStatus = await "gstore".checkUpdate();
      bool hasUpdate = updateStatus == 0 || updateStatus == 1;

      return ChannelResult.success(
        data: hasUpdate,
        from: ChannelType.localDb,
        metadata: {
          'currentVersion': config.version,
          'proxy': getProxy(),
        },
      );
    } catch (e) {
      appLog.error('LocalDbChannel: 检查更新失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.localDb,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async {
    try {
      var updateStatus = await "gstore".checkUpdate();
      bool success = updateStatus == 1; // DOWNLOAD_SUCCESS

      return ChannelResult.success(
        data: success,
        from: ChannelType.localDb,
        metadata: {'updateStatus': updateStatus},
      );
    } catch (e) {
      appLog.error('LocalDbChannel: 执行更新失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.localDb,
        error: e.toString(),
      );
    }
  }

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async {
    try {
      var config = await _database.dao.getVersion();
      return ChannelResult.success(
        data: config,
        from: ChannelType.localDb,
        fromCache: !forceRefresh,
      );
    } catch (e) {
      appLog.error('LocalDbChannel: 获取配置失败 - $e');
      return ChannelResult.failure(
        from: ChannelType.localDb,
        error: e.toString(),
      );
    }
  }

  @override
  Future<void> clearCache() async {
    // 本地数据库无缓存概念，无需清除
    debugPrint('LocalDbChannel: 无需清除缓存');
  }

  @override
  Future<int> getCacheSize() async {
    // 本地数据库缓存大小计算较复杂，这里返回 0
    // 实际可以通过 File(dbPath).length() 获取数据库文件大小
    return 0;
  }

  @override
  Future<void> dispose() async {
    isInitialized = false;
    appLog.info('LocalDbChannel: 已释放');
  }

  @override
  Widget? getAddAppWidget(
    BuildContext context,
    Function(AppSummary) onAppAdded, {
    VoidCallback? onAppSaved,
  }) {
    // 本地数据库渠道不需要添加功能，应用已经在数据库中
    return null;
  }
}

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
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/proxy/FdroidChannelDetailProxy.dart';
import 'package:gstore/core/service/app_icon_service.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/core/channel/AppUpdateCheckMixin.dart';

/// F-Droid 应用市场渠道实现
/// 架构：
/// - 使用 Rust RepoManager 搜索应用
/// - 使用 ChannelDatabase 存储用户添加的应用
class FdroidChannel extends IChannel with AppUpdateCheckMixin {
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

  /// 获取当前仓库地址（动态；模块下线时使用默认地址）
  String get _currentRepoUrl {
    return _repoManager?.currentSource.value?.repoUrl ?? 'https://f-droid.org/repo';
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

      // 转换为 AppInfo，构造完整的图标URL
      final apps = channelApps.map((channelApp) {
        final categories = channelApp.category?.split(',') ?? [];

        // 处理图标 URL
        String iconUrl;
        final iconKey = channelApp.icon;

        if (iconKey.isNotEmpty) {
          // 检查是否已经是完整 URL
          if (iconKey.startsWith('http://') || iconKey.startsWith('https://')) {
            // 已经是完整 URL，直接使用
            iconUrl = iconKey;
          } else {
            // 是相对路径，需要拼接完整 URL
            // icon 可能是：/fdroid/repo/icons/xxx.png 或 /icons/xxx.png 或 xxx.png
            String iconPath = iconKey;

            // _currentRepoUrl 格式：https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo
            // 如果 icon 已经包含 /fdroid/repo，需要从源地址提取基础域名
            if (iconPath.startsWith('/fdroid/repo')) {
              // 提取源地址的基础域名（去掉 /fdroid/repo）
              final uri = Uri.tryParse(_currentRepoUrl);
              if (uri != null) {
                iconUrl = '${uri.scheme}://${uri.host}$iconPath';
              } else {
                iconUrl = iconKey;
              }
            }
            // 如果只包含 /icons，去掉 /icons 然后拼接完整路径
            else if (iconPath.startsWith('/icons')) {
              iconUrl = '$_currentRepoUrl$iconPath';
            }
            // 其他情况，确保以 / 开头后拼接
            else {
              if (!iconPath.startsWith('/')) {
                iconPath = '/$iconPath';
              }
              iconUrl = '$_currentRepoUrl$iconPath';
            }
          }
        } else {
          // 默认图标
          iconUrl = '$_currentRepoUrl/icons/${channelApp.appId}.png';
        }

        debugPrint('FdroidChannel: 图标处理 - 原始=$iconKey, 最终=$iconUrl');

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

        // 处理图标 URL
        String iconUrl;
        final iconKey = appMap['icon'];

        if (iconKey != null && iconKey is String && iconKey.isNotEmpty) {
          // 检查是否已经是完整 URL
          if (iconKey.startsWith('http://') || iconKey.startsWith('https://')) {
            // 已经是完整 URL，直接使用
            iconUrl = iconKey;
          } else {
            // 是相对路径，需要拼接完整 URL
            // icon 可能是：/fdroid/repo/icons/xxx.png 或 /icons/xxx.png 或 xxx.png
            String iconPath = iconKey;

            // _currentRepoUrl 格式：https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo
            // 如果 icon 已经包含 /fdroid/repo，需要从源地址提取基础域名
            if (iconPath.startsWith('/fdroid/repo')) {
              // 提取源地址的基础域名（去掉 /fdroid/repo）
              final uri = Uri.tryParse(_currentRepoUrl);
              if (uri != null) {
                iconUrl = '${uri.scheme}://${uri.host}$iconPath';
              } else {
                iconUrl = iconKey;
              }
            }
            // 如果只包含 /icons，去掉 /icons 然后拼接完整路径
            else if (iconPath.startsWith('/icons')) {
              iconUrl = '$_currentRepoUrl$iconPath';
            }
            // 其他情况，确保以 / 开头后拼接
            else {
              if (!iconPath.startsWith('/')) {
                iconPath = '/$iconPath';
              }
              iconUrl = '$_currentRepoUrl$iconPath';
            }
          }
        } else {
          // 没有图标数据，尝试获取已安装应用的图标
          final installedIcon = await AppIconService.instance.getInstalledAppIcon(packageName);
          if (installedIcon != null) {
            iconUrl = installedIcon;
            debugPrint('FdroidChannel: 使用已安装应用图标 - $packageName');
          } else {
            // 使用默认图标
            iconUrl = '$_currentRepoUrl/icons/$packageName.png';
          }
        }

        debugPrint('FdroidChannel: 图标处理 - packageName=$packageName, iconKey=$iconKey, 最终=$iconUrl');

        return AppSummary(
          appId: packageName,
          packageName: (packageName as String).isNotEmpty ? packageName : null,
          name: appMap['name'] ?? '',
          user: appMap['authorName'] ?? '',
          repositories: packageName,
          icon: iconUrl,
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

      // 归一化图标路径，存储为相对路径（不包含完整URL）
      // app.icon 现在是完整URL，需要提取路径部分
      // 例如：https://f-droid.org/repo/icons/com.termux.png -> /com.termux.png
      String iconPath = '/${app.appId}.png';
      final icon = app.icon;
      if (icon.isNotEmpty) {
        if (icon.startsWith('http')) {
          // 完整URL，提取路径部分
          final uri = Uri.tryParse(icon);
          if (uri != null && uri.path.isNotEmpty) {
            // 移除 /icons 前缀（如果存在）
            String path = uri.path;
            if (path.startsWith('/icons')) {
              path = path.substring(7); // 移除 "/icons"
            }
            if (path.isNotEmpty) {
              iconPath = path.startsWith('/') ? path : '/$path';
            }
          }
        } else if (icon.startsWith('/icons')) {
          // 已经包含 /icons 前缀，移除它
          iconPath = icon.substring(7);
          if (!iconPath.startsWith('/')) {
            iconPath = '/$iconPath';
          }
        } else {
          // 相对路径，确保以 / 开头
          iconPath = icon.startsWith('/') ? icon : '/$icon';
        }
      }

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

            // 处理图标 URL（使用与 searchApps 相同的逻辑）
            String iconUrl;
            final iconKey = app.icon;

            if (iconKey.isNotEmpty) {
              // 检查是否已经是完整 URL
              if (iconKey.startsWith('http://') || iconKey.startsWith('https://')) {
                // 已经是完整 URL，直接使用
                iconUrl = iconKey;
              } else {
                // 是相对路径，需要拼接完整 URL
                String iconPath = iconKey;

                // _currentRepoUrl 格式：https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo
                // 如果 icon 已经包含 /fdroid/repo，提取源地址的基础域名
                if (iconPath.startsWith('/fdroid/repo')) {
                  final uri = Uri.tryParse(_currentRepoUrl);
                  if (uri != null) {
                    iconUrl = '${uri.scheme}://${uri.host}$iconPath';
                  } else {
                    iconUrl = iconKey;
                  }
                }
                // 如果只包含 /icons，直接拼接完整路径
                else if (iconPath.startsWith('/icons')) {
                  iconUrl = '$_currentRepoUrl$iconPath';
                }
                // 其他情况，确保以 / 开头后拼接
                else {
                  if (!iconPath.startsWith('/')) {
                    iconPath = '/$iconPath';
                  }
                  iconUrl = '$_currentRepoUrl$iconPath';
                }
              }
            } else {
              // 默认图标
              iconUrl = '$_currentRepoUrl/icons/${app.appId}.png';
            }

            debugPrint('FdroidChannel: 从数据库读取应用信息，图标处理 - 原始=$iconKey, 最终=$iconUrl');
            final appInfo = AppSummary(
              appId: app.appId,
              name: app.name,
              user: app.user,
              repositories: app.repositories,
              icon: iconUrl,
              des: app.description,
              category: categories,
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

      // 构造完整的图标URL（API返回的可能不包含完整路径）
      String iconUrl;
      final iconKey = data['icon'] as String?;

      if (iconKey != null && iconKey.isNotEmpty) {
        if (iconKey.startsWith('http://') || iconKey.startsWith('https://')) {
          // 已经是完整的 URL
          iconUrl = iconKey;
        } else {
          String iconPath = iconKey;
          // 确保以 / 开头
          if (!iconPath.startsWith('/')) {
            iconPath = '/$iconPath';
          }

          // 如果 iconPath 包含 /fdroid/repo，使用 scheme://host + iconPath
          if (iconPath.startsWith('/fdroid/repo')) {
            final uri = Uri.tryParse(_currentRepoUrl);
            if (uri != null) {
              iconUrl = '${uri.scheme}://${uri.host}$iconPath';
            } else {
              iconUrl = iconKey;
            }
          } else if (iconPath.startsWith('/icons')) {
            // 如果以 /icons 开头，直接拼接
            iconUrl = '$_currentRepoUrl$iconPath';
          } else {
            // 其他情况，正常拼接
            iconUrl = '$_currentRepoUrl$iconPath';
          }
        }
      } else {
        // 默认图标
        iconUrl = '$_currentRepoUrl/icons/$packageName.png';
      }
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
      if (!forceRefresh && service != null) {
        try {
          final appData = await service.getAppByPackageName(appId);
          if (appData != null) {
            final metadataJson = appData['metadata'] as String?;
            final versionsJson = appData['versions'] as String?;

            if (metadataJson != null && versionsJson != null) {
              debugPrint('FdroidChannel: 从数据库精确获取到 metadata 和 versions');
              return await _parseDetailFromJson(
                appId,
                appData,
                metadataJson,
                versionsJson,
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
      return await _fetchDetailFromApi(appId);
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
      final appData = await service.getAppByPackageName(appId);
      if (appData != null) {
        final metadataJson = appData['metadata'] as String?;
        final versionsJson = appData['versions'] as String?;
        if (metadataJson != null && versionsJson != null) {
          final result = await _parseDetailFromJson(
            appId,
            appData,
            metadataJson,
            versionsJson,
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
  Future<ChannelResult<IDetailInfo>> _parseDetailFromJson(
    String appId,
    Map<String, dynamic> appData,
    String metadataJson,
    String versionsJson,
  ) async {
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
      String iconUrl = _constructIconUrl(iconKey, appId);

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

        // 构造下载 URL
        String downloadUrl;
        if (fileName.startsWith('/')) {
          downloadUrl = '$_currentRepoUrl$fileName';
        } else {
          downloadUrl = '$_currentRepoUrl/$fileName';
        }

        downloads.add(DownloadInfo(
          url: downloadUrl,
          name: fileName,
          size: size,
          version: versionName,
          versionCode: versionCode,
          hash: hash,
          hashType: 'sha256',
          platform: _extractArch(fileName),
        ));
      }

      // 解析截图
      final screenshots = <ScreenshotInfo>[];
      final screenshotsData = metadata['screenshots'] as Map<String, dynamic>?;
      if (screenshotsData != null) {
        // 优先使用 phone 类型的截图
        final phoneShots = screenshotsData['phone'] as Map<String, dynamic>?;
        if (phoneShots != null) {
          // 优先使用 en-US，然后使用第一个可用的语言
          final enUsShots = phoneShots['en-US'] as List<dynamic>?;
          final shotsList = enUsShots ?? phoneShots.values.firstOrNull as List<dynamic>?;

          if (shotsList != null) {
            for (final shot in shotsList) {
              if (shot is Map<String, dynamic>) {
                final shotPath = shot['name'] as String?;
                if (shotPath != null) {
                  final screenshotUrl = '$_currentRepoUrl$shotPath';
                  screenshots.add(ScreenshotInfo(url: screenshotUrl));
                }
              }
            }
          }
        }
      }

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
  Future<ChannelResult<IDetailInfo>> _fetchDetailFromApi(String appId) async {
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

    // 获取完整仓库索引以获取更多详细信息
    final indexResponse = await _dio.get('${_currentRepoUrl}/index-v1.json');
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
    final iconUrl = _constructIconUrl(iconKey, appId);
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
          downloads.add(DownloadInfo(
            url: '$_currentRepoUrl/$apkName',
            name: apkName,
            size: size,
            version: versionName,
            versionCode: versionCode,
            hash: hash,
            hashType: hashType,
            platform: _extractArch(apkName),
          ));
        }
      }
    }

    // 获取截图（如果有）
    final screenshotsData = appData['screenshots'] as Map?;
    final screenshots = <ScreenshotInfo>[];
    if (screenshotsData != null) {
      screenshotsData.forEach((locale, shots) {
        if (shots is List) {
          for (final shot in shots) {
            if (shot is String) {
              screenshots.add(ScreenshotInfo(url: shot));
            } else if (shot is Map && shot['url'] is String) {
              screenshots.add(ScreenshotInfo(
                url: shot['url'] as String,
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

  /// 构造图标 URL
  String _constructIconUrl(String iconKey, String appId) {
    if (iconKey.startsWith('http://') || iconKey.startsWith('https://')) {
      return iconKey;
    }

    String iconPath = iconKey;
    if (!iconPath.startsWith('/')) {
      iconPath = '/$iconPath';
    }

    if (iconPath.startsWith('/fdroid/repo')) {
      final uri = Uri.tryParse(_currentRepoUrl);
      if (uri != null) {
        return '${uri.scheme}://${uri.host}$iconPath';
      }
    } else if (iconPath.startsWith('/icons')) {
      return '$_currentRepoUrl$iconPath';
    }

    return '$_currentRepoUrl$iconPath';
  }

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
      final response = await _dio.head('${_currentRepoUrl}/index-v1.json');
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

  /// 解析应用信息
  AppSummary _parseAppInfo(String packageName, Map appData) {
    final name = appData['name'] as String? ?? packageName;
    final summary = appData['summary'] as String? ?? '';
    final icon = appData['icon'] as String? ?? '$packageName.png';
    final license = appData['license'] as String?;

    return AppSummary(
      appId: packageName,
      packageName: packageName,
      name: name,
      user: appData['authorName'] ?? '',
      repositories: packageName,
      icon: '${_currentRepoUrl}/icons-640/$icon',
      des: summary,
      category: null,
    );
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
                    ? '${widget.channel._repoManager?.currentSource.value?.repoUrl ?? 'https://f-droid.org/repo'}/icons/${app.appId}.png'
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

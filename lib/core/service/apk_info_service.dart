import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:installed_apps/app_info.dart' as ia;
import 'package:installed_apps/installed_apps.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/GitHubChannel.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';
import 'package:gstore/core/rust/generated/models.dart';
import 'package:gstore/core/service/apk_native_service.dart';
import 'package:gstore/core/service/app_icon_service.dart';

/// APK 信息解析与更新服务
/// 下载完成后解析 APK，用真实包名/应用名/图标更新渠道与聚合记录
class ApkInfoService {
  ApkInfoService._();

  static final ApkInfoService instance = ApkInfoService._();

  /// 解析 APK 文件（Android 优先用原生插件，非 Android 回退 Rust）
  /// 返回 (ApkInfo, 图标PNG字节?)；图标字节仅原生插件提供
  Future<(ApkInfo?, Uint8List?)> parseApk(String apkPath) async {
    if (!apkPath.endsWith('.apk')) return (null, null);

    // Android 平台优先：PackageManager.getPackageArchiveInfo（原生、可靠、含图标）
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final native = await ApkNativeService.instance.parseApk(apkPath);
      if (native != null) {
        return (
          ApkInfo(
            packageName: native.packageName,
            versionName: native.versionName,
            versionCode: native.versionCode.toString(),
            appName: native.appName,
            minSdk: '',
            mainActivity: '',
          ),
          native.iconBytes,
        );
      }
    }

    // 非 Android 或原生失败：回退 Rust 解析（无图标）
    try {
      final rust = await FdroidRustRepoManager.parseApkInfo(apkPath);
      if (rust.packageName.isEmpty) return (null, null);
      return (rust, null);
    } catch (e) {
      appLog.error('ApkInfoService: Rust 解析 APK 失败 - $e');
      return (null, null);
    }
  }

  /// 下载完成后的统一处理
  /// 仅对 GitHub 渠道（appId 为 owner/repo）且解析出真实包名的 APK 生效
  Future<void> handleDownloadedApk({
    required String appId,
    required String apkPath,
  }) async {
    // 仅处理 GitHub 风格 appId（owner/repo）
    if (!appId.contains('/')) return;

    final (info, iconBytes) = await parseApk(apkPath);
    if (info == null) return;
    // 包名相同无需更新
    if (info.packageName == appId) return;

    appLog.info('ApkInfoService: 解析成功 $appId -> ${info.packageName}');

    // 原生插件提供了图标字节：直接存本地并更新记录
    if (iconBytes != null && iconBytes.isNotEmpty) {
      final iconPath = await _saveIconBytes(info.packageName, iconBytes);
      if (iconPath != null) {
        await _updatePackageNameAndIcon(
          appId,
          info.packageName,
          info.appName,
          iconPath,
        );
        return;
      }
    }

    // 步骤 1：立即更新渠道记录的包名（不等安装）
    await _updatePackageName(appId, info.packageName);

    // 步骤 2：后台等待安装完成，通过包名判断已安装后获取应用名与图标
    unawaited(_updateNameAndIconAfterInstall(appId, info.packageName));
  }

  /// 将图标 PNG 字节保存到本地缓存
  Future<String?> _saveIconBytes(String packageName, List<int> bytes) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final iconDir = Directory('${dir.path}/app_icons');
      await iconDir.create(recursive: true);
      final iconFile = File('${iconDir.path}/$packageName.png');
      await iconFile.writeAsBytes(bytes);
      debugPrint('ApkInfoService: 图标已保存 - ${iconFile.path}');
      return iconFile.path;
    } catch (e) {
      appLog.error('ApkInfoService: 保存图标失败 - $e');
      return null;
    }
  }

  /// 直接更新包名 + 应用名 + 图标（原生解析场景，图标无需等安装）
  Future<void> _updatePackageNameAndIcon(
    String oldAppId,
    String packageName,
    String appName,
    String iconPath,
  ) async {
    try {
      final db = await ChannelDatabaseManager.instance;
      final list = await db.dao.getAppsByChannel(ChannelType.github.code);
      final matched = list.where(
        (r) => r.appId == oldAppId || r.apprepo == oldAppId,
      );
      if (matched.isEmpty) return;
      final record = matched.first;
      final updated = ChannelAddedApp(
        appId: packageName,
        name: appName.isNotEmpty ? appName : record.name,
        user: record.user,
        repositories: record.repositories,
        apprepo: record.apprepo ?? oldAppId,
        icon: iconPath,
        description: record.description,
        category: record.category,
        addTime: record.addTime,
        channelCode: ChannelType.github.code,
        extra: record.extra,
      );
      await db.dao.insertApp(updated);
      if (record.appId != packageName) {
        await db.dao.removeApp(record.appId, ChannelType.github.code);
      }
      appLog.info(
          'ApkInfoService: 记录已更新(原生) $oldAppId -> $packageName '
          '(name=$appName, icon=$iconPath)');
      // 清除 GitHub 渠道缓存，确保渠道列表显示最新数据
      _clearGithubCache();
      await _updateAggregatorWithInfo(oldAppId, packageName, appName, iconPath);
    } catch (e) {
      appLog.error('ApkInfoService: 原生更新记录失败 - $e');
    }
  }

  /// 清除 GitHub 渠道缓存
  void _clearGithubCache() {
    try {
      final channel = ChannelManager.instance.getChannel(ChannelType.github);
      if (channel is GitHubChannel) {
        channel.clearCache();
      }
    } catch (e) {
      appLog.error('ApkInfoService: 清除 GitHub 缓存失败 - $e');
    }
  }

  /// 更新聚合记录（原生场景）
  Future<void> _updateAggregatorWithInfo(
    String oldAppId,
    String packageName,
    String appName,
    String iconPath,
  ) async {
    try {
      final aggregator = AppAggregatorManager.instance;
      final added = await aggregator.isAppAdded(
        channel: ChannelType.github,
        appId: oldAppId,
      );
      if (!added) return;
      await aggregator.removeApp(
        channel: ChannelType.github,
        appId: oldAppId,
      );
      await aggregator.addApp(
        channel: ChannelType.github,
        appInfo: AppSummary(
          appId: packageName,
          packageName: packageName,
          name: appName.isNotEmpty ? appName : oldAppId,
          user: '',
          repositories: oldAppId,
          icon: iconPath,
          des: '',
        ),
      );
      appLog.info('ApkInfoService: 聚合记录已更新(原生)');
    } catch (e) {
      appLog.error('ApkInfoService: 更新聚合记录失败 - $e');
    }
  }

  /// 立即将渠道记录 appId 替换为真实包名
  Future<void> _updatePackageName(String oldAppId, String packageName) async {
    try {
      final db = await ChannelDatabaseManager.instance;
      final list = await db.dao.getAppsByChannel(ChannelType.github.code);
      final matched = list.where(
        (r) => r.appId == oldAppId || r.apprepo == oldAppId,
      );
      if (matched.isEmpty) {
        debugPrint('ApkInfoService: 未找到匹配的渠道记录 $oldAppId');
        return;
      }
      final record = matched.first;
      final updated = ChannelAddedApp(
        appId: packageName,
        name: record.name,
        user: record.user,
        repositories: record.repositories,
        apprepo: record.apprepo ?? oldAppId,
        icon: record.icon,
        description: record.description,
        category: record.category,
        addTime: record.addTime,
        channelCode: ChannelType.github.code,
        extra: record.extra,
      );
      await db.dao.insertApp(updated);
      if (record.appId != packageName) {
        await db.dao.removeApp(record.appId, ChannelType.github.code);
      }
      appLog.info('ApkInfoService: 包名已更新 $oldAppId -> $packageName');
      _clearGithubCache();
    } catch (e) {
      appLog.error('ApkInfoService: 更新包名失败 - $e');
    }
  }

  /// 等待安装完成后，通过包名获取真实应用名与图标并更新记录
  Future<void> _updateNameAndIconAfterInstall(
    String oldAppId,
    String packageName,
  ) async {
    try {
      // 等待安装完成（后台轮询，最多约 60s）
      final installedInfo = await _waitAndGetInstalledInfo(packageName);

      String? realName;
      if (installedInfo != null && installedInfo.name.isNotEmpty) {
        realName = installedInfo.name;
      }

      // 提取图标（需已安装）
      String? iconPath;
      try {
        iconPath = await AppIconService.instance
            .getInstalledAppIcon(packageName);
      } catch (e) {
        appLog.error('ApkInfoService: 提取已安装图标失败 - $e');
      }

      if (realName == null && iconPath == null) {
        debugPrint('ApkInfoService: 未获取到应用名/图标（可能未安装）$packageName');
        return;
      }

      // 更新渠道记录
      final db = await ChannelDatabaseManager.instance;
      final list = await db.dao.getAppsByChannel(ChannelType.github.code);
      final matched = list.where(
        (r) => r.appId == packageName || r.apprepo == oldAppId,
      );
      if (matched.isEmpty) return;
      final record = matched.first;
      final updated = ChannelAddedApp(
        appId: record.appId,
        name: realName ?? record.name,
        user: record.user,
        repositories: record.repositories,
        apprepo: record.apprepo ?? oldAppId,
        icon: iconPath ?? record.icon,
        description: record.description,
        category: record.category,
        addTime: record.addTime,
        channelCode: ChannelType.github.code,
        extra: record.extra,
      );
      await db.dao.insertApp(updated);
      appLog.info('ApkInfoService: 应用名/图标已更新 '
          '(name=$realName, icon=$iconPath)');
      _clearGithubCache();

      // 更新聚合记录（若已添加首页）
      final aggregator = AppAggregatorManager.instance;
      final added = await aggregator.isAppAdded(
        channel: ChannelType.github,
        appId: record.appId,
      );
      if (added) {
        await aggregator.removeApp(
          channel: ChannelType.github,
          appId: record.appId,
        );
        await aggregator.addApp(
          channel: ChannelType.github,
          appInfo: AppSummary(
            appId: record.appId,
            packageName: null, // 原实现未提供包名（extra 为空），保持语义不变
            name: realName ?? record.name,
            user: '',
            repositories: record.repositories,
            icon: iconPath ?? '',
            des: record.description,
          ),
        );
        appLog.info('ApkInfoService: 聚合记录应用名/图标已更新');
      }
    } catch (e) {
      appLog.error('ApkInfoService: 更新应用名/图标失败 - $e');
    }
  }


  /// 等待应用安装完成，并获取已安装应用信息
  Future<ia.AppInfo?> _waitAndGetInstalledInfo(String packageName) async {
    for (var i = 0; i < 30; i++) {
      try {
        final installed = await InstalledApps.isAppInstalled(packageName);
        if (installed == true) {
          return await InstalledApps.getAppInfo(packageName);
        }
      } catch (e) {
        appLog.error('ApkInfoService: 等待安装检查失败 - $e');
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    appLog.info('ApkInfoService: 等待安装超时 $packageName');
    return null;
  }

}

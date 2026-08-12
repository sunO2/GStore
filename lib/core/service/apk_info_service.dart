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
    // 包名相同无需更新；空/非法包名不迁移（避免写入空 appId 脏行）
    final packageName = info.packageName.trim();
    if (packageName.isEmpty || packageName == appId) return;

    appLog.info('ApkInfoService: 解析成功 $appId -> $packageName');

    // 原生插件提供了图标字节：直接存本地并更新记录（含 name/icon）
    if (iconBytes != null && iconBytes.isNotEmpty) {
      final iconPath = await _saveIconBytes(packageName, iconBytes);
      if (iconPath != null) {
        await _migrateAppId(
          oldAppId: appId,
          newPackageName: packageName,
          name: info.appName,
          icon: iconPath,
        );
        return;
      }
    }

    // 步骤 1：立即更新渠道记录的包名（不等安装）
    await _updatePackageName(appId, packageName);

    // 步骤 2：后台等待安装完成，通过包名判断已安装后获取应用名与图标
    unawaited(_updateNameAndIconAfterInstall(appId, packageName));
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

  /// 统一编排：渠道记录 appId 迁移（owner/repo → 真实包名）+ 聚合库同步改名
  ///
  /// 分层：渠道表 schema/apprepo/extra 语义归 GitHubChannel.migrateAppId；
  /// 聚合库 appId 归 AppAggregatorManager.renameApp（只动聚合引用，绝不重建渠道记录）；
  /// 本服务仅做跨层编排。两个库（channel_apps.db / app_added.db）无法事务，
  /// 各自 try/catch 独立守卫（沿用"渠道保存失败不影响聚合"的容错哲学）。
  Future<void> _migrateAppId({
    required String oldAppId,
    required String newPackageName,
    String? name,
    String? icon,
  }) async {
    try {
      final channel = ChannelManager.instance.getChannel(ChannelType.github);
      if (channel is! GitHubChannel) return;
      final migrated = await channel.migrateAppId(
        oldAppId: oldAppId,
        newPackageName: newPackageName,
        name: name,
        icon: icon,
      );
      if (migrated == null) return;

      try {
        await AppAggregatorManager.instance.renameApp(
          channel: ChannelType.github,
          oldAppId: oldAppId,
          newAppId: newPackageName,
        );
      } catch (e) {
        appLog.error('ApkInfoService: 聚合记录改名失败 - $e');
      }
    } catch (e) {
      appLog.error('ApkInfoService: 迁移渠道记录失败 - $e');
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

  /// 立即将渠道记录 appId 替换为真实包名（非原生路径，无图标字节）
  Future<void> _updatePackageName(String oldAppId, String packageName) async {
    await _migrateAppId(oldAppId: oldAppId, newPackageName: packageName);
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

      // 更新渠道记录（appId 已由 _updatePackageName 迁移为 packageName；
      // 精确 PK 匹配优先，apprepo 兜底渠道迁移失败的场景）
      final db = await ChannelDatabaseManager.instance;
      var matched = await db.dao.getApp(packageName, ChannelType.github.code);
      if (matched == null) {
        final byApprepo = await db.dao
            .getAppsByChannel(ChannelType.github.code)
            .then((list) => list.where((r) => r.apprepo == oldAppId));
        if (byApprepo.isEmpty) return;
        matched = byApprepo.first;
      }
      final record = matched;
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

      // 聚合库不存 name/icon（只存引用，信息由渠道实时查）——无需重建聚合记录，
      // 仅通知首页刷新即可拉到新数据
      if (await AppAggregatorManager.instance.isAppAdded(
        channel: ChannelType.github,
        appId: record.appId,
      )) {
        AppAggregatorManager.instance.notifyAppsChanged();
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

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:installed_apps/app_info.dart' as ia;
import 'package:installed_apps/installed_apps.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/GitHubChannel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/AnalyzerRustDecoder.dart';
import 'package:gstore/core/rust/contract/ModuleTypes.dart';
import 'package:gstore/core/service/apk_native_service.dart';
import 'package:gstore/core/service/app_icon_service.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';

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

    // 非 Android 或原生失败：回退 Rust 解析（无图标；模块优先，失败自动降级宿主内置）
    try {
      final rust = await AnalyzerRustDecoder.parseApkInfo(apkPath);
      if (rust == null || rust.packageName.isEmpty) return (null, null);
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
    unawaited(_updateNameAndIconAfterInstall(appId, packageName)
        .catchError((Object error, StackTrace stackTrace) {
      debugPrint('ApkInfoService: 安装后更新未完成（已记录） - $error');
      debugPrint('$stackTrace');
    }));
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
  /// 聚合库 appId 归 AddedAppsFacade.rename（只动聚合引用，绝不重建渠道记录）；
  /// 本服务仅做跨层编排。两个库（channel_apps.db / app_added.db）无法事务，
  /// 各自 try/catch 独立守卫（沿用"渠道保存失败不影响聚合"的容错哲学）。
  Future<void> _migrateAppId({
    required String oldAppId,
    required String newPackageName,
    String? name,
    String? icon,
  }) async {
    // 渠道记录 appId 迁移属渠道域：核心已拥有（channels on）时由 Rust core 负责
    // appId 规范化，Dart 侧不再触碰旧渠道库（inert on the core lane，可整体删除）。
    if (CoreFlags.channels) return;
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
        await renameAggregateAfterInstall(
          oldAppId: oldAppId,
          newPackageName: newPackageName,
        );
      } catch (e) {
        appLog.error('ApkInfoService: 聚合记录改名失败 - $e');
      }
    } on LegacyWriteBlocked catch (blocked) {
      // 渠道库迁移同样可能被 `channel` 标记拦截：走 typed warning。
      _reportBlockedWrite('migrateChannelAppId', blocked);
    } catch (e) {
      appLog.error('ApkInfoService: 迁移渠道记录失败 - $e');
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
      // 归属检查放在 try 内：本方法是 unawaited 的后台任务，被标记拦截时
      // 必须按本文件的错误策略记录，不能把拒绝的 Future 抛给根 zone。
      await LegacyWriteGuard.assertAllowed('channel');
      // 等待安装完成（后台轮询，最多约 60s）
      final installedInfo = await _waitAndGetInstalledInfo(packageName);

      String? realName;
      if (installedInfo != null && installedInfo.name.isNotEmpty) {
        realName = installedInfo.name;
      }

      // 提取图标（需已安装）
      String? iconPath;
      try {
        iconPath =
            await AppIconService.instance.getInstalledAppIcon(packageName);
      } catch (e) {
        appLog.error('ApkInfoService: 提取已安装图标失败 - $e');
      }

      if (realName == null && iconPath == null) {
        debugPrint('ApkInfoService: 未获取到应用名/图标（可能未安装）$packageName');
        return;
      }

      // 渠道记录读写归 [GitHubChannel]（legacy backend 持有 channel_apps.db）；
      // 本服务只做编排，不再直连 ChannelDatabase（核心拥有渠道域时 guard 已
      // fail-closed，此分支不可达）。
      final channel = ChannelManager.instance.getChannel(ChannelType.github);
      if (channel is! GitHubChannel) return;
      final record = await channel.updateInstalledNameAndIcon(
        packageName: packageName,
        fallbackAppId: oldAppId,
        name: realName,
        icon: iconPath,
      );
      if (record == null) return;
      appLog.info('ApkInfoService: 应用名/图标已更新 '
          '(name=$realName, icon=$iconPath)');

      // 聚合库不存 name/icon（只存引用，信息由渠道实时查）——无需重建聚合记录，
      // 仅通知首页刷新即可拉到新数据
      await notifyAggregateAfterInstall(record.appId);
    } on LegacyWriteBlocked catch (blocked) {
      // 后台任务被核心写标记拦截：按 typed warning 记录，不能静默吞掉。
      _reportBlockedWrite('updateNameAndIcon', blocked);
    } catch (e) {
      appLog.error('ApkInfoService: 更新应用名/图标失败 - $e');
    }
  }

  /// 测试 seam：观察 typed 拦截告警（生产默认只写 appLog）。
  @visibleForTesting
  static void Function(CoreWriteBlockedWarning warning)? debugWarningSink;

  /// 安装后聚合库改名（走 [AddedAppsFacade]）。
  ///
  /// 返回 typed warning 当 `catalog` 写标记拒绝旧写入；调用方不得吞掉。
  @visibleForTesting
  Future<CoreWriteBlockedWarning?> renameAggregateAfterInstall({
    required String oldAppId,
    required String newPackageName,
  }) async {
    try {
      await AddedAppsFacade.instance.rename('github', oldAppId, newPackageName);
      return null;
    } on LegacyWriteBlocked catch (blocked) {
      return _reportBlockedWrite('renameApp', blocked);
    }
  }

  /// 安装后通知首页刷新（走 [AddedAppsFacade]，不直连 legacy 单例）。
  @visibleForTesting
  Future<CoreWriteBlockedWarning?> notifyAggregateAfterInstall(
    String appId,
  ) async {
    try {
      if (await AddedAppsFacade.instance.isAdded('github', appId)) {
        await AddedAppsFacade.instance.notifyAppsChanged();
      }
      return null;
    } on LegacyWriteBlocked catch (blocked) {
      return _reportBlockedWrite('notifyAppsChanged', blocked);
    }
  }

  CoreWriteBlockedWarning _reportBlockedWrite(
    String operation,
    LegacyWriteBlocked blocked,
  ) {
    final warning = CoreWriteBlockedWarning(
      domain: blocked.domain,
      operation: operation,
      detail: 'post-install write refused; the Rust core owns this domain',
    );
    appLog.warning('ApkInfoService: $warning');
    debugWarningSink?.call(warning);
    return warning;
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

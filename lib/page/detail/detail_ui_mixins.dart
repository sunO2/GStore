import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/channel_build_history_sheet.dart';
import 'package:gstore/core/design/channel_version_picker_sheet.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/service/metadata_submit_service.dart';
import 'package:gstore/page/detail/state.dart';
import 'package:gstore/page/web/browser.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// ==================== DetailBrowserMixin ====================

/// 浏览器/应用启动相关方法提取。
///
/// 需要宿主类提供 [state]、[request]、[detailChannel] 字段。
mixin DetailBrowserMixin on GetxController {
  DetailState get state;
  AppDetailRequest? get request;
  IDetailChannel? get detailChannel;

  @override
  void startApp(String packageName) => InstalledApps.startApp(packageName);

  @override
  void openBrowser(String url) {
    if (!url.startsWith("http://") &&
        !url.startsWith("https://") &&
        !url.startsWith("file://")) return;
    url = _stripProxyPrefix(url);
    try {
      final detail = state.detailInfo.value;
      final inAppBrowser = GStoreInAppBrowser(
        appInfo: detail != null
            ? _detailToAppInfo(detail)
            : (request != null ? _requestToAppInfo(request!) : null),
      );
      inAppBrowser.open(
        url: WebUri(url),
        settings: ChromeSafariBrowserSettings(
          shareState: CustomTabsShareState.SHARE_STATE_ON,
          barCollapsingEnabled: true,
        ),
      );
    } catch (e) {
      appLog.error('DetailLogic: 打开浏览器失败 - $e');
    }
  }

  String _stripProxyPrefix(String url) {
    final proxy = getProxy();
    if (proxy.isEmpty) return url;
    if (url.startsWith(proxy)) {
      final remainder = url.substring(proxy.length);
      if (remainder.startsWith('http://') || remainder.startsWith('https://')) {
        return remainder;
      }
    }
    return url;
  }

  @override
  void openProjectBrowser() {
    final detail = state.detailInfo.value;
    if (detail?.projectUrl != null) {
      openBrowser(detail!.projectUrl!);
    } else if (request != null && request!.channel == ChannelType.github) {
      final apiData = state.detailInfo.value?.extra['apiData'];
      if (apiData is Map && apiData['full_name'] is String) {
        openBrowser('https://github.com/${apiData['full_name']}');
        return;
      }
      openBrowser(
          'https://github.com/${request!.packageName ?? request!.appId}');
    }
  }

  AppSummary _detailToAppInfo(IDetailInfo detail) {
    final packageName = detail.packageName.isNotEmpty ? detail.packageName : null;
    return AppSummary(
      appId: detail.appId,
      packageName: packageName,
      name: detail.name,
      user: detail.developer ?? '',
      repositories: detail.packageName,
      icon: detail.icon,
      des: detail.description,
    );
  }

  AppSummary _requestToAppInfo(AppDetailRequest req) {
    return AppSummary(
      appId: req.appId,
      packageName: req.packageName?.isNotEmpty == true ? req.packageName : null,
      name: req.name,
      user: '',
      repositories: req.packageName ?? '',
      icon: req.icon ?? '',
      des: req.description ?? '',
    );
  }
}

// ==================== DetailMetadataMixin ====================

/// 应用元数据提交相关方法提取。
mixin DetailMetadataMixin on GetxController {
  DetailState get state;
  AppDetailRequest? get request;

  bool get canSubmitAppMetadata => _githubRepo() != null;

  ({String owner, String repo})? _githubRepo() {
    final detail = state.detailInfo.value;
    if (request?.channel == ChannelType.github) {
      final apiData = detail?.extra['apiData'];
      if (apiData is Map && apiData['full_name'] is String) {
        final parts = (apiData['full_name'] as String).split('/');
        if (parts.length == 2) return (owner: parts[0], repo: parts[1]);
      }
      final parts = (request!.appId).split('/');
      if (parts.length == 2) return (owner: parts[0], repo: parts[1]);
    } else if (request?.channel == ChannelType.localDb && detail != null) {
      final repositoryName = detail.extra['repositoryName']?.toString();
      final developer = detail.extra['developer']?.toString();
      if ((repositoryName?.isNotEmpty ?? false) &&
          (developer?.isNotEmpty ?? false)) {
        return (owner: developer!, repo: repositoryName!);
      }
    }
    return null;
  }

  @override
  Future<void> submitAppMetadata() async {
    final repo = _githubRepo();
    if (repo == null) {
      AppDialogs.showError('该应用不是 GitHub 仓库类型，无法完善应用信息');
      return;
    }
    final userManager = UserManager.instance;
    final loggedIn = await userManager.isLoggedIn();
    if (!loggedIn) {
      final goLogin = await AppDialogs.showDialog(
        title: '需要登录 GitHub',
        content: '提交完善应用信息需要登录 GitHub 账号，是否前往登录？',
        confirmText: '去登录',
        cancelText: '取消',
      );
      if (goLogin == true) appRouter.push(AppRoute.auth);
      return;
    }
    final confirmed = await AppDialogs.showDialog(
      title: '完善应用信息',
      content: '将向 GStore-Repositorys 提交 issue，'
          '由 Actions 自动提取 ${repo.owner}/${repo.repo} 最新 release APK 的\n'
          '应用名 / 包名 / 图标 / 版本信息。',
      confirmText: '提交',
      cancelText: '取消',
    );
    if (confirmed != true) return;
    try {
      final url = await MetadataSubmitService.instance
          .submitAppMetadata(owner: repo.owner, repo: repo.repo);
      if (url == null) {
        AppDialogs.showError('未登录，无法提交');
        return;
      }
      AppDialogs.showSuccess('已提交，仓库 Actions 将自动处理\n可在 issue 中查看进度',
          title: '提交成功');
    } catch (e) {
      AppDialogs.showError('提交失败: $e', title: '提交失败');
    }
  }
}

// ==================== DetailVersionPickerMixin ====================

/// 版本/环境切换、历史构建、UA 选择器相关方法提取。
mixin DetailVersionPickerMixin on GetxController {
  DetailState get state;
  AppDetailRequest? get request;
  IDetailChannel? get detailChannel;

  /// 宿主类（DetailLogic）实现的 DetailCallbacks 方法抽象声明
  Future<void> refreshDetail({required Map<String, dynamic> detailData});
  void showSuccess(String message, {String? title});
  void showError(String message, {String? title});
  Future<void> startDownload(DownloadInfo download, {int? downloadSize});

  @override
  Future<void> showVersionPicker({
    required Map<String, dynamic> options,
    required String appId,
  }) async {
    final ctx = Get.context;
    if (ctx == null) return;
    final envs = (options['envs'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const [];
    final versions = _parseVersionOptions(options);
    final sel = await ChannelVersionPickerSheet.show(
      context: ctx,
      title: options['title']?.toString() ?? '切换版本',
      envs: envs,
      versions: versions,
      currentEnv: options['currentEnv']?.toString(),
      currentVersion: options['currentVersion']?.toString(),
      onEnvChanged: (env) async {
        final dc = detailChannel;
        return _parseVersionOptions(
                await dc?.versionOptions(appId, env: env)) ??
            const <VersionOption>[];
      },
      onBuildHistory: ({required version, required env}) async {
        final dc = detailChannel;
        final bh = await dc?.buildHistory(
            appId: appId, version: version, env: env);
        if (bh == null) return const <BuildOption>[];
        final builds = ((bh['builds'] as List?)?.map((b) {
              final m = b as Map;
              return BuildOption(
                num: (m['num'] as num?)?.toInt() ?? 0,
                publishedAt: m['publishedAt'] != null
                    ? DateTime.tryParse(m['publishedAt'].toString())
                    : null,
                size: (m['size'] as num?)?.toInt(),
                changelog: m['changelog']?.toString(),
                installTimes: (m['installTimes'] as num?)?.toInt(),
                builtBy: m['builtBy']?.toString(),
                ipaName: m['ipaName']?.toString(),
              );
            }))?.toList() ??
            [];
        return builds;
      },
      onBuildSelect: (build, {required version, required env}) {
        unawaited(_downloadHistoricalBuild(
            build, version: version, env: env));
      },
    );
    if (sel == null) return;
    final dc = detailChannel;
    final detail = await dc?.switchVersion(
        appId: appId, env: sel.env, version: sel.version);
    if (detail != null) {
      await refreshDetail(detailData: detail);
      showSuccess('已切换到 ${sel.version}（${sel.env}）');
    } else {
      showError('切换版本失败');
    }
  }

  @override
  Future<void> showBuildHistory({
    required List<Map<String, dynamic>> builds,
    required String appId,
    required String version,
    required String env,
  }) async {
    final ctx = Get.context;
    if (ctx == null) return;
    final parsed = builds.map((b) => BuildOption(
      num: (b['num'] as num?)?.toInt() ?? 0,
      publishedAt: b['publishedAt'] != null
          ? DateTime.tryParse(b['publishedAt'].toString())
          : null,
      size: (b['size'] as num?)?.toInt(),
      changelog: b['changelog']?.toString(),
      installTimes: (b['installTimes'] as num?)?.toInt(),
      builtBy: b['builtBy']?.toString(),
      ipaName: b['ipaName']?.toString(),
    )).toList();
    final sel = await ChannelBuildHistorySheet.show(
        context: ctx, version: version, env: env, builds: parsed);
    if (sel == null) return;
    // 选中构建 → 下载
    final dc = detailChannel;
    final detail = await dc?.switchVersion(
        appId: appId,
        env: env,
        version: version,
        build: {
          'num': sel.num,
          if (sel.ipaName != null) 'ipaName': sel.ipaName,
        });
    if (detail == null) {
      showError('该构建暂不可下载');
      return;
    }
    await refreshDetail(detailData: detail);
    // 匹配下载项
    final proxy = JsChannelDetailProxy(detail);
    final match = sel.ipaName != null
        ? proxy.downloads.where((d) => d.name == sel.ipaName).firstOrNull
        : null;
    if (match != null) await startDownload(match);
  }

  @override
  Future<String?> showUAPicker({
    required List<String>? uaOptions,
    required String appId,
    String? current,
  }) async {
    final ctx = Get.context;
    if (ctx == null || uaOptions == null || uaOptions.isEmpty) return null;
    return showModalBottomSheet<String>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Theme.of(ctx).colorScheme.dialogSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.radiusSheet),
        ),
      ),
      builder: (c) {
        final colorScheme = Theme.of(c).colorScheme;
        final textTheme = Theme.of(c).textTheme;
        final maxHeight = MediaQuery.of(c).size.height * 0.7;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ===== 固定头部：标题 =====
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.xl,
                  AppSpacing.xl,
                  AppSpacing.sm,
                ),
                child: Text(
                  '切换 UA',
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
                ),
              ),
              // 副标题
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  0,
                  AppSpacing.xl,
                  AppSpacing.sm,
                ),
                child: Text(
                  '选择 User-Agent，确认后下载使用该 UA 请求',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              // ===== UA 选项列表（单选）=====
              Expanded(
                child: ListView.builder(
                  padding: AppSpacing.onlyHorizontalXL,
                  itemCount: uaOptions.length,
                  itemBuilder: (context, index) {
                    final ua = uaOptions[index];
                    final isSelected =
                        _uaDisplayName(ua) == _uaDisplayName(current ?? '');
                    return Column(
                      children: [
                        InkWell(
                          onTap: () => Navigator.of(c).pop(ua),
                          child: Padding(
                            padding: AppSpacing.onlyVerticalMD,
                            child: Row(
                              children: [
                                Icon(
                                  isSelected
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_off,
                                  size: AppTypography.iconMD,
                                  color: isSelected
                                      ? colorScheme.primary
                                      : colorScheme.outlineVariant,
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Text(
                                    _uaDisplayName(ua),
                                    style: textTheme.bodyMedium?.copyWith(
                                      fontWeight: AppTypography.weightMedium,
                                      color: isSelected
                                          ? colorScheme.primary
                                          : colorScheme.onSurface,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _uaDisplayName(String ua) {
    if (ua.contains('Android')) return 'Android';
    if (ua.contains('iPhone') || ua.contains('iOS')) return 'iOS';
    if (ua.contains('HarmonyOS')) return 'Harmony';
    return 'Android'; // fallback
  }

  List<VersionOption> _parseVersionOptions(Map<String, dynamic>? opts) {
    return (opts?['versions'] as List?)?.map((v) {
          final m = v as Map;
          return VersionOption(
            version: m['version']?.toString() ?? '',
            envs: (m['envs'] as List?)
                    ?.map((e) => e.toString())
                    .toList() ??
                const [],
            buildCount: (m['buildCount'] as num?)?.toInt() ?? 0,
          );
        }).toList() ??
        const <VersionOption>[];
  }

  Future<void> _downloadHistoricalBuild(
    BuildOption build, {
    required String version,
    required String env,
  }) async {
    final req = request;
    if (req == null) return;
    final dc = detailChannel;
    if (dc == null) return;
    final detail = await dc.switchVersion(
        appId: req.appId, env: env, version: version);
    if (detail == null) {
      showError('该构建暂不可下载');
      return;
    }
    final proxy = JsChannelDetailProxy(detail);
    final match = build.ipaName != null
        ? proxy.downloads.where((d) => d.name == build.ipaName).firstOrNull
        : null;
    if (match == null) {
      showError('该构建暂不可下载');
      return;
    }
    await startDownload(match);
  }
}
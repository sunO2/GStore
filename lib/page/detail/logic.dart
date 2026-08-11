import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/service/downloadService.dart';
import 'package:gstore/core/service/metadata_submit_service.dart';
import 'package:gstore/core/download/DownloadStrategyManager.dart';
import 'package:gstore/core/download/strategy/impl/LocalDbDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/VivoDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/GitHubDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/HttpDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/FdroidDownloadStrategy.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:gstore/page/web/browser.dart';
import 'package:installed_apps/installed_apps.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'state.dart';

class DetailLogic extends GetxController {
  final StreamController<DownloadStatus> counterController =
      StreamController<DownloadStatus>.broadcast();
  StreamSubscription? downloadListenerSubscription;

  final DetailState state = DetailState();

  /// 请求参数
  AppDetailRequest? request;

  /// 渠道管理器
  late ChannelManager _channelManager;

  @override
  void onReady() {
    _channelManager = Get.find(tag: 'channelManager');
    _initializeFromArguments();
    super.onReady();
  }

  /// 从参数初始化基础信息
  void _initializeFromArguments() {
    final args = Get.arguments;

    if (args == null) {
      state.errorMessage.value = '缺少参数';
      state.isLoading.value = false;
      return;
    }

    // 转换为 AppDetailRequest（类型安全）
    if (args is AppDetailRequest) {
      request = args;
    } else if (args is Map<String, dynamic>) {
      // 尝试从 Map 转换
      final channel = args['channel'];
      final channelType = channel is ChannelType
          ? channel
          : (channel is String ? ChannelType.fromCode(channel) : ChannelType.localDb);
      request = AppDetailRequest.fromAppInfo(args, channelType ?? ChannelType.localDb);
    } else {
      // 尝试从 AggregatedAppInfo 转换
      try {
        request = AppDetailRequest.fromAggregatedAppInfo(args);
      } catch (e) {
        state.errorMessage.value = '无效的参数类型: ${args.runtimeType}';
        state.isLoading.value = false;
        return;
      }
    }

    // 设置基础信息到 state
    state.request = request;
    state.isLoading.value = false;

    // 异步加载详情
    loadDetail();
  }

  /// 加载应用详情
  Future<void> loadDetail() async {
    if (request == null) {
      state.errorMessage.value = '缺少请求参数';
      return;
    }

    state.isLoadingDetail.value = true;
    state.errorMessage.value = '';

    try {
      // 通过渠道管理器获取详情
      final channelInstance = _channelManager.getChannel(request!.channel);
      if (channelInstance == null) {
        throw Exception('Channel not found: ${request!.channel}');
      }

      // 先获取基本信息（缓存数据）
      final basicInfoResult = await channelInstance.getAppInfo(
        request!.appId,
        forceRefresh: false,
      );

      // 再获取详情信息
      final result = await channelInstance.getAppDetail(
        request!.appId,
        forceRefresh: false,
      );

      if (!result.success || result.data == null) {
        throw Exception(result.error ?? 'Failed to load app detail');
      }

      state.detailInfo.value = result.data;

      // 详情加载后，使用详情中的 packageName 重新检测安装状态
      final detail = result.data;
      debugPrint('DetailLogic: detail.appId = ${detail?.appId}');
      debugPrint('DetailLogic: detail.packageName = "${detail?.packageName}"');
      debugPrint('DetailLogic: detail.runtimeType = ${detail?.runtimeType}');

      String? packageToCheck = detail?.packageName?.trim();
      debugPrint('DetailLogic: packageName 长度 = ${detail?.packageName?.length ?? 0}');
      debugPrint('DetailLogic: packageName bytes = ${detail?.packageName?.codeUnits}');

      // 如果详情中没有 packageName，尝试使用 appId（如果它看起来像包名）
      if ((packageToCheck == null || packageToCheck.isEmpty) &&
          (detail?.appId?.contains('.') ?? false)) {
        packageToCheck = detail!.appId.trim();
        debugPrint('DetailLogic: 使用详情 appId 作为包名进行检测: $packageToCheck');
      }

      debugPrint('DetailLogic: 最终用于检测的包名 = "$packageToCheck"');

      if (packageToCheck != null && packageToCheck.isNotEmpty) {
        try {
          final isInstalled = await InstalledApps.isAppInstalled(packageToCheck);
          debugPrint('DetailLogic: InstalledApps.isAppInstalled("$packageToCheck") = $isInstalled');

          if (isInstalled == true) {
            state.installInfo.value = await InstalledApps.getAppInfo(packageToCheck);
            appLog.info('DetailLogic: ✓ 应用已安装 - ${state.installInfo.value?.packageName}');
            debugPrint('DetailLogic:   安装版本 = ${state.installInfo.value?.versionName}');
            debugPrint('DetailLogic:   UI 将更新（installInfo 是响应式变量）');
          } else {
            appLog.info('DetailLogic: ✗ 应用未安装 - "$packageToCheck"');
          }
        } catch (e) {
          appLog.error('DetailLogic: 检测安装状态时出错: $e');
        }
      } else {
        appLog.error('DetailLogic: 无法检测安装状态 - 没有可用的包名');
      }
    } catch (e) {
      state.errorMessage.value = '加载详情失败: $e';
    } finally {
      state.isLoadingDetail.value = false;
    }
  }

  /// 开始下载
  /// 优先使用新的策略模式下载，失败时降级到旧方法
  /// 先建立状态监听（显示实时进度），再异步启动下载（不阻塞 UI）
  Future<void> startDownload(
    DownloadInfo download, {
    int? downloadSize,
  }) async {
    final detail = state.detailInfo.value;
    final req = request;
    if (detail == null && req == null) return;

    downloadListenerSubscription?.cancel();

    final appId = req?.appId ?? detail!.appId;
    final appName = req?.name ?? detail!.name;
    final version = download.version ?? 'unknown';
    final fileName = download.name;

    // 预先创建/获取下载状态，用于立即建立进度监听
    final status = await DownloadStatus.create(
      appId,
      appName,
      version,
      fileName,
      download.url,
      downloadSize: download.size ?? downloadSize,
    );

    // 立即监听进度并转发到 UI
    state.currentDownload.value = status;
    counterController.sink.add(status);
    downloadListenerSubscription = status.observer.listen((da) {
      // 同一实例更新时 GetX 不会自动通知，需强制 refresh
      state.currentDownload.value = da;
      state.currentDownload.refresh();
      counterController.sink.add(da);
    });

    // 异步启动下载（不阻塞，下载完成后会自动更新 status）
    unawaited(_startDownloadTask(download, appId, appName, version, fileName));
  }

  /// 实际启动下载任务（异步执行）
  Future<void> _startDownloadTask(
    DownloadInfo download,
    String appId,
    String appName,
    String version,
    String fileName,
  ) async {
    try {
      // 确保策略管理器已初始化
      _initializeDownloadStrategies();

      final detail = state.detailInfo.value;
      if (detail == null) return;

      // 尝试使用策略模式下载
      final context = await DownloadStrategyManager.instance.createContext(
        download,
        detail,
      );

      if (context != null) {
        debugPrint('DetailLogic: 使用策略模式下载 - ${context.downloadUrl}');
        await Get.find<DownloadService>().downloadWithContext(
          context,
          appId,
          appName,
          version,
          fileName,
        );
      } else {
        appLog.error('DetailLogic: 下载上下文创建失败，降级到旧方法');
        throw Exception('Failed to create download context');
      }
    } catch (e) {
      appLog.error('DetailLogic: 策略模式下载失败，降级到旧方法 - $e');
      try {
        await Get.find<DownloadService>().download(
          appId,
          appName,
          version,
          download.url,
          fileName,
          downloadSize: download.size,
        );
      } catch (e2) {
        appLog.error('DetailLogic: 下载失败 - $e2');
      }
    }
  }

  /// 初始化下载策略
  /// 确保所有渠道的策略都已注册
  void _initializeDownloadStrategies() {
    final manager = DownloadStrategyManager.instance;

    // 只在首次调用时注册策略
    if (manager.strategyCount == 0) {
      manager.registerAll([
        LocalDbDownloadStrategy(),
        VivoDownloadStrategy(),
        GitHubDownloadStrategy(),
        HttpDownloadStrategy(),
        FdroidDownloadStrategy(),
      ]);
      appLog.info('DetailLogic: 已注册 ${manager.strategyCount} 个下载策略');
    }
  }

  /// 启动应用
  void startApp(String packageName) {
    InstalledApps.startApp(packageName);
  }

  /// 打开浏览器
  void openBrowser(String url) {
    if (!url.startsWith("http://") &&
        !url.startsWith("https://") &&
        !url.startsWith("file://")) {
      return;
    }

    // 防止代理前缀污染（剥掉全局代理前缀，确保打开真实 URL）
    url = _stripProxyPrefix(url);

    try {
      final detail = state.detailInfo.value;
      GStoreInAppBrowser inAppBrowser = GStoreInAppBrowser(
        appInfo: detail != null
            ? _detailToAppInfo(detail)
            : (request != null ? _requestToAppInfo(request!) : null),
      );

      final settings = ChromeSafariBrowserSettings(
        shareState: CustomTabsShareState.SHARE_STATE_ON,
        barCollapsingEnabled: true,
      );
      inAppBrowser.open(url: WebUri(url), settings: settings);
    } catch (e) {
      appLog.error('DetailLogic: 打开浏览器失败 - $e');
    }
  }

  /// 剥掉代理前缀（如 https://ghfast.top/），保留原始 URL
  String _stripProxyPrefix(String url) {
    final proxy = getProxy();
    if (proxy.isEmpty) return url;

    // 仅当代理后紧跟协议边界时才剥离，避免误匹配（如 https://ghfast.top 误匹配 https://ghfast.top2.com）
    if (url.startsWith(proxy)) {
      final remainder = url.substring(proxy.length);
      // 剥离后必须是完整协议 URL（避免相对路径导致 WebUri 崩溃）
      if (remainder.startsWith('http://') ||
          remainder.startsWith('https://')) {
        debugPrint('DetailLogic: 剥掉代理前缀 - $url -> $remainder');
        return remainder;
      }
    }
    return url;
  }

  /// 打开项目主页
  void openProjectBrowser() {
    final detail = state.detailInfo.value;
    if (detail?.projectUrl != null) {
      openBrowser(detail!.projectUrl!);
    } else if (request != null && request!.channel == ChannelType.github) {
      // 如果是 GitHub 渠道，构造 GitHub URL
      final detailFromLogic = state.detailInfo.value;
      if (detailFromLogic != null) {
        // 尝试从 extra 获取 user/repositories（类型安全）
        final apiData = detailFromLogic.extra['apiData'];
        if (apiData is Map && apiData['full_name'] is String) {
          openBrowser('https://github.com/${apiData['full_name']}');
          return;
        }
      }
      openBrowser('https://github.com/${request!.packageName ?? request!.appId}');
    }
  }

  /// 是否可提交应用元数据（GitHub 渠道，或 LocalDb 中的 GitHub 仓库类型应用）
  bool get canSubmitAppMetadata => _githubRepo() != null;

  /// 从请求/详情中解析 GitHub owner/repo
  /// - GitHub 渠道：apiData.full_name 或 appId（owner/repo）
  /// - LocalDb 渠道：extra 中的 repositoryName + developer（GitHub 仓库类型应用）
  ({String owner, String repo})? _githubRepo() {
    final detail = state.detailInfo.value;

    if (request?.channel == ChannelType.github) {
      // 优先从 apiData.full_name 解析
      final apiData = detail?.extra['apiData'];
      if (apiData is Map && apiData['full_name'] is String) {
        final full = apiData['full_name'] as String;
        final parts = full.split('/');
        if (parts.length == 2) return (owner: parts[0], repo: parts[1]);
      }

      // 回退：appId 格式为 owner/repo
      final parts = (request!.appId).split('/');
      if (parts.length == 2) return (owner: parts[0], repo: parts[1]);
    } else if (request?.channel == ChannelType.localDb && detail != null) {
      // LocalDb 中的 GitHub 仓库类型应用：repositoryName + developer
      final repositoryName = detail.extra['repositoryName']?.toString();
      final developer = detail.extra['developer']?.toString();
      if ((repositoryName?.isNotEmpty ?? false) &&
          (developer?.isNotEmpty ?? false)) {
        return (owner: developer!, repo: repositoryName!);
      }
    }

    return null;
  }

  /// 提交应用元数据提取请求（触发 GStore-Repositorys Actions）
  Future<void> submitAppMetadata(BuildContext context) async {
    final repo = _githubRepo();
    if (repo == null) {
      AppDialogs.showError('该应用不是 GitHub 仓库类型，无法完善应用信息');
      return;
    }

    final userManager = Get.find<UserManager>();
    final loggedIn = await userManager.isLoggedIn();
    if (!loggedIn) {
      final goLogin = await AppDialogs.showDialog(
        title: '需要登录 GitHub',
        content: '提交完善应用信息需要登录 GitHub 账号，是否前往登录？',
        confirmText: '去登录',
        cancelText: '取消',
      );
      if (goLogin == true) {
        Get.toNamed(AppRoute.auth);
      }
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
      final url = await MetadataSubmitService.instance.submitAppMetadata(
        owner: repo.owner,
        repo: repo.repo,
      );
      if (url == null) {
        AppDialogs.showError('未登录，无法提交');
        return;
      }
      AppDialogs.showSuccess(
        '已提交，仓库 Actions 将自动处理\n可在 issue 中查看进度',
        title: '提交成功',
      );
      appLog.info('DetailLogic: 元数据请求已提交 - $url');
    } catch (e) {
      appLog.error('DetailLogic: 提交元数据请求失败 - $e');
      AppDialogs.showError('提交失败: $e', title: '提交失败');
    }
  }

  /// 将 IDetailInfo 转换为 AppSummary
  AppSummary _detailToAppInfo(IDetailInfo detail) {
    // 返回一个 AppSummary 对象（类型安全）
    // 注意：repositories 保持现映射 = detail.packageName（browser 的 appInfo 载荷依赖它，不得置空）
    final packageName = detail.packageName.isNotEmpty ? detail.packageName : null;
    return AppSummary(
      appId: detail.appId,
      packageName: packageName,
      name: detail.name,
      user: detail.developer ?? '',
      repositories: detail.packageName,
      icon: detail.icon,
      des: detail.description ?? '',
    );
  }

  /// 将 AppDetailRequest 转换为 AppSummary
  AppSummary _requestToAppInfo(AppDetailRequest req) {
    return AppSummary(
      appId: req.appId,
      packageName: req.packageName?.isNotEmpty == true ? req.packageName : null,
      name: req.name,
      user: '', // user 字段为空
      repositories: req.packageName ?? '', // repositories 保持现映射 = req.packageName（browser 载荷依赖）
      icon: req.icon ?? '', // icon 可能为空，使用空字符串作为默认值
      des: req.description ?? '',
    );
  }

  @override
  void onClose() {
    counterController.close();
    downloadListenerSubscription?.cancel();
    super.onClose();
  }
}

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
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
import 'widgets/more_actions_sheet.dart';

class DetailLogic extends GetxController {
  final StreamController<DownloadStatus> counterController =
      StreamController<DownloadStatus>.broadcast();
  StreamSubscription? downloadListenerSubscription;

  final DetailState state = DetailState();

  /// 请求参数
  AppDetailRequest? request;

  /// 渠道管理器
  late ChannelManager _channelManager;

  /// 聚合管理器（标签读写，与发现页同一套 added_app_tags）
  late AppAggregatorManager _aggregator;

  @override
  void onReady() {
    _channelManager = Get.find(tag: 'channelManager');
    _aggregator = Get.find(tag: 'aggregatorManager');
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

  /// 加载应用详情（分块渐进组装）
  ///
  /// ① getAppInfo → 基础 detailInfo 立即注入（名称/图标/描述/开发者/主页等）
  /// ② 三路并行（统计/下载/README），各自独立 try/catch，互不阻塞：
  ///    任一区块失败只降级自身（区块保持 null + loading 复位），不影响其他区块。
  Future<void> loadDetail() async {
    if (request == null) {
      state.errorMessage.value = '缺少请求参数';
      return;
    }

    state.isLoadingDetail.value = true;
    state.errorMessage.value = '';

    try {
      // 懒初始化（兼容单测直接调 loadDetail；正常流程 onReady 已注入，重复查找幂等）
      _channelManager = Get.find(tag: 'channelManager');
      final channelInstance = _channelManager.getChannel(request!.channel);
      if (channelInstance == null) {
        throw Exception('Channel not found: ${request!.channel}');
      }

      // 非分块渠道（Vivo/Fdroid/Http 等）：回退旧流程 getAppDetail 一次性完整注入。
      // 截图/下载/更新日志/权限/评分等区块仅旧流程提供，分块改造不得使其丢失。
      if (!channelInstance.supportsProgressiveLoading) {
        await _loadDetailLegacy(channelInstance);
        return;
      }

      // ① 基础信息（失败仅日志不阻塞，回退 request 参数）
      AppSummary? basic;
      try {
        final basicInfoResult = await channelInstance.getAppInfo(
          request!.appId,
          forceRefresh: false,
        );
        basic = basicInfoResult.success ? basicInfoResult.data : null;
      } catch (e) {
        appLog.error('DetailLogic: 获取基础信息失败（不阻塞分块加载） - $e');
      }

      // 基础 detailInfo 就绪即注入（头部/应用信息卡立即可渲染）
      final baseDetail = _buildBaseDetailInfo(basic);
      // 包名回退：getAppInfo（keepExistingPackageName: false）无 metadata 时
      // packageName 为 null（离线 LocalDb 应用检测丢失）——回退请求参数包名，
      // 使 packageName 语义与旧 getAppDetail（keepExistingPackageName: true）对齐。
      final effectivePackageName = (baseDetail.packageName?.isNotEmpty ?? false)
          ? baseDetail.packageName!
          : request!.packageName;
      final effectiveBase = (effectivePackageName != null &&
              effectivePackageName.isNotEmpty)
          ? baseDetail.copyWith(packageName: effectivePackageName)
          : baseDetail;
      state.detailInfo.value = _ProgressiveDetailInfo(effectiveBase);

      // packageName 就绪即执行安装检测（插件调用失败已容忍，不影响加载流程）
      final packageToCheck = effectivePackageName?.trim();
      if (packageToCheck != null && packageToCheck.isNotEmpty) {
        try {
          final isInstalled = await InstalledApps.isAppInstalled(packageToCheck);
          if (isInstalled == true) {
            state.installInfo.value = await InstalledApps.getAppInfo(packageToCheck);
            appLog.info('DetailLogic: ✓ 应用已安装 - ${state.installInfo.value?.packageName}');
          } else {
            appLog.info('DetailLogic: ✗ 应用未安装 - "$packageToCheck"');
          }
        } catch (e) {
          appLog.error('DetailLogic: 检测安装状态时出错: $e');
        }
      } else {
        appLog.error('DetailLogic: 无法检测安装状态 - 没有可用的包名');
      }

      // ② 三路并行分块加载（统计/下载/README），各自独立降级互不阻塞
      await Future.wait([
        _loadStatistics(channelInstance),
        _loadDownloads(channelInstance),
        _loadReadme(channelInstance),
      ]);
    } catch (e) {
      state.errorMessage.value = '加载详情失败: $e';
    } finally {
      state.isLoadingDetail.value = false;
    }
  }

  /// 旧流程加载详情（非分块渠道回退路径）：还原分块改造前的 loadDetail 主体。
  ///
  /// getAppInfo（缓存基础信息，失败仅日志不阻塞）→ getAppDetail 一次性完整注入
  /// （截图/下载/更新日志/权限/评分等全部区块）→ 基于详情 packageName 检测安装状态。
  /// isLoadingDetail 的复位由外层 loadDetail 的 finally 统一负责。
  Future<void> _loadDetailLegacy(IChannel channel) async {
    // 先获取基本信息（缓存数据；失败不阻塞，请求参数/详情兜底显示）
    try {
      await channel.getAppInfo(
        request!.appId,
        forceRefresh: false,
      );
    } catch (e) {
      appLog.error('DetailLogic: 获取基础信息失败（不阻塞详情加载） - $e');
    }

    // 再获取详情信息（一次性完整注入）
    final result = await channel.getAppDetail(
      request!.appId,
      forceRefresh: false,
    );
    if (!result.success || result.data == null) {
      throw Exception(result.error ?? 'Failed to load app detail');
    }

    state.detailInfo.value = result.data;

    // 详情加载后，使用详情中的 packageName 检测安装状态
    final detail = result.data;
    final packageToCheck = detail?.packageName.trim();
    if (packageToCheck != null && packageToCheck.isNotEmpty) {
      try {
        final isInstalled = await InstalledApps.isAppInstalled(packageToCheck);
        if (isInstalled == true) {
          state.installInfo.value = await InstalledApps.getAppInfo(packageToCheck);
          appLog.info('DetailLogic: ✓ 应用已安装 - ${state.installInfo.value?.packageName}');
        } else {
          appLog.info('DetailLogic: ✗ 应用未安装 - "$packageToCheck"');
        }
      } catch (e) {
        appLog.error('DetailLogic: 检测安装状态时出错: $e');
      }
    } else {
      appLog.error('DetailLogic: 无法检测安装状态 - 没有可用的包名');
    }
  }

  /// 基于基础信息（AppSummary）+ 请求参数构造渐进组装的基础详情。
  ///
  /// 字段与旧 getAppDetail 结果对齐：appId/name/icon/description/channel/
  /// packageName/version/developer/projectUrl + extra 基础键
  /// （developer/repositoryName/projectUrl/proxy——供 _githubRepo / 下载策略读取）。
  AppDetailInfo _buildBaseDetailInfo(AppSummary? basic) {
    final req = request!;
    final name = (basic?.name.isNotEmpty ?? false) ? basic!.name : req.name;
    final icon =
        (basic?.icon.isNotEmpty ?? false) ? basic!.icon : (req.icon ?? '');
    final des = (basic?.des.isNotEmpty ?? false)
        ? basic!.des
        : (req.description ?? '');
    final developer = (basic?.user.isNotEmpty ?? false) ? basic!.user : null;
    final projectUrl = _buildProjectUrl(basic);

    return AppDetailInfo(
      appId: (basic?.appId.isNotEmpty ?? false) ? basic!.appId : req.appId,
      name: name,
      icon: icon,
      description: des,
      channel: req.channel,
      sections: const [],
      packageName: basic?.packageName,
      developer: developer,
      projectUrl: projectUrl,
      extra: {
        if (developer != null) 'developer': developer,
        if (basic?.repositories.isNotEmpty ?? false)
          'repositoryName': basic!.repositories,
        if (projectUrl != null) 'projectUrl': projectUrl,
        'proxy': getProxy(),
      },
    );
  }

  /// 构造项目主页：GitHub 仓库型应用（user/repositories 齐备）→ github.com 地址。
  String? _buildProjectUrl(AppSummary? basic) {
    final user = basic?.user ?? '';
    final repo = basic?.repositories ?? '';
    if (user.isNotEmpty && repo.isNotEmpty) {
      return 'https://github.com/$user/$repo';
    }
    return null;
  }

  /// 区块数据到达后对当前 detailInfo 做 copyWith 增补（渐进组装，每次注入即渲染对应区块）
  void _updateDetailInfo(AppDetailInfo Function(AppDetailInfo) transform) {
    final current = state.detailInfo.value;
    if (current is _ProgressiveDetailInfo) {
      // 新包装实例触发 Rx 通知
      state.detailInfo.value = _ProgressiveDetailInfo(transform(current.inner));
    }
  }

  /// 分块加载：统计（apiList → extra.apiData，供 buildStatTags / createContext 解析）
  Future<void> _loadStatistics(IChannel channel) async {
    state.statisticsLoading.value = true;
    try {
      final result = await channel.fetchStatistics(request!.appId);
      if (result.success && result.data != null) {
        final apiData = result.data!;
        _updateDetailInfo((inner) {
          final extra = Map<String, dynamic>.from(inner.extra);
          extra['apiData'] = apiData;
          final sections = [...inner.sections];
          // 与原 _buildSections 语义一致：有 stars/forks 才声明统计区块
          if ((apiData['stargazers_count'] != null ||
                  apiData['forks_count'] != null) &&
              !sections.contains(DetailSection.statistics)) {
            sections.add(DetailSection.statistics);
          }
          return inner.copyWith(extra: extra, sections: sections);
        });
      }
    } catch (e) {
      appLog.error('DetailLogic: 加载统计失败（独立降级，不阻塞其他区块） - $e');
    } finally {
      state.statisticsLoading.value = false;
    }
  }

  /// 分块加载：下载列表（state.downloads + detailInfo.downloads/version + sections）
  Future<void> _loadDownloads(IChannel channel) async {
    state.downloadsLoading.value = true;
    try {
      final result = await channel.fetchDownloads(request!.appId);
      if (result.success) {
        final downloads = result.data ?? const <DownloadInfo>[];
        state.downloads.value = downloads;
        _updateDetailInfo((inner) {
          final sections = [...inner.sections];
          // 与原 _buildSections 语义一致：有下载项才声明下载区块
          if (downloads.isNotEmpty &&
              !sections.contains(DetailSection.downloads)) {
            sections.add(DetailSection.downloads);
          }
          return inner.copyWith(
            downloads: downloads,
            // 最新版本：下载列表首项（releases 按时间倒序，与旧 latestVersion 语义对齐）
            version: inner.version ??
                (downloads.isNotEmpty ? downloads.first.version : null),
            sections: sections,
          );
        });
      }
    } catch (e) {
      appLog.error('DetailLogic: 加载下载列表失败（独立降级，不阻塞其他区块） - $e');
    } finally {
      state.downloadsLoading.value = false;
    }
  }

  /// 分块加载：README（state.readme + detailInfo.extra.readme + sections）
  Future<void> _loadReadme(IChannel channel) async {
    state.readmeLoading.value = true;
    try {
      final result = await channel.fetchReadme(request!.appId);
      if (result.success && result.data != null) {
        final readme = result.data!;
        state.readme.value = readme;
        _updateDetailInfo((inner) {
          final extra = Map<String, dynamic>.from(inner.extra);
          extra['readme'] = readme;
          final sections = [...inner.sections];
          // 与原 _buildSections 语义一致：README 非空才声明区块
          if (readme.isNotEmpty && !sections.contains(DetailSection.readme)) {
            sections.add(DetailSection.readme);
          }
          return inner.copyWith(extra: extra, sections: sections);
        });
      }
    } catch (e) {
      appLog.error('DetailLogic: 加载 README 失败（独立降级，不阻塞其他区块） - $e');
    } finally {
      state.readmeLoading.value = false;
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

  /// 本地库预置分类加载失败/为空时的内置回退列表（与发现页一致）
  static const List<String> _fallbackPresetTags = [
    '工具',
    '游戏',
    '社交',
    '影音',
    '阅读',
    '效率',
    '系统',
  ];

  /// 打开"更多"底部面板：分类标签编辑（与发现页同一套 added_app_tags）+ 动作宫格
  ///
  /// 标签 key 使用 canonical appId（渠道自报规范化），与聚合库/发现页完全一致，
  /// 避免首页匹配不到标签（上次 bug 教训）。
  Future<void> showMoreActions(BuildContext context) async {
    final req = request;
    if (req == null) return;

    // 解析 canonical appId（复刻发现页 showTagPickerForApp 的模式：
    // 渠道 getAppInfo 返回的 AppSummary 交给 canonicalAppId 规范化）
    final channelInstance = _channelManager.getChannel(req.channel);
    String canonicalId = req.appId;
    if (channelInstance != null) {
      try {
        final basicInfo = await channelInstance.getAppInfo(
          req.appId,
          forceRefresh: false,
        );
        final appSummary = basicInfo.success ? basicInfo.data : null;
        if (appSummary != null) {
          canonicalId = await channelInstance.canonicalAppId(appSummary);
        }
      } catch (e) {
        appLog.error('DetailLogic: 解析 canonical appId 失败，使用原始 appId - $e');
      }
    }

    // 读取当前标签（用规范化 appId）
    final currentTags = await _aggregator.getTags(
      channel: req.channel,
      appId: canonicalId,
    );

    // 加载预置分类：本地库 AppCategory 的 description 作为标签值
    var presetTags = <String>[];
    try {
      final categories = await "gstore".repoDB.db.dao.getAllCategory();
      presetTags = categories
          .map((c) => c.description.trim())
          .where((d) => d.isNotEmpty)
          .toList();
    } catch (e) {
      appLog.error('DetailLogic: 加载预置分类失败，使用内置列表 - $e');
    }
    if (presetTags.isEmpty) {
      presetTags = _fallbackPresetTags;
    }

    // 构建动作宫格
    final actions = <MoreActionItem>[
      // 完善应用信息（GitHub 渠道 / LocalDb 的 GitHub 仓库类型应用）
      if (canSubmitAppMetadata)
        MoreActionItem(
          icon: Icons.manage_search,
          label: '完善应用信息',
          onTap: () => submitAppMetadata(context),
        ),
      // 项目主页（打开项目的 GitHub 地址 / 项目详情地址）
      if (state.detailInfo.value?.projectUrl != null)
        MoreActionItem(
          icon: Icons.language,
          label: '项目主页',
          onTap: openProjectBrowser,
        ),
    ];

    // 弹出底部面板（顶部标签编辑 + 底部动作宫格）
    if (!context.mounted) return;
    final result = await showMoreActionsSheet(
      context,
      appName: req.name,
      presetTags: presetTags,
      currentTags: currentTags,
      actions: actions,
    );
    if (result == null) return; // 取消/关闭，不保存

    try {
      // 保存标签（用规范化 appId，与聚合库 key 一致）
      await _aggregator.setTags(
        channel: req.channel,
        appId: canonicalId,
        tags: result,
      );
      AppDialogs.showSuccess('分类标签已更新', title: '保存成功');
    } catch (e) {
      appLog.error('DetailLogic: 保存标签失败 - $e');
      AppDialogs.showError('保存标签失败: $e', title: '保存失败');
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
      des: detail.description,
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

/// 渐进组装中的详情信息：包装 [AppDetailInfo]，暴露 [IDetailInfo] 接口。
///
/// AppDetailInfo 本身不实现 IDetailInfo（渠道详情走各自的 ChannelDetailProxy），
/// 这里在 logic 内做最小适配，保证 state.detailInfo / DownloadStrategyManager.createContext
/// 等以 IDetailInfo 消费的路径兼容；字段与旧 getAppDetail 结果对齐
/// （downloads/readme/statistics/version/developer/projectUrl/extra 各键）。
class _ProgressiveDetailInfo implements IDetailInfo {
  _ProgressiveDetailInfo(this.inner);

  /// 内部承载对象（三路数据到达时通过 copyWith 增补）
  final AppDetailInfo inner;

  @override
  String get packageName => inner.packageName ?? '';

  @override
  String get appName => inner.name;

  @override
  String get name => inner.name;

  @override
  String get icon => inner.icon;

  @override
  String get description => inner.description;

  @override
  String get appId => inner.appId;

  @override
  String get channelId => inner.channel.code;

  @override
  ChannelType get channelType => inner.channel;

  @override
  String? get version => inner.version;

  @override
  String? get developer => inner.developer;

  @override
  String? get projectUrl => inner.projectUrl;

  @override
  List<DownloadInfo> get downloads => inner.downloads;

  @override
  List<DetailSection> get sections => inner.sections;

  @override
  Map<String, dynamic> get extra => inner.extra;

  @override
  String? get readme => inner.readme;

  @override
  List<ScreenshotInfo>? get screenshots => inner.screenshots;

  @override
  String? get changelog => inner.changelog;

  @override
  List<String>? get permissions => inner.permissions;

  @override
  StatisticsInfo? get statistics {
    final s = inner.statistics;
    if (s != null) return s;
    // 与渠道代理一致：从 extra.apiData 解析 GitHub 统计
    final apiData = inner.extra['apiData'];
    if (apiData is Map) {
      final stars = apiData['stargazers_count'];
      final watchers = apiData['watchers_count'];
      final forks = apiData['forks_count'];
      if (stars is int || watchers is int || forks is int) {
        return StatisticsInfo(
          stars: stars is int ? stars : null,
          watchers: watchers is int ? watchers : null,
          forks: forks is int ? forks : null,
        );
      }
    }
    return null;
  }

  @override
  List<StatTag> buildStatTags() {
    // 与 GitHub/LocalDb 渠道代理一致：从 extra.apiData 构建统计标签
    final tags = <StatTag>[];
    final apiData = inner.extra['apiData'];
    if (apiData is Map) {
      final stars = apiData['stargazers_count'];
      final watchers = apiData['watchers_count'];
      final forks = apiData['forks_count'];
      if (stars is int && stars > 0) tags.add(StatTag.stars(stars));
      if (watchers is int && watchers > 0) tags.add(StatTag.watchers(watchers));
      if (forks is int && forks > 0) tags.add(StatTag.forks(forks));
    }
    return tags;
  }

  @override
  bool get isValid => inner.isValid;
}

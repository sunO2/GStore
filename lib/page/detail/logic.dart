import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/js_detail_channel.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/channel_build_history_sheet.dart';
import 'package:gstore/core/design/channel_version_picker_sheet.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/model/StatTag.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
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

  /// 渠道管理器（channel 模块下线时为 null，消费点软降级）
  ChannelManager? _channelManager;

  /// 页面级 detail 通道（zip 渠道包 detail.js 独立 runtime，Wave 3）。
  /// 创建于页面初始化（req 就绪后）；无 detail.js → null → 详情消费走 entry 原路径。
  /// 页面退出在 [onClose] 经 JsChannel.releaseDetailChannel 释放（工厂缓存一致性）。
  JsDetailChannel? _detailChannel;

  /// 聚合管理器（标签读写，与发现页同一套 added_app_tags；aggregate 模块下线时为 null）
  late IAggregateService? _aggregator;

  @override
  void onReady() {
    _channelManager = ModuleManager.instance.get<ChannelManager>();
    _aggregator = ModuleManager.instance.get<IAggregateService>();
    _initializeFromArguments();
    _initDetailChannel();
    super.onReady();
  }

  /// Wave 3：获取页面级 detail 通道（zip 包 detail.js，独立 runtime 消费详情方法）。
  ///
  /// 仅在 req 就绪且渠道为 JsChannel 时调 [JsChannel.getDetailChannel]；
  /// 渠道包无 detail.js → 工厂返回 null（详情走 entry 原路径，兼容）。
  /// 幂等：工厂 appId 级缓存，重复调用返回同一实例。
  void _initDetailChannel() {
    final req = request;
    if (_detailChannel != null || req == null) return;
    final ch = _channelManager?.getChannel(req.channel);
    if (ch is JsChannel) {
      _detailChannel = ch.getDetailChannel(req.appId);
    }
  }

  /// 当前详情页脚本消费源：detailChannel（zip 包 detail.js）优先，entry 回退。
  ///
  /// 非脚本渠道（GitHub/LocalDb 等）→ null（详情页脚本消费路径不适用）。
  _DetailScriptSource? get _detailScriptSource {
    final detailChannel = _detailChannel;
    if (detailChannel != null) return _DetailJsScriptSource(detailChannel);
    final req = request;
    if (req == null) return null;
    final ch = _channelManager?.getChannel(req.channel);
    if (ch is JsChannel) return _EntryScriptSource(ch);
    return null;
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
      _channelManager = ModuleManager.instance.get<ChannelManager>();
      _initDetailChannel(); // 兼容单测直调 loadDetail（onReady 未走时补初始化）
      final channelInstance = _channelManager?.getChannel(request!.channel);
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
    // Wave 3：zip 渠道包 detail.js 存在 → detailChannel 消费（页面级独立 runtime）；
    // 无 detail.js（getDetailChannel null）→ 原 channel.getAppDetail 路径（兼容）。
    // detail.js 脚本失败（返回 null）→ 回退 entry 原路径（安全兜底）。
    ChannelResult<IDetailInfo> result;
    final detailChannel = _detailChannel;
    if (detailChannel != null) {
      final raw = await detailChannel.getAppDetail(request!.appId);
      if (raw == null) {
        appLog.warning(
            'DetailLogic: detail.js getAppDetail 失败，回退 entry 原路径 - ${request!.appId}');
        result = await channel.getAppDetail(
          request!.appId,
          forceRefresh: false,
        );
      } else {
        result = ChannelResult.success(
          data: JsChannelDetailProxy(raw),
          from: ChannelType.custom,
          fromCache: false,
        );
      }
    } else {
      result = await channel.getAppDetail(
        request!.appId,
        forceRefresh: false,
      );
    }
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
          // metadata 全量并入 extra（versionCode 等供更新检测消费）
          final meta = apiData['metadata'];
          if (meta is Map) {
            extra['metadata'] = Map<String, dynamic>.from(meta);
          }
          final metaVersion = apiData['versionName']?.toString();
          final sections = [...inner.sections];
          // 与原 _buildSections 语义一致：有 stars/forks 才声明统计区块
          if ((apiData['stargazers_count'] != null ||
                  apiData['forks_count'] != null) &&
              !sections.contains(DetailSection.statistics)) {
            sections.add(DetailSection.statistics);
          }
          return inner.copyWith(
            extra: extra,
            // metadata versionName 优先（APK 提取，更准确）；否则 releases 首项
            // （_loadDownloads 兜底 inner.version ?? downloads.first.version）
            version: metaVersion?.isNotEmpty == true ? metaVersion : inner.version,
            sections: sections,
          );
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

    // 下载前守卫：URL 为空（脚本未生成下载地址，如未配置渠道凭证/认证失败）→
    // 提示配置凭证，不创建下载记录、不发起空 URL 下载
    // （避免"下载异常：null" + 下载管理出现空链接记录）
    final downloadUrl = download.url.trim();
    if (downloadUrl.isEmpty) {
      appLog.warning('DetailLogic: 下载地址为空，取消下载 - ${download.name}');
      AppDialogs.showWarning(
        download.note?.isNotEmpty == true
            ? download.note!
            : '下载地址不可用\n请先在渠道环境变量配置 PINGAN_USER/PINGAN_PASS 后重试',
      );
      return;
    }

    downloadListenerSubscription?.cancel();

    final appId = req?.appId ?? detail!.appId;
    final appName = req?.name ?? detail!.name;
    final version = download.version ?? 'unknown';
    final fileName = download.name;

    // 下载前日志：记录实际发起下载的 URL（排查下载链路每层值）
    appLog.info('DetailLogic: startDownload - name=$fileName url=$downloadUrl');

    // 预先创建/获取下载状态，用于立即建立进度监听
    final status = await DownloadStatus.create(
      appId,
      appName,
      version,
      fileName,
      downloadUrl,
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
    // 下载模块下线 → 注册表取不到服务，降级提示不抛
    final service = ModuleManager.instance.get<IDownloadService>();
    if (service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }

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
        await service.downloadWithContext(
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
        await service.download(
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
    // 渠道 getAppInfo 返回的 AppSummary 交给 canonicalAppId 规范化）。
    // 脚本渠道（JsChannel）跳过：canonicalAppId 默认原样返回 appInfo.appId，
    // 且 getAppInfo 会触发脚本网络请求（build-list）——点"更多"应零请求，
    // 直接用 req.appId 作 canonicalId 即可。
    final channelInstance = _channelManager?.getChannel(req.channel);
    String canonicalId = req.appId;
    if (channelInstance != null && channelInstance is! JsChannel) {
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
    // aggregate 模块下线 → 注册表取不到服务，降级提示不抛
    final aggregator = _aggregator;
    if (aggregator == null) {
      AppDialogs.showWarning('聚合模块未启用');
      return;
    }
    final currentTags = await aggregator.getTags(
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

    // 构建动作宫格（通用项 + 渠道专属项）
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

    // 脚本渠道（Hybrid Wave B/Wave 3）：详情页操作由脚本 detailMenu 声明，
    // Flutter 只渲染 + 桥接；点击动作 → 调脚本 jscall，JS 内部经 host.ui 驱动交互。
    // Wave 3：有 zip 包 detail.js → detailChannel（页面级 runtime）优先消费，
    // 无 → entry JsChannel 回退（兼容）。
    if (channelInstance is JsChannel) {
      final source = _detailScriptSource;
      if (source == null) return; // 理论不可达（channelInstance 已确认 JsChannel）
      // host.ui 注入：脚本 host.ui.showVersionPicker / showBuildHistory / refreshDetail
      // 的 Flutter 实现（ChannelLoader 创建渠道时无 context，详情页使用时注入）。
      // detailChannel 创建于页面初始化（早于此处注入），需向其 runtime 补注入；
      // entry 同步注入（保持 Wave B 行为，detail.js 缺失回退路径同样可用）。
      Future<Map<String, dynamic>?> showVersionPicker(
              Map<String, dynamic> options) =>
          _showVersionPickerFromScript(context, source, options);
      Future<Map<String, dynamic>?> showBuildHistory(
              Map<String, dynamic> options) =>
          _showBuildHistoryFromScript(context, options);
      Future<void> refreshDetail(Map<String, dynamic> params) =>
          _refreshDetailFromScript(source, params);
      channelInstance.setUiCallbacks(
        uiShowVersionPicker: showVersionPicker,
        uiShowBuildHistory: showBuildHistory,
        uiRefreshDetail: refreshDetail,
      );
      _detailChannel?.setUiCallbacks(
        uiShowVersionPicker: showVersionPicker,
        uiShowBuildHistory: showBuildHistory,
        uiRefreshDetail: refreshDetail,
      );

      final menu = await source.detailMenu(req.appId);
      if (menu == null || menu.isEmpty) {
        // 脚本未声明 detailMenu → 维持现状：写死"切换版本"
        actions.add(
          MoreActionItem(
            icon: Icons.swap_vert,
            label: '切换版本',
            onTap: () => _openVersionSwitcher(context, source),
          ),
        );
      } else {
        // 脚本声明了 detailMenu → 用脚本 Actions 构建宫格（替换写死"切换版本"）
        for (final action in menu) {
          final label = action['action']?.toString() ?? '';
          if (label.isEmpty) continue;
          actions.add(
            MoreActionItem(
              icon: Icons.extension, // icon 字段暂不解析，用默认图标
              label: label,
              onTap: () => _handleJsAction(source, action, context),
            ),
          );
        }
      }
    }

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
      await aggregator.setTags(
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

  /// 打开"切换版本"选择器（仅脚本渠道；detailMenu 未实现时的写死入口）。
  ///
  /// 流程：脚本 versionOptions（按当前详情 env 单 env 拉取）→
  /// [_showVersionPicker] 选 env+version（env 切换按需刷新版本列表）→
  /// 确认后 [_refreshDetailAfterSwitch] 脚本 switchVersion 返回该 env+version
  /// 的详情 Map（同 getAppDetail 结构）→ 用 JsChannelDetailProxy 整体刷新
  /// state.detailInfo（截图/下载/更新日志按新 env+version）。
  /// Wave 3：消费源为 [_DetailScriptSource]（detailChannel 优先，entry 回退）。
  Future<void> _openVersionSwitcher(
    BuildContext context,
    _DetailScriptSource source,
  ) async {
    final req = request;
    if (req == null) return;

    final opts = await source.versionOptions(req.appId, env: _currentDetailEnv());
    if (opts == null) {
      AppDialogs.showError('无法获取版本选项（脚本未实现或失败）');
      return;
    }
    if (!context.mounted) return;

    final sel = await _showVersionPicker(context, source, opts);
    if (sel == null) return; // 取消/关闭，不刷新

    await _refreshDetailAfterSwitch(source, sel.env, sel.version);
  }

  /// 弹版本选择器（[ChannelVersionPickerSheet.show]）。
  ///
  /// 数据来自 [opts]（versionOptions 或脚本 host.ui.showVersionPicker 的
  /// options 同构：envs / versions / currentEnv / currentVersion）；
  /// env 切换按需调脚本 versionOptions 刷新该 env 的版本列表；
  /// 历史构建经脚本 buildHistory 拉取，选中 → [_downloadHistoricalBuild]。
  /// 返回用户确认的 [VersionSelection] 或 null（取消/关闭）。
  Future<VersionSelection?> _showVersionPicker(
    BuildContext context,
    _DetailScriptSource source,
    Map<String, dynamic> opts, {
    String? title,
  }) async {
    final req = request;
    if (req == null) return null;

    final envs = (opts['envs'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];
    final versions = _parseVersionOptions(opts);

    return ChannelVersionPickerSheet.show(
      context: context,
      title: title ?? '切换版本',
      envs: envs,
      versions: versions,
      currentEnv: opts['currentEnv']?.toString(),
      currentVersion: opts['currentVersion']?.toString(),
      onEnvChanged: (env) async =>
          _parseVersionOptions(await source.versionOptions(req.appId, env: env)),
      onBuildHistory: ({required version, required env}) async {
        final bh = await source.buildHistory(
          appId: req.appId,
          version: version,
          env: env,
        );
        final builds = (bh?['builds'] as List?)
                ?.map((b) {
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
                })
                .toList() ??
            const <BuildOption>[];
        return builds;
      },
      // 携带该行所属 version/env（组件按当前选中 env + 行 version 传参），
      // 多行同时展开时各自下载定位互不干扰（不复用"最近展开"捕获）。
      onBuildSelect: (build, {required version, required env}) {
        unawaited(_downloadHistoricalBuild(
          source,
          build,
          version: version,
          env: env,
        ));
      },
    );
  }

  /// host.ui.showVersionPicker 的 Flutter 实现（脚本详情页动作内部调用）。
  ///
  /// [options] 由脚本传入（title/envs/versions/currentEnv/currentVersion），
  /// 直接用其数据弹 [ChannelVersionPickerSheet]；返回用户选择
  /// `{env, version}` 或 null（取消）。
  Future<Map<String, dynamic>?> _showVersionPickerFromScript(
    BuildContext context,
    _DetailScriptSource source,
    Map<String, dynamic> options,
  ) async {
    if (!context.mounted) return null;
    final sel = await _showVersionPicker(
      context,
      source,
      options,
      title: options['title']?.toString(),
    );
    if (sel == null) return null; // 取消/关闭
    return {'env': sel.env, 'version': sel.version};
  }

  /// host.ui.showBuildHistory 的 Flutter 实现：弹 [ChannelBuildHistorySheet] 单选构建。
  ///
  /// options: `{version, env, builds:[{num, publishedAt, size, changelog, installTimes, builtBy, ipaName}]}`
  /// 返回选中 build Map（num/ipaName 等，脚本据此刷新详情）或 null（取消/关闭）。
  Future<Map<String, dynamic>?> _showBuildHistoryFromScript(
    BuildContext context,
    Map<String, dynamic> options,
  ) async {
    if (!context.mounted) return null;

    final version = options['version']?.toString() ?? '';
    final env = options['env']?.toString() ?? '';
    final builds = (options['builds'] as List?)
            ?.map((b) {
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
            })
            .toList() ??
        const <BuildOption>[];

    final sel = await ChannelBuildHistorySheet.show(
      context: context,
      version: version,
      env: env,
      builds: builds,
    );
    if (sel == null) return null; // 取消/关闭
    return {
      'num': sel.num,
      'ipaName': sel.ipaName,
      'publishedAt': sel.publishedAt?.toIso8601String(),
      'size': sel.size,
      'changelog': sel.changelog,
    };
  }

  /// host.ui.refreshDetail 的 Flutter 实现（脚本详情页动作内部调用）。
  ///
  /// [params]：`{appId, env, version}` → 调脚本 switchVersion 拿该 env+version
  /// 详情 → 整体刷新 state.detailInfo（与选择器确认共用刷新逻辑）。
  Future<void> _refreshDetailFromScript(
    _DetailScriptSource source,
    Map<String, dynamic> params,
  ) async {
    final env = params['env']?.toString() ?? '';
    final version = params['version']?.toString() ?? '';
    if (env.isEmpty || version.isEmpty) return;
    // build 可选：历史构建选中项 {num, ipaName} → 刷新详情时切换到该构建
    final build = params['build'];
    await _refreshDetailAfterSwitch(
      source,
      env,
      version,
      build: build is Map ? Map<String, dynamic>.from(build) : null,
    );
  }

  /// 执行脚本声明的详情页动作（Hybrid Wave B：点击 → 调脚本 jscall）。
  ///
  /// 面板关闭时序：showMoreActionsSheet 的动作宫格由面板内部 [_MoreActionsSheet]
  /// 先 `Navigator.pop` 关闭面板、再执行 onTap —— onTap 执行时面板已在关闭中，
  /// 故这里不再重复 pop（重复 pop 会误关详情页本身）；[clickIsDimiss] 为 true
  /// 的动作走同一时序（面板先关、jscall 后调）。
  ///
  /// jscall 返回不做处理（JS 全权，交互由 host.ui 回调驱动，[setUiCallbacks]
  /// 注入的版本选择器/刷新详情实现已就绪）。
  Future<void> _handleJsAction(
    _DetailScriptSource source,
    Map<String, dynamic> action,
    BuildContext context,
  ) async {
    final req = request;
    if (req == null) return;

    final method = action['jscall']?.toString();
    if (method == null || method.isEmpty) return;

    await source.invokeScriptMethod(method, {'appId': req.appId});
  }

  /// switchVersion → state.detailInfo 整体刷新（选择器确认与 host.ui.refreshDetail 共用）。
  Future<void> _refreshDetailAfterSwitch(
    _DetailScriptSource source,
    String env,
    String version, {
    Map<String, dynamic>? build,
  }) async {
    final req = request;
    if (req == null) return;

    final detail = await source.switchVersion(
      appId: req.appId,
      env: env,
      version: version,
      build: build,
    );
    if (detail == null) {
      AppDialogs.showError('切换版本失败');
      return;
    }
    state.detailInfo.value = JsChannelDetailProxy(detail);
    final msg = build == null
        ? '已切换到 $version（$env）'
        : '已切换到 $version 构建 #${build['num']}（$env）';
    AppDialogs.showSuccess(msg);
  }

  /// 当前详情所属 env（脚本详情 extra.env；无 → null → 脚本按凭证默认 env）
  String? _currentDetailEnv() {
    final detail = state.detailInfo.value;
    if (detail == null) return null;
    final extra = detail.extra['extra'];
    if (extra is Map) return extra['env']?.toString();
    return null;
  }

  /// 解析脚本 versionOptions 返回的 versions 列表 → [VersionOption]
  List<VersionOption> _parseVersionOptions(Map<String, dynamic>? opts) {
    return (opts?['versions'] as List?)
            ?.map((v) {
              final m = v as Map;
              return VersionOption(
                version: m['version']?.toString() ?? '',
                envs: (m['envs'] as List?)
                        ?.map((e) => e.toString())
                        .toList() ??
                    const <String>[],
                buildCount: (m['buildCount'] as num?)?.toInt() ?? 0,
              );
            })
            .toList() ??
        const <VersionOption>[];
  }

  /// 历史构建下载：调脚本 switchVersion 拿该 env+version 详情 downloads，
  /// 匹配该 build 的下载项（ipaName == download.name）→ startDownload；
  /// 无匹配/脚本失败 → 提示"该构建暂不可下载"（历史构建下载走现有下载器）。
  Future<void> _downloadHistoricalBuild(
    _DetailScriptSource source,
    BuildOption build, {
    required String version,
    required String env,
  }) async {
    final req = request;
    if (req == null) return;

    final detail = await source.switchVersion(
      appId: req.appId,
      env: env,
      version: version,
    );
    if (detail == null) {
      AppDialogs.showError('该构建暂不可下载');
      return;
    }

    final proxy = JsChannelDetailProxy(detail);
    final ipaName = build.ipaName;
    DownloadInfo? match;
    if (ipaName != null && ipaName.isNotEmpty) {
      for (final d in proxy.downloads) {
        if (d.name == ipaName) {
          match = d;
          break;
        }
      }
    }
    if (match == null) {
      AppDialogs.showError('该构建暂不可下载');
      return;
    }
    await startDownload(match);
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
    // Wave 3：释放页面级 detail runtime（工厂缓存一致性——经
    // JsChannel.releaseDetailChannel 移除 appId 缓存并 dispose，页面退出即释放；
    // 未创建过该 appId 的 detail 通道 → 幂等无操作）。
    final req = request;
    if (req != null) {
      final ch = _channelManager?.getChannel(req.channel);
      if (ch is JsChannel) {
        ch.releaseDetailChannel(req.appId);
      }
    }
    _detailChannel = null;
    counterController.close();
    downloadListenerSubscription?.cancel();
    super.onClose();
  }
}

/// 详情页脚本消费源（Wave 3）：zip 渠道包 detail.js 的 detailChannel（页面级
/// 独立 runtime）优先，无 detail.js → entry JsChannel 回退（兼容）。
///
/// 统一 versionOptions / switchVersion / buildHistory / detailMenu / jscall 的
/// 消费入口——详情页逻辑只面向该抽象，不关心脚本来自 entry 还是 detail.js。
abstract class _DetailScriptSource {
  Future<Map<String, dynamic>?> versionOptions(String appId, {String? env});

  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  });

  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  });

  Future<List<Map<String, dynamic>>?> detailMenu(String appId);

  Future<dynamic> invokeScriptMethod(
    String method, [
    Map<String, dynamic>? params,
  ]);
}

/// entry JsChannel 适配（无 detail.js 时回退；Wave B 原路径）
class _EntryScriptSource implements _DetailScriptSource {
  _EntryScriptSource(this._js);

  final JsChannel _js;

  @override
  Future<Map<String, dynamic>?> versionOptions(String appId, {String? env}) =>
      _js.versionOptions(appId, env: env);

  @override
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) =>
      _js.switchVersion(appId: appId, env: env, version: version, build: build);

  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) =>
      _js.buildHistory(appId: appId, version: version, env: env);

  @override
  Future<List<Map<String, dynamic>>?> detailMenu(String appId) =>
      _js.detailMenu(appId);

  @override
  Future<dynamic> invokeScriptMethod(
    String method, [
    Map<String, dynamic>? params,
  ]) =>
      _js.invokeScriptMethod(method, params);
}

/// detail.js detailChannel 适配（zip 渠道包页面级 runtime，优先消费）
class _DetailJsScriptSource implements _DetailScriptSource {
  _DetailJsScriptSource(this._ch);

  final JsDetailChannel _ch;

  @override
  Future<Map<String, dynamic>?> versionOptions(String appId, {String? env}) =>
      _ch.versionOptions(appId, env: env);

  @override
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) =>
      _ch.switchVersion(appId: appId, env: env, version: version, build: build);

  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) =>
      _ch.buildHistory(appId: appId, version: version, env: env);

  @override
  Future<List<Map<String, dynamic>>?> detailMenu(String appId) =>
      _ch.detailMenu(appId);

  @override
  Future<dynamic> invokeScriptMethod(
    String method, [
    Map<String, dynamic>? params,
  ]) =>
      _ch.callMain(method, params);
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

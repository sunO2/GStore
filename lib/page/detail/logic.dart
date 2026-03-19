import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/service/downloadService.dart';
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
            debugPrint('DetailLogic: ✓ 应用已安装 - ${state.installInfo.value?.packageName}');
            debugPrint('DetailLogic:   安装版本 = ${state.installInfo.value?.versionName}');
            debugPrint('DetailLogic:   UI 将更新（installInfo 是响应式变量）');
          } else {
            debugPrint('DetailLogic: ✗ 应用未安装 - "$packageToCheck"');

            // 尝试列出所有已安装应用，看看是否有类似包名
            try {
              final allApps = await InstalledApps.getInstalledApps();
              debugPrint('DetailLogic: 已安装应用总数 = ${allApps.length}');

              final packageToCheckLower = packageToCheck.toLowerCase();
              final searchPart = packageToCheckLower.split('.').last;

              final similarApps = allApps.where((app) {
                final appName = app.packageName.toLowerCase();
                return appName.contains(searchPart) || packageToCheckLower.contains(appName.split('.').last);
              }).toList();

              if (similarApps.isNotEmpty) {
                debugPrint('DetailLogic: 找到类似包名的应用:');
                for (var app in similarApps.take(5)) {
                  debugPrint('DetailLogic:   - ${app.packageName} (${app.name})');
                }
              }
            } catch (e) {
              debugPrint('DetailLogic: 获取已安装应用列表失败: $e');
            }
          }
        } catch (e) {
          debugPrint('DetailLogic: 检测安装状态时出错: $e');
        }
      } else {
        debugPrint('DetailLogic: 无法检测安装状态 - 没有可用的包名');
      }
    } catch (e) {
      state.errorMessage.value = '加载详情失败: $e';
    } finally {
      state.isLoadingDetail.value = false;
    }
  }

  /// 开始下载
  /// 优先使用新的策略模式下载，失败时降级到旧方法
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

    DownloadStatus? status;

    // 尝试使用新的策略模式下载
    try {
      // 确保策略管理器已初始化
      _initializeDownloadStrategies();

      // 创建下载上下文
      final context = await DownloadStrategyManager.instance.createContext(
        download,
        detail!,
      );

      if (context != null) {
        debugPrint('DetailLogic: 使用策略模式下载 - ${context.downloadUrl}');
        status = await Get.find<DownloadService>().downloadWithContext(
          context,
          appId,
          appName,
          download.version ?? 'unknown',
          download.name,
        );
      } else {
        debugPrint('DetailLogic: 下载上下文创建失败，降级到旧方法');
        throw Exception('Failed to create download context');
      }
    } catch (e) {
      debugPrint('DetailLogic: 策略模式下载失败，降级到旧方法 - $e');
      // 降级到旧的下载方法
      status = await Get.find<DownloadService>().download(
        appId,
        appName,
        download.version ?? 'unknown',
        download.url,
        download.name,
        downloadSize: download.size ?? downloadSize,
      );
    }

    if (status != null) {
      counterController.sink.add(status);
      downloadListenerSubscription = status.observer.listen((da) {
        counterController.sink.add(da);
      });
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
      debugPrint('DetailLogic: 已注册 ${manager.strategyCount} 个下载策略');
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

  /// 将 IDetailInfo 转换为 AppInfo
  AppInfo _detailToAppInfo(IDetailInfo detail) {
    // 返回一个 AppInfo 对象（类型安全）
    return AppInfo(
      detail.appId,
      detail.name,
      detail.developer ?? '',
      detail.packageName ?? '',
      detail.icon,
      detail.description ?? '',
      null,
    );
  }

  /// 将 AppDetailRequest 转换为 AppInfo
  AppInfo _requestToAppInfo(AppDetailRequest req) {
    return AppInfo(
      req.appId,
      req.name,
      '', // user 字段为空
      req.packageName ?? '',
      req.icon ?? '', // icon 可能为空，使用空字符串作为默认值
      req.description ?? '',
      null,
    );
  }

  @override
  void onClose() {
    counterController.close();
    downloadListenerSubscription?.cancel();
    super.onClose();
  }
}

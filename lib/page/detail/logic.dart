import 'package:gstore/core/core.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/IDetailData.dart';
import 'package:gstore/core/service/downloadService.dart';
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

    // 转换为 AppDetailRequest
    if (args is AppDetailRequest) {
      request = args as AppDetailRequest;
    } else if (args is Map) {
      // 尝试从 Map 转换
      request = AppDetailRequest.fromAppInfo(
        args as Map<String, dynamic>,
        args['channel'] ?? ChannelType.localDb,
      );
    } else {
      // 尝试从 AggregatedAppInfo 转换
      request = AppDetailRequest.fromAggregatedAppInfo(args);
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
      // 检查应用是否已安装
      if (await InstalledApps.isAppInstalled(request!.appId) ?? false) {
        state.installInfo = await InstalledApps.getAppInfo(request!.appId);
      }

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
    } catch (e) {
      state.errorMessage.value = '加载详情失败: $e';
    } finally {
      state.isLoadingDetail.value = false;
    }
  }

  /// 开始下载
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

    final status = await Get.find<DownloadService>().download(
      appId,
      appName,
      download.version ?? 'unknown',
      download.url,
      download.name,
      downloadSize: download.size ?? downloadSize,
    );

    counterController.sink.add(status);
    downloadListenerSubscription = status.observer.listen((da) {
      counterController.sink.add(da);
    });
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
        // 尝试从 extra 获取 user/repositories
        final apiData = detailFromLogic.extra['apiData'] as Map?;
        if (apiData != null && apiData['full_name'] != null) {
          openBrowser('https://github.com/${apiData['full_name']}');
          return;
        }
      }
      openBrowser('https://github.com/${request!.packageName ?? request!.appId}');
    }
  }

  /// 将 IDetailData 转换为 AppInfo
  dynamic _detailToAppInfo(IDetailData detail) {
    // 返回一个类似 AppInfo 的对象
    return {
      'appId': detail.appId,
      'name': detail.name,
      'icon': detail.icon,
      'des': detail.description,
      'user': detail.developer,
      'repositories': detail.packageName,
    };
  }

  /// 将 AppDetailRequest 转换为 AppInfo
  dynamic _requestToAppInfo(AppDetailRequest req) {
    return {
      'appId': req.appId,
      'name': req.name,
      'icon': req.icon,
      'des': req.description,
      'user': null,
      'repositories': req.packageName,
    };
  }

  @override
  void onClose() {
    counterController.close();
    downloadListenerSubscription?.cancel();
    super.onClose();
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/standard_detail_channel.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/download/strategy/impl/LocalDbDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/VivoDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/GitHubDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/HttpDownloadStrategy.dart';
import 'package:gstore/core/download/strategy/impl/FdroidDownloadStrategy.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:installed_apps/app_info.dart' as installed;
import 'state.dart';
import 'detail_ui_mixins.dart';
import 'widgets/more_actions_sheet.dart' as mas;

class DetailLogic extends GetxController
    with
        DetailBrowserMixin,
        DetailMetadataMixin,
        DetailVersionPickerMixin
    implements DetailCallbacks {
  final StreamController<DownloadTask> counterController =
      StreamController<DownloadTask>.broadcast();
  StreamSubscription? downloadListenerSubscription;

  /// 更多按钮忙碌态兜底超时（防脚本异常挂死状态）
  static const Duration _actionBusyTimeout = Duration(seconds: 15);

  /// 忙碌态兜底 Timer（重复开启重置，false/超时/dispose 时取消）
  Timer? _actionBusyTimer;

  final DetailState state = DetailState();

  /// 请求参数
  AppDetailRequest? request;

  /// 渠道管理器（channel 模块下线时为 null，消费点软降级）
  ChannelManager? _channelManager;

  /// 页面级 detail 通道（JsDetailChannel 或 StandardDetailChannel）。
  IDetailChannel? detailChannel;

  /// 聚合管理器（标签读写）
  late IAggregateService? _aggregator;

  static const List<String> _fallbackPresetTags = [
    '工具', '游戏', '社交', '影音', '阅读', '效率', '系统',
  ];

  @override
  void onReady() {
    _channelManager = ModuleManager.instance.get<ChannelManager>();
    _aggregator = ModuleManager.instance.get<IAggregateService>();
    _initializeFromArguments();
    _initAndLoad();
    super.onReady();
  }

  /// 获取 channel → bind → load
  Future<void> _initAndLoad() async {
    final req = request;
    if (req == null) return;
    final code = req.channelCode ?? req.channel.code;
    final ch = _channelManager?.getChannelByCode(code);
    if (ch == null) return;
    var dc = ch.getDetailChannel(req.appId);
    dc ??= StandardDetailChannel(
      appId: req.appId,
      channel: ch,
      request: req,
      channelCode: code,
    );
    dc.bind(state, this);
    detailChannel = dc;
    await dc.load();
  }

  /// 加载详情（错误页重试 / 单测直调入口）。
  Future<void> loadDetail() async {
    state.errorMessage.value = '';
    if (request == null) {
      state.errorMessage.value = '缺少请求参数';
      return;
    }
    _channelManager = ModuleManager.instance.get<ChannelManager>();
    await _initAndLoad();
  }

  /// 从参数初始化基础信息
  void _initializeFromArguments() {
    final args = Get.arguments;
    if (args == null) {
      state.errorMessage.value = '缺少参数';
      state.isLoading.value = false;
      return;
    }
    if (args is AppDetailRequest) {
      request = args;
    } else if (args is Map<String, dynamic>) {
      final channel = args['channel'];
      final channelType = channel is ChannelType
          ? channel
          : (channel is String
              ? ChannelType.fromCode(channel)
              : ChannelType.localDb);
      request = AppDetailRequest.fromAppInfo(
          args, channelType ?? ChannelType.localDb);
    } else {
      try {
        request = AppDetailRequest.fromAggregatedAppInfo(args);
      } catch (e) {
        state.errorMessage.value = '无效的参数类型: ${args.runtimeType}';
        state.isLoading.value = false;
        return;
      }
    }
    state.request = request;
    state.isLoading.value = false;
  }

  /// 开始下载
  /// [fromScript] true = 从脚本 download handler 回调（跳过 JS 渠道委托，防递归）
  @override
  Future<void> startDownload(
    DownloadInfo download, {
    int? downloadSize,
    bool fromScript = false,
  }) async {
    final channel = detailChannel;
    // 仅 UI 入口触发时委托脚本——脚本 download handler 回调直接走标准流程，防递归。
    if (!fromScript && channel != null && channel.drivesOwnDownloads) {
      await channel.startDownload(download);
      return;
    }
    final detail = state.detailInfo.value;
    final req = request;
    if (detail == null && req == null) return;
    final downloadUrl = download.url.trim();
    if (downloadUrl.isEmpty) {
      AppDialogs.showWarning(
        download.note?.isNotEmpty == true
            ? download.note!
            : '下载地址不可用\n请先在渠道环境变量配置所需凭证后重试',
      );
      return;
    }
    downloadListenerSubscription?.cancel();
    final appId = req?.appId ?? detail!.appId;
    final appName = req?.name ?? detail!.name;
    final version = download.version ?? 'unknown';
    final fileName = download.name;
    appLog.info('DetailLogic: startDownload - name=$fileName url=$downloadUrl');
    final service = ModuleManager.instance.get<IDownloadService>();
    if (service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    unawaited(() async {
      final task = await service.download(
        appId, appName, version, downloadUrl, fileName,
        downloadSize: download.size ?? downloadSize,
      );
      state.currentDownload.value = task;
      counterController.sink.add(task);
      final id = task.id;
      if (id != null) {
        downloadListenerSubscription?.cancel();
        downloadListenerSubscription = service.watch(id).listen((da) {
          state.currentDownload.value = da;
          state.currentDownload.refresh();
          counterController.sink.add(da);
        });
      }
    }());
  }

  Future<void> _startDownloadTask(
    DownloadInfo download,
    String appId,
    String appName,
    String version,
    String fileName,
  ) async {
    final service = ModuleManager.instance.get<IDownloadService>();
    if (service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    try {
      _initializeDownloadStrategies();
      final detail = state.detailInfo.value;
      if (detail == null) return;
      final request =
          await DownloadStrategyManager.instance.createRequest(download, detail);
      if (request != null) {
        await service.downloadWithContext(
            request, appId, appName, version, fileName);
      } else {
        throw Exception('Failed to create download request');
      }
    } catch (e) {
      appLog.error('DetailLogic: 下载失败 - $e');
      try {
        await service.download(appId, appName, version, download.url, fileName,
            downloadSize: download.size);
      } catch (e2) {
        appLog.error('DetailLogic: 下载降级失败 - $e2');
      }
    }
  }

  void _initializeDownloadStrategies() {
    final manager = DownloadStrategyManager.instance;
    if (manager.strategyCount == 0) {
      manager.registerAll([
        LocalDbDownloadStrategy(),
        VivoDownloadStrategy(),
        GitHubDownloadStrategy(),
        HttpDownloadStrategy(),
        FdroidDownloadStrategy(),
      ]);
    }
  }

  /// 安装已下载完成的 APK（Shizuku 优先，回退系统安装）
  Future<void> installCurrentTask(DownloadTask task) async {
    final manager = ModuleManager.instance.get<InstallManager>();
    if (manager == null) {
      AppDialogs.showWarning('安装模块未启用');
      return;
    }
    if (GetPlatform.isAndroid && task.fileName.endsWith('.apk')) {
      await manager.installApk(task.filePath);
    }
  }

  /// 重试失败的下载（断点续传）
  Future<void> retryCurrentTask(DownloadTask task) async {
    final id = task.id;
    final service = ModuleManager.instance.get<IDownloadService>();
    if (id == null || service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    service.retry(id);
  }

  /// 继续暂停的下载
  Future<void> resumeCurrentTask(DownloadTask task) async {
    final id = task.id;
    final service = ModuleManager.instance.get<IDownloadService>();
    if (id == null || service == null) {
      AppDialogs.showWarning('下载模块未启用');
      return;
    }
    service.resume(id);
  }

  /// 打开"更多"底部面板：标签编辑 + 渠道动作宫格
  Future<void> showMoreActions(BuildContext context) async {
    final req = request;
    if (req == null) return;
    final code = req.channelCode ?? req.channel.code;
    final channelInstance = _channelManager?.getChannelByCode(code);
    String canonicalId = req.appId;
    // 非 JS 渠道：通过 getAppInfo 解析 canonical appId
    if (channelInstance != null) {
      try {
        final basicInfo =
            await channelInstance.getAppInfo(req.appId, forceRefresh: false);
        final appSummary = basicInfo.success ? basicInfo.data : null;
        if (appSummary != null) {
          canonicalId = await channelInstance.canonicalAppId(appSummary);
        }
      } catch (e) {
        appLog.error('DetailLogic: 解析 canonical appId 失败 - $e');
      }
    }
    final aggregator = _aggregator;
    var currentTags = <String>[];
    var presetTags = <String>[];
    try {
      if (aggregator != null) {
        currentTags = await aggregator.getTags(
          channelCode: req.channelCode ?? req.channel.code,
          appId: canonicalId,
        );
      }
      try {
        final categories =
            await "gstore".repoDB.db.dao.getAllCategory();
        presetTags = categories
            .map((c) => c.description.trim())
            .where((d) => d.isNotEmpty)
            .toList();
      } catch (_) {}
      if (presetTags.isEmpty) presetTags = _fallbackPresetTags;
    } catch (_) {
      presetTags = _fallbackPresetTags;
    }

    // 从 channel 获取动作项
    final channel = detailChannel;
    final channelActions = channel?.getActions() ?? <DetailAction>[];

    final allActions = [
      ...channelActions,
    ];

    if (!context.mounted) return;
    final result = await showMoreActionsSheet(
      appName: req.name,
      presetTags: presetTags,
      currentTags: currentTags,
      actions: allActions,
    );
    if (result == null) return;
    try {
      if (aggregator == null) {
        AppDialogs.showError('聚合模块未启用，标签未保存');
        return;
      }
      await aggregator.setTags(
        channelCode: req.channelCode ?? req.channel.code,
        appId: canonicalId,
        tags: result,
      );
      AppDialogs.showSuccess('分类标签已更新', title: '保存成功');
    } catch (e) {
      AppDialogs.showError('保存标签失败: $e', title: '保存失败');
    }
  }

  // ==================== DetailCallbacks 留在 logic 的薄委托实现 ====================

  @override
  Future<void> refreshDetail(
      {required Map<String, dynamic> detailData}) async {
    state.detailInfo.value = JsChannelDetailProxy(detailData);
    _applyInstalledInfo(detailData);
  }

  @override
  Future<void> updateDetail({required Map<String, dynamic> partial}) async {
    final current = state.detailInfo.value;
    if (current is JsChannelDetailProxy) {
      // 已有 JS 详情：在原数据副本上展开合并。
      // extra 是 _data 的别名 → partial.extra 必须逐键展开写入顶层，
      // 禁止嵌套进 merged['extra']（嵌套键无任何 getter 消费）。
      final merged = Map<String, dynamic>.from(current.data);
      partial.forEach((k, v) {
        if (k == 'extra' && v is Map) {
          v.forEach((ek, ev) => merged[ek.toString()] = ev);
        } else {
          merged[k] = v;
        }
      });
      state.detailInfo.value = JsChannelDetailProxy(merged);
      _applyInstalledInfo(merged);
    } else {
      // 首次推送（null 或非 JS proxy）：以 partial 创建，
      // extra 键同样展开写入顶层——与上一分支语义完全一致。
      final flat = Map<String, dynamic>.from(partial);
      if (flat['extra'] is Map) {
        final extra = flat.remove('extra') as Map;
        extra.forEach((ek, ev) => flat[ek.toString()] = ev);
      }
      state.detailInfo.value = JsChannelDetailProxy(flat);
      _applyInstalledInfo(flat);
    }
  }

  /// 详情数据顶层 `installedVersion`(String)/`installedVersionCode`(num)
  /// → 合成 [installed.AppInfo] 写入 installInfo（点亮 VersionBadge 当前版本）。
  ///
  /// presence-driven：键缺失或 installedVersion 为空串 → 不动 installInfo
  /// （不重置不覆盖，保留既有安装检测结果）。
  void _applyInstalledInfo(Map<String, dynamic> data) {
    final rawVersion = data['installedVersion'];
    if (rawVersion == null) return;
    final versionName = rawVersion.toString().trim();
    if (versionName.isEmpty) return;
    final pkg = data['packageName']?.toString() ?? '';
    final name = data['name']?.toString() ?? '';
    state.installInfo.value = installed.AppInfo(
      name: name.isNotEmpty ? name : pkg,
      icon: null,
      packageName: pkg,
      versionName: versionName,
      versionCode: _asVersionCode(data['installedVersionCode']),
      builtWith: installed.BuiltWith.native_or_others,
      installedTimestamp: 0,
    );
  }

  /// installedVersionCode 宽松归一：int 直取；num 截断；数字字符串解析；
  /// 其余（null / 非数值字符串 / 其它类型）→ 0。负数按原值透传（仅类型归一，
  /// 不做语义钳制——渠道脚本侧已保证来源为插件返回的 versionCode）。
  int _asVersionCode(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) {
      final trimmed = raw.trim();
      return int.tryParse(trimmed) ?? double.tryParse(trimmed)?.toInt() ?? 0;
    }
    return 0;
  }

  @override
  Future<void> updateDownloadList(
      {required List<DownloadInfo> downloads}) async {
    await detailChannel?.updateDownloads(downloads);
  }

  @override
  void syncDownloadToFB(DownloadInfo download) {
    final req = request;
    final appId = req?.appId ?? download.url;
    final appName = req?.name ?? download.name;
    final version = download.version ?? 'unknown';
    final fileName = download.name;
    final downloadUrl = download.url.trim();
    if (downloadUrl.isEmpty) return;

    unawaited(() async {
      final service = ModuleManager.instance.get<IDownloadService>();
      if (service == null) return;

      try {
        final task = await service.download(
          appId, appName, version, downloadUrl, fileName,
          downloadSize: download.size,
        );

        state.currentDownload.value = task;
        counterController.sink.add(task);
        downloadListenerSubscription?.cancel();
        final id = task.id;
        if (id != null) {
          downloadListenerSubscription = service.watch(id).listen((da) {
            state.currentDownload.value = da;
            state.currentDownload.refresh();
            counterController.sink.add(da);
          });
        }
      } catch (e) {
        appLog.error('DetailLogic: syncDownloadToFB 失败 - $e');
      }
    }());
  }

  @override
  Future<void> setActionBusy({required bool visible, String? label}) async {
    if (!visible) {
      debugPrint('DetailLogic: setActionBusy(false)');
      _actionBusyTimer?.cancel();
      _actionBusyTimer = null;
      state.actionBusy.value = false;
      state.actionBusyLabel.value = '';
      return;
    }
    debugPrint('DetailLogic: setActionBusy(true, label=${label ?? ''})');
    if (label != null && label.isNotEmpty) {
      state.actionBusyLabel.value = label;
    }
    state.actionBusy.value = true;
    // 兜底：重复开启重置 Timer，到时自动复位防脚本异常挂死状态
    _actionBusyTimer?.cancel();
    _actionBusyTimer = Timer(_actionBusyTimeout, () {
      debugPrint('DetailLogic: actionBusy 超时自动复位');
      state.actionBusy.value = false;
      state.actionBusyLabel.value = '';
    });
  }

  @override
  void showSuccess(String message, {String? title}) =>
      AppDialogs.showSuccess(message, title: title);

  @override
  void showError(String message, {String? title}) =>
      AppDialogs.showError(message, title: title);

  @override
  Future<bool?> showWarningDialog({
    required String title,
    required String content,
    String? confirmText,
    String? cancelText,
    bool isDangerous = false,
  }) =>
      AppDialogs.showDialog(
        title: title,
        content: content,
        confirmText: confirmText ?? '确定',
        cancelText: cancelText,
        isDangerous: isDangerous,
      );

  @override
  Future<List<String>?> showMoreActionsSheet({
    required String appName,
    required List<String> presetTags,
    required List<String> currentTags,
    required List<DetailAction> actions,
  }) async {
    final ctx = Get.context;
    if (ctx == null) return null;
    return mas.showMoreActionsSheet(
      ctx,
      appName: appName,
      presetTags: presetTags,
      currentTags: currentTags,
      actions: actions
          .map((a) => mas.MoreActionItem(
                icon: a.icon,
                iconImage: a.iconImage,
                label: a.label,
                onTap: () => a.onTap(),
              ))
          .toList(),
    );
  }

  @override
  void onClose() {
    _actionBusyTimer?.cancel();
    _actionBusyTimer = null;
    final req = request;
    if (req != null) {
      final code = req.channelCode ?? req.channel.code;
      _channelManager
          ?.getChannelByCode(code)
          ?.releaseDetailChannel(req.appId);
    }
    detailChannel = null;
    counterController.close();
    downloadListenerSubscription?.cancel();
    super.onClose();
  }
}
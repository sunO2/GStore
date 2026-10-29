import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/model/proxy/JsChannelDetailProxy.dart';
import 'package:gstore/core/channel/impl/facade_detail_channel.dart';
import 'package:gstore/core/channel/impl/standard_detail_channel.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/event/app_event.dart';
import 'package:gstore/core/event/live_refresh.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/download_module_unavailable_exception.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/script/rust_script_detail_channel.dart';
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_ui_handler_registry.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:gstore/page/installed_apps/sdk_analysis_page.dart';
import 'package:installed_apps/app_info.dart' as installed;
import 'state.dart';
import 'detail_ui_mixins.dart';
import 'widgets/more_actions_sheet.dart' as mas;

/// 详情页业务逻辑（Riverpod 版，取代旧 GetX 控制器）。
///
/// 生命周期由详情页 [DetailPage] 驱动：
/// - 构造：持有 [DetailState]（页面经 [detailStateProvider] 注入同一实例；
///   直接构造时自建一份，兼容单测）；
/// - [start]：页面挂载后调用（等价原 GetX onReady，幂等）；
/// - [shutdown]：页面销毁时调用（等价原 GetX onClose）。channel 清理 /
///   Timer / 流订阅均在 [shutdown] 完成。
class DetailLogic
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

  final DetailState state;

  /// 请求参数
  AppDetailRequest? request;

  /// go_router extra 传入的路由参数，view 构造后设置（等价原路由 arguments）。
  Object? _extra;

  /// UI 上下文（view build 注入，幂等；未注入时回退全局 navigator key）。
  BuildContext? _uiContext;

  /// 已完成初始化/已释放标记（[start]/[shutdown] 幂等）
  bool _started = false;
  bool _shutDown = false;

  /// 目录变化（Rust 上行 `catalog.changed`）的防抖订阅：仅在本页受影响的
  /// app（`app_id` 命中）或整渠道变更（`app_id == null`）时重取详情。
  LiveRefreshSubscription? _liveRefresh;

  DetailLogic({DetailState? state}) : state = state ?? DetailState();

  /// 设置路由 extra（DetailPage build 内经 GoRouterState.of(context).extra 传入）。
  void setRouteExtra(Object? extra) => _extra = extra;

  /// 注入 UI 上下文（供 channel 回调驱动的选择器/弹窗使用）。
  void setContext(BuildContext? ctx) => _uiContext = ctx;

  /// UI 上下文：优先 view 注入的 context；未注入时回退全局 navigator key。
  BuildContext? get uiContext => _uiContext ?? appNavigatorKey.currentContext;

  /// 渠道管理器（channel 模块下线时为 null，消费点软降级）
  ChannelManager? _channelManager;

  /// 页面级 detail 通道（JsDetailChannel 或 StandardDetailChannel）。
  IDetailChannel? detailChannel;

  /// 当前页面在进程级 UI handler 注册表里的绑定句柄（页面退出时解绑）。
  ///
  /// `DetailCallbacks` 是页面级对象，而 `ScriptUiRequestRouter` 是进程级
  /// 单例；详情页把自身绑定到 `ScriptUiHandlerRegistry`，`ui.*` handler 在
  /// 调用时读取，不把页面 callbacks 固化进 channel 初始化。
  ScriptUiBinding? _scriptUiBinding;

  static const List<String> _fallbackPresetTags = [
    '工具', '游戏', '社交', '影音', '阅读', '效率', '系统',
  ];

  /// 页面挂载后初始化（view initState → microtask 调用，等价原 GetX onReady）。
  /// 幂等：重复调用自动跳过（页面重建不重复 bind/load）。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    // 目录变化（catalog.changed）→ 防抖重取详情；仅本页受影响的 app 或整渠道
    // 变更触发（复用既有 detailChannel.load()，无新 loading UI）。
    _liveRefresh = LiveRefreshSubscription(
      shouldRefresh: _affectedByCatalogChange,
      onRefresh: _refetchForLiveEvent,
    );
    _channelManager = ModuleManager.instance.get<ChannelManager>();
    _initializeFromArguments();
    await _initAndLoad();
  }

  /// 本页是否受该目录变更影响：
  /// - `catalog.changed.app_id` 命中当前 app → 是（仅该 app）；
  /// - `app_id == null`（整渠道变更）且 `key` 命中当前渠道（或缺省）→ 是；
  /// - 其余（其他 app / 其他渠道）→ 否，不重取。
  bool _affectedByCatalogChange(AppEvent event) {
    if (event.type != AppEventTypes.catalogChanged) return false;
    final req = request;
    if (req == null) return false;
    final data = event.data;
    final appId = data?['app_id'];
    if (appId != null) return appId.toString() == req.appId;
    final key = data?['key'];
    final code = req.channelCode ?? req.channel.code;
    return key == null || key.toString() == code;
  }

  /// 目录变化 → 防抖后重取详情（复用 [detailChannel] 的既有 load 路径）。
  void _refetchForLiveEvent() {
    if (_shutDown) return;
    final channel = detailChannel;
    if (channel == null) return;
    unawaited(channel.load());
  }

  /// 获取 channel → bind → load
  Future<void> _initAndLoad() async {
    final req = request;
    if (req == null) return;
    final code = req.channelCode ?? req.channel.code;
    final ch = _channelManager?.getChannelByCode(code);
    if (ch == null) {
      // Rust 脚本通道：flag on 时 js_* 渠道包归 ScriptApi，Dart 渠道已注销。
      if (await _loadRustScriptChannel(req, code)) return;
      // 门面可用的渠道（如 local_db，Dart 实例已下线）没有 Dart IChannel，
      // 但 core 拥有其数据 → 构造门面详情通道，避免误报「渠道不可用」。
      final manager = _channelManager;
      if (manager != null && manager.facadeEligible(code)) {
        final dc = FacadeDetailChannel(
          appId: req.appId,
          channelCode: code,
          request: req,
        );
        dc.bind(state, this);
        detailChannel = dc;
        await dc.load();
        return;
      }
      if (CoreFlags.jsChannel) {
        // 解析失败：给出类型化错误，避免 SizedBox.shrink() 静默白屏。
        state.errorMessage = '渠道不可用或未注册: $code';
        state.isLoadingDetail = false;
        return;
      }
      return; // flag off：旧路径逐字节不变（保持原静默返回）
    }
    var dc = ch.getDetailChannel(req.appId);
    dc ??= StandardDetailChannel(
      appId: req.appId,
      channel: ch,
      request: req,
      channelCode: code,
    );
    dc.bind(state, this);
    detailChannel = dc;
    _scriptUiBinding = ScriptUiHandlerRegistry.instance.bind(
      callbacks: this,
      appId: () => req.appId,
      channelKey: () => code,
    );
    await dc.load();
  }

  /// Rust 脚本通道解析：flag on 且 [code] 命中 Rust lane 时构造
  /// [RustScriptDetailChannel] 并加载，返回 true；否则返回 false。
  ///
  /// 缓存未命中时先刷新一次（deep-link 冷启动场景），仍无则回落类型化错误。
  Future<bool> _loadRustScriptChannel(AppDetailRequest req, String code) async {
    if (!CoreFlags.jsChannel) return false;
    final lane = RustScriptChannelLane.instance;
    if (lane.packFor(code) == null) {
      await lane.refresh();
    }
    if (lane.packFor(code) == null) return false;

    final dc = RustScriptDetailChannel(
      appId: req.appId,
      channelKey: code,
      request: req,
    );
    dc.bind(state, this);
    detailChannel = dc;
    _scriptUiBinding = ScriptUiHandlerRegistry.instance.bind(
      callbacks: this,
      appId: () => req.appId,
      channelKey: () => code,
    );
    await dc.load();
    return true;
  }

  /// 加载详情（错误页重试 / 单测直调入口）。
  Future<void> loadDetail() async {
    state.errorMessage = '';
    if (request == null) {
      state.errorMessage = '缺少请求参数';
      return;
    }
    _channelManager = ModuleManager.instance.get<ChannelManager>();
    await _initAndLoad();
  }

  /// 从参数初始化基础信息
  void _initializeFromArguments() {
    final args = _extra;
    if (args == null) {
      state.errorMessage = '缺少参数';
      state.isLoading = false;
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
        state.errorMessage = '无效的参数类型: ${args.runtimeType}';
        state.isLoading = false;
        return;
      }
    }
    state.request = request;
    state.isLoading = false;
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
    final detail = state.detailInfo;
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
      try {
        final task = await service.download(
          appId, appName, version, downloadUrl, fileName,
          downloadSize: download.size ?? downloadSize,
        );
        state.currentDownload = task;
        counterController.sink.add(task);
        final id = task.id;
        if (id != null) {
          downloadListenerSubscription?.cancel();
          // 列表级单订阅（service.watchAll）后按 id 过滤：不再为本任务单独建
          // 一条 `service.watch(id)` → 不再多出一条 500ms 原生轮询线程
          // （与 7f610d59 下载页的收口一致）。进度经 state.currentDownload 只
          // 递增进度修订号，不 notifyListeners → 不重建整页。
          downloadListenerSubscription = service.watchAll().listen((da) {
            if (da.id != id) return;
            state.currentDownload = da;
            counterController.sink.add(da);
          });
        }
      } on DownloadModuleUnavailableException catch (e) {
        AppDialogs.showError(e.userMessage, title: '下载失败');
      } catch (e) {
        appLog.error('DetailLogic: startDownload 失败 - $e');
      }
    }());
  }

  /// 安装已下载完成的 APK（Shizuku 优先，回退系统安装）
  Future<void> installCurrentTask(DownloadTask task) async {
    final manager = ModuleManager.instance.get<InstallManager>();
    if (manager == null) {
      AppDialogs.showWarning('安装模块未启用');
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android && task.fileName.endsWith('.apk')) {
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
    setContext(context);
    final req = request;
    if (req == null) return;
    final code = req.channelCode ?? req.channel.code;
    final manager = _channelManager;
    String canonicalId = req.appId;
    // 经门面路由解析 canonical appId：flag on 时 core 拥有 channel 域，Dart 渠道读被
    // 守卫拦截；lane code / 无实例时 getAppInfoByCode 失败，回退原 appId。
    if (manager != null) {
      try {
        final basicInfo = await manager.getAppInfoByCode(
          code,
          req.appId,
          forceRefresh: false,
        );
        final appSummary = basicInfo.success ? basicInfo.data : null;
        if (appSummary != null) {
          canonicalId = await manager.canonicalAppIdByCode(code, appSummary);
        }
      } catch (e) {
        appLog.error('DetailLogic: 解析 canonical appId 失败 - $e');
      }
    }
    var currentTags = <String>[];
    var presetTags = <String>[];
    try {
      // 读路径与写路径同源：走 AddedAppsFacade（flag on 读 Rust core / flag off
      // 回落旧 backend），不再直读旧聚合服务（flag on 时读旧库 → 标签陈旧）。
      currentTags = await AddedAppsFacade.instance.tags(
        req.channelCode ?? req.channel.code,
        canonicalId,
      );
      try {
        // 读路径与 core 同源：分类预设走 CatalogFacade（flag on 读 Rust core /
        // flag off 回落旧 backend），不再直读旧 apps.db。
        final categories = await CatalogFacade.instance.categories();
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
      if (state.isInstalled)
        DetailAction(
          label: '应用分析',
          icon: TablerIcons.analyze,
          onTap: _openAppAnalysis,
        ),
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
      // 写路径走 facade（flag on 写 Rust core / flag off 回落旧 backend）——
      // 旧 catalog 写守卫在 flag on 时抛 LegacyWriteBlocked(catalog)。
      await AddedAppsFacade.instance.setTags(
        req.channelCode ?? req.channel.code,
        canonicalId,
        result,
      );
      // 标签变化 → 通知首页刷新（与旧 setTags 的 _notifyAppsChanged 同义）
      await AddedAppsFacade.instance.notifyAppsChanged();
      AppDialogs.showSuccess('分类标签已更新', title: '保存成功');
    } catch (e) {
      AppDialogs.showError('保存标签失败: $e', title: '保存失败');
    }
  }

  /// 打开应用分析页（仅已安装时入口存在）：
  /// 优先取 base + split 全部 APK 源路径，失败回退单一 sourceDir。
  Future<void> _openAppAnalysis() async {
    final app = state.installInfo;
    final ctx = uiContext;
    if (app == null || ctx == null) return;
    final sourceDirs = await ApkSourceService.instance.getSourceDirs(app.packageName);
    String? sourceDir;
    if (sourceDirs.isNotEmpty) {
      sourceDir = sourceDirs.first;
    } else {
      sourceDir = await ApkSourceService.instance.getSourceDir(app.packageName);
    }
    if (sourceDir == null || !ctx.mounted) {
      AppDialogs.showError('无法获取 ${app.name} 的 APK 路径');
      return;
    }
    if (!ctx.mounted) return;
    final dir = sourceDir;
    Navigator.of(ctx).push(
      MaterialPageRoute<void>(
        builder: (_) => SdkAnalysisPage(
          app: app,
          sourceDir: dir,
          sourceDirs: sourceDirs.isNotEmpty ? sourceDirs : null,
        ),
      ),
    );
  }

  // ==================== DetailCallbacks 留在 logic 的薄委托实现 ====================

  @override
  Future<void> refreshDetail(
      {required Map<String, dynamic> detailData}) async {
    state.detailInfo = JsChannelDetailProxy(detailData);
    _applyInstalledInfo(detailData);
  }

  @override
  Future<void> updateDetail({required Map<String, dynamic> partial}) async {
    final current = state.detailInfo;
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
      state.detailInfo = JsChannelDetailProxy(merged);
      _applyInstalledInfo(merged);
    } else {
      // 首次推送（null 或非 JS proxy）：以 partial 创建，
      // extra 键同样展开写入顶层——与上一分支语义完全一致。
      final flat = Map<String, dynamic>.from(partial);
      if (flat['extra'] is Map) {
        final extra = flat.remove('extra') as Map;
        extra.forEach((ek, ev) => flat[ek.toString()] = ev);
      }
      state.detailInfo = JsChannelDetailProxy(flat);
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
    state.installInfo = installed.AppInfo(
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

        state.currentDownload = task;
        counterController.sink.add(task);
        downloadListenerSubscription?.cancel();
        final id = task.id;
        if (id != null) {
          // 与 startDownload 同款：列表级单订阅 + 按 id 过滤，杜绝 per-task 轮询。
          downloadListenerSubscription = service.watchAll().listen((da) {
            if (da.id != id) return;
            state.currentDownload = da;
            counterController.sink.add(da);
          });
        }
      } on DownloadModuleUnavailableException catch (e) {
        appLog.error('DetailLogic: syncDownloadToFB 失败 - ${e.userMessage}');
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
      state.actionBusy = false;
      state.actionBusyLabel = '';
      return;
    }
    debugPrint('DetailLogic: setActionBusy(true, label=${label ?? ''})');
    if (label != null && label.isNotEmpty) {
      state.actionBusyLabel = label;
    }
    state.actionBusy = true;
    // 兜底：重复开启重置 Timer，到时自动复位防脚本异常挂死状态
    _actionBusyTimer?.cancel();
    _actionBusyTimer = Timer(_actionBusyTimeout, () {
      debugPrint('DetailLogic: actionBusy 超时自动复位');
      state.actionBusy = false;
      state.actionBusyLabel = '';
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
    final ctx = uiContext;
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

  /// 释放资源（等价原 GetX onClose）：取消忙碌态 Timer、释放 detail 通道、
  /// 关闭下载进度流、取消下载监听。幂等。
  void shutdown() {
    if (_shutDown) return;
    _shutDown = true;
    _actionBusyTimer?.cancel();
    _actionBusyTimer = null;
    _liveRefresh?.dispose();
    _liveRefresh = null;
    final binding = _scriptUiBinding;
    _scriptUiBinding = null;
    if (binding != null) {
      ScriptUiHandlerRegistry.instance.unbind(binding);
    }
    final req = request;
    if (req != null) {
      final code = req.channelCode ?? req.channel.code;
      _channelManager
          ?.getChannelByCode(code)
          ?.releaseDetailChannel(req.appId);
    }
    final dc = detailChannel;
    if (dc is RustScriptDetailChannel) {
      // Rust 通道：释放 (key, app_id) detail runtime（Dart 渠道未注册，上面的
      // getChannelByCode 为 null，不会重复释放）。
      unawaited(dc.dispose());
    }
    detailChannel = null;
    counterController.close();
    downloadListenerSubscription?.cancel();
  }
}

/// 详情页状态 provider（每 push 独立实例）。
///
/// `autoDispose`：页面 pop 后无监听 → 状态与监听器自动清理，保证下一次 push
/// 拿到全新实例（等价旧实现「dispose 时显式删除控制器」语义）。
/// 详情页构造其 [DetailLogic] 时经 `ref.read(detailStateProvider)` 注入同一
/// 状态；channel 经 [IDetailChannel.bind] 注入后直接改写该状态（mutable
/// [DetailState]，见 state.dart）。
final detailStateProvider =
    ChangeNotifierProvider.autoDispose<DetailState>((ref) {
  final state = DetailState();
  ref.onDispose(state.dispose);
  return state;
});
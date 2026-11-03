import 'package:flutter/foundation.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:installed_apps/app_info.dart';

/// 详情页可变状态（Riverpod 版）。
///
/// 取代 GetX 时代的 `Rx` 字段：每个字段是「私有 backing + 同名
/// getter/setter」，setter 在值变化时自动 [notifyListeners]。channel 经
/// [IDetailChannel.bind] 注入后仍可直接改写（`state.foo = x`，一次字段
/// 一次通知）。
///
/// 与旧响应式语义的等价保证：
/// - setter 用 `==` 判重（同一值赋值不重复通知，等价旧 Rx 的 value 赋值）；
/// - 下载进度等「同实例原地更新」场景（DownloadTask 被下载服务原地改动、
///   引用不变）需强制发通知 —— 用 [refresh]（等价旧 Rx 的 refresh）。
class DetailState extends ChangeNotifier {
  /// 请求参数（基础信息）
  AppDetailRequest? request;

  /// 应用详情信息
  IDetailInfo? _detailInfo;
  IDetailInfo? get detailInfo => _detailInfo;
  set detailInfo(IDetailInfo? v) {
    if (_detailInfo == v) return;
    _detailInfo = v;
    notifyListeners();
  }

  /// 是否正在加载（改为 false，避免显示大块 loading）
  bool _isLoading = false;
  bool get isLoading => _isLoading;
  set isLoading(bool v) {
    if (_isLoading == v) return;
    _isLoading = v;
    notifyListeners();
  }

  /// 错误信息
  String _errorMessage = '';
  String get errorMessage => _errorMessage;
  set errorMessage(String v) {
    if (_errorMessage == v) return;
    _errorMessage = v;
    notifyListeners();
  }

  /// 已安装的应用信息
  AppInfo? _installInfo;
  AppInfo? get installInfo => _installInfo;
  set installInfo(AppInfo? v) {
    if (_installInfo == v) return;
    _installInfo = v;
    notifyListeners();
  }

  /// 是否正在加载详情（基础信息已显示）
  bool _isLoadingDetail = false;
  bool get isLoadingDetail => _isLoadingDetail;
  set isLoadingDetail(bool v) {
    if (_isLoadingDetail == v) return;
    _isLoadingDetail = v;
    notifyListeners();
  }

  /// 下载进度专用可监听对象（与整页状态解耦）。
  ///
  /// 下载服务每 ~500ms 原地更新同一 [DownloadTask] 实例。进度若走
  /// [notifyListeners]，根节点 `ref.watch(detailStateProvider)` 会整页重建——
  /// 详情页上下滑动时约 2 次/秒的整页重建即卡顿来源。进度只驱动 FAB，因此
  /// 单独用一个 [ValueNotifier] 承载：页面根节点不监听它，只有 FAB 的
  /// `ValueListenableBuilder` 监听。
  ///
  /// 用「修订号」而非 DownloadTask 值：下载服务原地更新同一实例时 `==` 不变，
  /// [ValueNotifier] 的判重会吞掉通知，故每次进度回调递增修订号强制通知。
  final ValueNotifier<int> downloadProgressRevision = ValueNotifier<int>(0);

  bool _disposed = false;

  /// 当前下载任务（用于 FAB 进度显示）。
  ///
  /// 赋值只递增 [downloadProgressRevision] 通知进度监听者，**不**触发
  /// [notifyListeners]——进度变化不重建整页（详情页滑动卡顿修复）。
  DownloadTask? _currentDownload;
  DownloadTask? get currentDownload => _currentDownload;
  set currentDownload(DownloadTask? v) {
    if (_disposed) return;
    _currentDownload = v;
    downloadProgressRevision.value++;
  }

  /// 下载列表（分块加载独立注入，null=未就绪/失败降级）
  List<DownloadInfo>? _downloads;
  List<DownloadInfo>? get downloads => _downloads;
  set downloads(List<DownloadInfo>? v) {
    if (_downloads == v) return;
    _downloads = v;
    notifyListeners();
  }

  /// README 内容（分块加载独立注入，null=未就绪/失败降级）
  String? _readme;
  String? get readme => _readme;
  set readme(String? v) {
    if (_readme == v) return;
    _readme = v;
    notifyListeners();
  }

  /// 下载列表区块加载中
  bool _downloadsLoading = false;
  bool get downloadsLoading => _downloadsLoading;
  set downloadsLoading(bool v) {
    if (_downloadsLoading == v) return;
    _downloadsLoading = v;
    notifyListeners();
  }

  /// README 区块加载中
  bool _readmeLoading = false;
  bool get readmeLoading => _readmeLoading;
  set readmeLoading(bool v) {
    if (_readmeLoading == v) return;
    _readmeLoading = v;
    notifyListeners();
  }

  /// 统计区块加载中
  bool _statisticsLoading = false;
  bool get statisticsLoading => _statisticsLoading;
  set statisticsLoading(bool v) {
    if (_statisticsLoading == v) return;
    _statisticsLoading = v;
    notifyListeners();
  }

  /// 更多按钮忙碌态（慢操作如切版本/切 UA 进行中，AppBar actions 响应式渲染）
  bool _actionBusy = false;
  bool get actionBusy => _actionBusy;
  set actionBusy(bool v) {
    if (_actionBusy == v) return;
    _actionBusy = v;
    notifyListeners();
  }

  /// 忙碌态描述文案（如「正在切换版本…」，空串用默认提示）
  String _actionBusyLabel = '';
  String get actionBusyLabel => _actionBusyLabel;
  set actionBusyLabel(String v) {
    if (_actionBusyLabel == v) return;
    _actionBusyLabel = v;
    notifyListeners();
  }

  /// 入库状态是否已从 core 读取完成（避免按钮闪烁）。
  bool _libraryChecked = false;
  bool get libraryChecked => _libraryChecked;
  set libraryChecked(bool v) {
    if (_libraryChecked == v) return;
    _libraryChecked = v;
    notifyListeners();
  }

  /// 当前应用是否已在库中（added_apps 成员关系）。
  bool _libraryAdded = false;
  bool get libraryAdded => _libraryAdded;
  set libraryAdded(bool v) {
    if (_libraryAdded == v) return;
    _libraryAdded = v;
    notifyListeners();
  }

  /// 正在执行「加入渠道并入库」。
  bool _libraryBusy = false;
  bool get libraryBusy => _libraryBusy;
  set libraryBusy(bool v) {
    if (_libraryBusy == v) return;
    _libraryBusy = v;
    notifyListeners();
  }

  /// 获取当前显示的名称（优先使用详情，否则使用请求）
  String get displayName => detailInfo?.name ?? request?.name ?? '';

  /// 获取当前显示的图标（优先使用详情，否则使用请求）
  String get displayIcon => detailInfo?.icon ?? request?.icon ?? '';

  /// 获取当前显示的描述（优先使用详情，否则使用请求）
  String get displayDescription =>
      detailInfo?.description ?? request?.description ?? '';

  /// 获取当前显示的版本（优先使用详情）
  String? get displayVersion => detailInfo?.version;

  /// 是否有详情信息
  bool get hasDetailInfo => detailInfo != null;

  /// 是否已安装
  bool get isInstalled => installInfo != null;

  /// 释放：随详情页 `autoDispose` 一起销毁进度通知器。
  ///
  /// 幂等：`ChangeNotifierProvider` 自身与 `ref.onDispose(state.dispose)` 都会
  /// 触发本方法，重复调用不得二次 dispose 进度通知器。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    downloadProgressRevision.dispose();
    super.dispose();
  }
}

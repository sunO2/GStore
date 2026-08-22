import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/page/detail/state.dart';

/// 详情通道接口：每个 appId 独立实例，数据/缓存随实例隔离。
/// 页面退出经 [IChannel.releaseDetailChannel] 释放。
abstract class IDetailChannel {
  String get appId;

  /// 注入状态容器 + UI 回调接口。
  /// 页面打开后调用，channel 在 [load] 及后续交互中把数据写入 [state]。
  void bind(DetailState state, DetailCallbacks callbacks);

  /// 加载数据（并更新到 bound 的 [DetailState]）。
  Future<void> load();

  /// 返回操作项列表（"更多"按钮面板展示）。
  List<DetailAction> getActions();

  /// 发起下载。
  Future<void> startDownload(DownloadInfo info);

  Future<void> dispose();
}
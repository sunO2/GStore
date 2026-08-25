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

  /// 是否由渠道自身驱动下载（如 JS 渠道经脚本 callMain('download') 真实触发）。
  /// false（默认）：下载由宿主（DetailLogic）编排（DownloadStatus.create → listener → service）。
  /// true：DetailLogic 直接委托 [startDownload] 后 return，不走宿主编排。
  bool get drivesOwnDownloads => false;

  /// 发起下载。
  Future<void> startDownload(DownloadInfo info);

  /// 版本/环境切换选项（JS 渠道实现；标准渠道默认 null = 不支持）
  Future<Map<String, dynamic>?> versionOptions(String appId, {String? env}) async => null;

  /// 切换版本/环境（JS 渠道实现；默认 null）
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) async => null;

  /// 指定版本历史构建（JS 渠道实现；默认 null）
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async => null;

  /// 更新下载区（JS 代理数据专用；默认 no-op）
  Future<void> updateDownloads(List<DownloadInfo> downloads) async {}

  Future<void> dispose();
}
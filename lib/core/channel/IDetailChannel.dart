/// 详情通道接口：每个 appId 独立实例，数据/缓存随实例隔离。
/// 页面退出经 [IChannel.releaseDetailChannel] 释放。
abstract class IDetailChannel {
  String get appId;
  Future<void> dispose();
}
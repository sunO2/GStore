import 'package:flutter/services.dart';

/// 代理 VPN 的 Dart 触发层。
///
/// 只负责拉起系统 VPN 授权流程与前台服务（[prepare]/[start]/[stop]），不含任何
/// 网络、解析或路由逻辑——那些都在 Rust（`gstore_mod_proxy`）。Kotlin 侧入口为
/// `MainActivity` 的 `gstore/proxy_vpn` 通道。
class ProxyVpnTrigger {
  ProxyVpnTrigger._();

  static const MethodChannel _channel = MethodChannel('gstore/proxy_vpn');

  /// 触发系统 VPN 同意对话框；用户同意后由 Kotlin 启动 `ProxyVpnService`。
  static Future<bool> prepare({String configJson = '{}'}) async {
    final result =
        await _channel.invokeMethod<bool>('prepare', {'config': configJson});
    return result ?? false;
  }

  /// 直接启动前台服务（须已授权）。
  static Future<bool> start({String configJson = '{}'}) async {
    final result =
        await _channel.invokeMethod<bool>('start', {'config': configJson});
    return result ?? false;
  }

  /// 停止前台服务。
  ///
  /// 拆除是尽力而为：平台通道不可用（`MissingPluginException`）或原生侧报错
  /// （`PlatformException`）时返回 `false` 而非抛出，确保断开流程的 finally 里
  /// 调用它绝不会中断后续清理 / 覆盖 core.stop 的原始错误。
  static Future<bool> stop() async {
    try {
      final result = await _channel.invokeMethod<bool>('stop');
      return result ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> isRunning() async {
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }

  /// 消费 QS 磁贴的「连接」请求（由 MainActivity 的 pending 标志置位）。
  ///
  /// 与 [stop] 同样防御：平台通道不可用或原生报错时返回 `false` 而非抛出。
  static Future<bool> consumeProxyConnect() async {
    try {
      return await _channel.invokeMethod<bool>('consumeProxyConnect') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 消费 QS 磁贴「长按」打开代理页的请求。
  static Future<bool> consumeProxyOpen() async {
    try {
      return await _channel.invokeMethod<bool>('consumeProxyOpen') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开系统「VPN」设置页，引导用户开启「始终开启的 VPN」。
  ///
  /// App 无法直接切换系统设置；Kotlin 侧 `Settings.ACTION_VPN_SETTINGS` 兜底失败
  /// 时静默返回。仅用于 always-on 引导（Todo 23/24）。
  static Future<bool> openAlwaysOnSettings() async {
    final result = await _channel.invokeMethod<bool>('alwaysOnSettings');
    return result ?? false;
  }
}

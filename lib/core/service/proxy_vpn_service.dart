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

  static Future<bool> stop() async {
    final result = await _channel.invokeMethod<bool>('stop');
    return result ?? false;
  }

  static Future<bool> isRunning() async {
    return await _channel.invokeMethod<bool>('isRunning') ?? false;
  }
}

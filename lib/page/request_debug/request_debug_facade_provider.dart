/// 共享「请求调试」门面 provider（GetX DI seam 的等价物）。
///
/// 请求调试页（[RequestDebugPage]）与抓包桥（[RequestDebugCaptureBridge]）默认
/// 都经本 provider 取**同一个** [RequestDebugFacade]，进而共享同一
/// [RequestDebugStore]。这消除二者各自 `DefaultRequestDebugFacade.production()`
/// 造成的「双门面覆盖」：任一方的内存变更不再被另一方的陈旧快照在落盘时覆盖
/// （见 plan todo 8）。
///
/// 装配位置：本文件位于页面层，因为生产组合需要页面层的
/// [ProxyModuleCaptureRulesPort]（core 层不得 import 页面/FFI）。
///
/// 测试接缝（不破坏既有注入假实现）：
/// - [overrideFacade] 显式注入假门面（测试 / 宿主定制）；
/// - [reset] 显式 per-test 重置：清除注入与进程单例，下一次访问重建生产门面。
library;

import 'package:gstore/core/request_debug/request_debug.dart';

import 'proxy_capture_rules_port.dart';

/// 共享「请求调试」门面 provider（进程内单例 + 可注入 + 可重置）。
class RequestDebugFacadeProvider {
  RequestDebugFacadeProvider._();

  /// 测试 / 宿主显式注入的门面（优先于单例）。
  static RequestDebugFacade? _override;

  /// 进程内共享生产门面（懒创建，保证页面与抓包桥拿到同一实例）。
  static RequestDebugFacade? _shared;

  /// 当前共享门面。
  ///
  /// 优先级：注入门面 → 进程单例 → 按生产组合创建单例。首次访问即固化，
  /// 后续调用返回同一实例（同一 store）。
  static RequestDebugFacade get instance =>
      _override ?? (_shared ??= _createProduction());

  /// 生产组合：真实 store / sender + 经 [ProxyModule] 的改写规则端口。
  static RequestDebugFacade _createProduction() =>
      DefaultRequestDebugFacade.production(
        captureRules: ProxyModuleCaptureRulesPort(),
      );

  /// 注入门面（测试 / 宿主 seam）。传 `null` 等价于仅清除注入。
  static void overrideFacade(RequestDebugFacade? facade) {
    _override = facade;
  }

  /// 显式 per-test 重置：清除注入与单例，下一次访问重建生产门面。
  ///
  /// 测试 `tearDown` 调用以确保不跨测试泄漏 store / facade。
  static void reset() {
    _override = null;
    _shared = null;
  }
}

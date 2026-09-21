/// 节点 / 代理组页面依赖的最小门面契约。
///
/// 冻结的 [ProxyFacade] 只暴露 `ping` / `version` / `events`；而 `node.select` /
/// `node.delay_test` 是 [ProxyModule] 上的方法（见 `ProxyModule.dart`）。为了
/// **不改动冻结契约**（`lib/core/rust/proxy/*`），节点页只依赖这个更小的接口：
/// 生产环境用 [ProxyModuleNodesFacade] 适配，测试注入假实现即可，无需原生模块。
///
/// 约定：本层只做「转发 + 展示」，**绝不**在 Dart 内实现任何延迟探测 / 解析逻辑
/// （全部在 Rust 侧）。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 节点页所需的模块能力（在冻结 [ProxyFacade] 之外的 `node.*` 动作）。
abstract class ProxyNodesFacade {
  /// 类型化代理事件流（[ProxyNodeDelayEvent] 用于逐节点延迟回填）。
  Stream<ProxyEvent> get events;

  /// `node.select`：把用户选择应用到 selector/url-test/fallback 组。
  Future<NodeSelectResult> nodeSelect(String group, String node);

  /// `node.delay_test`：逐节点 HTTP 探测（不可达是逐项结果，不是调用错误）。
  Future<DelayTestResult> nodeDelayTest(NodeDelayTestRequest request);
}

/// 生产适配器：把 [ProxyNodesFacade] 转发到 [ProxyModule] 单例。
class ProxyModuleNodesFacade implements ProxyNodesFacade {
  ProxyModuleNodesFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Stream<ProxyEvent> get events => _module.events;

  @override
  Future<NodeSelectResult> nodeSelect(String group, String node) =>
      _module.nodeSelect(group, node);

  @override
  Future<DelayTestResult> nodeDelayTest(NodeDelayTestRequest request) =>
      _module.nodeDelayTest(request);
}

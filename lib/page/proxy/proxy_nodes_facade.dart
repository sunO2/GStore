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

/// 节点页所需的模块能力（在冻结 [ProxyFacade] 之外的 `profile.get` / `node.*`）。
abstract class ProxyNodesFacade {
  /// 类型化代理事件流（[ProxyNodeDelayEvent] 用于逐节点延迟回填）。
  Stream<ProxyEvent> get events;

  /// `profile.get`：按 id 读取存储的订阅（含 `nodes` / `groups`）。
  ///
  /// 节点页的数据源：首页只持有「选中的 profile id」，节点/分组清单由本页
  /// 经此方法自行加载（Rust 侧已完成解析与分组）。
  Future<StoredProfile> profileGet(String id);

  /// `node.select`：把用户选择应用到 selector/url-test/fallback 组。
  Future<NodeSelectResult> nodeSelect(String group, String node);

  /// `node.delay_test`：逐节点 HTTP 探测（不可达是逐项结果，不是调用错误）。
  Future<DelayTestResult> nodeDelayTest(NodeDelayTestRequest request);

  /// `node.list`：引擎运行时各代理组的实时选中（`now`）与可选性（`selectable`）。
  Future<NodeListResult> nodeList();

  /// `config.apply`：以 [profileId] 重新生成并应用配置（引擎热生效）。
  ///
  /// 节点页在「引擎运行中但某分组未在当前生效配置里」时，best-effort 调用它让
  /// 新分组落进引擎，再重取 [nodeList] 后选择。失败语义由调用方决定（页面按
  /// best-effort 吞掉异常，仅 `debugPrint`）。
  Future<void> reconcileEngine(String profileId);
}

/// 生产适配器：把 [ProxyNodesFacade] 转发到 [ProxyModule] 单例。
class ProxyModuleNodesFacade implements ProxyNodesFacade {
  ProxyModuleNodesFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Stream<ProxyEvent> get events => _module.events;

  @override
  Future<StoredProfile> profileGet(String id) => _module.profileGet(id);

  @override
  Future<NodeSelectResult> nodeSelect(String group, String node) =>
      _module.nodeSelect(group, node);

  @override
  Future<DelayTestResult> nodeDelayTest(NodeDelayTestRequest request) =>
      _module.nodeDelayTest(request);

  @override
  Future<NodeListResult> nodeList() => _module.nodeList();

  @override
  Future<void> reconcileEngine(String profileId) =>
      _module.configApply(GenerateRequest(profileId: profileId));
}

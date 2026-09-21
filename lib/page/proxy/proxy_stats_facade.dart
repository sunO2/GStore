/// 域名统计看板（Todo 22c）展示层门面契约。
///
/// 冻结的 [ProxyFacade] 只暴露 `ping` / `version` / `events`；统计页需要
/// `stats.domain.get` / `stats.domain.reset`。为**不改动冻结契约**，这里定义
/// 窄接口 [ProxyStatsFacade] 并由 [ProxyModuleStatsFacade] 适配 [ProxyModule]。
///
/// **纯展示层**：排序 / 时间范围 / 重置都只是转发参数；字节等口径由 Rust
/// 计算（`stats.domain.get`），Dart 仅按单行字段展示，**不聚合任何总量**。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 统计页所需的模块能力（`stats.domain.get` / `stats.domain.reset`）。
abstract class ProxyStatsFacade {
  /// `stats.domain.get`：按域名聚合统计（含 Rust 排序）。
  Future<DomainPage> statsDomainGet(StatsDomainGetRequest request);

  /// `stats.domain.reset`：清空聚合与持久化行。
  Future<StatsResetResult> statsDomainReset();
}

/// 生产适配器：[ProxyModule] → [ProxyStatsFacade] 的薄转发。
class ProxyModuleStatsFacade implements ProxyStatsFacade {
  ProxyModuleStatsFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<DomainPage> statsDomainGet(StatsDomainGetRequest request) =>
      _module.statsDomainGet(request);

  @override
  Future<StatsResetResult> statsDomainReset() => _module.statsDomainReset();
}

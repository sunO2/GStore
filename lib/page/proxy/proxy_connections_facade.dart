/// 实时连接页（Todo 21）展示层门面契约。
///
/// 冻结的 [ProxyFacade] 只暴露 `ping` / `version` / `events`；连接页需要
/// `conn.list` / `conn.close` / `conn.close_all`。为**不改动冻结契约**，这里定义
/// 窄接口 [ProxyConnectionsFacade] 并由 [ProxyModuleConnectionsFacade] 适配
/// [ProxyModule]。
///
/// **纯展示层薄转发**：分页 offset/limit 与域名/出站筛选都只是转发参数；连接表、
/// 容量截断、排序与关闭动作全部在 Rust 侧（`API.md` §2.10），Dart 仅按字段展示，
/// **不聚合、不落盘、不重排**。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 连接页所需的模块能力（`conn.*`）。
abstract class ProxyConnectionsFacade {
  /// `conn.list`：分页 / 可过滤的活动连接。
  Future<ConnPage> connList(ConnListRequest request);

  /// `conn.close`：幂等关闭一个连接（缺席返回 `closed:false`，非错误）。
  Future<ConnCloseResult> connClose(String id);

  /// `conn.close_all`：关闭全部连接。
  Future<ConnCloseAllResult> connCloseAll();
}

/// 生产适配器：[ProxyModule] → [ProxyConnectionsFacade] 的薄转发。
class ProxyModuleConnectionsFacade implements ProxyConnectionsFacade {
  ProxyModuleConnectionsFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<ConnPage> connList(ConnListRequest request) =>
      _module.connList(request);

  @override
  Future<ConnCloseResult> connClose(String id) => _module.connClose(id);

  @override
  Future<ConnCloseAllResult> connCloseAll() => _module.connCloseAll();
}

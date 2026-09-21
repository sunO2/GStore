/// DNS 设置页（Todo 22a）展示层门面契约。
///
/// 冻结的 [ProxyFacade]（`lib/core/rust/proxy/ProxyModule.dart`）只暴露
/// `ping` / `version` / `events`；DNS 页需要 `dns.*` 读取 / 保存 / 清缓存。
/// 为**不改动冻结契约**，这里定义窄接口 [ProxyDnsFacade]，生产环境用
/// [ProxyModuleDnsFacade] 适配 [ProxyModule]，测试注入假实现即可。
///
/// **纯展示层**：只做参数透传，不含解析 / 网络 / 路由逻辑（全部在 Rust 的
/// `gstore_mod_proxy`，见 `rust/gstore_mod_proxy/API.md` §2.7）。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// DNS 页所需的模块能力（`dns.get` / `dns.set` / `dns.clear_cache`）。
abstract class ProxyDnsFacade {
  /// `dns.get`：有效配置 + 统计 + 近期查询/映射。
  Future<DnsSnapshot> dnsGet();

  /// `dns.set`：提交部分 DNS 配置补丁（`DnsConfig` JSON 字段；显式空列表
  /// 表示清空该列表，符合 Rust 侧 `apply_patch` 的合并语义）。
  Future<DnsSetResult> dnsSet(Map<String, dynamic> payload);

  /// `dns.clear_cache`：清空缓存与 fake-IP 分配。
  Future<DnsClearResult> dnsClearCache();
}

/// 生产适配器：[ProxyModule] → [ProxyDnsFacade] 的薄转发。
class ProxyModuleDnsFacade implements ProxyDnsFacade {
  ProxyModuleDnsFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<DnsSnapshot> dnsGet() => _module.dnsGet();

  @override
  Future<DnsSetResult> dnsSet(Map<String, dynamic> payload) =>
      _module.invoke<DnsSetResult>(
        ProxyMethods.dnsSet,
        DnsSetResult.fromJson,
        payload: payload,
      );

  @override
  Future<DnsClearResult> dnsClearCache() => _module.dnsClearCache();
}

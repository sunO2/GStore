/// 「当前选中的节点」持久化接缝（page 层）。
///
/// 模块没有「记住上次选择的节点」的持久化：`node.select` 只把选择应用到当前
/// 运行的 selector / url-test / fallback 组（`rust/gstore_mod_proxy/src/nodes.rs`），
/// 进程重启后首页与节点页都会丢失「用户选的是哪个节点」这一信息。为了让
/// 首页入口卡能显示「当前选中的节点」、节点页能在重入时高亮已选节点，这里定义
/// 一个 page 层的小接缝：
///
/// * 生产实现沿用统一 [ConfigStore]（`proxy_active_node_label`，值为
///   `{"group":...,"node":...}` 的 JSON），所有读写 best-effort，持久化失败绝不影响
///   页面；
/// * 测试注入内存实现即可，无需原生模块 / 平台存储。
///
/// 为**不改动冻结契约**（`lib/core/rust/proxy/*`），本文件只做持久化，不新增任何
/// 门面方法；`node.select` 的调用语义保持不变。
library;

import 'dart:convert';

import 'package:gstore/core/config/config_store.dart';

/// 一次「节点选择」：所属分组 + 节点名。
///
/// `group` 用于节点页按组回显高亮（`{group: node}`），`node` 用于首页展示。
class ProxyActiveNode {
  const ProxyActiveNode({required this.group, required this.node});

  /// 选择所在的分组名（如 `PROXY`）。
  final String group;

  /// 被选中的节点名（首页展示的标签）。
  final String node;
}

/// 当前选中节点的只读 + 写入接缝。
abstract class ProxyActiveNodeStore {
  /// 读取当前选中的节点；未设置 / 读取失败返回 `null`。
  Future<ProxyActiveNode?> read();

  /// 持久化当前选中的节点。
  Future<void> write(ProxyActiveNode selection);

  /// 清除当前选中。
  Future<void> clear();
}

/// 生产实现：统一 [ConfigStore]（共享偏好 / 加密存储自动路由）。
///
/// 所有读写都做 best-effort：`ConfigStore` 未初始化 / 存储异常时读返回 `null`、
/// 写静默忽略，绝不因持久化失败而崩溃页面。
class ConfigStoreProxyActiveNodeStore implements ProxyActiveNodeStore {
  const ConfigStoreProxyActiveNodeStore();

  /// 持久化 key（沿用代理设置页 `proxy_*` 命名）。
  static const String key = 'proxy_active_node_label';

  @override
  Future<ProxyActiveNode?> read() async {
    try {
      final value = await ConfigStore.instance.readString(key);
      if (value == null || value.isEmpty) return null;
      final decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      final node = decoded['node'];
      final group = decoded['group'];
      if (node is! String || node.isEmpty) return null;
      return ProxyActiveNode(
        group: group is String ? group : '',
        node: node,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(ProxyActiveNode selection) async {
    if (selection.node.isEmpty) return;
    try {
      await ConfigStore.instance.writeString(
        key,
        jsonEncode(<String, String>{
          'group': selection.group,
          'node': selection.node,
        }),
      );
    } catch (_) {
      // 持久化失败不阻断选择（本次会话仍以内存选择为准）。
    }
  }

  @override
  Future<void> clear() async {
    try {
      await ConfigStore.instance.remove(key);
    } catch (_) {
      // best-effort
    }
  }
}

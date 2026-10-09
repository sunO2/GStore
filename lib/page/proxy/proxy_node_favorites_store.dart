/// 「收藏节点」持久化接缝（page 层）。
///
/// 模块没有「节点收藏」概念：`node.list` / `profile.get` 只描述引擎与订阅本身，
/// 不记忆用户偏好。为了让节点页能把收藏的节点置顶，这里定义一个小接缝：
///
/// * 生产实现沿用统一 [ConfigStore]（key `proxy_node_favorites`，值为收藏键的
///   JSON 数组字符串），所有读写 best-effort，持久化失败绝不影响页面；
/// * 测试可注入内存实现，无需原生模块 / 平台存储。
///
/// 收藏键为 `分组名\u0000节点名`：节点名可在不同分组内重名，用分组限定作用域，
/// 避免同名节点跨组串收藏。为**不改动冻结契约**（`lib/core/rust/proxy/*`），
/// 本文件只做持久化，不新增任何门面方法。
library;

import 'dart:convert';

import 'package:gstore/core/config/config_store.dart';

/// 收藏键构造：分组作用域内的节点（NUL 分隔，任何分组/节点名都安全）。
String proxyNodeFavoriteKey(String group, String node) => '$group\u0000$node';

/// 收藏节点的只读 + 写入接缝。
abstract class ProxyNodeFavoritesStore {
  /// 读取收藏键集合；未设置 / 读取失败返回空集合。
  Future<Set<String>> read();

  /// 覆盖写入收藏键集合。
  Future<void> write(Set<String> keys);
}

/// 生产实现：统一 [ConfigStore]（普通存储，非敏感）。
///
/// 所有读写都做 best-effort：`ConfigStore` 未初始化 / 存储异常时读返回空集合、
/// 写静默忽略，绝不因持久化失败而崩溃页面。
class ConfigStoreProxyNodeFavoritesStore implements ProxyNodeFavoritesStore {
  const ConfigStoreProxyNodeFavoritesStore();

  /// 持久化 key（沿用代理设置页 `proxy_*` 命名）。
  static const String key = 'proxy_node_favorites';

  @override
  Future<Set<String>> read() async {
    try {
      final String? value = await ConfigStore.instance.readString(key);
      if (value == null || value.isEmpty) return <String>{};
      final Object? decoded = jsonDecode(value);
      if (decoded is! List) return <String>{};
      return decoded.whereType<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  @override
  Future<void> write(Set<String> keys) async {
    try {
      await ConfigStore.instance.writeString(key, jsonEncode(keys.toList()));
    } catch (_) {
      // 持久化失败不阻断收藏（本次会话仍以内存收藏为准）。
    }
  }
}

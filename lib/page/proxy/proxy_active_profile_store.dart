/// 「当前选中的订阅」持久化接缝（page 层）。
///
/// 模块没有 `profile.select` 方法：`core.start` / `config.generate` 接受可选
/// `profileId`，Rust 侧解析规则是「显式 `profileId`，否则用存储顺序里的第一个」
/// （`rust/gstore_mod_proxy/src/config.rs`）。因此「选中的订阅」= Dart 侧持久化的
/// profile id，连接时经 `CoreStartRequest(profileId: ...)` 传入。
///
/// 为**不改动冻结契约**（`lib/core/rust/proxy/*`），这里定义一个可注入的小接口：
/// 生产实现沿用统一 [ConfigStore]（`proxy_active_profile_id`），测试注入内存实现
/// 即可，无需原生模块 / 平台存储。
library;

import 'package:gstore/core/config/config_store.dart';

/// 当前选中订阅 id 的只读 + 写入接缝。
abstract class ProxyActiveProfileStore {
  /// 读取当前选中的 profile id；未设置 / 读取失败返回 `null`。
  Future<String?> read();

  /// 持久化当前选中的 profile id。
  Future<void> write(String id);

  /// 清除当前选中（例如已失效且无法自动选中）。
  Future<void> clear();
}

/// 生产实现：统一 [ConfigStore]（共享偏好 / 加密存储自动路由）。
///
/// 所有读写都做 best-effort：`ConfigStore` 未初始化 / 存储异常时读返回 `null`、
/// 写静默忽略，绝不因持久化失败而崩溃页面。
class ConfigStoreProxyActiveProfileStore implements ProxyActiveProfileStore {
  const ConfigStoreProxyActiveProfileStore();

  /// 持久化 key（沿用代理设置页 `proxy_*` 命名）。
  static const String key = 'proxy_active_profile_id';

  @override
  Future<String?> read() async {
    try {
      final value = await ConfigStore.instance.readString(key);
      if (value == null || value.isEmpty) return null;
      return value;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String id) async {
    if (id.isEmpty) return;
    try {
      await ConfigStore.instance.writeString(key, id);
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

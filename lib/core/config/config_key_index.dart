/// 裸 key → 分组 wire key（`module.key`）的兼容索引。
///
/// 历史调用点（代理页的 7 个 store 与 `proxy_settings_facade`）仍使用
/// `proxy_engine_stack` 这类旧裸 key；运行时只接受 Rust 注册表里的分组 key。
/// 本索引负责把这 11 个代理别名映射到分组 key，其余 key 必须本身就是已注册
/// 的 wire key（例如 [ConfigKeys.agentModels]）。
///
/// 未命中别名且未注册时返回 `null`，由 [ConfigStore] 记录日志并拒绝，绝不抛异常。
library;

/// 裸 key 兼容索引（无状态，纯查表）。
class ConfigKeyIndex {
  ConfigKeyIndex._();

  /// 11 个代理页旧裸 key → 分组 wire key（与 Rust 注册表一致）。
  static const Map<String, String> proxyAliases = <String, String>{
    'proxy_engine_stack': 'proxy.engine_stack',
    'proxy_engine_mtu': 'proxy.engine_mtu',
    'proxy_routing_mode': 'proxy.routing_mode',
    'proxy_run_mode': 'proxy.run_mode',
    'proxy_active_node_label': 'proxy.active_node_label',
    'proxy_active_profile_id': 'proxy.active_profile_id',
    'proxy_sheet_view_mode': 'proxy.sheet_view_mode',
    'proxy_split_mode': 'proxy.split_mode',
    'proxy_split_apps': 'proxy.split_apps',
    'proxy_always_on_intent': 'proxy.always_on_intent',
    'proxy_log_level': 'proxy.log_level',
  };

  /// `LegacyConfigKeys` 中**单值**旧键 → 分组 wire key。
  ///
  /// 仅供 `ConfigRegistry.migrateLegacy`（Todo 17 移除前的兼容路径）与旧备份
  /// 适配使用；聚合对象（`download_config`/`update_config`/`webdav_config`）
  /// 在磁盘上并无单值，不在此表内。这样旧键迁移能命中注册表，避免“拒绝未注册
  /// key”导致旧值被删除而未迁移。
  static const Map<String, String> legacyAliases = <String, String>{
    'theme_config': 'theme.config',
    'theme_mode': 'theme.mode',
    'proxy_url': 'network.proxy_url',
    'catalog_url': 'catalog.source_url',
    'agent_models': 'agent.models',
    'agent_selected_model_id': 'agent.selected_model_id',
    'agent_model_catalog': 'agent.model_catalog',
    'fdroid_sources': 'fdroid.sources',
    'last_source_id': 'fdroid.last_source_id',
    'selected_channels': 'discovery.selected_channels',
    'webdav_url': 'webdav.url',
    'webdav_username': 'webdav.username',
    'webdav_password': 'webdav.password',
    'webdav_backup_path': 'webdav.backup_path',
    'webdav_enable_https': 'webdav.enable_https',
  };

  /// 全部别名（供静态扫描 / 测试断言）。
  static Map<String, String> get aliases => proxyAliases;

  /// 解析 [key] 为已注册的 wire key。
  ///
  /// 顺序：本身已注册 → 代理别名 → 旧单值键别名（含裸/`config_` 前缀）→ `null`。
  static String? resolve(
    String key, {
    required bool Function(String wireKey) isRegistered,
  }) {
    if (isRegistered(key)) return key;
    for (final alias in _candidates(key)) {
      if (isRegistered(alias)) return alias;
    }
    return null;
  }

  /// 依次尝试的候选分组 key（含去掉历史 `config_` 前缀后的别名）。
  static Iterable<String> _candidates(String key) sync* {
    final proxy = proxyAliases[key];
    if (proxy != null) yield proxy;
    final legacy = legacyAliases[key];
    if (legacy != null) yield legacy;
    if (key.startsWith('config_')) {
      final bare = key.substring('config_'.length);
      final proxyBare = proxyAliases[bare];
      if (proxyBare != null) yield proxyBare;
      final legacyBare = legacyAliases[bare];
      if (legacyBare != null) yield legacyBare;
    }
  }
}

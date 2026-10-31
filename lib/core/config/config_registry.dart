/// 配置注册表
///
/// 集中声明 GStore 所有应用配置项（内置注册表）。
///
/// **唯一事实来源**是 Rust 侧 `rust/gstore_core/src/config/schema.rs`：
/// 运行时 key 一律是分组形式 `module.key`；本文件的 [ConfigKeys] 只是 Rust
/// 注册表 key 的 Dart 常量镜像，[ConfigEntry] 元数据（类型/默认值/敏感/
/// Agent 可见性/描述）必须与 Rust 保持一致（`test/config_keys_grouped_test.dart`
/// 会对照由 Rust 注册表生成的 `test/fixtures/config_registry_keys.json` 校验）。
///
/// [LegacyConfigKeys] 仅用于旧数据迁移、旧备份兼容与回滚，**禁止**在运行时
/// 读写路径中使用。
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_service.dart';
import 'config_store.dart';

/// 分组模块名（wire key 的第一段，即 `module.key` 中的 `module`）。
///
/// 与 Rust `ConfigKey.module` 一一对应；[misc] 预留给未归组的宿主级配置，
/// 当前注册表未使用。
class ConfigModules {
  ConfigModules._();

  /// 主题
  static const String theme = 'theme';

  /// 下载
  static const String download = 'download';

  /// 更新
  static const String update = 'update';

  /// WebDAV
  static const String webdav = 'webdav';

  /// 网络（GitHub 代理等跨模块可读项）
  static const String network = 'network';

  /// 目录库
  static const String catalog = 'catalog';

  /// Agent
  static const String agent = 'agent';

  /// F-Droid
  static const String fdroid = 'fdroid';

  /// 发现页
  static const String discovery = 'discovery';

  /// 性能监控
  static const String perf = 'perf';

  /// 业务模块开关（`module.<name>.enabled`）
  static const String module = 'module';

  /// 代理页持久化
  static const String proxy = 'proxy';

  /// 未归组的宿主级配置（预留，当前未注册）
  static const String misc = 'misc';

  /// 全部模块名（包含预留的 [misc]）。
  static const Set<String> all = <String>{
    theme,
    download,
    update,
    webdav,
    network,
    catalog,
    agent,
    fdroid,
    discovery,
    perf,
    module,
    proxy,
    misc,
  };
}

/// 内置配置 key 常量（分组 wire key `module.key`）
///
/// 常量名保持历史命名，仅**值**切换为分组形式，调用方无需改代码。
/// 完整清单与 Rust `schema.rs` 的 53 个条目一一对应。
class ConfigKeys {
  ConfigKeys._();

  // ---- theme ----

  /// 主题配置（JSON，桥接 ThemeConfigProvider）
  static const String themeConfig = 'theme.config';

  /// 主题模式（0=system 1=light 2=dark）
  static const String themeMode = 'theme.mode';

  // ---- download ----

  /// 多段下载开关（false = 单连接下载）
  static const String downloadMultiSegmentEnabled =
      'download.multi_segment.enabled';

  /// 仅在 Wi-Fi 下下载
  static const String downloadWifiOnly = 'download.wifi_only';

  /// 最大并发下载任务数（1-10）
  static const String downloadMaxConcurrent = 'download.max_concurrent';

  /// 多段下载时单任务默认连接数（分段数）
  static const String downloadDefaultConnections =
      'download.default_connections';

  /// 下载失败最大重试次数（0-5）
  static const String downloadMaxRetries = 'download.max_retries';

  /// 全局限速（字节/秒，0 = 不限速）
  static const String downloadSpeedLimitBps = 'download.speed_limit_bps';

  // ---- update ----

  /// 更新渠道：stable / beta / dev
  static const String updateChannel = 'update.channel';

  /// 自动更新策略：never / wifi_only / always
  static const String updateAutoUpdatePolicy = 'update.auto_update_policy';

  /// 忽略预发布版本
  static const String updateIgnorePrerelease = 'update.ignore_prerelease';

  /// 静默更新（不弹提示）
  static const String updateSilentUpdate = 'update.silent_update';

  /// 检查更新间隔（小时）
  static const String updateCheckIntervalHours = 'update.check_interval_hours';

  /// 上次检查更新时间（ISO-8601 字符串）
  static const String updateLastCheckTime = 'update.last_check_time';

  /// 上次更新到的版本
  static const String updateLastUpdatedVersion = 'update.last_updated_version';

  // ---- webdav ----

  /// WebDAV 服务器地址
  static const String webdavUrl = 'webdav.url';

  /// WebDAV 用户名
  static const String webdavUsername = 'webdav.username';

  /// WebDAV 密码（敏感，读取时脱敏）
  static const String webdavPassword = 'webdav.password';

  /// WebDAV 备份路径
  static const String webdavBackupPath = 'webdav.backup_path';

  /// 是否启用 HTTPS
  static const String webdavEnableHttps = 'webdav.enable_https';

  // ---- network / catalog ----

  /// GitHub 代理前缀
  static const String proxyUrl = 'network.proxy_url';

  /// 目录库下载地址（远端 catalog DB；空串 = 未配置）
  static const String catalogUrl = 'catalog.source_url';

  // ---- agent ----

  /// Agent 模型列表（JSON，含 API Key，敏感）
  static const String agentModels = 'agent.models';

  /// Agent 当前选中模型 id
  static const String agentSelectedModelId = 'agent.selected_model_id';

  /// Agent 模型列表缓存（JSON：Base URL → 该端点拉取到的模型 ID 列表）
  static const String agentModelCatalog = 'agent.model_catalog';

  // ---- fdroid / discovery ----

  /// F-Droid 源列表（JSON）
  static const String fdroidSources = 'fdroid.sources';

  /// F-Droid 当前源 id
  static const String lastSourceId = 'fdroid.last_source_id';

  /// 发现页选中的渠道（字符串列表）
  static const String selectedChannels = 'discovery.selected_channels';

  // ---- perf ----

  /// 每应用性能档案（JSON：包名 → 档案，见 `PerfProfile`）
  static const String perfProfiles = 'perf.profiles';

  /// 按应用性能模式总开关（false = 不自动应用任何档案；默认关闭 fail-closed）
  static const String perfProfilesEnabled = 'perf.profiles.enabled';

  /// 电池/功耗历史采样器开关（默认关闭；仅用户显式开启性能监控后启动）
  static const String perfHistoryEnabled = 'perf.history.enabled';

  // ---- 模块开关（module.<name>.enabled，见 ModuleToggleConfig.keyOf）----

  /// 渠道模块开关
  static const String moduleChannelEnabled = 'module.channel.enabled';

  /// 下载模块开关
  static const String moduleDownloadEnabled = 'module.download.enabled';

  /// 备份模块开关
  static const String moduleBackupEnabled = 'module.backup.enabled';

  /// WebDAV 模块开关
  static const String moduleWebdavEnabled = 'module.webdav.enabled';

  /// F-Droid 模块开关
  static const String moduleFdroidEnabled = 'module.fdroid.enabled';

  /// 主题模块开关
  static const String moduleThemeEnabled = 'module.theme.enabled';

  /// 安装模块开关
  static const String moduleInstallEnabled = 'module.install.enabled';

  /// 聚合模块开关
  static const String moduleAggregateEnabled = 'module.aggregate.enabled';

  /// Agent 工具模块开关
  static const String moduleAgentToolsEnabled = 'module.agent_tools.enabled';

  /// 更新模块开关（预留，接口就绪前恒启用）
  static const String moduleUpdateEnabled = 'module.update.enabled';

  /// 角标模块开关（预留，接口就绪前恒启用）
  static const String moduleBadgeEnabled = 'module.badge.enabled';

  // ---- proxy 页面持久化 ----

  /// 代理隧道 stack：gvisor / system
  static const String proxyEngineStack = 'proxy.engine_stack';

  /// 代理隧道 MTU（最小 1280）
  static const String proxyEngineMtu = 'proxy.engine_mtu';

  /// 用户选择的路由模式：direct / rule / global
  static const String proxyRoutingMode = 'proxy.routing_mode';

  /// 用户选择的运行模式：off / vpn / lanProxy
  static const String proxyRunMode = 'proxy.run_mode';

  /// 当前选中节点（JSON：`{"group":...,"node":...}`）
  static const String proxyActiveNodeLabel = 'proxy.active_node_label';

  /// 当前选中订阅 profile id
  static const String proxyActiveProfileId = 'proxy.active_profile_id';

  /// 节点弹层排布模式：grid / list
  static const String proxySheetViewMode = 'proxy.sheet_view_mode';

  /// VPN 分流模式：full / allow / disallow
  static const String proxySplitMode = 'proxy.split_mode';

  /// 分流选中的应用清单
  static const String proxySplitApps = 'proxy.split_apps';

  /// 应用侧「始终开启」意图（不直接控制系统开关）
  static const String proxyAlwaysOnIntent = 'proxy.always_on_intent';

  /// 代理日志保留级别：debug / info / warn / error
  static const String proxyLogLevel = 'proxy.log_level';

  /// 全部运行时 wire key（与 Rust 注册表 53 个条目一一对应）。
  ///
  /// 静态守卫（`test/config_keys_grouped_test.dart`）用它检查：都有 `.`、
  /// 无重复、模块前缀都在 [ConfigModules.all] 内、且每个 key 都存在于 Rust
  /// 注册表 fixture 中。
  static const List<String> all = <String>[
    themeConfig,
    themeMode,
    downloadMultiSegmentEnabled,
    downloadWifiOnly,
    downloadMaxConcurrent,
    downloadDefaultConnections,
    downloadMaxRetries,
    downloadSpeedLimitBps,
    updateChannel,
    updateAutoUpdatePolicy,
    updateIgnorePrerelease,
    updateSilentUpdate,
    updateCheckIntervalHours,
    updateLastCheckTime,
    updateLastUpdatedVersion,
    webdavUrl,
    webdavUsername,
    webdavPassword,
    webdavBackupPath,
    webdavEnableHttps,
    proxyUrl,
    catalogUrl,
    agentModels,
    agentSelectedModelId,
    agentModelCatalog,
    fdroidSources,
    lastSourceId,
    selectedChannels,
    perfProfiles,
    perfProfilesEnabled,
    perfHistoryEnabled,
    moduleChannelEnabled,
    moduleDownloadEnabled,
    moduleBackupEnabled,
    moduleWebdavEnabled,
    moduleFdroidEnabled,
    moduleThemeEnabled,
    moduleInstallEnabled,
    moduleAggregateEnabled,
    moduleAgentToolsEnabled,
    moduleUpdateEnabled,
    moduleBadgeEnabled,
    proxyEngineStack,
    proxyEngineMtu,
    proxyRoutingMode,
    proxyRunMode,
    proxyActiveNodeLabel,
    proxyActiveProfileId,
    proxySheetViewMode,
    proxySplitMode,
    proxySplitApps,
    proxyAlwaysOnIntent,
    proxyLogLevel,
  ];
}

/// 旧版（未分组）配置 key —— **仅**用于迁移、旧备份兼容与回滚。
///
/// 运行时代码禁止使用这些字符串：`ConfigService` / `ConfigStore` 只接受
/// [ConfigKeys] 中的分组 wire key。`config_*` / `secure_config_*` 存储键的
/// 映射表属于迁移工具（Todo 21），此处不重复。
class LegacyConfigKeys {
  LegacyConfigKeys._();

  // ---- 旧 ConfigKeys 裸值 ----

  /// 旧主题配置（聚合 JSON）
  static const String themeConfig = 'theme_config';

  /// 旧主题模式
  static const String themeMode = 'theme_mode';

  /// 旧下载配置（聚合 JSON，磁盘上并无此单值）
  static const String downloadConfig = 'download_config';

  /// 旧更新配置（聚合 JSON，磁盘上并无此单值）
  static const String updateConfig = 'update_config';

  /// 旧 WebDAV 配置（聚合 JSON，磁盘上并无此单值）
  static const String webdavConfig = 'webdav_config';

  /// 旧 GitHub 代理前缀
  static const String proxyUrl = 'proxy_url';

  /// 旧目录库地址
  static const String catalogUrl = 'catalog_url';

  /// 旧 Agent 模型列表
  static const String agentModels = 'agent_models';

  /// 旧 Agent 当前选中模型 id
  static const String agentSelectedModelId = 'agent_selected_model_id';

  /// 旧 Agent 模型列表缓存
  static const String agentModelCatalog = 'agent_model_catalog';

  /// 旧 F-Droid 源列表
  static const String fdroidSources = 'fdroid_sources';

  /// 旧 F-Droid 当前源 id
  static const String lastSourceId = 'last_source_id';

  /// 旧发现页选中渠道
  static const String selectedChannels = 'selected_channels';

  // ---- 旧 WebDAV 字段（裸 key，历史 `ConfigRegistry.migrateLegacy` 读取）----

  /// 旧 WebDAV 服务器地址
  static const String webdavUrl = 'webdav_url';

  /// 旧 WebDAV 用户名
  static const String webdavUsername = 'webdav_username';

  /// 旧 WebDAV 密码
  static const String webdavPassword = 'webdav_password';

  /// 旧 WebDAV 备份路径
  static const String webdavBackupPath = 'webdav_backup_path';

  /// 旧 WebDAV HTTPS 开关
  static const String webdavEnableHttps = 'webdav_enable_https';

  /// 全部旧裸 key（迁移工具 / 旧备份适配使用）。
  static const List<String> all = <String>[
    themeConfig,
    themeMode,
    downloadConfig,
    updateConfig,
    webdavConfig,
    proxyUrl,
    catalogUrl,
    agentModels,
    agentSelectedModelId,
    agentModelCatalog,
    fdroidSources,
    lastSourceId,
    selectedChannels,
    webdavUrl,
    webdavUsername,
    webdavPassword,
    webdavBackupPath,
    webdavEnableHttps,
  ];
}

/// 内置配置元数据（与 Rust `schema.rs` 逐项对齐）。
///
/// 仅在水合前作为同步元数据兜底；`ConfigService.ensureReady()` 之后以 Rust
/// `ConfigApi.list()` 为准。字段含义：
/// - `type` / `defaultValue`：Rust `value_type` / `default_json`
/// - `sensitive`：Rust `sensitive`（Secret 项必为 true）
/// - `agentAccessible`：Rust `agent_accessible`
/// - `description` / `descriptionEn`：Rust `description_zh` / `description_en`
const List<ConfigEntry> _appCoreConfigEntries = <ConfigEntry>[
  // ---- theme ----
  ConfigEntry(
    key: ConfigKeys.themeConfig,
    type: ConfigValueType.json,
    defaultValue: <String, dynamic>{},
    agentAccessible: true,
    category: 'theme',
    example: '{"fontStyle":3}',
    description: '主题配置（颜色/字体/圆角等 JSON；字段值用数字索引，空对象表示使用默认主题）',
    descriptionEn:
        'Theme config (colors/font/radius JSON; numeric field indices; empty object = defaults)',
  ),
  ConfigEntry(
    key: ConfigKeys.themeMode,
    type: ConfigValueType.int,
    defaultValue: 0,
    agentAccessible: true,
    enumValues: ['0', '1', '2'],
    category: 'theme',
    description: '主题模式：0=跟随系统 1=浅色 2=深色',
    descriptionEn: 'Theme mode: 0=system 1=light 2=dark',
  ),
  // ---- download ----
  ConfigEntry(
    key: ConfigKeys.downloadMultiSegmentEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    agentAccessible: true,
    category: 'download',
    description: '多段下载开关（关闭后单连接下载）',
    descriptionEn: 'Multi-segment download toggle (off = single connection)',
  ),
  ConfigEntry(
    key: ConfigKeys.downloadWifiOnly,
    type: ConfigValueType.bool,
    defaultValue: false,
    agentAccessible: true,
    category: 'download',
    description: '仅在 Wi-Fi 下下载',
    descriptionEn: 'Download only over Wi-Fi',
  ),
  ConfigEntry(
    key: ConfigKeys.downloadMaxConcurrent,
    type: ConfigValueType.int,
    defaultValue: 3,
    agentAccessible: true,
    min: 1,
    max: 10,
    category: 'download',
    description: '最大并发下载任务数（1-10）',
    descriptionEn: 'Maximum concurrent download tasks (1-10)',
  ),
  ConfigEntry(
    key: ConfigKeys.downloadDefaultConnections,
    type: ConfigValueType.int,
    defaultValue: 4,
    agentAccessible: true,
    min: 1,
    category: 'download',
    description: '启用多段下载时单任务默认连接数（分段数）',
    descriptionEn:
        'Default per-task connections (segments) when multi-segment is enabled',
  ),
  ConfigEntry(
    key: ConfigKeys.downloadMaxRetries,
    type: ConfigValueType.int,
    defaultValue: 3,
    agentAccessible: true,
    min: 0,
    max: 5,
    category: 'download',
    description: '下载失败最大重试次数（0-5）',
    descriptionEn: 'Maximum download retries (0-5)',
  ),
  ConfigEntry(
    key: ConfigKeys.downloadSpeedLimitBps,
    type: ConfigValueType.int,
    defaultValue: 0,
    agentAccessible: true,
    min: 0,
    unit: 'B/s',
    category: 'download',
    description: '全局限速（字节/秒，0 表示不限速）',
    descriptionEn: 'Global speed limit in bytes/second (0 = unlimited)',
  ),
  // ---- update ----
  ConfigEntry(
    key: ConfigKeys.updateChannel,
    type: ConfigValueType.string,
    defaultValue: 'stable',
    agentAccessible: true,
    enumValues: ['stable', 'beta', 'dev'],
    category: 'update',
    description: '更新渠道：stable / beta / dev',
    descriptionEn: 'Update channel: stable / beta / dev',
  ),
  ConfigEntry(
    key: ConfigKeys.updateAutoUpdatePolicy,
    type: ConfigValueType.string,
    defaultValue: 'wifi_only',
    agentAccessible: true,
    enumValues: ['never', 'wifi_only', 'always'],
    category: 'update',
    description: '自动更新策略：never / wifi_only / always（字符串，不使用枚举索引）',
    descriptionEn:
        'Auto-update policy: never / wifi_only / always (strings, not enum indices)',
  ),
  ConfigEntry(
    key: ConfigKeys.updateIgnorePrerelease,
    type: ConfigValueType.bool,
    defaultValue: true,
    agentAccessible: true,
    category: 'update',
    description: '忽略预发布版本',
    descriptionEn: 'Ignore prerelease versions',
  ),
  ConfigEntry(
    key: ConfigKeys.updateSilentUpdate,
    type: ConfigValueType.bool,
    defaultValue: false,
    agentAccessible: true,
    category: 'update',
    description: '静默更新（不弹提示）',
    descriptionEn: 'Silent update (no prompt)',
  ),
  ConfigEntry(
    key: ConfigKeys.updateCheckIntervalHours,
    type: ConfigValueType.int,
    defaultValue: 24,
    agentAccessible: true,
    category: 'update',
    description: '检查更新间隔（小时）',
    descriptionEn: 'Update check interval in hours',
  ),
  ConfigEntry(
    key: ConfigKeys.updateLastCheckTime,
    type: ConfigValueType.string,
    defaultValue: '',
    agentAccessible: true,
    category: 'update',
    description: '上次检查更新时间（ISO-8601 字符串，空串表示从未检查）',
    descriptionEn:
        'Last update check time (ISO-8601 string; empty = never checked)',
  ),
  ConfigEntry(
    key: ConfigKeys.updateLastUpdatedVersion,
    type: ConfigValueType.string,
    defaultValue: '',
    agentAccessible: true,
    category: 'update',
    description: '上次更新到的版本（空串表示从未更新）',
    descriptionEn: 'Last updated version (empty = never updated)',
  ),
  // ---- webdav ----
  ConfigEntry(
    key: ConfigKeys.webdavUrl,
    type: ConfigValueType.string,
    defaultValue: '',
    sensitive: true,
    agentAccessible: true,
    category: 'webdav',
    example: 'https://dav.example.com/remote.php/dav/files/user',
    description: 'WebDAV 服务器地址',
    descriptionEn: 'WebDAV server URL',
  ),
  ConfigEntry(
    key: ConfigKeys.webdavUsername,
    type: ConfigValueType.string,
    defaultValue: '',
    sensitive: true,
    agentAccessible: true,
    category: 'webdav',
    description: 'WebDAV 用户名',
    descriptionEn: 'WebDAV username',
  ),
  ConfigEntry(
    key: ConfigKeys.webdavPassword,
    type: ConfigValueType.string,
    defaultValue: '',
    sensitive: true,
    category: 'webdav',
    description: 'WebDAV 密码（仅 owner 可读，读取时脱敏）',
    descriptionEn: 'WebDAV password (owner-only, masked on read)',
  ),
  ConfigEntry(
    key: ConfigKeys.webdavBackupPath,
    type: ConfigValueType.string,
    defaultValue: '/GStore',
    sensitive: true,
    agentAccessible: true,
    category: 'webdav',
    description: 'WebDAV 备份路径',
    descriptionEn: 'WebDAV backup path',
  ),
  ConfigEntry(
    key: ConfigKeys.webdavEnableHttps,
    type: ConfigValueType.bool,
    defaultValue: true,
    sensitive: true,
    agentAccessible: true,
    category: 'webdav',
    description: '是否启用 HTTPS',
    descriptionEn: 'Whether HTTPS is enabled',
  ),
  // ---- network / catalog ----
  ConfigEntry(
    key: ConfigKeys.proxyUrl,
    type: ConfigValueType.string,
    defaultValue: '',
    agentAccessible: true,
    category: 'network',
    example: 'https://gh-proxy.org/',
    description: 'GitHub 代理前缀（空串表示不使用）',
    descriptionEn: 'GitHub proxy prefix (empty = disabled)',
  ),
  ConfigEntry(
    key: ConfigKeys.catalogUrl,
    type: ConfigValueType.string,
    defaultValue: 'https://github.com/sunO2/GStore-Repositorys',
    agentAccessible: true,
    category: 'catalog',
    example: 'https://github.com/<owner>/<repo>',
    description: '目录库地址：GitHub 仓库地址或直接的 .db 下载地址（空串 = 未配置）',
    descriptionEn:
        'Catalog source: GitHub repo URL or direct .db URL (empty = unset)',
  ),
  // ---- agent ----
  ConfigEntry(
    key: ConfigKeys.agentModels,
    type: ConfigValueType.json,
    defaultValue: <dynamic>[],
    sensitive: true,
    category: 'agent',
    description: 'Agent 模型列表（JSON 数组，含 API Key；仅 owner 可读）',
    descriptionEn:
        'Agent model list (JSON array, includes API keys; owner-only)',
  ),
  ConfigEntry(
    key: ConfigKeys.agentSelectedModelId,
    type: ConfigValueType.string,
    defaultValue: '',
    agentAccessible: true,
    category: 'agent',
    description: 'Agent 当前选中模型 ID',
    descriptionEn: 'Agent selected model ID',
  ),
  ConfigEntry(
    key: ConfigKeys.agentModelCatalog,
    type: ConfigValueType.json,
    defaultValue: <String, dynamic>{},
    category: 'agent',
    description: 'Agent 模型列表缓存（Base URL → 模型 ID 列表）',
    descriptionEn: 'Agent model list cache (base URL -> model ID list)',
  ),
  // ---- fdroid / discovery ----
  ConfigEntry(
    key: ConfigKeys.fdroidSources,
    type: ConfigValueType.json,
    defaultValue: <dynamic>[],
    category: 'fdroid',
    description: 'F-Droid 源列表（JSON 数组）',
    descriptionEn: 'F-Droid source list (JSON array)',
  ),
  ConfigEntry(
    key: ConfigKeys.lastSourceId,
    type: ConfigValueType.string,
    defaultValue: '',
    category: 'fdroid',
    description: 'F-Droid 当前源 ID',
    descriptionEn: 'F-Droid current source ID',
  ),
  ConfigEntry(
    key: ConfigKeys.selectedChannels,
    type: ConfigValueType.stringList,
    defaultValue: <String>[],
    category: 'discovery',
    description: '发现页选中的渠道',
    descriptionEn: 'Selected channels on the discovery page',
  ),
  // ---- perf ----
  ConfigEntry(
    key: ConfigKeys.perfProfiles,
    type: ConfigValueType.json,
    defaultValue: <String, dynamic>{},
    category: 'perf',
    example: '{"com.example.app":{"enabled":true,"gpu_level":2}}',
    description: '每应用性能档案（JSON：包名 → 档案，空对象 = 无档案）',
    descriptionEn:
        'Per-app performance profiles (JSON: package -> profile; empty = none)',
  ),
  ConfigEntry(
    key: ConfigKeys.perfProfilesEnabled,
    type: ConfigValueType.bool,
    defaultValue: false,
    category: 'perf',
    description: '按应用性能模式总开关（默认关闭）',
    descriptionEn: 'Per-app performance mode master switch (default off)',
  ),
  ConfigEntry(
    key: ConfigKeys.perfHistoryEnabled,
    type: ConfigValueType.bool,
    defaultValue: false,
    category: 'perf',
    description: '电池/功耗历史采样器开关（默认关闭）',
    descriptionEn: 'Battery/power history sampler switch (default off)',
  ),
  // ---- 模块开关 ----
  ConfigEntry(
    key: ConfigKeys.moduleChannelEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: '渠道模块开关',
    descriptionEn: 'Channel module toggle',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleDownloadEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: '下载模块开关',
    descriptionEn: 'Download module toggle',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleBackupEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: '备份模块开关',
    descriptionEn: 'Backup module toggle',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleWebdavEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: 'WebDAV 模块开关',
    descriptionEn: 'WebDAV module toggle',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleFdroidEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: 'F-Droid 模块开关',
    descriptionEn: 'F-Droid module toggle',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleThemeEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: '主题模块开关',
    descriptionEn: 'Theme module toggle',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleInstallEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: '安装模块开关',
    descriptionEn: 'Install module toggle',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleAggregateEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: '聚合模块开关',
    descriptionEn: 'Aggregate module toggle',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleAgentToolsEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: 'Agent 工具模块开关',
    descriptionEn: 'Agent tools module toggle',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleUpdateEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: '更新模块开关（预留，接口就绪前恒启用）',
    descriptionEn: 'Update module toggle (reserved, always on)',
  ),
  ConfigEntry(
    key: ConfigKeys.moduleBadgeEnabled,
    type: ConfigValueType.bool,
    defaultValue: true,
    category: 'module',
    description: '角标模块开关（预留，接口就绪前恒启用）',
    descriptionEn: 'Badge module toggle (reserved, always on)',
  ),
  // ---- proxy 页面持久化 ----
  ConfigEntry(
    key: ConfigKeys.proxyEngineStack,
    type: ConfigValueType.string,
    defaultValue: 'gvisor',
    enumValues: ['gvisor', 'system'],
    category: 'proxy',
    description: '代理隧道 stack：gvisor / system',
    descriptionEn: 'Proxy tunnel stack: gvisor / system',
  ),
  ConfigEntry(
    key: ConfigKeys.proxyEngineMtu,
    type: ConfigValueType.int,
    defaultValue: 1500,
    min: 1280,
    unit: 'bytes',
    category: 'proxy',
    description: '代理隧道 MTU（最小 1280）',
    descriptionEn: 'Proxy tunnel MTU (minimum 1280)',
  ),
  ConfigEntry(
    key: ConfigKeys.proxyRoutingMode,
    type: ConfigValueType.string,
    defaultValue: 'rule',
    enumValues: ['direct', 'rule', 'global'],
    category: 'proxy',
    description: '用户选择的路由模式：direct / rule / global',
    descriptionEn: 'User-selected routing mode: direct / rule / global',
  ),
  ConfigEntry(
    key: ConfigKeys.proxyRunMode,
    type: ConfigValueType.string,
    defaultValue: 'vpn',
    enumValues: ['off', 'vpn', 'lanProxy'],
    category: 'proxy',
    description: '用户选择的运行模式：off / vpn / lanProxy',
    descriptionEn: 'User-selected run mode: off / vpn / lanProxy',
  ),
  ConfigEntry(
    key: ConfigKeys.proxyActiveNodeLabel,
    type: ConfigValueType.json,
    defaultValue: <String, dynamic>{},
    category: 'proxy',
    description: '当前选中节点（JSON：{"group":...,"node":...}）',
    descriptionEn: 'Active node selection (JSON: {"group":...,"node":...})',
  ),
  ConfigEntry(
    key: ConfigKeys.proxyActiveProfileId,
    type: ConfigValueType.string,
    defaultValue: '',
    category: 'proxy',
    description: '当前选中订阅 profile id',
    descriptionEn: 'Active subscription profile id',
  ),
  ConfigEntry(
    key: ConfigKeys.proxySheetViewMode,
    type: ConfigValueType.string,
    defaultValue: 'list',
    enumValues: ['grid', 'list'],
    category: 'proxy',
    description: '节点弹层排布模式：grid / list（未设置回落到 list）',
    descriptionEn:
        'Node sheet layout: grid / list (unset falls back to list)',
  ),
  ConfigEntry(
    key: ConfigKeys.proxySplitMode,
    type: ConfigValueType.string,
    defaultValue: 'full',
    enumValues: ['full', 'allow', 'disallow'],
    category: 'proxy',
    description: 'VPN 分流模式：full / allow / disallow',
    descriptionEn: 'VPN split-tunnel mode: full / allow / disallow',
  ),
  ConfigEntry(
    key: ConfigKeys.proxySplitApps,
    type: ConfigValueType.stringList,
    defaultValue: <String>[],
    category: 'proxy',
    description: '分流选中的应用清单',
    descriptionEn: 'Selected apps for split tunneling',
  ),
  ConfigEntry(
    key: ConfigKeys.proxyAlwaysOnIntent,
    type: ConfigValueType.bool,
    defaultValue: false,
    category: 'proxy',
    description: '应用侧「始终开启」意图（不直接控制系统开关）',
    descriptionEn: 'App-side always-on intent (does not toggle the system switch)',
  ),
  ConfigEntry(
    key: ConfigKeys.proxyLogLevel,
    type: ConfigValueType.string,
    defaultValue: 'info',
    enumValues: ['debug', 'info', 'warn', 'error'],
    category: 'proxy',
    description: '代理日志保留级别：debug / info / warn / error',
    descriptionEn: 'Proxy log level: debug / info / warn / error',
  ),
];

/// 应用核心配置模块（**已废弃的兼容壳**）
///
/// Rust 注册表是唯一事实来源；本类只保留旧调用方（`DownloadModule` 与若干
/// 存量测试）的编译兼容，返回与 Rust 对齐的元数据列表。水合后
/// `ConfigService.registerModule()` 是 no-op（C2），Todo 32 删除。
class AppCoreConfigModule extends ConfigModule {
  AppCoreConfigModule();

  @override
  String get moduleName => 'app_core';

  @override
  List<ConfigEntry> get configs => _appCoreConfigEntries;

  @override
  void registerProviders(ConfigService service) {
    // 桥接已由 Rust 注册表水合取代，无需 provider。
  }
}

/// 内置注册表
class ConfigRegistry {
  ConfigRegistry._();

  /// 全部内置配置项（与 Rust 注册表逐项对齐的元数据）
  static List<ConfigEntry> get entries => _appCoreConfigEntries;

  /// 注册全部内置配置项（旧入口，保留兼容；水合后 no-op）
  static void registerAll(ConfigService service) {
    service.registerModule(AppCoreConfigModule());
  }

  /// 存量迁移：将散落的旧 prefs key 迁移到统一存储
  ///
  /// 策略：读旧值 → 写入统一存储（旧 key 原样保留）→ 删除旧 prefs key。
  /// 只读取 [LegacyConfigKeys]，绝不把旧裸 key 当作运行时 key。
  /// 说明：完整的分组 wire key 映射由 `ConfigMigrationTool`（Todo 21）负责，
  /// 本方法仅为 Todo 17 移除前的兼容路径。
  static Future<void> migrateLegacy(ConfigStore store) async {
    final prefs = await SharedPreferences.getInstance();

    for (final key in LegacyConfigKeys.all) {
      try {
        final value = prefs.get(key);
        if (value == null) continue;
        // 写入统一存储（ConfigStore 自动加 config_ 前缀）
        await store.write(key, value);
        await prefs.remove(key);
        debugPrint(
            'ConfigRegistry: 迁移配置 $key -> ${store.isSensitive(key) ? 'secure' : 'normal'} 存储');
      } catch (e) {
        debugPrint('ConfigRegistry: 迁移配置 $key 失败 - $e');
      }
    }
  }
}

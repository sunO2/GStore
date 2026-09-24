/// 代理设置页（Todo 23）展示层门面 + 持久化 / 平台接缝。
///
/// 冻结的 [ProxyFacade]（`lib/core/rust/proxy/ProxyModule.dart`）只暴露
/// `ping` / `version` / `events`；设置页需要 `log.set_level` /
/// `stats.domain.reset` / 引擎调试信息，以及本地分流 / 常驻 / 端口的**持久化**。
/// 为**不改动冻结契约**，这里定义窄接口 [ProxySettingsFacade]，生产环境用
/// [ProxyModuleSettingsFacade] 组合 [ProxyModule] + [ConfigStore] +
/// `installed_apps` 插件 + [ProxyVpnTrigger]；测试注入假实现即可。
///
/// 职责边界（重要）：
/// * **分流模式 + 应用清单**：持久化到应用侧配置，并映射为 `ProxyVpnService`
///   的配置 JSON（`mode` / `allowedApps` / `disallowedApps`）。绝不
///   `addDisallowedApplication(self)`——环路由宿主 `protect_fd` 解决（Todo 4），
///   分流模式允许列表兜底保证本应用永不出现在 `disallowedApps` 中。
/// * **始终开启**：应用**无法**直接切换系统「始终开启的 VPN」。此处只持久化
///   「应用侧意图」，并在服务运行中把它并入推送的配置；系统重启（null Intent）
///   由 Kotlin 侧持久化配置恢复。系统开关须用户在系统设置手动开启。
/// * **LAN 入站**（[ProxyLanConfig]）：经 `lan.get` / `lan.set` /
///   `lan.status` 下发内核（Todo 28），默认关闭；未配置认证时展示安全警告。
/// * **引擎侧设置**（[ProxyEngineSettings]）：stack / mtu 应用侧持久化，
///   启动引擎时由首页读取并入 `core.start`。
/// * **日志级别 / 重置统计**：`log.set_level` / `stats.domain.reset`。
/// * **引擎调试信息**：`version` / `ping` / `core.get_mode`（模块不可用时降级）。
///
/// **纯展示 / 转发层**：不含解析 / 网络 / 路由 / 统计逻辑（全部在 Rust 的
/// `gstore_mod_proxy`）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/service/proxy_vpn_service.dart';
import 'package:gstore/page/proxy/proxy_engine_settings_store.dart';
import 'package:installed_apps/installed_apps.dart' as installed;

// `ProxyLanConfig` / `ProxyLanStatus` 已迁至冻结契约 `ProxyContract.dart`；此处
// 再导出，使既有 `import 'proxy_settings_facade.dart'` 的调用方无需改动。
// 弱网模拟（`net.shaper.*`）模型同样再导出，供设置页（Todo 14）与预设表直接使用。
export 'package:gstore/core/rust/proxy/ProxyContract.dart'
    show
        ProxyLanConfig,
        ProxyLanStatus,
        ProxyShaperConfig,
        ProxyShaperDirection,
        ProxyShaperCounters,
        ProxyShaperSnapshot;

/// 本应用包名。
///
/// 分流「排除应用」列表必须过滤掉它：Todo 4 决策规定**绝不**
/// `addDisallowedApplication(self)`（环路修复走宿主 `protect_fd`）。
const String kGStorePackageName = 'com.suno2.gstore';

/// `ProxyVpnService` 的 TUN 接口地址（IPv4 + RFC 4193 ULA IPv6）。
///
/// **必须始终是合法 CIDR**：Kotlin 侧会逐条校验，非法地址被过滤，若地址集为空
/// 则启动以 `start_failed` 终止（F2 缺陷：曾依赖非法默认 IPv6 导致永不连通）。
const List<String> kProxyVpnAddresses = <String>['10.10.0.2/32', 'fd00::1/128'];

/// 全量默认路由（IPv4 + IPv6），保证 `full` 隧道语义。
const List<String> kProxyVpnRoutes = <String>['0.0.0.0/0', '::/0'];

/// 隧道内 DNS 服务器（由 Rust 模块的 UDP:53 劫持作答）。
///
/// 必须满足：① 不是 TUN 自身地址（`kProxyVpnAddresses` = 10.10.0.2 / fd00::1，
/// 发往自身地址的包不会进 TUN）；② 不落在 fake-IP 池 `198.18.0.0/16` 内；
/// ③ 被 `0.0.0.0/0` 路由捕获。10.10.0.1 同时满足三点。
/// 说明：这只让「明文 UDP:53」确定性进入劫持；Android「私人 DNS」(DoT/853)
/// 仍绕过它（见 rust/gstore_mod_proxy/API.md §9.3）。
const List<String> kProxyVpnDnsServers = <String>['10.10.0.1'];

// ==================== 分流模式 ====================

/// `ProxyVpnService` 的三个隧道模式（Kotlin `parseConfig` 的 `mode`）。
enum ProxySplitTunnelMode {
  /// 全局：所有应用走代理。
  full('full', '全局'),

  /// 仅选中应用走代理（`allowedApps`）。
  allow('allow', '仅选中应用'),

  /// 除选中应用外走代理（`disallowedApps`）。
  disallow('disallow', '排除选中应用');

  const ProxySplitTunnelMode(this.wire, this.label);

  /// Kotlin 配置 JSON 中的字面值。
  final String wire;

  /// 界面展示名。
  final String label;

  static ProxySplitTunnelMode fromWire(Object? value) {
    final s = value?.toString();
    for (final mode in values) {
      if (mode.wire == s) return mode;
    }
    return ProxySplitTunnelMode.full;
  }
}

// ==================== 聚合配置 ====================

/// 设置页聚合的本地配置（持久化单元）。
@immutable
class ProxySettingsConfig {
  const ProxySettingsConfig({
    this.splitMode = ProxySplitTunnelMode.full,
    this.selectedApps = const <String>{},
    this.alwaysOnIntent = false,
    this.logLevel = ProxyLogLevel.info,
  });

  /// 分流模式。
  final ProxySplitTunnelMode splitMode;

  /// 分流的应用清单（`allow` 为白名单 / `disallow` 为排除名单）。
  final Set<String> selectedApps;

  /// 应用侧「始终开启」意图（不直接控制系统开关）。
  final bool alwaysOnIntent;

  /// 日志保留级别（`log.set_level`）。
  final ProxyLogLevel logLevel;

  ProxySettingsConfig copyWith({
    ProxySplitTunnelMode? splitMode,
    Set<String>? selectedApps,
    bool? alwaysOnIntent,
    ProxyLogLevel? logLevel,
  }) =>
      ProxySettingsConfig(
        splitMode: splitMode ?? this.splitMode,
        selectedApps: selectedApps ?? this.selectedApps,
        alwaysOnIntent: alwaysOnIntent ?? this.alwaysOnIntent,
        logLevel: logLevel ?? this.logLevel,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'splitMode': splitMode.wire,
        'selectedApps': selectedApps.toList(),
        'alwaysOnIntent': alwaysOnIntent,
        'logLevel': logLevel.wire,
      };

  factory ProxySettingsConfig.fromMap(Map<String, dynamic> map) {
    final rawApps = map['selectedApps'];
    return ProxySettingsConfig(
      splitMode: ProxySplitTunnelMode.fromWire(map['splitMode']),
      selectedApps: rawApps is List
          ? rawApps.map((e) => e.toString()).toSet()
          : const <String>{},
      alwaysOnIntent: map['alwaysOnIntent'] == true,
      logLevel: ProxyLogLevel.fromWire(map['logLevel']),
    );
  }

  /// 生成 `ProxyVpnService` 的配置 JSON。
  ///
  /// 始终携带显式的 [kProxyVpnAddresses] / [kProxyVpnRoutes]（合法 CIDR），
  /// 使 Kotlin `parseConfig` 不再依赖其内置默认值（F2 修复：旧默认 IPv6 非法，
  /// 导致 `addAddress` 抛异常、VPN 永不连通）。
  ///
  /// * `full` → 不写应用清单（Kotlin 默认全局）。
  /// * `allow` → `allowedApps` = 选中清单。
  /// * `disallow` → `disallowedApps` = 选中清单**去掉本应用**
  ///   （Todo 4：绝不 `addDisallowedApplication(self)`）。
  /// * `dns` 显式设为 [kProxyVpnDnsServers]（隧道内 DNS），使系统明文 UDP:53
  ///   查询确定性进入 TUN，由 Rust 模块（fake-IP 劫持）作答；不再依赖底层
  ///   网络提供的 DNS。注意：Android「私人 DNS」(DoT/853) 不经 UDP:53，
  ///   仍绕过该劫持。
  String toVpnConfigJson() {
    final apps = selectedApps.toList()..sort();
    final payload = <String, dynamic>{
      'mode': splitMode.wire,
      'addresses': kProxyVpnAddresses,
      'routes': kProxyVpnRoutes,
      'dns': kProxyVpnDnsServers,
    };
    switch (splitMode) {
      case ProxySplitTunnelMode.full:
        break;
      case ProxySplitTunnelMode.allow:
        payload['allowedApps'] = apps;
        break;
      case ProxySplitTunnelMode.disallow:
        payload['disallowedApps'] =
            apps.where((pkg) => pkg != kGStorePackageName).toList();
        break;
    }
    return jsonEncode(payload);
  }

  /// 本分流配置是否**恰为** [appAllowlist] 的合法镜像（`allow` + 集合相等）。
  ///
  /// 抓包应用范围（`capture.config.appScope == routing`）时，「哪些应用」的单一
  /// 数据源是 `capture.config.appAllowlist`；VPN `allowedApps` 只是它的派生镜像。
  /// 一旦不再相等（用户改了分流模式 / 清单）即视为**漂移**——调用方据此自动关闭
  /// 抓包，绝不在 Dart 侧静默重写用户路由。
  bool mirrorsAppAllowlist(List<String> appAllowlist) {
    if (splitMode != ProxySplitTunnelMode.allow) return false;
    final expected = appAllowlist.toSet();
    if (selectedApps.length != expected.length) return false;
    return selectedApps.containsAll(expected);
  }
}

// ==================== 抓包应用范围 ↔ VPN 分流耦接 ====================

/// 抓包应用范围（`appScope == routing`）与 VPN 分流耦合所需的最小接缝。
///
/// * [loadSplitTunnel]：读取持久化分流配置（镜像判定 / 漂移检测）。
/// * [saveSplitTunnel]：把 `allow` + 镜像清单持久化，并推送给运行中的
///   `ProxyVpnService`（`allowedApps` 即时生效）。
///
/// 「哪些应用」的单一数据源是 `capture.config.appAllowlist`；本接缝是
/// `appScope=routing` 时把该清单**派生镜像**为 VPN `allowedApps` 的唯一写入点，
/// 页面不得各自另建清单。
abstract class ProxySplitTunnelFacade {
  Future<ProxySettingsConfig> loadSplitTunnel();

  Future<void> saveSplitTunnel({
    required ProxySplitTunnelMode mode,
    required Set<String> apps,
  });
}

// ==================== 已安装应用 ====================

/// 分流选择器中的已安装应用项（仅包名 + 名称；不拉取图标，避免慢加载）。
@immutable
class InstalledAppOption {
  const InstalledAppOption({required this.packageName, required this.name});

  final String packageName;
  final String name;
}

/// 已安装应用来源接缝（生产 = `installed_apps` 插件；测试注入假实现）。
abstract class ProxyInstalledAppsProvider {
  /// 返回用户应用（**排除系统应用**）；失败时返回空列表（绝不抛错）。
  Future<List<InstalledAppOption>> list();
}

/// 生产实现：`installed_apps` 平台通道（`QUERY_ALL_PACKAGES` 已在清单声明）。
class PlatformInstalledAppsProvider implements ProxyInstalledAppsProvider {
  const PlatformInstalledAppsProvider();

  @override
  Future<List<InstalledAppOption>> list() async {
    try {
      final apps = await installed.InstalledApps.getInstalledApps(
        true, // excludeSystemApps
        false, // withIcon（不取图标，避免慢加载）
      );
      final options = apps
          .where((app) => app.packageName.isNotEmpty)
          .map((app) => InstalledAppOption(
                packageName: app.packageName,
                name: app.name.isEmpty ? app.packageName : app.name,
              ))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return options;
    } catch (_) {
      // 权限缺失 / 平台异常 → 空列表（UI 显示显式空态，不崩溃）
      return const <InstalledAppOption>[];
    }
  }
}

// ==================== 持久化 ====================

/// 设置持久化接缝（生产 = [ConfigStore]；测试可注入内存实现）。
abstract class ProxySettingsStore {
  Future<ProxySettingsConfig> read();

  Future<void> write(ProxySettingsConfig config);
}

/// 生产实现：统一 [ConfigStore]（共享偏好 / 加密存储自动路由）。
class ConfigStoreProxySettingsStore implements ProxySettingsStore {
  const ConfigStoreProxySettingsStore();

  static const String _keySplitMode = 'proxy_split_mode';
  static const String _keySelectedApps = 'proxy_split_apps';
  static const String _keyAlwaysOn = 'proxy_always_on_intent';
  static const String _keyLogLevel = 'proxy_log_level';

  @override
  Future<ProxySettingsConfig> read() async {
    final store = ConfigStore.instance;
    final mode = await store.readString(_keySplitMode);
    final apps = await _readStringList(store, _keySelectedApps);
    final alwaysOn = await store.readBool(_keyAlwaysOn) ?? false;
    final logLevel = await store.readString(_keyLogLevel);
    return ProxySettingsConfig(
      splitMode: ProxySplitTunnelMode.fromWire(mode),
      selectedApps: apps.toSet(),
      alwaysOnIntent: alwaysOn,
      logLevel: logLevel == null
          ? ProxyLogLevel.info
          : ProxyLogLevel.fromWire(logLevel),
    );
  }

  @override
  Future<void> write(ProxySettingsConfig config) async {
    final store = ConfigStore.instance;
    await store.writeString(_keySplitMode, config.splitMode.wire);
    await store.write(_keySelectedApps, config.selectedApps.toList());
    await store.write(_keyAlwaysOn, config.alwaysOnIntent);
    await store.writeString(_keyLogLevel, config.logLevel.wire);
  }

  Future<List<String>> _readStringList(ConfigStore store, String key) async {
    final raw = await store.readValue(key);
    if (raw is List) return raw.map((e) => e.toString()).toList();
    if (raw is String && raw.isNotEmpty) return raw.split(',');
    return const <String>[];
  }
}

/// 连接路径专用：读取持久化设置并生成 Kotlin `ProxyVpnService` 配置 JSON。
///
/// 供 VPN 首页在 `prepare()` 前调用（Todo 23 → Todo 24 交接：连接必须带上
/// 分流模式 / 应用清单，而不是硬编码 `{}`）。读取失败时返回 `{}`（全量路由默认）。
Future<String> loadProxyVpnConfigJson({ProxySettingsStore? store}) async {
  try {
    final config = await (store ?? const ConfigStoreProxySettingsStore()).read();
    return config.toVpnConfigJson();
  } catch (_) {
    return '{}';
  }
}

// ==================== VPN 配置应用接缝 ====================
/// 把分流配置**推送给运行中的** `ProxyVpnService`。
///
/// 应用**不**在设置页主动拉起 VPN 授权（避免误触系统同意弹窗）：
/// * 服务未运行 → 仅持久化，下次连接使用；
/// * 服务运行中 → 用新配置重启其 `onStartCommand`（`mode` / 应用清单即时生效）。
abstract class ProxyVpnConfigApplier {
  Future<void> apply(String configJson);
}

/// 生产实现：经 [ProxyVpnTrigger] 平台通道（`isRunning` → `start`）。
class PlatformProxyVpnConfigApplier implements ProxyVpnConfigApplier {
  const PlatformProxyVpnConfigApplier();

  @override
  Future<void> apply(String configJson) async {
    if (!await ProxyVpnTrigger.isRunning()) return;
    await ProxyVpnTrigger.start(configJson: configJson);
  }
}

// ==================== 引擎调试信息 ====================

/// 引擎调试信息聚合（模块不可用时各字段为 null，不抛错）。
@immutable
class ProxyEngineInfo {
  const ProxyEngineInfo({this.version, this.ping, this.mode});

  final ProxyVersionInfo? version;
  final ProxyPingResult? ping;
  final CoreModeResult? mode;

  /// 三项皆空表示模块不可用 / 未安装。
  bool get isEmpty => version == null && ping == null && mode == null;
}

// ==================== 门面 ====================

/// 设置页所需的模块能力 + 本地持久化 + 平台接缝。
abstract class ProxySettingsFacade {
  /// 读取本地聚合配置。
  Future<ProxySettingsConfig> loadSettings();

  /// 保存分流模式 + 应用清单（持久化并推送给运行中的服务）。
  Future<void> saveSplitTunnel({
    required ProxySplitTunnelMode mode,
    required Set<String> apps,
  });

  /// 持久化「始终开启」应用侧意图。
  Future<void> setAlwaysOnIntent(bool value);

  /// 读取引擎侧设置（stack / mtu；应用侧持久化）。
  Future<ProxyEngineSettings> loadEngineSettings();

  /// 保存引擎侧设置（应用侧持久化）。
  Future<void> saveEngineSettings(ProxyEngineSettings settings);

  /// `lan.get`：读取 LAN 入站配置。
  Future<ProxyLanConfig> loadLanConfig();

  /// `lan.status`：读取 LAN 监听状态。
  Future<ProxyLanStatus> loadLanStatus();

  /// `lan.set`：下发 LAN 配置并返回最新状态。
  Future<ProxyLanStatus> saveLanConfig(ProxyLanConfig config);

  /// `net.shaper.get`：读取弱网配置（意图 + 引擎生效）+ 运行态 + 计数器。
  Future<ProxyShaperSnapshot> loadShaperConfig();

  /// `net.shaper.set`：下发弱网配置并返回最新快照。
  Future<ProxyShaperSnapshot> saveShaperConfig(ProxyShaperConfig config);

  /// `log.set_level` + 本地持久化。
  Future<LogSetLevelResult> setLogLevel(ProxyLogLevel level);

  /// `stats.domain.reset`。
  Future<StatsResetResult> resetStats();

  /// 读取已安装应用（失败返回空列表）。
  Future<List<InstalledAppOption>> loadInstalledApps();

  /// 读取引擎调试信息（模块三调用，各自降级）。
  Future<ProxyEngineInfo> loadEngineInfo();
}

/// 生产适配器：组合 [ProxyModule] + [ProxySettingsStore] +
/// [ProxyInstalledAppsProvider] + [ProxyVpnConfigApplier]。
///
/// 构造不触碰 FFI / 平台通道；只有调用方法时才按需访问。
class ProxyModuleSettingsFacade
    implements ProxySettingsFacade, ProxySplitTunnelFacade {
  ProxyModuleSettingsFacade({
    ProxyModule? module,
    ProxySettingsStore? store,
    ProxyInstalledAppsProvider? appsProvider,
    ProxyVpnConfigApplier? applier,
    ProxyEngineSettingsStore? engineStore,
  })  : _module = module ?? ProxyModule.instance,
        _store = store ?? const ConfigStoreProxySettingsStore(),
        _appsProvider = appsProvider ?? const PlatformInstalledAppsProvider(),
        _applier = applier ?? const PlatformProxyVpnConfigApplier(),
        _engineStore =
            engineStore ?? const ConfigStoreProxyEngineSettingsStore();

  final ProxyModule _module;
  final ProxySettingsStore _store;
  final ProxyInstalledAppsProvider _appsProvider;
  final ProxyVpnConfigApplier _applier;
  final ProxyEngineSettingsStore _engineStore;

  @override
  Future<ProxySettingsConfig> loadSettings() => _store.read();

  @override
  Future<ProxySettingsConfig> loadSplitTunnel() => _store.read();

  @override
  Future<void> saveSplitTunnel({
    required ProxySplitTunnelMode mode,
    required Set<String> apps,
  }) async {
    final current = await _store.read();
    final next = current.copyWith(splitMode: mode, selectedApps: apps);
    await _store.write(next);
    await _applyToService(next);
  }

  @override
  Future<void> setAlwaysOnIntent(bool value) async {
    final current = await _store.read();
    final next = current.copyWith(alwaysOnIntent: value);
    await _store.write(next);
    // 常驻意图同样并入服务配置（运行中即时生效；系统重启由 Kotlin 持久化恢复）。
    await _applyToService(next);
  }

  @override
  Future<ProxyEngineSettings> loadEngineSettings() => _engineStore.read();

  @override
  Future<void> saveEngineSettings(ProxyEngineSettings settings) =>
      _engineStore.write(settings);

  @override
  Future<ProxyLanConfig> loadLanConfig() => _module.lanGet();

  @override
  Future<ProxyLanStatus> loadLanStatus() => _module.lanStatus();

  @override
  Future<ProxyLanStatus> saveLanConfig(ProxyLanConfig config) =>
      _module.lanSet(config);

  @override
  Future<ProxyShaperSnapshot> loadShaperConfig() => _module.netShaperGet();

  @override
  Future<ProxyShaperSnapshot> saveShaperConfig(ProxyShaperConfig config) =>
      _module.netShaperSet(config);

  @override
  Future<LogSetLevelResult> setLogLevel(ProxyLogLevel level) async {
    final result = await _module.logSetLevel(level.wire);
    final current = await _store.read();
    await _store.write(current.copyWith(logLevel: level));
    return result;
  }

  @override
  Future<StatsResetResult> resetStats() => _module.statsDomainReset();

  @override
  Future<List<InstalledAppOption>> loadInstalledApps() => _appsProvider.list();

  @override
  Future<ProxyEngineInfo> loadEngineInfo() async {
    ProxyVersionInfo? version;
    ProxyPingResult? ping;
    CoreModeResult? mode;
    try {
      version = await _module.version();
    } catch (_) {
      // 模块不可用 → 保留 null
    }
    try {
      ping = await _module.ping();
    } catch (_) {
      // 模块不可用 → 保留 null
    }
    try {
      mode = await _module.coreGetMode();
    } catch (_) {
      // 模块不可用 → 保留 null
    }
    return ProxyEngineInfo(version: version, ping: ping, mode: mode);
  }

  Future<void> _applyToService(ProxySettingsConfig config) async {
    try {
      await _applier.apply(config.toVpnConfigJson());
    } catch (_) {
      // 通道异常不阻断持久化（设置已落盘，连接时再应用）
    }
  }
}

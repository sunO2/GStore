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
/// * **本地端口 / 混合入站**：仅渲染 + 本地持久化。`lan.*` 是**保留**方法
///   （Todo 28 接入），此处**绝不**发起任何 `lan.*` 调用。
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
import 'package:installed_apps/installed_apps.dart' as installed;

/// 本应用包名。
///
/// 分流「排除应用」列表必须过滤掉它：Todo 4 决策规定**绝不**
/// `addDisallowedApplication(self)`（环路修复走宿主 `protect_fd`）。
const String kGStorePackageName = 'com.suno2.gstore';

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

// ==================== 本地端口 / 混合入站 ====================

/// 本地端口与混合入站设置（**仅本地持久化**，`lan.*` 由 Todo 28 接入）。
@immutable
class ProxyLocalPorts {
  const ProxyLocalPorts({
    this.mixedPort = 7890,
    this.socksPort = 7891,
    this.httpPort = 7892,
    this.allowLan = false,
  });

  /// 混合入站端口（mixed）。
  final int mixedPort;

  /// SOCKS 入站端口。
  final int socksPort;

  /// HTTP 入站端口。
  final int httpPort;

  /// 是否允许局域网访问（allow-lan）。
  final bool allowLan;

  Map<String, dynamic> toMap() => <String, dynamic>{
        'mixedPort': mixedPort,
        'socksPort': socksPort,
        'httpPort': httpPort,
        'allowLan': allowLan,
      };

  factory ProxyLocalPorts.fromMap(Map<String, dynamic> map) => ProxyLocalPorts(
        mixedPort: _asInt(map['mixedPort'], 7890),
        socksPort: _asInt(map['socksPort'], 7891),
        httpPort: _asInt(map['httpPort'], 7892),
        allowLan: map['allowLan'] == true,
      );

  ProxyLocalPorts copyWith({
    int? mixedPort,
    int? socksPort,
    int? httpPort,
    bool? allowLan,
  }) =>
      ProxyLocalPorts(
        mixedPort: mixedPort ?? this.mixedPort,
        socksPort: socksPort ?? this.socksPort,
        httpPort: httpPort ?? this.httpPort,
        allowLan: allowLan ?? this.allowLan,
      );
}

// ==================== 聚合配置 ====================

/// 设置页聚合的本地配置（持久化单元）。
@immutable
class ProxySettingsConfig {
  const ProxySettingsConfig({
    this.splitMode = ProxySplitTunnelMode.full,
    this.selectedApps = const <String>{},
    this.alwaysOnIntent = false,
    this.localPorts = const ProxyLocalPorts(),
    this.logLevel = ProxyLogLevel.info,
  });

  /// 分流模式。
  final ProxySplitTunnelMode splitMode;

  /// 分流的应用清单（`allow` 为白名单 / `disallow` 为排除名单）。
  final Set<String> selectedApps;

  /// 应用侧「始终开启」意图（不直接控制系统开关）。
  final bool alwaysOnIntent;

  /// 本地端口 / 混合入站（Todo 28 预留）。
  final ProxyLocalPorts localPorts;

  /// 日志保留级别（`log.set_level`）。
  final ProxyLogLevel logLevel;

  ProxySettingsConfig copyWith({
    ProxySplitTunnelMode? splitMode,
    Set<String>? selectedApps,
    bool? alwaysOnIntent,
    ProxyLocalPorts? localPorts,
    ProxyLogLevel? logLevel,
  }) =>
      ProxySettingsConfig(
        splitMode: splitMode ?? this.splitMode,
        selectedApps: selectedApps ?? this.selectedApps,
        alwaysOnIntent: alwaysOnIntent ?? this.alwaysOnIntent,
        localPorts: localPorts ?? this.localPorts,
        logLevel: logLevel ?? this.logLevel,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'splitMode': splitMode.wire,
        'selectedApps': selectedApps.toList(),
        'alwaysOnIntent': alwaysOnIntent,
        'localPorts': localPorts.toMap(),
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
      localPorts: map['localPorts'] is Map
          ? ProxyLocalPorts.fromMap(
              Map<String, dynamic>.from(map['localPorts'] as Map))
          : const ProxyLocalPorts(),
      logLevel: ProxyLogLevel.fromWire(map['logLevel']),
    );
  }

  /// 生成 `ProxyVpnService` 的配置 JSON（仅分流相关字段）。
  ///
  /// * `full` → 不写应用清单（Kotlin 默认全局）。
  /// * `allow` → `allowedApps` = 选中清单。
  /// * `disallow` → `disallowedApps` = 选中清单**去掉本应用**
  ///   （Todo 4：绝不 `addDisallowedApplication(self)`）。
  String toVpnConfigJson() {
    final apps = selectedApps.toList()..sort();
    final payload = <String, dynamic>{'mode': splitMode.wire};
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
  static const String _keyLocalPorts = 'proxy_local_ports';
  static const String _keyLogLevel = 'proxy_log_level';

  @override
  Future<ProxySettingsConfig> read() async {
    final store = ConfigStore.instance;
    final mode = await store.readString(_keySplitMode);
    final apps = await _readStringList(store, _keySelectedApps);
    final alwaysOn = await store.readBool(_keyAlwaysOn) ?? false;
    final portsRaw = await store.readString(_keyLocalPorts);
    final logLevel = await store.readString(_keyLogLevel);
    return ProxySettingsConfig(
      splitMode: ProxySplitTunnelMode.fromWire(mode),
      selectedApps: apps.toSet(),
      alwaysOnIntent: alwaysOn,
      localPorts: _decodePorts(portsRaw),
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
    await store.writeString(_keyLocalPorts, jsonEncode(config.localPorts.toMap()));
    await store.writeString(_keyLogLevel, config.logLevel.wire);
  }

  Future<List<String>> _readStringList(ConfigStore store, String key) async {
    final raw = await store.readValue(key);
    if (raw is List) return raw.map((e) => e.toString()).toList();
    if (raw is String && raw.isNotEmpty) return raw.split(',');
    return const <String>[];
  }

  ProxyLocalPorts _decodePorts(String? raw) {
    if (raw == null || raw.isEmpty) return const ProxyLocalPorts();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return ProxyLocalPorts.fromMap(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 损坏值 → 默认
    }
    return const ProxyLocalPorts();
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

  /// 保存本地端口 / 混合入站（本地持久化；`lan.*` 由 Todo 28 接入）。
  Future<void> saveLocalPorts(ProxyLocalPorts ports);

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
class ProxyModuleSettingsFacade implements ProxySettingsFacade {
  ProxyModuleSettingsFacade({
    ProxyModule? module,
    ProxySettingsStore? store,
    ProxyInstalledAppsProvider? appsProvider,
    ProxyVpnConfigApplier? applier,
  })  : _module = module ?? ProxyModule.instance,
        _store = store ?? const ConfigStoreProxySettingsStore(),
        _appsProvider = appsProvider ?? const PlatformInstalledAppsProvider(),
        _applier = applier ?? const PlatformProxyVpnConfigApplier();

  final ProxyModule _module;
  final ProxySettingsStore _store;
  final ProxyInstalledAppsProvider _appsProvider;
  final ProxyVpnConfigApplier _applier;

  @override
  Future<ProxySettingsConfig> loadSettings() => _store.read();

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
  Future<void> saveLocalPorts(ProxyLocalPorts ports) async {
    final current = await _store.read();
    await _store.write(current.copyWith(localPorts: ports));
    // Todo 28：接入 `lan.*` 后在此下发端口 / allow-lan（当前仅本地持久化）。
  }

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

int _asInt(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

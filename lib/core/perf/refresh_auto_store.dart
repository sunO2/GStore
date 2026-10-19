/// 「每应用自动刷新率」配置的持久化存储（WS-D）。
///
/// 承载：
/// * 全局开关 `enabled`（是否按前台应用自动切换刷新率）；
/// * 离开已配置应用 / 桌面 / 无配置前台时的**默认恢复值** `defaultMin` /
///   `defaultPeak`（`null` = 不恢复，保持现状）；
/// * 每应用配置表 `{package: {package,label,min,peak}}`。
///
/// ## 存储形态与安全默认
/// 单个 SharedPreferences 键（[SharedPrefsRefreshAutoStore.storageKey]）承载整份
/// JSON：`{"enabled":bool,"defaultMin":int?,"defaultPeak":int?,"entries":{...}}`。
/// 无记录 / 空串 / 非 Map / **畸形 JSON** / 单个损坏条目 → 全部**宽容降级**
/// （忽略坏数据，绝不抛异常）。
///
/// ## 解耦
/// 本层只读写配置，**不**执行任何 Shizuku 命令 —— 自动应用引擎
/// （[RefreshAutoEngine]）在其之上构建，仅经 [RefreshRateController] 走 settings。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// 单个应用的刷新率配置（`{package,label,min,peak}`）。
class RefreshAutoEntry {
  const RefreshAutoEntry({
    required this.package,
    required this.label,
    required this.min,
    required this.peak,
  });

  /// 包名（配置身份键）。
  final String package;

  /// 展示名（缺省回退包名）。
  final String label;

  /// 期望最小刷新率（Hz）。
  final int min;

  /// 期望峰值刷新率（Hz）。
  final int peak;

  /// 复制并覆盖字段。
  RefreshAutoEntry copyWith({
    String? package,
    String? label,
    int? min,
    int? peak,
  }) =>
      RefreshAutoEntry(
        package: package ?? this.package,
        label: label ?? this.label,
        min: min ?? this.min,
        peak: peak ?? this.peak,
      );

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'package': package,
        'label': label,
        'min': min,
        'peak': peak,
      };

  /// 宽容反序列化：缺字段用默认值（`min`/`peak` 缺失时回退 0）。
  factory RefreshAutoEntry.fromJson(Map<String, dynamic> json) {
    final package = json['package']?.toString() ?? '';
    return RefreshAutoEntry(
      package: package,
      label: json['label']?.toString() ?? package,
      min: _asInt(json['min']) ?? 0,
      peak: _asInt(json['peak']) ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RefreshAutoEntry &&
      other.package == package &&
      other.label == label &&
      other.min == min &&
      other.peak == peak;

  @override
  int get hashCode => Object.hash(package, label, min, peak);

  @override
  String toString() =>
      'RefreshAutoEntry($package, $label, min: $min, peak: $peak)';
}

/// 整份自动刷新率配置。
class RefreshAutoConfig {
  const RefreshAutoConfig({
    this.enabled = false,
    this.defaultMin,
    this.defaultPeak,
    this.entries = const <String, RefreshAutoEntry>{},
  });

  /// 是否启用「按前台自动切换」。
  final bool enabled;

  /// 默认恢复 min（Hz）；`null` = 未设置（不恢复）。
  final int? defaultMin;

  /// 默认恢复 peak（Hz）；`null` = 未设置（不恢复）。
  final int? defaultPeak;

  /// 每应用配置（包名 → 条目）。
  final Map<String, RefreshAutoEntry> entries;

  /// 是否配置了可用的默认恢复对。
  bool get hasDefaults => defaultMin != null && defaultPeak != null;

  /// 复制并覆盖字段。
  RefreshAutoConfig copyWith({
    bool? enabled,
    int? defaultMin,
    int? defaultPeak,
    Map<String, RefreshAutoEntry>? entries,
    bool clearDefaults = false,
  }) =>
      RefreshAutoConfig(
        enabled: enabled ?? this.enabled,
        defaultMin: clearDefaults ? null : (defaultMin ?? this.defaultMin),
        defaultPeak: clearDefaults ? null : (defaultPeak ?? this.defaultPeak),
        entries: entries ?? this.entries,
      );

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        if (defaultMin != null) 'defaultMin': defaultMin,
        if (defaultPeak != null) 'defaultPeak': defaultPeak,
        'entries': <String, dynamic>{
          for (final entry in entries.entries) entry.key: entry.value.toJson(),
        },
      };

  @override
  String toString() => 'RefreshAutoConfig(enabled: $enabled, '
      'defaultMin: $defaultMin, defaultPeak: $defaultPeak, '
      'entries: ${entries.length})';
}

/// 将任意原始值解码为 [RefreshAutoConfig]（纯函数，**绝不抛**）。
///
/// [raw] 可为 `null` / JSON 字符串 / 已解码 `Map`。非 Map / 非法 JSON → 空配置；
/// 单个损坏条目 → 跳过。
RefreshAutoConfig decodeRefreshAutoConfig(Object? raw) {
  Object? decoded = raw;
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const RefreshAutoConfig();
    try {
      decoded = jsonDecode(trimmed);
    } catch (error) {
      debugPrint('[RefreshAutoStore] JSON 解析失败，按空配置处理: $error');
      return const RefreshAutoConfig();
    }
  }
  if (decoded is! Map) return const RefreshAutoConfig();
  final map = decoded.map((key, value) => MapEntry(key.toString(), value));

  final entries = <String, RefreshAutoEntry>{};
  final rawEntries = map['entries'];
  if (rawEntries is Map) {
    rawEntries.forEach((key, value) {
      if (key is! String || key.isEmpty) return;
      if (value is! Map) return;
      try {
        final entry = RefreshAutoEntry.fromJson(
          value.map((k, v) => MapEntry(k.toString(), v)),
        );
        // 身份以 map 键为准（缺省 / 不一致时归一）；label 缺省回退包名。
        final package = entry.package.isEmpty ? key : entry.package;
        entries[key] = entry.copyWith(
          package: package,
          label: entry.label.isEmpty ? package : entry.label,
        );
      } catch (error) {
        debugPrint('[RefreshAutoStore] 跳过损坏条目 $key: $error');
      }
    });
  }

  return RefreshAutoConfig(
    enabled: map['enabled'] == true,
    defaultMin: _asInt(map['defaultMin']),
    defaultPeak: _asInt(map['defaultPeak']),
    entries: entries,
  );
}

/// 将 [RefreshAutoConfig] 编码为可 JSON 序列化的 map（纯函数，**绝不抛**）。
Map<String, dynamic> encodeRefreshAutoConfig(RefreshAutoConfig config) =>
    config.toJson();

/// 宽容地把任意值解析为 `int?`（`int` / 可解析字符串 / `num`）。
int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value.toString().trim());
}

/// 自动刷新率配置持久化接口。
abstract class RefreshAutoStore {
  /// 读取整份配置；无记录 / 失败 → 空配置（enabled=false）。
  Future<RefreshAutoConfig> load();

  /// 覆盖保存整份配置；返回是否写入成功。
  Future<bool> save(RefreshAutoConfig config);

  /// 新增 / 覆盖单个应用配置；[RefreshAutoEntry.package] 为空 → `false`（不写）。
  Future<bool> upsert(RefreshAutoEntry entry);

  /// 删除单个应用配置；不存在视为成功。
  Future<bool> remove(String package);

  /// 清空全部应用配置（保留 enabled / defaults？—— 这里一并重置为默认空配置）。
  Future<bool> clear();

  /// 设置全局开关（保留既有条目 / 默认值）。
  Future<bool> setEnabled(bool enabled);

  /// 设置默认恢复值；两者皆 `null` = 清除默认（不恢复）。
  Future<bool> setDefaults({int? min, int? peak});
}

/// 生产实现：`shared_preferences`。
class SharedPrefsRefreshAutoStore implements RefreshAutoStore {
  const SharedPrefsRefreshAutoStore();

  /// 存储键。
  static const String storageKey = 'perf_refresh_auto_config';

  @override
  Future<RefreshAutoConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return const RefreshAutoConfig();
      return decodeRefreshAutoConfig(raw);
    } catch (error) {
      debugPrint('[RefreshAutoStore] 读取配置失败: $error');
      return const RefreshAutoConfig();
    }
  }

  @override
  Future<bool> save(RefreshAutoConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(
        storageKey,
        jsonEncode(encodeRefreshAutoConfig(config)),
      );
    } catch (error) {
      debugPrint('[RefreshAutoStore] 保存配置失败: $error');
      return false;
    }
  }

  @override
  Future<bool> upsert(RefreshAutoEntry entry) async {
    if (entry.package.isEmpty) return false;
    final config = await load();
    return save(
      config.copyWith(
        entries: <String, RefreshAutoEntry>{
          ...config.entries,
          entry.package: entry,
        },
      ),
    );
  }

  @override
  Future<bool> remove(String package) async {
    final config = await load();
    if (!config.entries.containsKey(package)) return true;
    final next = <String, RefreshAutoEntry>{...config.entries}..remove(package);
    return save(config.copyWith(entries: next));
  }

  @override
  Future<bool> clear() => save(const RefreshAutoConfig());

  @override
  Future<bool> setEnabled(bool enabled) async {
    final config = await load();
    return save(config.copyWith(enabled: enabled));
  }

  @override
  Future<bool> setDefaults({int? min, int? peak}) async {
    final config = await load();
    if (min == null && peak == null) {
      return save(config.copyWith(clearDefaults: true));
    }
    return save(config.copyWith(defaultMin: min, defaultPeak: peak));
  }
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryRefreshAutoStore implements RefreshAutoStore {
  InMemoryRefreshAutoStore([RefreshAutoConfig? seed])
      : _config = seed ?? const RefreshAutoConfig();

  RefreshAutoConfig _config;

  /// 当前配置快照（测试断言用）。
  RefreshAutoConfig get config => _config;

  @override
  Future<RefreshAutoConfig> load() async => _config;

  @override
  Future<bool> save(RefreshAutoConfig config) async {
    _config = config;
    return true;
  }

  @override
  Future<bool> upsert(RefreshAutoEntry entry) async {
    if (entry.package.isEmpty) return false;
    _config = _config.copyWith(
      entries: <String, RefreshAutoEntry>{
        ..._config.entries,
        entry.package: entry,
      },
    );
    return true;
  }

  @override
  Future<bool> remove(String package) async {
    final next = <String, RefreshAutoEntry>{..._config.entries}..remove(package);
    _config = _config.copyWith(entries: next);
    return true;
  }

  @override
  Future<bool> clear() async {
    _config = const RefreshAutoConfig();
    return true;
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    _config = _config.copyWith(enabled: enabled);
    return true;
  }

  @override
  Future<bool> setDefaults({int? min, int? peak}) async {
    _config = (min == null && peak == null)
        ? _config.copyWith(clearDefaults: true)
        : _config.copyWith(defaultMin: min, defaultPeak: peak);
    return true;
  }
}

// Shared in-memory `ConfigApiClient` for grouped theme/proxy call-site tests.
//
// The fake applies the same module/key filter as the Rust bus, so
// `ConfigService.watch*` keeps exercising the production filtering path.

import 'dart:async';
import 'dart:convert';

import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/rust/generated/config_api.dart' as generated;

generated.ConfigEntryDto groupedEntry({
  required String wireKey,
  required String valueType,
  required String defaultJson,
  bool sensitive = false,
  bool agentAccessible = true,
  List<String> enumValues = const <String>[],
  String category = '',
  double? min,
  double? max,
}) {
  final dot = wireKey.indexOf('.');
  final module = wireKey.substring(0, dot);
  final key = wireKey.substring(dot + 1);
  return generated.ConfigEntryDto(
    module: module,
    key: key,
    wireKey: wireKey,
    valueType: valueType,
    valueJson: defaultJson,
    masked: false,
    revision: BigInt.zero,
    sensitive: sensitive,
    agentAccessible: agentAccessible,
    visibility: 'owner',
    defaultJson: defaultJson,
    descriptionZh: wireKey,
    descriptionEn: wireKey,
    category: category,
    enumValues: enumValues,
    min: min,
    max: max,
    example: null,
  );
}

/// Registry metadata for every key touched by the theme/proxy call sites.
List<generated.ConfigEntryDto> groupedConfigEntries() {
  return <generated.ConfigEntryDto>[
    groupedEntry(
      wireKey: 'theme.mode',
      valueType: 'int',
      defaultJson: '0',
      category: 'theme',
      enumValues: const <String>['0', '1', '2'],
    ),
    groupedEntry(
      wireKey: 'theme.config',
      valueType: 'json',
      defaultJson: '{}',
      category: 'theme',
    ),
    groupedEntry(
      wireKey: 'network.proxy_url',
      valueType: 'string',
      defaultJson: '""',
      category: 'network',
    ),
    groupedEntry(
      wireKey: 'proxy.engine_stack',
      valueType: 'string',
      defaultJson: '"gvisor"',
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.engine_mtu',
      valueType: 'int',
      defaultJson: '1500',
      min: 1280,
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.routing_mode',
      valueType: 'string',
      defaultJson: '"rule"',
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.run_mode',
      valueType: 'string',
      defaultJson: '"vpn"',
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.active_node_label',
      valueType: 'string',
      defaultJson: '""',
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.active_profile_id',
      valueType: 'string',
      defaultJson: '""',
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.sheet_view_mode',
      valueType: 'string',
      defaultJson: '"list"',
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.split_mode',
      valueType: 'string',
      defaultJson: '"full"',
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.split_apps',
      valueType: 'string_list',
      defaultJson: '[]',
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.always_on_intent',
      valueType: 'bool',
      defaultJson: 'false',
      category: 'proxy',
    ),
    groupedEntry(
      wireKey: 'proxy.log_level',
      valueType: 'string',
      defaultJson: '"info"',
      category: 'proxy',
    ),
  ];
}

/// In-memory [ConfigApiClient] keyed by grouped wire key.
class GroupedConfigApiClient implements ConfigApiClient {
  GroupedConfigApiClient({List<generated.ConfigEntryDto>? entries})
      : _entries = entries ?? groupedConfigEntries();

  final List<generated.ConfigEntryDto> _entries;
  final Map<String, Object?> _values = <String, Object?>{};

  final StreamController<generated.ConfigChangeDto> _changes =
      StreamController<generated.ConfigChangeDto>.broadcast(sync: true);
  int _revision = 0;

  /// Current committed value for a grouped wire key (test introspection).
  Object? raw(String wireKey) => _values[wireKey];

  generated.ConfigEntryDto? _entryFor(String module, String key) {
    for (final entry in _entries) {
      if (entry.module == module && entry.key == key) return entry;
    }
    return null;
  }

  generated.ConfigEntryDto _requireEntry(String module, String key) {
    final entry = _entryFor(module, key);
    if (entry == null) throw StateError('config_unknown: $module.$key');
    return entry;
  }

  void _emit(
    generated.ConfigEntryDto entry, {
    required Object? oldValue,
    required Object? newValue,
    required String source,
  }) {
    _changes.add(
      generated.ConfigChangeDto(
        module: entry.module,
        key: entry.key,
        wireKey: entry.wireKey,
        valueJson: newValue == null ? null : jsonEncode(newValue),
        oldValueJson: oldValue == null ? null : jsonEncode(oldValue),
        revision: BigInt.from(++_revision),
        source: source,
      ),
    );
  }

  generated.ConfigOpResultDto _op(
    String action,
    generated.ConfigEntryDto entry,
    Object? value,
  ) {
    return generated.ConfigOpResultDto(
      success: true,
      message: '$action ${entry.wireKey}',
      module: entry.module,
      key: entry.key,
      wireKey: entry.wireKey,
      valueJson: value == null ? null : jsonEncode(value),
      defaultJson: entry.defaultJson,
    );
  }

  Future<void> close() => _changes.close();

  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) async {
    return _entries
        .where((entry) => module == null || entry.module == module)
        .toList();
  }

  @override
  Future<generated.ConfigSnapshotDto?> snapshot({
    required String module,
    required String key,
  }) async {
    final entry = _requireEntry(module, key);
    if (!_values.containsKey(entry.wireKey)) return null;
    return generated.ConfigSnapshotDto(
      module: entry.module,
      key: entry.key,
      wireKey: entry.wireKey,
      valueJson: jsonEncode(_values[entry.wireKey]),
      masked: false,
      revision: BigInt.from(_revision),
      updatedAt: 0,
      updatedBy: 'user',
    );
  }

  @override
  Future<List<generated.ConfigSnapshotDto>> snapshots({String? module}) async {
    final out = <generated.ConfigSnapshotDto>[];
    for (final entry in _entries) {
      if (module != null && entry.module != module) continue;
      final snap = await snapshot(module: entry.module, key: entry.key);
      if (snap != null) out.add(snap);
    }
    return out;
  }

  @override
  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  }) async {
    final entry = _requireEntry(module, key);
    if (!_values.containsKey(entry.wireKey)) return entry.defaultJson;
    return jsonEncode(_values[entry.wireKey]);
  }

  @override
  Future<generated.ConfigOpResultDto> set({
    required String module,
    required String key,
    required String valueJson,
    required String source,
  }) async {
    final entry = _requireEntry(module, key);
    final value = jsonDecode(valueJson);
    final oldValue = _values[entry.wireKey];
    _values[entry.wireKey] = value;
    _emit(entry, oldValue: oldValue, newValue: value, source: source);
    return _op('set', entry, value);
  }

  @override
  Future<generated.ConfigOpResultDto> clear({
    required String module,
    required String key,
    required String source,
  }) async {
    final entry = _requireEntry(module, key);
    final oldValue = _values.remove(entry.wireKey);
    _emit(entry, oldValue: oldValue, newValue: null, source: source);
    return _op('clear', entry, null);
  }

  @override
  Future<generated.ConfigOpResultDto> reset({
    required String module,
    required String key,
    required String source,
  }) async {
    final entry = _requireEntry(module, key);
    final oldValue = _values[entry.wireKey];
    final value = jsonDecode(entry.defaultJson);
    _values[entry.wireKey] = value;
    _emit(entry, oldValue: oldValue, newValue: value, source: source);
    return _op('reset', entry, value);
  }

  @override
  Stream<generated.ConfigChangeDto> watch({
    required String module,
    String? key,
  }) {
    return _changes.stream.where(
      (change) =>
          change.module == module && (key == null || change.key == key),
    );
  }
}

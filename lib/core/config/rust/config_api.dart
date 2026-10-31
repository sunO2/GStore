/// Thin Dart wrapper over the generated FRB [`generated.ConfigApi`].
///
/// It owns no configuration logic: reads/writes are delegated to Rust and the
/// generated DTOs are mapped onto the existing [`ConfigEntry`] /
/// [`ConfigSnapshot`] / [`ConfigChangeEvent`] models so `ConfigService` can
/// switch its backing store without changing its public surface.
///
/// Watches are **not** filtered in Dart. [`watch`] passes the module/key
/// filter down to the generated `ConfigApi.watch`, whose Rust-side bus only
/// forwards matching changes (C18). A Dart-side `where` would require a global
/// firehose and is deliberately avoided.
library;

import 'dart:convert';

import '../config_service.dart'
    show
        ConfigChangeEvent,
        ConfigChangeSource,
        ConfigEntry,
        ConfigOpResult,
        ConfigSnapshot,
        ConfigValueType;
import '../../rust/generated/bridge.dart' as generated;
import '../../rust/generated/config_api.dart' as generated;

/// Narrow seam over the generated opaque API.
///
/// Only the members this wrapper actually uses are listed, which keeps the
/// wrapper testable without a native library and makes the mapping/filtering
/// contract explicit. Production uses [_GeneratedConfigApiClient].
abstract class ConfigApiClient {
  Future<List<generated.ConfigEntryDto>> list({String? module});

  Future<generated.ConfigSnapshotDto?> snapshot({
    required String module,
    required String key,
  });

  Future<List<generated.ConfigSnapshotDto>> snapshots({String? module});

  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  });

  Future<generated.ConfigOpResultDto> set({
    required String module,
    required String key,
    required String valueJson,
    required String source,
  });

  Future<generated.ConfigOpResultDto> clear({
    required String module,
    required String key,
    required String source,
  });

  Future<generated.ConfigOpResultDto> reset({
    required String module,
    required String key,
    required String source,
  });

  Stream<generated.ConfigChangeDto> watch({
    required String module,
    String? key,
  });
}

/// Optional capability for clients backed by the real `ConfigApi.export`.
///
/// It is kept separate from [ConfigApiClient] so the many in-memory fakes (and
/// any external implementers) do not have to grow a raw-export method; they get
/// an equivalent list+get derivation in [ConfigRustApi.export].
abstract class ConfigExportApiClient {
  /// Raw export for backups (the only raw DTO, C3/C16).
  Future<generated.ConfigExportDto> export();
}

/// One decoded raw export entry (backup artifact only).
class ConfigExportValue {
  const ConfigExportValue({
    required this.module,
    required this.key,
    required this.wireKey,
    required this.value,
  });

  final String module;
  final String key;
  final String wireKey;
  final Object? value;
}

/// Maps the generated FRB facade onto [ConfigApiClient].
class _GeneratedConfigApiClient
    implements ConfigApiClient, ConfigExportApiClient {
  _GeneratedConfigApiClient(this._api);

  final generated.ConfigApi _api;

  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) =>
      _api.list(module: module);

  @override
  Future<generated.ConfigSnapshotDto?> snapshot({
    required String module,
    required String key,
  }) =>
      _api.snapshot(module: module, key: key);

  @override
  Future<List<generated.ConfigSnapshotDto>> snapshots({String? module}) =>
      _api.snapshots(module: module);

  @override
  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  }) =>
      _api.get_(module: module, key: key, masked: masked);

  @override
  Future<generated.ConfigOpResultDto> set({
    required String module,
    required String key,
    required String valueJson,
    required String source,
  }) =>
      _api.set_(
        module: module,
        key: key,
        valueJson: valueJson,
        source: source,
      );

  @override
  Future<generated.ConfigOpResultDto> clear({
    required String module,
    required String key,
    required String source,
  }) =>
      _api.clear(module: module, key: key, source: source);

  @override
  Future<generated.ConfigOpResultDto> reset({
    required String module,
    required String key,
    required String source,
  }) =>
      _api.reset(module: module, key: key, source: source);

  @override
  Stream<generated.ConfigChangeDto> watch({
    required String module,
    String? key,
  }) =>
      _api.watch(module: module, key: key);

  @override
  Future<generated.ConfigExportDto> export() => _api.export_();
}

/// Dart-side entry point for the module-scoped Rust config store.
class ConfigRustApi {
  ConfigRustApi(this._client);

  final ConfigApiClient _client;

  /// Creates the Rust facade. `CoreApi.init()` must have run first, otherwise
  /// Rust rejects the call with `CORE_E_NOT_INITIALIZED`.
  static Future<ConfigRustApi> init({ConfigApiClient? client}) async {
    if (client != null) return ConfigRustApi(client);
    return ConfigRustApi(
      _GeneratedConfigApiClient(await generated.ConfigApi.init()),
    );
  }

  /// Registry metadata plus current values, mapped to [ConfigEntry].
  Future<List<ConfigEntry>> list({String? module}) async {
    final entries = await _client.list(module: module);
    final mapped = entries.map(_entryFromDto).toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return mapped;
  }

  /// One stored snapshot, or `null` when the key has no committed value.
  Future<ConfigSnapshot?> snapshot(String module, String key) async {
    final dto = await _client.snapshot(module: module, key: key);
    if (dto == null) return null;
    final entry = await _entryDto(module, key);
    if (entry == null) return null;
    return _snapshotFromDtos(_entryFromDto(entry), dto);
  }

  /// Stored snapshots joined with the registry metadata (type/descriptions).
  ///
  /// `ConfigSnapshotDto` only carries the value, so the declared type and
  /// metadata come from a single `list(module)` call.
  Future<List<ConfigSnapshot>> snapshots({String? module}) async {
    final entries = {for (final e in await list(module: module)) e.key: e};
    final dtos = await _client.snapshots(module: module);
    final out = <ConfigSnapshot>[];
    for (final dto in dtos) {
      final entry = entries[dto.wireKey];
      if (entry == null) continue;
      out.add(_snapshotFromDtos(entry, dto));
    }
    out.sort((a, b) => a.key.compareTo(b.key));
    return out;
  }

  /// Reads one value as JSON. `masked: false` is the trusted-raw read (C3).
  Future<Object?> get(String module, String key, {bool masked = true}) async {
    return _decodeJson(await _client.get(
      module: module,
      key: key,
      masked: masked,
    ));
  }

  /// Validates, commits, and publishes one value.
  Future<ConfigOpResult> set(
    String module,
    String key,
    Object? value, {
    ConfigChangeSource source = ConfigChangeSource.internal,
  }) async {
    final dto = await _client.set(
      module: module,
      key: key,
      valueJson: jsonEncode(value),
      source: _sourceCode(source),
    );
    return _opResultFromDto(dto);
  }

  /// Clears a stored value (reads fall back to the registry default).
  Future<ConfigOpResult> clear(
    String module,
    String key, {
    ConfigChangeSource source = ConfigChangeSource.internal,
  }) async {
    return _opResultFromDto(await _client.clear(
      module: module,
      key: key,
      source: _sourceCode(source),
    ));
  }

  /// Restores and persists the registry default.
  Future<ConfigOpResult> reset(
    String module,
    String key, {
    ConfigChangeSource source = ConfigChangeSource.internal,
  }) async {
    return _opResultFromDto(await _client.reset(
      module: module,
      key: key,
      source: _sourceCode(source),
    ));
  }

  /// Filtered change stream for one module, optionally narrowed to one key.
  ///
  /// [key] is `null` for a whole-module watch. The filter is evaluated by Rust
  /// before delivery, so a subscriber never receives unrelated modules/keys.
  Stream<ConfigChangeEvent> watch(String module, [String? key]) {
    return _client
        .watch(module: module, key: key)
        .map(_changeEventFromDto);
  }

  /// Raw export for backups (C3/C16). Never masked; backup-only.
  ///
  /// Production clients expose the real `ConfigApi.export` through
  /// [ConfigExportApiClient]. In-memory fakes without that capability get an
  /// equivalent list+get derivation; entries that cannot be read are skipped so
  /// a stale `config_entry` row never fails the whole export.
  Future<List<ConfigExportValue>> export() async {
    final client = _client;
    final generated.ConfigExportDto dto;
    if (client is ConfigExportApiClient) {
      dto = await (client as ConfigExportApiClient).export();
    } else {
      dto = await _exportFromList(client);
    }
    return <ConfigExportValue>[
      for (final entry in dto.entries)
        ConfigExportValue(
          module: entry.module,
          key: entry.key,
          wireKey: entry.wireKey,
          value: _decodeJson(entry.valueJson),
        ),
    ];
  }

  Future<generated.ConfigExportDto> _exportFromList(
    ConfigApiClient client,
  ) async {
    final entries = <generated.ConfigExportEntryDto>[];
    for (final entry in await client.list()) {
      try {
        final valueJson = await client.get(
          module: entry.module,
          key: entry.key,
          masked: false,
        );
        entries.add(generated.ConfigExportEntryDto(
          module: entry.module,
          key: entry.key,
          wireKey: entry.wireKey,
          valueJson: valueJson,
        ));
      } catch (_) {
        // Unregistered/unreadable row: skip it, keep the rest of the backup.
      }
    }
    return generated.ConfigExportDto(
      revision: BigInt.zero,
      entries: entries,
    );
  }

  Future<generated.ConfigEntryDto?> _entryDto(
    String module,
    String key,
  ) async {
    final entries = await _client.list(module: module);
    for (final entry in entries) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  static ConfigEntry _entryFromDto(generated.ConfigEntryDto dto) {
    return ConfigEntry(
      key: dto.wireKey,
      type: _valueType(dto.valueType),
      defaultValue: _decodeJson(dto.defaultJson),
      sensitive: dto.sensitive,
      agentAccessible: dto.agentAccessible,
      description: dto.descriptionZh,
      descriptionEn: dto.descriptionEn,
      enumValues: dto.enumValues.isEmpty ? null : dto.enumValues,
      category: dto.category.isEmpty ? null : dto.category,
      unit: dto.unit,
      min: dto.min,
      max: dto.max,
      example: dto.example,
    );
  }

  static ConfigSnapshot _snapshotFromDtos(
    ConfigEntry entry,
    generated.ConfigSnapshotDto dto,
  ) {
    return ConfigSnapshot(
      key: entry.key,
      type: entry.type.name,
      value: _decodeJson(dto.valueJson),
      defaultValue: entry.defaultValue,
      description: entry.description,
      descriptionEn: entry.descriptionEn,
      sensitive: entry.sensitive,
      agentAccessible: entry.agentAccessible,
      enumValues: entry.enumValues,
      category: entry.category,
      unit: entry.unit,
      min: entry.min,
      max: entry.max,
      example: entry.example,
    );
  }

  static ConfigChangeEvent _changeEventFromDto(
    generated.ConfigChangeDto dto,
  ) {
    return ConfigChangeEvent(
      key: dto.wireKey,
      oldValue: _decodeJson(dto.oldValueJson),
      newValue: _decodeJson(dto.valueJson),
      source: _source(dto.source),
    );
  }

  static ConfigOpResult _opResultFromDto(generated.ConfigOpResultDto dto) {
    final value = _decodeJson(dto.valueJson);
    final defaultValue = _decodeJson(dto.defaultJson);
    return dto.success
        ? ConfigOpResult.success(
            dto.message,
            key: dto.wireKey,
            value: value,
            defaultValue: defaultValue,
          )
        : ConfigOpResult.failure(
            dto.message,
            key: dto.wireKey,
            value: value,
            defaultValue: defaultValue,
          );
  }

  static Object? _decodeJson(String? text) {
    if (text == null) return null;
    return jsonDecode(text);
  }

  static ConfigValueType _valueType(String code) {
    return switch (code) {
      'bool' => ConfigValueType.bool,
      'int' => ConfigValueType.int,
      'double' => ConfigValueType.double,
      'string' => ConfigValueType.string,
      'string_list' => ConfigValueType.stringList,
      _ => ConfigValueType.json,
    };
  }

  static ConfigChangeSource _source(String code) {
    return switch (code) {
      'user' => ConfigChangeSource.user,
      'agent' => ConfigChangeSource.agent,
      _ => ConfigChangeSource.internal,
    };
  }

  static String _sourceCode(ConfigChangeSource source) {
    return switch (source) {
      ConfigChangeSource.user => 'user',
      ConfigChangeSource.agent => 'agent',
      ConfigChangeSource.internal => 'internal',
    };
  }
}

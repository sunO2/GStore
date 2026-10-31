/// 内存后端：`ConfigStore.initialize({storages})` 的兼容实现。
///
/// 它把 `CompositeConfigStorage` 包装成一个最小的 Rust `ConfigApiClient`，注入
/// `ConfigService`（生产 Rust 客户端不受影响），因此 **ConfigStore 与
/// ConfigService 共享同一份测试存储**：20 个使用 `MemoryConfigStorage` 的文件与
/// 17 个调用 `initialize({storages})` 的文件无需修改。
///
/// fake 只模拟门面所需的 Rust 语义（注册表 / 原始读 / 脱敏事件 / 精确
/// watch 过滤），不做 schema/范围校验（`ConfigService.set` 已在 Dart 侧完成）。
library;

import 'dart:async';
import 'dart:convert';

import '../rust/generated/config_api.dart' as generated;
import 'config_backend.dart';
import 'config_service.dart';
import 'config_storage.dart';
import 'rust/config_api.dart';

/// 测试/无 Rust 环境下的内存后端。
class MemoryConfigBackend extends RustConfigBackend {
  MemoryConfigBackend({
    required List<ConfigStorage> storages,
    required List<ConfigEntry> entries,
  })  : _storages = storages,
        _entries = entries;

  final List<ConfigStorage> _storages;
  final List<ConfigEntry> _entries;

  @override
  Future<void> initialize() async {
    final storage = CompositeConfigStorage(_storages);
    await storage.initialize();
    final client = _StorageConfigApiClient(storage, _entries);
    final service = ConfigService.instance;
    // 清理上一个测试残留的镜像/全局订阅，再注入同一份存储的 fake API。
    // ignore: invalid_use_of_visible_for_testing_member
    await service.resetForTest();
    // ignore: invalid_use_of_visible_for_testing_member
    service.debugSetApi(ConfigRustApi(client));
    // 不在此处水合：允许存量测试在 initialize 之后、首次读写之前调用
    // `ConfigService.register(...)`（C2：水合前注册仍填充同步元数据）。
  }
}

/// 以 [CompositeConfigStorage] 为事实来源的 [ConfigApiClient]。
class _StorageConfigApiClient implements ConfigApiClient {
  _StorageConfigApiClient(this._storage, List<ConfigEntry> entries)
      : _entries = {
          for (final entry in entries)
            if (_split(entry.key) != null) entry.key: entry,
        };

  final CompositeConfigStorage _storage;
  final Map<String, ConfigEntry> _entries;

  final StreamController<generated.ConfigChangeDto> _changes =
      StreamController<generated.ConfigChangeDto>.broadcast(sync: true);
  int _revision = 0;

  ConfigEntry? _entry(String module, String key) => _entries['$module.$key'];

  ConfigEntry _require(String module, String key) {
    final entry = _entry(module, key);
    if (entry == null) {
      throw StateError('config_unknown: $module.$key');
    }
    return entry;
  }

  Future<Object?> _value(String wireKey) => _storage.getValue(wireKey);

  void _emit(
    ConfigEntry entry, {
    required Object? oldValue,
    required Object? newValue,
    required String source,
  }) {
    final oldJson =
        oldValue == null ? null : jsonEncode(entry.sensitive ? '***' : oldValue);
    final newJson =
        newValue == null ? null : jsonEncode(entry.sensitive ? '***' : newValue);
    if (_changes.isClosed) return;
    final parts = _split(entry.key)!;
    _changes.add(generated.ConfigChangeDto(
      module: parts.$1,
      key: parts.$2,
      wireKey: entry.key,
      valueJson: newJson,
      oldValueJson: oldJson,
      revision: BigInt.from(++_revision),
      source: source,
    ));
  }

  generated.ConfigOpResultDto _op(
    String action,
    ConfigEntry entry,
    Object? value, {
    required bool success,
  }) {
    final parts = _split(entry.key)!;
    return generated.ConfigOpResultDto(
      success: success,
      message: success ? '$action ${entry.key}' : '$action failed: ${entry.key}',
      module: parts.$1,
      key: parts.$2,
      wireKey: entry.key,
      valueJson: value == null ? null : jsonEncode(value),
      defaultJson: jsonEncode(entry.defaultValue),
    );
  }

  generated.ConfigEntryDto _entryDto(ConfigEntry entry, String wireKey) {
    final parts = _split(wireKey)!;
    return generated.ConfigEntryDto(
      module: parts.$1,
      key: parts.$2,
      wireKey: wireKey,
      valueType: _typeCode(entry.type),
      valueJson: 'null',
      masked: entry.sensitive,
      revision: BigInt.from(_revision),
      sensitive: entry.sensitive,
      agentAccessible: entry.agentAccessible,
      visibility: entry.sensitive ? 'secret' : 'owner',
      defaultJson: jsonEncode(entry.defaultValue),
      descriptionZh: entry.description,
      descriptionEn: entry.descriptionEn,
      category: entry.category ?? '',
      unit: entry.unit,
      min: entry.min?.toDouble(),
      max: entry.max?.toDouble(),
      enumValues: entry.enumValues ?? const <String>[],
      example: entry.example,
    );
  }

  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) async {
    // 合并内置注册表与“水合前 register(...)”的条目（C2）。
    final merged = <String, ConfigEntry>{
      for (final entry in _entries.values) entry.key: entry,
    };
    for (final entry in ConfigService.instance.list()) {
      merged.putIfAbsent(entry.key, () => entry);
    }
    return merged.values
        .where((entry) => _split(entry.key) != null)
        .where((entry) => module == null || entry.key.startsWith('$module.'))
        .map((entry) => _entryDto(entry, entry.key))
        .toList();
  }

  @override
  Future<generated.ConfigSnapshotDto?> snapshot({
    required String module,
    required String key,
  }) async {
    final entry = _require(module, key);
    final value = await _value(entry.key);
    if (value == null) return null;
    return generated.ConfigSnapshotDto(
      module: module,
      key: key,
      wireKey: entry.key,
      valueJson: jsonEncode(entry.sensitive ? '***' : value),
      masked: entry.sensitive,
      revision: BigInt.from(_revision),
      updatedAt: 0,
      updatedBy: 'fake',
    );
  }

  @override
  Future<List<generated.ConfigSnapshotDto>> snapshots({String? module}) async {
    final out = <generated.ConfigSnapshotDto>[];
    for (final entry in _entries.values) {
      final parts = _split(entry.key)!;
      if (module != null && parts.$1 != module) continue;
      final snap = await snapshot(module: parts.$1, key: parts.$2);
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
    final entry = _require(module, key);
    final value = await _value(entry.key);
    // 与 Rust `ConfigStore::get` 一致：未显式写入 → 返回注册表 default_json
    // （raw 与 masked 都是默认值）；仅“已设置且敏感 + masked”返回 `***`。
    if (value == null) return jsonEncode(entry.defaultValue);
    if (masked && entry.sensitive) return jsonEncode('***');
    return jsonEncode(value);
  }

  @override
  Future<generated.ConfigOpResultDto> set({
    required String module,
    required String key,
    required String valueJson,
    required String source,
  }) async {
    final entry = _require(module, key);
    final value = jsonDecode(valueJson);
    final oldValue = await _value(entry.key);
    final ok = await _storage.setValue(entry.key, value);
    if (!ok) return _op('set', entry, null, success: false);
    _emit(entry, oldValue: oldValue, newValue: value, source: source);
    return _op('set', entry, value, success: true);
  }

  @override
  Future<generated.ConfigOpResultDto> clear({
    required String module,
    required String key,
    required String source,
  }) async {
    final entry = _require(module, key);
    final oldValue = await _value(entry.key);
    final ok = await _storage.remove(entry.key);
    if (!ok) return _op('clear', entry, null, success: false);
    _emit(entry, oldValue: oldValue, newValue: null, source: source);
    return _op('clear', entry, null, success: true);
  }

  @override
  Future<generated.ConfigOpResultDto> reset({
    required String module,
    required String key,
    required String source,
  }) async {
    final entry = _require(module, key);
    final oldValue = await _value(entry.key);
    final value = entry.defaultValue;
    final ok = await _storage.setValue(entry.key, value);
    if (!ok) return _op('reset', entry, null, success: false);
    _emit(entry, oldValue: oldValue, newValue: value, source: source);
    return _op('reset', entry, value, success: true);
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

  static (String, String)? _split(String wireKey) {
    final dot = wireKey.indexOf('.');
    if (dot <= 0 || dot == wireKey.length - 1) return null;
    return (wireKey.substring(0, dot), wireKey.substring(dot + 1));
  }

  static String _typeCode(ConfigValueType type) {
    return switch (type) {
      ConfigValueType.bool => 'bool',
      ConfigValueType.int => 'int',
      ConfigValueType.double => 'double',
      ConfigValueType.string => 'string',
      ConfigValueType.stringList => 'string_list',
      ConfigValueType.json => 'json',
    };
  }
}

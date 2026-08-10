/// 统一存储访问器
///
/// 封装 CompositeConfigStorage，提供：
/// - 按敏感标记自动路由（sensitive → SecureStorage，否则普通存储）
/// - 类型化读写（bool/int/double/String/List<String>）
/// - 键迁移（旧散落 key → 注册表 key）
/// - 统一变化事件流
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';

import 'config_storage.dart';

/// 统一存储访问器（单例）
///
/// 所有配置读写最终都经过此访问器，保证：
/// 1. 敏感配置自动进入加密存储
/// 2. 所有写入统一广播变化事件（订阅者可主动响应）
class ConfigStore {
  ConfigStore._internal();

  static ConfigStore? _instance;
  static ConfigStore get instance => _instance ??= ConfigStore._internal();

  CompositeConfigStorage? _storage;

  /// 是否已初始化
  bool _initialized = false;

  /// 敏感 key 集合（注册表写入后维护）
  final Set<String> _sensitiveKeys = {};

  /// 初始化（幂等）
  Future<void> initialize({List<ConfigStorage>? storages}) async {
    if (_initialized) return;
    final storage = CompositeConfigStorage(
      storages ?? [
        SharedPrefsConfigStorage(),
        SecureConfigStorage(),
      ],
    );
    await storage.initialize();
    _storage = storage;
    _initialized = true;
  }

  /// 重置内部状态（仅测试使用）
  @visibleForTesting
  void resetForTest() {
    _initialized = false;
    _storage = null;
    _sensitiveKeys.clear();
  }

  CompositeConfigStorage get _store {
    if (_storage == null) {
      throw StateError('ConfigStore 未初始化，请先调用 ConfigInitializer.initialize()');
    }
    return _storage!;
  }

  /// 标记敏感 key（注册表调用）
  void markSensitive(String key) {
    _sensitiveKeys.add(key);
  }

  /// 该 key 是否敏感
  bool isSensitive(String key) => _sensitiveKeys.contains(key);

  /// 敏感 key 列表
  Set<String> get sensitiveKeys => Set.unmodifiable(_sensitiveKeys);

  /// 目标存储：敏感 key 走加密存储，否则普通存储（无对应类型时回退首个）
  ConfigStorage _target(String key) {
    final desired = _sensitiveKeys.contains(key)
        ? StorageType.secure
        : StorageType.normal;
    for (final s in _store.storages) {
      if (s.type == desired) return s;
    }
    return _store.storages.first;
  }

  /// 读取字符串（敏感自动路由，普通存储未命中时回退加密存储）
  Future<String?> readString(String key) async {
    final target = _target(key);
    final value = await target.getString(key);
    if (value != null) return value;
    // 兼容：敏感 key 首次注册前可能存于普通存储
    if (_sensitiveKeys.contains(key)) {
      for (final s in _store.storages) {
        if (s.type == StorageType.normal) {
          final v = await s.getString(key);
          if (v != null) return v;
        }
      }
    }
    return null;
  }

  /// 读取类型化值
  Future<Object?> readValue(String key) async {
    final target = _target(key);
    var value = await target.getValue(key);
    if (value != null) return value;
    if (_sensitiveKeys.contains(key)) {
      for (final s in _store.storages) {
        if (s.type == StorageType.normal) {
          value = await s.getValue(key);
          if (value != null) return value;
        }
      }
    }
    return null;
  }

  /// 读取 bool
  Future<bool?> readBool(String key) async {
    final v = await readValue(key);
    return v is bool ? v : null;
  }

  /// 读取 int
  Future<int?> readInt(String key) async {
    final v = await readValue(key);
    return v is int ? v : null;
  }

  /// 读取 double
  Future<double?> readDouble(String key) async {
    final v = await readValue(key);
    return v is double ? v : null;
  }

  /// 读取字符串列表
  Future<List<String>?> readStringList(String key) async {
    final v = await readValue(key);
    if (v is List<String>) return v;
    if (v is String && v.isNotEmpty) return v.split(',').toList();
    return null;
  }

  /// 写入（自动路由 + 广播事件）
  Future<bool> write(String key, Object? value) {
    return _target(key).setValue(key, value);
  }

  /// 写入字符串
  Future<bool> writeString(String key, String value) {
    return _target(key).setString(key, value);
  }

  /// 删除 key
  Future<bool> remove(String key) {
    return _target(key).remove(key);
  }

  /// 检查是否存在
  Future<bool> contains(String key) async {
    for (final s in _store.storages) {
      if (await s.containsKey(key)) return true;
    }
    return false;
  }

  /// 迁移旧键到新键（跨存储：按目标敏感路由写入）
  Future<bool> migrate(String oldKey, String newKey) async {
    if (oldKey == newKey) return true;
    final value = await _store.getValue(oldKey);
    if (value == null) return true;
    final ok = await write(newKey, value);
    if (ok) {
      for (final s in _store.storages) {
        await s.remove(oldKey);
      }
    }
    return ok;
  }

  /// 所有存储变化事件
  Stream<StorageChangeEvent> get changes => _store.changes;

  /// 监听指定 key 变化（值：StorageChangeEvent，remove 时 value 为 null）
  Stream<StorageChangeEvent> watch(String key) {
    return changes.where((e) => e.key == key || e.key == 'config_$key');
  }
}

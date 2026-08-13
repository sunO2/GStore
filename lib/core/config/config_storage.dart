/// 配置存储抽象层
///
/// 提供统一的存储接口，屏蔽底层存储实现差异
library;

import 'dart:async';
import 'package:async/async.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 存储类型枚举
enum StorageType {
  /// 普通存储（SharedPreferences）
  /// 适用于非敏感配置
  normal,

  /// 加密存储（FlutterSecureStorage）
  /// 适用于敏感配置（密码、token 等）
  secure,

  /// 内存存储
  /// 适用于临时配置
  memory,
}

/// 存储变化事件
///
/// 由写入拦截统一发出（不依赖平台原生监听），
/// 订阅者可据此实现"配置变化 → 功能主动响应"。
class StorageChangeEvent {
  /// 变化的键
  final String key;

  /// 新值（remove/clear 时为 null）
  final Object? value;

  /// 所在存储类型
  final StorageType storageType;

  const StorageChangeEvent({
    required this.key,
    this.value,
    required this.storageType,
  });

  @override
  String toString() =>
      'StorageChangeEvent{key: $key, value: $value, type: $storageType}';
}

/// 配置存储接口
///
/// 提供统一的键值存储接口，支持不同类型的存储后端
abstract class ConfigStorage {
  /// 存储类型
  StorageType get type;

  /// 初始化存储
  Future<void> initialize();

  /// 保存字符串
  Future<bool> setString(String key, String value);

  /// 获取字符串
  Future<String?> getString(String key);

  /// 保存整数
  Future<bool> setInt(String key, int value);

  /// 获取整数
  Future<int?> getInt(String key);

  /// 保存布尔值
  Future<bool> setBool(String key, bool value);

  /// 获取布尔值
  Future<bool?> getBool(String key);

  /// 保存 double
  Future<bool> setDouble(String key, double value);

  /// 获取 double
  Future<double?> getDouble(String key);

  /// 保存字符串列表
  Future<bool> setStringList(String key, List<String> value);

  /// 获取字符串列表
  Future<List<String>?> getStringList(String key);

  /// 删除指定键
  Future<bool> remove(String key);

  /// 清空所有数据
  Future<bool> clear();

  /// 检查键是否存在
  Future<bool> containsKey(String key);

  /// 按值类型保存（bool/int/double/String/List<String> 自动分派）
  Future<bool> setValue(String key, Object? value) async {
    if (value == null) return remove(key);
    return switch (value) {
      final bool v => setBool(key, v),
      final int v => setInt(key, v),
      final double v => setDouble(key, v),
      final String v => setString(key, v),
      final List<String> v => setStringList(key, v),
      _ => setString(key, value.toString()),
    };
  }

  /// 按值类型读取（返回存储原始值；无此键返回 null）
  Future<Object?> getValue(String key) async {
    final value = await getString(key);
    if (value == null) return null;
    // 尝试按存储原始类型读取
    final intValue = int.tryParse(value);
    if (intValue != null) return intValue;
    if (value == 'true') return true;
    if (value == 'false') return false;
    final doubleValue = double.tryParse(value);
    if (doubleValue != null) return doubleValue;
    return value;
  }

  /// 迁移键：将 [oldKey] 的值迁移到 [newKey] 并删除旧键
  /// 返回是否完成迁移（旧键不存在视为已完成）
  Future<bool> migrateKey(String oldKey, String newKey) async {
    if (oldKey == newKey) return true;
    final value = await getString(oldKey);
    if (value == null) return true;
    final ok = await setString(newKey, value);
    if (ok) await remove(oldKey);
    return ok;
  }

  /// 监听键变化（基于 changes 过滤；remove 时发出 null）
  Stream<String?> watch(String key);

  /// 存储变化事件流（所有写入/删除的统一广播）
  Stream<StorageChangeEvent> get changes;

  /// 获取所有键
  Future<Set<String>> keys();
}

/// SharedPreferences 存储实现
class SharedPrefsConfigStorage implements ConfigStorage {
  SharedPrefsConfigStorage() {
    // Constructor intentionally left empty
  }

  static const String _prefix = 'config_';

  @override
  StorageType get type => StorageType.normal;

  /// 变化事件广播器（写入拦截）
  final _changesController =
      StreamController<StorageChangeEvent>.broadcast();

  @override
  Stream<StorageChangeEvent> get changes => _changesController.stream;

  /// 发出变化事件（remove 时 value 为 null）
  void _emit(String key, Object? value) {
    if (_changesController.isClosed) return;
    _changesController.add(StorageChangeEvent(
      key: _key(key),
      value: value,
      storageType: StorageType.normal,
    ));
  }

  @override
  Future<void> initialize() async {
    // 预热插件（不缓存实例：测试中 setMockInitialValues 会替换平台存储，
    // 每次操作经 _getPrefs() 重新解析，保证始终读写最新数据）
    await _getPrefs();
  }

  Future<SharedPreferences> _getPrefs() async {
    // 这里需要导入 shared_preferences
    // 为了避免循环依赖，在实现文件中导入
    return SharedPreferences.getInstance();
  }

  String _key(String key) => '$_prefix$key';

  @override
  Future<bool> setString(String key, String value) async {
    final ok = await (await _getPrefs()).setString(_key(key), value);
    if (ok) _emit(key, value);
    return ok;
  }

  @override
  Future<String?> getString(String key) async {
    return (await _getPrefs()).getString(_key(key));
  }

  @override
  Future<bool> setInt(String key, int value) async {
    final ok = await (await _getPrefs()).setInt(_key(key), value);
    if (ok) _emit(key, value);
    return ok;
  }

  @override
  Future<int?> getInt(String key) async {
    return (await _getPrefs()).getInt(_key(key));
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    final ok = await (await _getPrefs()).setBool(_key(key), value);
    if (ok) _emit(key, value);
    return ok;
  }

  @override
  Future<bool?> getBool(String key) async {
    return (await _getPrefs()).getBool(_key(key));
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    final ok = await (await _getPrefs()).setDouble(_key(key), value);
    if (ok) _emit(key, value);
    return ok;
  }

  @override
  Future<double?> getDouble(String key) async {
    return (await _getPrefs()).getDouble(_key(key));
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    final ok = await (await _getPrefs()).setStringList(_key(key), value);
    if (ok) _emit(key, value);
    return ok;
  }

  @override
  Future<List<String>?> getStringList(String key) async {
    return (await _getPrefs()).getStringList(_key(key));
  }

  @override
  Future<bool> remove(String key) async {
    final ok = await (await _getPrefs()).remove(_key(key));
    if (ok) _emit(key, null);
    return ok;
  }

  @override
  Future<bool> clear() async {
    final allKeys = await keys();
    for (final key in allKeys) {
      await remove(key);
    }
    return true;
  }

  @override
  Future<bool> containsKey(String key) async {
    return (await _getPrefs()).containsKey(_key(key));
  }

  @override
  Stream<String?> watch(String key) {
    return changes
        .where((e) => e.key == _key(key))
        .map((e) => e.value?.toString());
  }

  @override
  Future<Set<String>> keys() async {
    final allKeys = (await _getPrefs()).getKeys();
    return allKeys.where((key) => key.startsWith(_prefix)).map((key) => key.substring(_prefix.length)).toSet();
  }

  @override
  Future<Object?> getValue(String key) async {
    // SharedPreferences 原生支持类型化读取，直接返回原始值
    return (await _getPrefs()).get(_key(key));
  }

  @override
  Future<bool> setValue(String key, Object? value) async {
    if (value == null) return remove(key);
    return switch (value) {
      final bool v => setBool(key, v),
      final int v => setInt(key, v),
      final double v => setDouble(key, v),
      final String v => setString(key, v),
      final List<String> v => setStringList(key, v),
      _ => setString(key, value.toString()),
    };
  }

  @override
  Future<bool> migrateKey(String oldKey, String newKey) async {
    if (oldKey == newKey) return true;
    final rawKey = _key(oldKey);
    final exists = (await _getPrefs()).containsKey(rawKey);
    if (!exists) return true;
    final value = (await _getPrefs()).get(rawKey);
    final ok = await setValue(newKey, value);
    if (ok) await (await _getPrefs()).remove(rawKey);
    return ok;
  }

  void dispose() {
    _changesController.close();
  }
}

/// FlutterSecureStorage 存储实现
class SecureConfigStorage implements ConfigStorage {
  SecureConfigStorage() {
    // Constructor intentionally left empty
  }

  static const String _prefix = 'secure_config_';
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  /// 变化事件广播器（写入拦截）
  final _changesController =
      StreamController<StorageChangeEvent>.broadcast();

  @override
  Stream<StorageChangeEvent> get changes => _changesController.stream;

  /// 发出变化事件（remove 时 value 为 null）
  void _emit(String key, Object? value) {
    if (_changesController.isClosed) return;
    _changesController.add(StorageChangeEvent(
      key: _key(key),
      value: value,
      storageType: StorageType.secure,
    ));
  }

  @override
  StorageType get type => StorageType.secure;

  @override
  Future<void> initialize() async {
    // FlutterSecureStorage 不需要显式初始化
  }

  String _key(String key) => '$_prefix$key';

  @override
  Future<bool> setString(String key, String value) async {
    try {
      await _storage.write(key: _key(key), value: value);
      _emit(key, value);
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<String?> getString(String key) async {
    try {
      return await _storage.read(key: _key(key));
    } catch (e) {
      return null;
    }
  }

  @override
  Future<bool> setInt(String key, int value) async {
    return await setString(key, value.toString());
  }

  @override
  Future<int?> getInt(String key) async {
    final value = await getString(key);
    if (value == null) return null;
    return int.tryParse(value);
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    return await setString(key, value.toString());
  }

  @override
  Future<bool?> getBool(String key) async {
    final value = await getString(key);
    if (value == null) return null;
    if (value == 'true') return true;
    if (value == 'false') return false;
    return null;
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    return await setString(key, value.toString());
  }

  @override
  Future<double?> getDouble(String key) async {
    final value = await getString(key);
    if (value == null) return null;
    return double.tryParse(value);
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    return await setString(key, value.join(','));
  }

  @override
  Future<List<String>?> getStringList(String key) async {
    final value = await getString(key);
    if (value == null) return null;
    return value.split(',');
  }

  @override
  Future<bool> remove(String key) async {
    try {
      await _storage.delete(key: _key(key));
      _emit(key, null);
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    try {
      await _storage.deleteAll();
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<bool> containsKey(String key) async {
    final value = await getString(key);
    return value != null;
  }

  @override
  Stream<String?> watch(String key) {
    return changes
        .where((e) => e.key == _key(key))
        .map((e) => e.value?.toString());
  }

  @override
  Future<Set<String>> keys() async {
    // FlutterSecureStorage 不支持列出所有键
    // 返回空集合
    return const {};
  }

  @override
  Future<Object?> getValue(String key) async {
    final value = await getString(key);
    if (value == null) return null;
    final intValue = int.tryParse(value);
    if (intValue != null) return intValue;
    if (value == 'true') return true;
    if (value == 'false') return false;
    final doubleValue = double.tryParse(value);
    if (doubleValue != null) return doubleValue;
    return value;
  }

  @override
  Future<bool> setValue(String key, Object? value) async {
    if (value == null) return remove(key);
    return setString(key, value.toString());
  }

  @override
  Future<bool> migrateKey(String oldKey, String newKey) async {
    if (oldKey == newKey) return true;
    final value = await getString(oldKey);
    if (value == null) return true;
    final ok = await setString(newKey, value);
    if (ok) await remove(oldKey);
    return ok;
  }
}

/// 内存存储实现
///
/// 适用于测试与临时配置；支持事件广播。
class MemoryConfigStorage implements ConfigStorage {
  MemoryConfigStorage();

  final Map<String, Object?> _data = {};

  /// 变化事件广播器（写入拦截）
  final _changesController =
      StreamController<StorageChangeEvent>.broadcast();

  @override
  Stream<StorageChangeEvent> get changes => _changesController.stream;

  /// 发出变化事件（remove 时 value 为 null）
  void _emit(String key, Object? value) {
    if (_changesController.isClosed) return;
    _changesController.add(StorageChangeEvent(
      key: key,
      value: value,
      storageType: StorageType.memory,
    ));
  }

  @override
  StorageType get type => StorageType.memory;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> setString(String key, String value) async {
    _data[key] = value;
    _emit(key, value);
    return true;
  }

  @override
  Future<String?> getString(String key) async {
    final v = _data[key];
    return v is String ? v : null;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    _data[key] = value;
    _emit(key, value);
    return true;
  }

  @override
  Future<int?> getInt(String key) async {
    final v = _data[key];
    return v is int ? v : null;
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    _data[key] = value;
    _emit(key, value);
    return true;
  }

  @override
  Future<bool?> getBool(String key) async {
    final v = _data[key];
    return v is bool ? v : null;
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    _data[key] = value;
    _emit(key, value);
    return true;
  }

  @override
  Future<double?> getDouble(String key) async {
    final v = _data[key];
    return v is double ? v : null;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _data[key] = List.of(value);
    _emit(key, value);
    return true;
  }

  @override
  Future<List<String>?> getStringList(String key) async {
    final v = _data[key];
    return v is List<String> ? List.of(v) : null;
  }

  @override
  Future<bool> remove(String key) async {
    final existed = _data.containsKey(key);
    _data.remove(key);
    if (existed) _emit(key, null);
    return true;
  }

  @override
  Future<bool> clear() async {
    _data.clear();
    return true;
  }

  @override
  Future<bool> containsKey(String key) async => _data.containsKey(key);

  @override
  Stream<String?> watch(String key) {
    return changes
        .where((e) => e.key == key)
        .map((e) => e.value?.toString());
  }

  @override
  Future<Set<String>> keys() async => Set.of(_data.keys);

  @override
  Future<Object?> getValue(String key) async => _data[key];

  @override
  Future<bool> setValue(String key, Object? value) async {
    if (value == null) return remove(key);
    _data[key] = value;
    _emit(key, value);
    return true;
  }

  @override
  Future<bool> migrateKey(String oldKey, String newKey) async {
    if (oldKey == newKey) return true;
    if (!_data.containsKey(oldKey)) return true;
    _data[newKey] = _data[oldKey];
    _data.remove(oldKey);
    _emit(newKey, _data[newKey]);
    return true;
  }
}

/// 组合存储（同时支持多种存储类型）
class CompositeConfigStorage implements ConfigStorage {
  CompositeConfigStorage(this.storages);

  final List<ConfigStorage> storages;

  @override
  StorageType get type => StorageType.normal;

  @override
  Stream<StorageChangeEvent> get changes {
    return StreamGroup.merge(
      storages.map((s) => s.changes),
    );
  }

  @override
  Future<void> initialize() async {
    for (final storage in storages) {
      await storage.initialize();
    }
  }

  ConfigStorage _getStorageForType(StorageType type) {
    return storages.firstWhere(
      (s) => s.type == type,
      orElse: () => storages.first,
    );
  }

  @override
  Future<bool> setString(String key, String value) async {
    final storage = _getStorageForType(StorageType.normal);
    return await storage.setString(key, value);
  }

  @override
  Future<String?> getString(String key) async {
    for (final storage in storages) {
      final value = await storage.getString(key);
      if (value != null) return value;
    }
    return null;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    final storage = _getStorageForType(StorageType.normal);
    return await storage.setInt(key, value);
  }

  @override
  Future<int?> getInt(String key) async {
    for (final storage in storages) {
      final value = await storage.getInt(key);
      if (value != null) return value;
    }
    return null;
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    final storage = _getStorageForType(StorageType.normal);
    return await storage.setBool(key, value);
  }

  @override
  Future<bool?> getBool(String key) async {
    for (final storage in storages) {
      final value = await storage.getBool(key);
      if (value != null) return value;
    }
    return null;
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    final storage = _getStorageForType(StorageType.normal);
    return await storage.setDouble(key, value);
  }

  @override
  Future<double?> getDouble(String key) async {
    for (final storage in storages) {
      final value = await storage.getDouble(key);
      if (value != null) return value;
    }
    return null;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    final storage = _getStorageForType(StorageType.normal);
    return await storage.setStringList(key, value);
  }

  @override
  Future<List<String>?> getStringList(String key) async {
    for (final storage in storages) {
      final value = await storage.getStringList(key);
      if (value != null) return value;
    }
    return null;
  }

  @override
  Future<bool> remove(String key) async {
    bool success = true;
    for (final storage in storages) {
      success = success && await storage.remove(key);
    }
    return success;
  }

  @override
  Future<bool> clear() async {
    bool success = true;
    for (final storage in storages) {
      success = success && await storage.clear();
    }
    return success;
  }

  @override
  Future<bool> containsKey(String key) async {
    for (final storage in storages) {
      if (await storage.containsKey(key)) return true;
    }
    return false;
  }

  @override
  Stream<String?> watch(String key) {
    // 合并所有存储的流
    return StreamGroup.merge(
      storages.map((s) => s.watch(key)),
    );
  }

  @override
  Future<bool> setValue(String key, Object? value) async {
    if (value == null) return remove(key);
    final storage = _getStorageForType(StorageType.normal);
    return await storage.setValue(key, value);
  }

  @override
  Future<Object?> getValue(String key) async {
    for (final storage in storages) {
      final value = await storage.getValue(key);
      if (value != null) return value;
    }
    return null;
  }

  @override
  Future<bool> migrateKey(String oldKey, String newKey) async {
    if (oldKey == newKey) return true;
    final value = await getValue(oldKey);
    if (value == null) return true;
    final ok = await setValue(newKey, value);
    if (ok) {
      for (final storage in storages) {
        await storage.remove(oldKey);
      }
    }
    return ok;
  }

  @override
  Future<Set<String>> keys() async {
    final Set<String> allKeys = {};
    for (final storage in storages) {
      allKeys.addAll(await storage.keys());
    }
    return allKeys;
  }
}

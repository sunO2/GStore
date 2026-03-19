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

  /// 监听键变化
  Stream<String?> watch(String key);

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

  SharedPreferences? _prefs;

  @override
  Future<void> initialize() async {
    _prefs ??= await _getInstance();
  }

  Future<SharedPreferences> _getInstance() async {
    // 延迟导入避免循环依赖
    final SharedPreferences prefs = await _getPrefs();
    return prefs;
  }

  Future<SharedPreferences> _getPrefs() async {
    // 这里需要导入 shared_preferences
    // 为了避免循环依赖，在实现文件中导入
    return SharedPreferences.getInstance();
  }

  SharedPreferences get _prefsInstance {
    if (_prefs == null) {
      throw StateError('SharedPrefsConfigStorage not initialized. Call initialize() first.');
    }
    return _prefs!;
  }

  String _key(String key) => '$_prefix$key';

  @override
  Future<bool> setString(String key, String value) async {
    return await _prefsInstance.setString(_key(key), value);
  }

  @override
  Future<String?> getString(String key) async {
    return _prefsInstance.getString(_key(key));
  }

  @override
  Future<bool> setInt(String key, int value) async {
    return await _prefsInstance.setInt(_key(key), value);
  }

  @override
  Future<int?> getInt(String key) async {
    return _prefsInstance.getInt(_key(key));
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    return await _prefsInstance.setBool(_key(key), value);
  }

  @override
  Future<bool?> getBool(String key) async {
    return _prefsInstance.getBool(_key(key));
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    return await _prefsInstance.setDouble(_key(key), value);
  }

  @override
  Future<double?> getDouble(String key) async {
    return _prefsInstance.getDouble(_key(key));
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    return await _prefsInstance.setStringList(_key(key), value);
  }

  @override
  Future<List<String>?> getStringList(String key) async {
    return _prefsInstance.getStringList(_key(key));
  }

  @override
  Future<bool> remove(String key) async {
    return await _prefsInstance.remove(_key(key));
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
    return _prefsInstance.containsKey(_key(key));
  }

  @override
  Stream<String?> watch(String key) {
    // SharedPreferences 不原生支持流，使用轮询或事件总线
    // 这里返回一个永不发出的流，需要配合事件总线使用
    return const Stream.empty();
  }

  @override
  Future<Set<String>> keys() async {
    final allKeys = _prefsInstance.getKeys();
    return allKeys.where((key) => key.startsWith(_prefix)).map((key) => key.substring(_prefix.length)).toSet();
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
    // FlutterSecureStorage 不原生支持流
    return const Stream.empty();
  }

  @override
  Future<Set<String>> keys() async {
    // FlutterSecureStorage 不支持列出所有键
    // 返回空集合
    return const {};
  }
}

/// 组合存储（同时支持多种存储类型）
class CompositeConfigStorage implements ConfigStorage {
  CompositeConfigStorage(this.storages);

  final List<ConfigStorage> storages;

  @override
  StorageType get type => StorageType.normal;

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
  Future<Set<String>> keys() async {
    final Set<String> allKeys = {};
    for (final storage in storages) {
      allKeys.addAll(await storage.keys());
    }
    return allKeys;
  }
}

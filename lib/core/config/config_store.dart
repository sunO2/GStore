/// 统一存储访问器（兼容适配器）
///
/// Todo 16：Rust 配置是唯一权威。本类保留原有公开签名，作为 **兼容适配器**
/// 架在 `ConfigBackend` 接缝之上：
/// - 生产：`RustConfigBackend`（委托 `ConfigService`/`ConfigApi`，读取 raw）。
/// - 测试：`MemoryConfigBackend`（`initialize({storages})` 注入的存储 fake）。
///
/// 适配器职责：裸 key → 注册 wire key（含 11 个代理别名）、C6 JSON 字符串兼容、
/// 敏感标记、事件映射。未注册 key 记录日志并返回 `false`/`null`，绝不抛异常。
///
/// 读取一律 raw：敏感项走 `ConfigService.getRaw`（可信应用内，C3），绝不返回
/// `get` 的 `***` 脱敏默认值，也绝不在日志中输出值。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'config_backend.dart';
import 'config_key_index.dart';
import 'config_memory_backend.dart';
import 'config_registry.dart' show ConfigRegistry;
import 'config_service.dart' show ConfigChangeEvent, ConfigService, ConfigValueType;
import 'config_storage.dart';

/// 统一存储访问器（单例）
class ConfigStore {
  ConfigStore._internal();

  static ConfigStore? _instance;
  static ConfigStore get instance => _instance ??= ConfigStore._internal();

  ConfigBackend? _backend;

  /// 是否已初始化
  bool _initialized = false;

  /// 敏感 key 集合（注册表写入后维护）
  final Set<String> _sensitiveKeys = {};

  /// 初始化（幂等）。
  ///
  /// [storages] 非空 → 内存 fake（保留 17 个 `initialize({storages})` 测试）；
  /// 生产 → Rust 后端。测试环境未显式传 storages 时也使用默认存储 fake，保证
  /// 旧测试仍可运行；**生产进程不会**走 SharedPreferences/SecureStorage 路由。
  Future<void> initialize({List<ConfigStorage>? storages}) async {
    if (storages == null) {
      if (_initialized) {
        if (_isFlutterTest) {
          final backend = _backend;
          if (backend is MemoryConfigBackend) {
            // 测试隔离：复用同一批存储实例但重建 fake 接线，清掉
            // ConfigService 镜像/全局订阅，避免上一个用例的代理值泄漏。
            await backend.initialize();
          }
        }
        return;
      }
    }
    // 显式传入 storages：即使已初始化也重建（每个测试从干净后端开始）。
    final backend = _createBackend(storages);
    await backend.initialize();
    _backend = backend;
    _initialized = true;
  }

  ConfigBackend _createBackend(List<ConfigStorage>? storages) {
    if (storages != null) {
      return MemoryConfigBackend(
        storages: storages,
        entries: ConfigRegistry.entries,
      );
    }
    if (_isFlutterTest) {
      // 仅普通存储：fake 始终按普通类型落盘，SecureStorage 在测试宿主没有插件
      // 实现（remove 返回 false），会污染 clear/set(null) 的返回值。
      return MemoryConfigBackend(
        storages: [SharedPrefsConfigStorage()],
        entries: ConfigRegistry.entries,
      );
    }
    return const RustConfigBackend();
  }

  static bool get _isFlutterTest =>
      Platform.environment['FLUTTER_TEST'] == 'true';

  /// 重置内部状态（仅测试使用）
  @visibleForTesting
  void resetForTest() {
    _initialized = false;
    _backend = null;
    _sensitiveKeys.clear();
    // ConfigService.resetForTest 的清理体是同步的；丢弃 Future 即可。
    // ignore: invalid_use_of_visible_for_testing_member
    unawaited(ConfigService.instance.resetForTest());
  }

  ConfigBackend get _requireBackend {
    final backend = _backend;
    if (backend == null) {
      throw StateError('ConfigStore 未初始化，请先调用 ConfigInitializer.initialize()');
    }
    return backend;
  }

  /// 标记敏感 key（注册表调用）
  void markSensitive(String key) => _sensitiveKeys.add(key);

  /// 该 key 是否敏感
  bool isSensitive(String key) => _sensitiveKeys.contains(key);

  /// 敏感 key 列表
  Set<String> get sensitiveKeys => Set.unmodifiable(_sensitiveKeys);

  /// 裸 key → 已注册 wire key；未注册记录日志（不含值）并返回 null。
  Future<String?> _resolve(String key) async {
    // 未初始化仍是明确错误（与旧实现一致）：只有已初始化后的 ensureReady
    // 失败才降级为 logged-null。
    _requireBackend;
    try {
      await ConfigService.instance.ensureReady();
    } catch (error, stackTrace) {
      // 未注册 key 仍走下方 logged-null；这里只暴露底层 ensureReady 失败原因
      // （例如缺少原生桥），绝不记录配置值。
      debugPrint('[ConfigStore] ensureReady 失败（按空值处理）: $error');
      debugPrint('[ConfigStore] ensureReady 堆栈: $stackTrace');
      return null;
    }
    final wireKey = ConfigKeyIndex.resolve(
      key,
      isRegistered: ConfigService.instance.has,
    );
    if (wireKey == null) {
      debugPrint('[ConfigStore] 未注册的配置 key（已忽略）: $key');
    }
    return wireKey;
  }

  /// 读取字符串（json 类型按 C6 还原为 JSON 文本）。
  Future<String?> readString(String key) async {
    final wireKey = await _resolve(key);
    if (wireKey == null) return null;
    final raw = await _requireBackend.read(wireKey);
    final value = raw ?? _defaultOf(wireKey);
    if (value == null) return null;
    if (_typeOf(wireKey) == ConfigValueType.json) {
      return _jsonToText(value);
    }
    return value is String ? value : null;
  }

  /// 读取类型化值（json 类型返回解码后的 Map/List）。
  Future<Object?> readValue(String key) async {
    final wireKey = await _resolve(key);
    if (wireKey == null) return null;
    final raw = await _requireBackend.read(wireKey);
    final value = raw ?? _defaultOf(wireKey);
    if (value == null) return null;
    return switch (_typeOf(wireKey)) {
      ConfigValueType.json => _jsonValue(value),
      ConfigValueType.stringList => _stringListValue(value),
      _ => value,
    };
  }

  /// 读取 bool
  Future<bool?> readBool(String key) async => _as<bool>(await readValue(key));

  /// 读取 int
  Future<int?> readInt(String key) async => _as<int>(await readValue(key));

  /// 读取 double
  Future<double?> readDouble(String key) async =>
      _as<double>(await readValue(key));

  static T? _as<T>(Object? value) => value is T ? value : null;

  /// 读取字符串列表
  Future<List<String>?> readStringList(String key) async {
    final value = await readValue(key);
    final list = _stringListValue(value);
    if (list != null) return list;
    if (value is String && value.isNotEmpty) return value.split(',');
    return null;
  }

  /// 写入（json 类型字符串按 C6 解码；null 视为删除）。
  Future<bool> write(String key, Object? value) async {
    final wireKey = await _resolve(key);
    if (wireKey == null) return false;
    if (value == null) return _requireBackend.remove(wireKey);
    Object? normalized = value;
    if (_typeOf(wireKey) == ConfigValueType.json && value is String) {
      normalized = _decodeJsonText(value);
      if (normalized == null) {
        debugPrint('[ConfigStore] json 配置需要合法 JSON 字符串（已忽略）: $key');
        return false;
      }
    }
    return _requireBackend.write(wireKey, normalized);
  }

  /// 写入字符串（json 类型自动解析为 Map/List 后再落盘，C6）。
  Future<bool> writeString(String key, String value) async {
    final wireKey = await _resolve(key);
    if (wireKey == null) return false;
    if (_typeOf(wireKey) == ConfigValueType.json) {
      final decoded = _decodeJsonText(value);
      if (decoded is! Map && decoded is! List) {
        debugPrint('[ConfigStore] json 配置字符串无法解析（已忽略）: $key');
        return false;
      }
      return _requireBackend.write(wireKey, decoded);
    }
    return _requireBackend.write(wireKey, value);
  }

  /// 删除 key
  Future<bool> remove(String key) async {
    final wireKey = await _resolve(key);
    if (wireKey == null) return false;
    return _requireBackend.remove(wireKey);
  }

  /// 检查是否存在（显式写入，不含注册默认值）
  Future<bool> contains(String key) async {
    final wireKey = await _resolve(key);
    if (wireKey == null) return false;
    return _requireBackend.contains(wireKey);
  }

  /// 迁移旧键到新键（读取旧值 → 写入新键 → 删除旧键）。
  Future<bool> migrate(String oldKey, String newKey) async {
    final newWire = await _resolve(newKey);
    if (newWire == null) return false;
    final oldWire = await _resolve(oldKey);
    if (oldWire == null || oldWire == newWire) return true;
    final value = await _requireBackend.read(oldWire);
    if (value == null) return true;
    final ok = await _requireBackend.write(newWire, value);
    if (ok) await _requireBackend.remove(oldWire);
    return ok;
  }

  /// 所有配置变化事件（映射全局 `ConfigService.onChange`）。
  Stream<StorageChangeEvent> get changes =>
      _requireBackend.changes.map(_toStorageEvent);

  /// 监听指定 key（委托 `ConfigService.watch(wireKey)`，Rust/fake 已过滤）。
  Stream<StorageChangeEvent> watch(String key) async* {
    final wireKey = await _resolve(key);
    if (wireKey == null) return;
    yield* _requireBackend.watch(wireKey).map(_toStorageEvent);
  }

  ConfigValueType? _typeOf(String wireKey) =>
      ConfigService.instance.entry(wireKey)?.type;

  Object? _defaultOf(String wireKey) =>
      ConfigService.instance.entry(wireKey)?.defaultValue;

  StorageChangeEvent _toStorageEvent(ConfigChangeEvent event) {
    final sensitive =
        ConfigService.instance.entry(event.key)?.sensitive ?? false;
    return StorageChangeEvent(
      key: event.key,
      value: event.newValue,
      storageType: sensitive ? StorageType.secure : StorageType.normal,
    );
  }

  /// 展开历史双重编码的 JSON 文本，返回规范化的单层 JSON 字符串。
  static String _jsonToText(Object? raw) {
    Object? value = raw;
    for (var depth = 0; depth < 3 && value is String; depth++) {
      final text = value.trim();
      if (!_looksJson(text)) break;
      try {
        value = jsonDecode(text);
      } catch (_) {
        break;
      }
    }
    if (value is Map || value is List) return jsonEncode(value);
    if (value is String) return value;
    return raw?.toString() ?? '';
  }

  /// 解析 JSON 文本（最多展开三层历史编码）；无法解析返回 null。
  static Object? _decodeJsonText(String text) {
    Object? value = text.trim();
    for (var depth = 0; depth < 3; depth++) {
      if (value is! String) return value;
      if (!_looksJson(value) || value.trim().isEmpty) return null;
      try {
        value = jsonDecode(value);
      } catch (_) {
        return null;
      }
    }
    return value is String ? null : value;
  }

  static Object? _jsonValue(Object raw) {
    Object? value = raw;
    for (var depth = 0; depth < 3 && value is String; depth++) {
      final text = value.trim();
      if (!_looksJson(text)) break;
      try {
        value = jsonDecode(text);
      } catch (_) {
        break;
      }
    }
    return _deepJson(value);
  }

  static bool _looksJson(String text) =>
      text.startsWith('{') || text.startsWith('[') || text.startsWith('"');

  static List<String>? _stringListValue(Object? value) {
    if (value is List) return value.map((e) => e.toString()).toList();
    return null;
  }

  static Object? _deepJson(Object? value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          '${entry.key}': _deepJson(entry.value),
      };
    }
    if (value is List) return value.map(_deepJson).toList();
    return value;
  }
}

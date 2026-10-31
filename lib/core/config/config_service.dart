/// 统一配置服务（ConfigService）
///
/// 配置系统的统一门面（Todo 14：Rust `ConfigApi` 客户端 + 元数据/原始值镜像）：
/// - 元数据：`ensureReady()` 从 Rust 注册表（`ConfigApi.list()`）水合到同步
///   [ConfigEntry] 映射，`list`/`entry`/`has`/`isAgentAccessible`/`snapshot`
///   等同步/半同步 API 因此无需每次访问 FFI。
/// - 读写：全部委托 Rust；`getRaw`/可信读取按需 `ConfigApi.get(masked:false)`，
///   `get`/`getT` 先查镜像再 `ConfigApi.get`（默认脱敏）。
/// - 镜像：[ConfigEntry] 原始值缓存（按 wire key）；**绝不缓存敏感明文**（C3）。
/// - 订阅：`watch`/`watchMany`/`watchModule` 把 module/key 过滤器下推给
///   `ConfigApi.watch`，由 Rust 在 FRB 之前过滤；`onChange` 保持全局语义，
///   由每个模块的 Rust 订阅汇总，因此镜像只订阅全局来源、不会与过滤流重复。
/// - 安全：敏感项（密码/API Key）读取自动脱敏，Agent 写白名单校验。
///
/// 核心架构：写入方（Agent/UI）只负责写配置，功能模块作为订阅者
/// 监听 onChange 后自行更新，实现"配置修改 → 功能主动响应"。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'config_provider.dart';
import 'rust/config_api.dart';

/// 配置值类型
enum ConfigValueType {
  bool,
  int,
  double,
  string,
  stringList,
  json,
}

/// 配置变更来源
enum ConfigChangeSource {
  /// 用户界面修改
  user,

  /// Agent 工具修改
  agent,

  /// 系统内部修改
  internal,
}

/// 配置变更事件
class ConfigChangeEvent {
  /// 配置 key（wire key，如 `theme.mode`）
  final String key;

  /// 旧值（首次设置/未知时可能为 null）
  final Object? oldValue;

  /// 新值（clear 时为 null）
  final Object? newValue;

  /// 变更来源
  final ConfigChangeSource source;

  const ConfigChangeEvent({
    required this.key,
    this.oldValue,
    this.newValue,
    this.source = ConfigChangeSource.internal,
  });

  @override
  String toString() =>
      'ConfigChangeEvent{key: $key, old: $oldValue, new: $newValue, src: $source}';
}

/// 配置操作结果（供 Agent 展示，结构化字段便于解析）
class ConfigOpResult {
  /// 是否成功
  final bool success;

  /// 结果描述（中文，可直接展示给用户/Agent）
  final String message;

  /// 操作涉及的配置 key
  final String? key;

  /// 设置后的值（clear 时为 null）
  final Object? value;

  /// 该配置的默认值（便于 Agent 判断是否已改默认）
  final Object? defaultValue;

  const ConfigOpResult.success(
    this.message, {
    this.key,
    this.value,
    this.defaultValue,
  }) : success = true;

  const ConfigOpResult.failure(
    this.message, {
    this.key,
    this.value,
    this.defaultValue,
  }) : success = false;

  @override
  String toString() => message;
}

/// 声明式配置注册项
///
/// 只包含静态元数据（值动态存储，见 ConfigSnapshot），
/// 保持单一数据源、避免双写同步问题。
class ConfigEntry {
  /// 配置 key（唯一标识，wire key，如 `theme.mode`）
  final String key;

  /// 值类型
  final ConfigValueType type;

  /// 默认值（reset 时恢复）
  final Object? defaultValue;

  /// 是否敏感（加密存储 + 读取脱敏）
  final bool sensitive;

  /// 是否允许 Agent 读写（白名单）
  final bool agentAccessible;

  /// 中文描述（Agent list 展示）
  final String description;

  /// 英文描述
  final String descriptionEn;

  /// 可选的枚举取值（String 类型限定）
  final List<String>? enumValues;

  /// 分组（如 theme/download/network/agent），便于分类展示
  final String? category;

  /// 单位（如 MB、%，用于数值类配置）
  final String? unit;

  /// 数值最小值（int/double 类型限定）
  final num? min;

  /// 数值最大值（int/double 类型限定）
  final num? max;

  /// 示例值（帮助 AI/用户理解正确取值）
  final String? example;

  const ConfigEntry({
    required this.key,
    required this.type,
    this.defaultValue,
    this.sensitive = false,
    this.agentAccessible = false,
    this.description = '',
    this.descriptionEn = '',
    this.enumValues,
    this.category,
    this.unit,
    this.min,
    this.max,
    this.example,
  });
}

/// 配置模块
///
/// 后期新增模块在初始化时实现此接口并调用
/// [ConfigService.registerModule] 注册自身配置，
/// 注册后即可被 Agent 枚举/读取/修改，无需改动核心代码。
abstract class ConfigModule {
  /// 模块名（唯一，用于追踪与注销）
  String get moduleName;

  /// 本模块的配置项
  List<ConfigEntry> get configs;

  /// 可选：桥接本模块已存在的 ConfigProvider
  void registerProviders(ConfigService service) {}
}

/// 配置快照（元数据 + 当前值合并）
///
/// 供 Agent list/get 使用：一次获取类型/当前值/默认值/可选项/示例等全部信息。
class ConfigSnapshot {
  /// 配置 key
  final String key;

  /// 值类型名（bool/int/double/string/stringList/json）
  final String type;

  /// 当前值（敏感项脱敏为 '***'；未设置时为 null）
  final Object? value;

  /// 默认值
  final Object? defaultValue;

  /// 中文描述
  final String description;

  /// 英文描述
  final String descriptionEn;

  /// 是否敏感
  final bool sensitive;

  /// 是否允许 Agent 访问
  final bool agentAccessible;

  /// 可选枚举值
  final List<String>? enumValues;

  /// 分组
  final String? category;

  /// 单位
  final String? unit;

  /// 最小值
  final num? min;

  /// 最大值
  final num? max;

  /// 示例值
  final String? example;

  const ConfigSnapshot({
    required this.key,
    required this.type,
    this.value,
    this.defaultValue,
    this.description = '',
    this.descriptionEn = '',
    this.sensitive = false,
    this.agentAccessible = false,
    this.enumValues,
    this.category,
    this.unit,
    this.min,
    this.max,
    this.example,
  });

  /// 转换为 JSON（供 Agent 直接消费）
  Map<String, dynamic> toJson() {
    return {
      'key': key,
      'type': type,
      'value': value,
      'defaultValue': defaultValue,
      'description': description,
      'descriptionEn': descriptionEn,
      'sensitive': sensitive,
      'agentAccessible': agentAccessible,
      'enumValues': enumValues,
      'category': category,
      'unit': unit,
      'min': min,
      'max': max,
      'example': example,
    };
  }
}

/// 统一配置服务（单例）
///
/// Rust 侧是唯一事实来源；Dart 侧只保留同步元数据 [ConfigEntry] 与非敏感
/// 原始值镜像，避免每次读走 FFI，同时确保敏感明文永不进入 Dart 镜像（C3）。
class ConfigService {
  ConfigService._internal();

  static ConfigService? _instance;
  static ConfigService get instance => _instance ??= ConfigService._internal();

  /// 注册表（wire key → 元数据）
  ///
  /// `ensureReady()` 之前由 `register*` 填充（旧调用方兼容），水合后替换为
  /// Rust 注册表内容。
  final Map<String, ConfigEntry> _registry = {};

  /// 非敏感原始值镜像（wire key → value）
  ///
  /// 绝不写入敏感项明文（C3）。`getRaw`/可信读取按需走 Rust，不依赖该镜像。
  final Map<String, Object?> _mirror = {};

  /// clear 旧值兜底（仅非敏感），用于旧值早于清除被捕获（C26）。
  final Map<String, Object?> _pendingClearOld = {};

  /// 已注册的 ConfigProvider 桥接表（仅兼容存量 `bridgeProvider` 调用，
  /// 已不再委托读取/写入；见 Todo 14"不要保留 provider 委托"）。
  final Map<String, ConfigProvider<dynamic>> _providers = {};

  /// 已注册的配置模块（moduleName → module；仅水合前有效）
  final Map<String, ConfigModule> _modules = {};

  /// 全局变更事件控制器
  StreamController<ConfigChangeEvent> _changeController =
      StreamController<ConfigChangeEvent>.broadcast();

  /// 每个模块的全局订阅（汇总为 [onChange]；镜像只从这里更新）
  final List<StreamSubscription<ConfigChangeEvent>> _globalSubs = [];

  ConfigRustApi? _api;
  Future<void>? _readyFuture;
  bool _hydrated = false;

  /// 配置变化事件流（全局；external/host 变更同样会到达）
  Stream<ConfigChangeEvent> get onChange => _changeController.stream;

  /// 测试注入的 Rust API 客户端（生产由 `ConfigRustApi.init()` 创建）。
  @visibleForTesting
  void debugSetApi(ConfigRustApi api) {
    _api = api;
    _readyFuture = null;
    _hydrated = false;
  }

  /// 测试读取镜像（用于断言敏感明文从未进入 Dart 镜像，C3）。
  @visibleForTesting
  Map<String, Object?> get debugMirror =>
      Map<String, Object?>.unmodifiable(_mirror);

  /// 测试重置单例状态（不关闭事件控制器，避免测试之间互相影响）。
  @visibleForTesting
  Future<void> resetForTest() async {
    for (final sub in _globalSubs) {
      unawaited(sub.cancel());
    }
    _globalSubs.clear();
    if (_changeController.isClosed) {
      _changeController = StreamController<ConfigChangeEvent>.broadcast();
    }
    _registry.clear();
    _mirror.clear();
    _pendingClearOld.clear();
    _providers.clear();
    _modules.clear();
    _api = null;
    _readyFuture = null;
    _hydrated = false;
  }

  /// 水合入口（幂等）。
  ///
  /// 这是**唯一**调用 `ConfigApi.init()` 并 `ConfigApi.list()` 的地方：
  /// 在任意读/写之前把 Rust 注册表加载进同步 `_registry`，并建立全局事件订阅。
  Future<void> ensureReady() {
    final ready = _readyFuture;
    if (ready != null) return ready;
    final future = _hydrate();
    _readyFuture = future;
    return future;
  }

  Future<void> _hydrate() async {
    try {
      final existing = _api;
      final api = existing ?? await ConfigRustApi.init();
      _api = api;
      final entries = await api.list();
      // Rust 注册表是唯一事实来源：水合后丢弃水合前的旧 Dart 元数据（含 legacy key）。
      _registry.clear();
      for (final entry in entries) {
        _registry[entry.key] = entry;
      }
      _hydrated = true;
      _subscribeGlobal(api);
    } catch (_) {
      // 允许重试：初始化失败不应把实例永久卡在失败态。
      _readyFuture = null;
      rethrow;
    }
  }

  void _subscribeGlobal(ConfigRustApi api) {
    final modules = <String>{};
    for (final key in _registry.keys) {
      final module = _moduleOf(key);
      if (module != null) modules.add(module);
    }
    for (final module in modules) {
      _globalSubs.add(api.watch(module).listen(_onGlobalEvent));
    }
  }

  void _onGlobalEvent(ConfigChangeEvent raw) {
    final event = _normalizeEvent(raw);
    final entry = _registry[event.key];
    if (entry == null || entry.sensitive) {
      _mirror.remove(event.key);
    } else if (event.newValue == null) {
      _mirror.remove(event.key);
    } else {
      _mirror[event.key] = event.newValue;
    }
    if (!_changeController.isClosed) {
      _changeController.add(event);
    }
  }

  /// 注册配置项（重复 key 覆盖更新）。
  ///
  /// 水合后为兼容性 no-op；水合前只填充同步元数据（无 provider 委托）。
  void register(ConfigEntry entry) {
    if (_hydrated) return;
    _registry[entry.key] = entry;
  }

  /// 注册批量配置项（水合后 no-op）。
  void registerAll(List<ConfigEntry> entries) {
    if (_hydrated) return;
    for (final entry in entries) {
      register(entry);
    }
  }

  /// 注册配置模块（幂等；水合后 no-op）。
  void registerModule(ConfigModule module) {
    if (_hydrated) return;
    _modules[module.moduleName] = module;
    registerAll(module.configs);
    module.registerProviders(this);
  }

  /// 注销配置模块（水合后 no-op）。
  void unregisterModule(String moduleName) {
    if (_hydrated) return;
    final module = _modules.remove(moduleName);
    if (module == null) return;
    final keys = module.configs.map((e) => e.key).toSet();
    keys.forEach(_registry.remove);
    keys.forEach(_providers.remove);
  }

  /// 是否已注册指定模块（Rust 注册表或水合前的 Dart 模块）。
  bool hasModule(String moduleName) {
    if (_modules.containsKey(moduleName)) return true;
    return _registry.keys.any((key) => _moduleOf(key) == moduleName);
  }

  /// 已注册模块名列表（Dart 模块 + Rust 注册表中的模块，去重保序）。
  List<String> get moduleNames {
    final names = <String>{};
    names.addAll(_modules.keys);
    for (final key in _registry.keys) {
      final module = _moduleOf(key);
      if (module != null) names.add(module);
    }
    return names.toList();
  }

  /// 桥接已存在的 ConfigProvider（兼容存量调用；水合后 no-op，不再委托）。
  void bridgeProvider<T>(ConfigProvider<T> provider) {
    if (_hydrated) return;
    _providers[provider.configKey] = provider;
  }

  /// 初始化（兼容旧调用；同步 no-op，实际水合见 [ensureReady]）。
  void initialize() {}

  /// 注册表条目
  ConfigEntry? entry(String key) => _registry[key];

  /// 是否已注册
  bool has(String key) => _registry.containsKey(key);

  /// 所有注册项（按 key 排序，保证输出稳定）
  List<ConfigEntry> list() {
    final entries = _registry.values.toList();
    entries.sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }

  /// 该配置是否允许 Agent 访问
  bool isAgentAccessible(String key) => _registry[key]?.agentAccessible ?? false;

  /// Raw config export for backups (C3/C16).
  ///
  /// This is the **only** caller-facing surface that returns raw values for
  /// every registered key (including secrets); it must never be used for UI or
  /// Agent output. All backup export paths share this single `ConfigApi.export`
  /// route.
  Future<List<ConfigExportValue>> exportRaw() async {
    final api = await _requireApi();
    return api.export();
  }

  /// 读取真实值（内部功能模块使用，不做脱敏）。
  ///
  /// 可信读取：始终按需 `ConfigApi.get(masked:false)`（C3）；非敏感值顺带
  /// 刷新镜像，敏感明文绝不入镜像。
  Future<Object?> getRaw(String key) async {
    final api = await _requireApi();
    final entry = _registry[key];
    if (entry == null) return null;
    final parts = _splitWire(key);
    final raw = await api.get(parts.module, parts.key, masked: false);
    final value = _coerceValue(entry, raw);
    if (!entry.sensitive && value != null) {
      _mirror[key] = value;
    }
    return value;
  }

  /// 读取值（对外默认脱敏：敏感项返回 '***' 表示已设置）。
  ///
  /// - 未注册：null
  /// - 敏感项：`ConfigApi.get(masked:true)`（'***' 或默认值）
  /// - 普通项：先查镜像，再 `ConfigApi.get`
  Future<Object?> get(String key, {bool masked = true}) async {
    final api = await _requireApi();
    final entry = _registry[key];
    if (entry == null) return null;
    final parts = _splitWire(key);
    if (!entry.sensitive && _mirror.containsKey(key)) {
      return _mirror[key];
    }
    final raw = await api.get(parts.module, parts.key, masked: masked);
    final value = _coerceValue(entry, raw);
    if (!entry.sensitive && value != null) {
      _mirror[key] = value;
    }
    return value;
  }

  /// 类型化读取（普通项）
  Future<T?> getT<T>(String key) async {
    final value = await get(key);
    return value is T ? value : null;
  }

  /// 获取单个配置快照（元数据 + 当前值；敏感值脱敏）。
  Future<ConfigSnapshot?> snapshot(String key) async {
    final api = await _requireApi();
    final entry = _registry[key];
    if (entry == null) return null;
    final parts = _splitWire(key);
    final snap = await api.snapshot(parts.module, parts.key);
    if (snap != null) {
      if (!entry.sensitive && snap.value != null) {
        _mirror[key] = _coerceValue(entry, snap.value);
      }
      return snap;
    }
    // 未设置：保留旧语义（value = null），元数据来自注册表。
    return ConfigSnapshot(
      key: entry.key,
      type: entry.type.name,
      value: null,
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

  /// 获取全部配置快照（按 key 排序）
  Future<List<ConfigSnapshot>> snapshots() async {
    await ensureReady();
    final result = <ConfigSnapshot>[];
    for (final entry in list()) {
      final snap = await snapshot(entry.key);
      if (snap != null) result.add(snap);
    }
    return result;
  }

  /// 写入配置（由 Rust 校验/提交/广播事件）。
  ///
  /// 保留 Dart 侧友好校验（未知 key/类型/范围/枚举），随后调用
  /// `ConfigApi.set`；镜像仅对非敏感项即时更新。
  Future<ConfigOpResult> set(
    String key,
    Object? value, {
    ConfigChangeSource source = ConfigChangeSource.internal,
  }) async {
    final api = await _requireApi();
    final entry = _registry[key];
    if (entry == null) {
      return ConfigOpResult.failure('未知配置项: $key', key: key);
    }

    // JSON 类型配置兼容字符串输入：
    // LLM 函数调用参数多为字符串，若 value 是 JSON 字符串则解析为 Map/List
    var normalized = value;
    if (entry.type == ConfigValueType.json && normalized is String) {
      final trimmed = normalized.trim();
      if (trimmed.isNotEmpty) {
        try {
          normalized = jsonDecode(trimmed);
        } catch (_) {
          return ConfigOpResult.failure(
            '配置 $key 需要 JSON 对象（如 {"fontStyle": 3}）或合法 JSON 字符串',
            key: key,
          );
        }
      }
    }

    // 类型校验
    if (!_typeMatches(entry, normalized)) {
      return ConfigOpResult.failure(
        '配置 $key 需要 ${_typeLabel(entry.type)} 类型',
        key: key,
      );
    }

    // 数值范围校验
    if (normalized is num && (entry.min != null || entry.max != null)) {
      final min = entry.min;
      final max = entry.max;
      if (min != null && normalized < min) {
        return ConfigOpResult.failure('配置 $key 不能小于 $min', key: key);
      }
      if (max != null && normalized > max) {
        return ConfigOpResult.failure('配置 $key 不能大于 $max', key: key);
      }
    }

    // 枚举校验
    final enumValues = entry.enumValues;
    if (enumValues != null && normalized is String) {
      if (!enumValues.contains(normalized)) {
        return ConfigOpResult.failure(
          '配置 $key 取值必须在 ${enumValues.join('/')} 中',
          key: key,
        );
      }
    }

    final parts = _splitWire(key);
    try {
      final result = await api.set(
        parts.module,
        parts.key,
        normalized,
        source: source,
      );
      if (result.success && !entry.sensitive && result.value != null) {
        _mirror[key] = _coerceValue(entry, result.value);
      }
      return result;
    } catch (error) {
      return ConfigOpResult.failure(
        '保存配置失败: $key ($error)',
        key: key,
        defaultValue: entry.defaultValue,
      );
    }
  }

  /// 恢复默认值（reset）
  Future<ConfigOpResult> reset(
    String key, {
    ConfigChangeSource source = ConfigChangeSource.internal,
  }) async {
    final api = await _requireApi();
    final entry = _registry[key];
    if (entry == null) {
      return ConfigOpResult.failure('未知配置项: $key', key: key);
    }
    final parts = _splitWire(key);
    try {
      final result = await api.reset(parts.module, parts.key, source: source);
      if (result.success && !entry.sensitive && result.value != null) {
        _mirror[key] = _coerceValue(entry, result.value);
      }
      return result;
    } catch (error) {
      return ConfigOpResult.failure(
        '恢复默认值失败: $key ($error)',
        key: key,
        defaultValue: entry.defaultValue,
      );
    }
  }

  /// 清除配置（恢复未设置状态）。
  ///
  /// 旧值在清除**之前**捕获（C26），非敏感项用于事件 oldValue 兜底。
  Future<ConfigOpResult> clear(
    String key, {
    ConfigChangeSource source = ConfigChangeSource.internal,
  }) async {
    final api = await _requireApi();
    final entry = _registry[key];
    if (entry == null) {
      return ConfigOpResult.failure('未知配置项: $key', key: key);
    }
    final oldValue = await getRaw(key);
    if (!entry.sensitive && oldValue != null) {
      _pendingClearOld[key] = oldValue;
    }
    final parts = _splitWire(key);
    try {
      final result = await api.clear(parts.module, parts.key, source: source);
      _mirror.remove(key);
      return result;
    } catch (error) {
      _pendingClearOld.remove(key);
      return ConfigOpResult.failure(
        '清除配置失败: $key ($error)',
        key: key,
        defaultValue: entry.defaultValue,
      );
    }
  }

  /// 监听指定配置变化（wire key 精确匹配；过滤器下推到 Rust）。
  Stream<ConfigChangeEvent> watch(String wireKey) async* {
    final api = await _requireApi();
    final parts = _splitWire(wireKey);
    yield* api.watch(parts.module, parts.key).map(_normalizeEvent);
  }

  /// 监听整个模块的变化（过滤器下推到 Rust；`key=null`）。
  Stream<ConfigChangeEvent> watchModule(String module) async* {
    final api = await _requireApi();
    yield* api.watch(module).map(_normalizeEvent);
  }

  /// 监听多个配置变化（每个 wire key 各自下推精确过滤器）。
  Stream<ConfigChangeEvent> watchMany(List<String> keys) {
    final unique = keys.toSet().toList();
    if (unique.isEmpty) return const Stream<ConfigChangeEvent>.empty();
    final subs = <StreamSubscription<ConfigChangeEvent>>[];
    late final StreamController<ConfigChangeEvent> controller;
    controller = StreamController<ConfigChangeEvent>(
      onListen: () {
        for (final key in unique) {
          subs.add(
            watch(key).listen(controller.add, onError: controller.addError),
          );
        }
      },
      onCancel: () {
        for (final sub in subs) {
          unawaited(sub.cancel());
        }
        subs.clear();
      },
    );
    return controller.stream;
  }

  /// 释放资源
  void dispose() {
    for (final sub in _globalSubs) {
      unawaited(sub.cancel());
    }
    _globalSubs.clear();
    if (!_changeController.isClosed) {
      _changeController.close();
    }
    _readyFuture = null;
    _hydrated = false;
  }

  Future<ConfigRustApi> _requireApi() async {
    await ensureReady();
    final api = _api;
    if (api == null) {
      throw StateError('ConfigService: Rust ConfigApi 未初始化');
    }
    return api;
  }

  String? _moduleOf(String wireKey) {
    final dot = wireKey.indexOf('.');
    if (dot <= 0) return null;
    return wireKey.substring(0, dot);
  }

  ({String module, String key}) _splitWire(String wireKey) {
    final dot = wireKey.indexOf('.');
    if (dot <= 0 || dot == wireKey.length - 1) {
      throw ArgumentError.value(
        wireKey,
        'wireKey',
        '必须是 module.key 形式（如 theme.mode）',
      );
    }
    return (
      module: wireKey.substring(0, dot),
      key: wireKey.substring(dot + 1),
    );
  }

  ConfigChangeEvent _normalizeEvent(ConfigChangeEvent event) {
    final pending = _pendingClearOld.remove(event.key);
    final oldValue = event.oldValue ?? pending;
    return ConfigChangeEvent(
      key: event.key,
      oldValue: _coerceByKey(event.key, oldValue),
      newValue: _coerceByKey(event.key, event.newValue),
      source: event.source,
    );
  }

  Object? _coerceByKey(String key, Object? value) {
    final entry = _registry[key];
    if (entry == null) return value;
    return _coerceValue(entry, value);
  }

  Object? _coerceValue(ConfigEntry entry, Object? value) {
    if (value == null) return null;
    switch (entry.type) {
      case ConfigValueType.bool:
      case ConfigValueType.string:
        return value;
      case ConfigValueType.int:
        return value is num ? value.toInt() : value;
      case ConfigValueType.double:
        return value is num ? value.toDouble() : value;
      case ConfigValueType.stringList:
        if (value is List) return List<String>.from(value);
        return value;
      case ConfigValueType.json:
        return _deepJson(value);
    }
  }

  /// 规范化 JSON 值（`Map<String, dynamic>` / `List<Object?>`），避免
  /// `getT<List<String>>`/`getT<Map<String, dynamic>>` 因 `List<dynamic>`
  /// 静默失败（C26/C6）。
  Object? _deepJson(Object? value) {
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          '${entry.key}': _deepJson(entry.value),
      };
    }
    if (value is List) {
      return value.map(_deepJson).toList();
    }
    return value;
  }

  bool _typeMatches(ConfigEntry entry, Object? value) {
    if (value == null) return true;
    return switch (entry.type) {
      ConfigValueType.bool => value is bool,
      ConfigValueType.int => value is int,
      ConfigValueType.double => value is double || value is int,
      ConfigValueType.string => value is String,
      ConfigValueType.stringList =>
        value is List && value.every((e) => e is String),
      ConfigValueType.json => value is Map || value is List,
    };
  }

  String _typeLabel(ConfigValueType type) {
    return switch (type) {
      ConfigValueType.bool => '布尔值',
      ConfigValueType.int => '整数',
      ConfigValueType.double => '数字',
      ConfigValueType.string => '字符串',
      ConfigValueType.stringList => '字符串列表',
      ConfigValueType.json => 'JSON',
    };
  }
}

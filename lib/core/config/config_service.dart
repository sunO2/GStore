/// 统一配置服务（ConfigService）
///
/// 配置系统的统一门面：
/// - 声明式注册表（ConfigEntry）：类型/默认值/敏感/Agent 白名单/描述/分组/单位/示例
/// - 模块化注册（ConfigModule）：模块初始化时注册自身配置，支持覆盖更新与注销
/// - 读写路由：已注册 ConfigProvider 的 key 委托 provider，其余走 ConfigStore
/// - 统一事件总线：所有变更广播 ConfigChangeEvent，功能模块订阅后主动响应
/// - 结构化快照（ConfigSnapshot）：元数据 + 当前值合并返回，Agent 一次解析全懂
/// - 安全：敏感项（密码/API Key）读取自动脱敏，Agent 写白名单校验
///
/// 核心架构：写入方（Agent/UI）只负责写配置，功能模块作为订阅者
/// 监听 onChange 后自行更新，实现"配置修改 → 功能主动响应"。
library;

import 'dart:async';

import 'package:gstore/core/core.dart';

import 'config_provider.dart';
import 'config_store.dart';

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
  /// 配置 key
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
  /// 配置 key（唯一标识）
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
class ConfigService {
  ConfigService._internal();

  static ConfigService? _instance;
  static ConfigService get instance => _instance ??= ConfigService._internal();

  /// 注册表
  final Map<String, ConfigEntry> _registry = {};

  /// 已注册的 ConfigProvider 桥接表（key → provider）
  final Map<String, ConfigProvider<dynamic>> _providers = {};

  /// 已注册的配置模块（moduleName → module）
  final Map<String, ConfigModule> _modules = {};

  /// 变更事件控制器
  final _changeController =
      StreamController<ConfigChangeEvent>.broadcast();

  /// 配置变化事件流
  Stream<ConfigChangeEvent> get onChange => _changeController.stream;

  /// 注册配置项（重复 key 覆盖更新）
  void register(ConfigEntry entry) {
    _registry[entry.key] = entry;
    if (entry.sensitive) {
      ConfigStore.instance.markSensitive(entry.key);
    }
  }

  /// 注册批量配置项
  void registerAll(List<ConfigEntry> entries) {
    for (final entry in entries) {
      register(entry);
    }
  }

  /// 注册配置模块（幂等：同名模块重复注册 = 覆盖更新）
  ///
  /// 注册后模块的配置项立即可用（list/get/set/clear/快照）。
  void registerModule(ConfigModule module) {
    _modules[module.moduleName] = module;
    registerAll(module.configs);
    module.registerProviders(this);
  }

  /// 注销配置模块
  ///
  /// 移除该模块的配置项与 provider 桥接（已存储的数据保留，避免误删用户配置）。
  void unregisterModule(String moduleName) {
    final module = _modules.remove(moduleName);
    if (module == null) return;
    final keys = module.configs.map((e) => e.key).toSet();
    keys.forEach(_registry.remove);
    keys.forEach(_providers.remove);
  }

  /// 是否已注册指定模块
  bool hasModule(String moduleName) => _modules.containsKey(moduleName);

  /// 已注册模块名列表（按注册顺序）
  List<String> get moduleNames => _modules.keys.toList();

  /// 桥接已存在的 ConfigProvider（读写委托，保持现有机制兼容）
  void bridgeProvider<T>(ConfigProvider<T> provider) {
    _providers[provider.configKey] =
        provider as ConfigProvider<dynamic>;
  }

  /// 初始化（幂等；需先 ConfigStore.initialize）
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

  /// 读取真实值（内部功能模块使用，不做脱敏）
  ///
  /// - 有 provider 桥接：委托 provider.load()（对象转 Map 返回）
  /// - 否则：从 ConfigStore 读取（按注册类型转换）
  Future<Object?> getRaw(String key) async {
    final provider = _providers[key];
    if (provider != null) {
      final value = await provider.load();
      return _toJson(value);
    }
    final entry = _registry[key];
    if (entry == null) return null;
    final store = ConfigStore.instance;
    return switch (entry.type) {
      ConfigValueType.bool => await store.readBool(key),
      ConfigValueType.int => await store.readInt(key),
      ConfigValueType.double => await store.readDouble(key),
      ConfigValueType.string => await store.readString(key),
      ConfigValueType.stringList => await store.readStringList(key),
      ConfigValueType.json => await store.readValue(key),
    };
  }

  /// 将对象转为可 JSON 序列化的 Map（有 toJson 时）
  Object? _toJson(Object? value) {
    if (value == null) return null;
    if (value is Map || value is List || value is String ||
        value is bool || value is num) {
      return value;
    }
    try {
      final m = (value as dynamic).toJson();
      return m is Map ? m : value;
    } catch (_) {
      return value;
    }
  }

  /// 读取值（对外默认脱敏：敏感项返回 '***' 表示已设置）
  ///
  /// 返回值：
  /// - 未设置：null
  /// - 敏感项已设置：'***'
  /// - 普通项：真实值
  Future<Object?> get(String key, {bool masked = true}) async {
    if (masked && _registry[key]?.sensitive == true) {
      final exists = await ConfigStore.instance.contains(key) ||
          _providers.containsKey(key) && await _providers[key]!.exists();
      return exists ? '***' : null;
    }
    return getRaw(key);
  }

  /// 类型化读取（普通项）
  Future<T?> getT<T>(String key) async {
    final value = await get(key);
    return value is T ? value : null;
  }

  /// 获取单个配置快照（元数据 + 当前值；敏感值脱敏）
  Future<ConfigSnapshot?> snapshot(String key) async {
    final entry = _registry[key];
    if (entry == null) return null;
    final value = await get(key);
    return ConfigSnapshot(
      key: entry.key,
      type: entry.type.name,
      value: value,
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
    final result = <ConfigSnapshot>[];
    for (final entry in list()) {
      final snap = await snapshot(entry.key);
      if (snap != null) result.add(snap);
    }
    return result;
  }

  /// 写入配置（广播事件；已桥接 provider 时委托 provider.save）
  ///
  /// [source] 变更来源
  Future<ConfigOpResult> set(
    String key,
    Object? value, {
    ConfigChangeSource source = ConfigChangeSource.internal,
  }) async {
    final entry = _registry[key];
    if (entry == null) {
      return ConfigOpResult.failure('未知配置项: $key', key: key);
    }

    // 类型校验
    if (!_typeMatches(entry, value)) {
      return ConfigOpResult.failure(
        '配置 $key 需要 ${_typeLabel(entry.type)} 类型',
        key: key,
      );
    }

    // 数值范围校验
    if (value is num && (entry.min != null || entry.max != null)) {
      if (entry.min != null && value < entry.min!) {
        return ConfigOpResult.failure(
          '配置 $key 不能小于 ${entry.min}',
          key: key,
        );
      }
      if (entry.max != null && value > entry.max!) {
        return ConfigOpResult.failure(
          '配置 $key 不能大于 ${entry.max}',
          key: key,
        );
      }
    }

    // 枚举校验
    if (entry.enumValues != null && value is String) {
      if (!entry.enumValues!.contains(value)) {
        return ConfigOpResult.failure(
          '配置 $key 取值必须在 ${entry.enumValues!.join('/')} 中',
          key: key,
        );
      }
    }

    final oldValue = await getRaw(key);

    // 桥接 provider：Map 值走 importFromJson（保持与备份导入一致），否则 save
    final provider = _providers[key];
    if (provider != null) {
      final ok = value is Map<String, dynamic>
          ? await provider.importFromJson(value)
          : await provider.save(value);
      if (!ok) {
        return ConfigOpResult.failure('保存配置失败: $key', key: key);
      }
    } else {
      final ok = await ConfigStore.instance.write(key, value);
      if (!ok) {
        return ConfigOpResult.failure('保存配置失败: $key', key: key);
      }
    }

    _emit(key, oldValue, value, source);
    return ConfigOpResult.success(
      '配置已更新: $key',
      key: key,
      value: value,
      defaultValue: entry.defaultValue,
    );
  }

  /// 恢复默认值（reset）
  Future<ConfigOpResult> reset(
    String key, {
    ConfigChangeSource source = ConfigChangeSource.internal,
  }) async {
    final entry = _registry[key];
    if (entry == null) {
      return ConfigOpResult.failure('未知配置项: $key', key: key);
    }
    if (entry.defaultValue == null) {
      await clear(key, source: source);
      return ConfigOpResult.success(
        '配置已清除: $key',
        key: key,
        defaultValue: null,
      );
    }
    return set(key, entry.defaultValue, source: source);
  }

  /// 清除配置（恢复未设置状态）
  Future<ConfigOpResult> clear(
    String key, {
    ConfigChangeSource source = ConfigChangeSource.internal,
  }) async {
    final entry = _registry[key];
    if (entry == null) {
      return ConfigOpResult.failure('未知配置项: $key', key: key);
    }
    final provider = _providers[key];
    if (provider != null) {
      await provider.clear();
    } else {
      await ConfigStore.instance.remove(key);
    }
    _emit(key, await getRaw(key), null, source);
    return ConfigOpResult.success(
      '配置已清除: $key',
      key: key,
      value: null,
      defaultValue: entry.defaultValue,
    );
  }

  /// 监听指定配置变化
  Stream<ConfigChangeEvent> watch(String key) {
    return onChange.where((e) => e.key == key);
  }

  /// 监听多个配置变化
  Stream<ConfigChangeEvent> watchMany(List<String> keys) {
    final set = keys.toSet();
    return onChange.where((e) => set.contains(e.key));
  }

  void _emit(String key, Object? oldValue, Object? newValue,
      ConfigChangeSource source) {
    if (_changeController.isClosed) return;
    _changeController.add(ConfigChangeEvent(
      key: key,
      oldValue: oldValue,
      newValue: newValue,
      source: source,
    ));
  }

  bool _typeMatches(ConfigEntry entry, Object? value) {
    if (value == null) return true;
    return switch (entry.type) {
      ConfigValueType.bool => value is bool,
      ConfigValueType.int => value is int,
      ConfigValueType.double => value is double || value is int,
      ConfigValueType.string => value is String,
      ConfigValueType.stringList => value is List && value.every((e) => e is String),
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

  /// 释放资源
  void dispose() {
    _changeController.close();
  }
}

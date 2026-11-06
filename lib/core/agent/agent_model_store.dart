import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';

/// LLM Provider 类型
enum AgentLlmProvider {
  /// Google Gemini
  google,

  /// OpenAI 及 OpenAI 兼容服务（可自定义 BaseURL）
  openai,
}

/// 单个模型配置
class AgentModel {
  /// 唯一标识
  String id;

  /// 显示名称（用户自定义）
  String name;

  /// Provider 类型
  AgentLlmProvider provider;

  /// API Key
  String apiKey;

  /// 模型名称
  String model;

  /// Base URL
  String baseUrl;

  /// 是否启用工具调用（function calling）。
  /// 本地小模型的 tool calling 普遍不可靠，降级模式下关闭可避免乱调工具。
  bool toolsEnabled;

  /// 是否在对话中展示思考过程（reasoning / think 标签）。
  /// 关闭后思考内容仍会被记录，只是不在时间轴展开。
  bool showReasoning;

  AgentModel({
    required this.id,
    this.name = '',
    this.provider = AgentLlmProvider.google,
    this.apiKey = '',
    this.model = '',
    this.baseUrl = '',
    this.toolsEnabled = true,
    this.showReasoning = true,
  });

  /// 默认模型名（根据 provider）
  String get defaultModel {
    switch (provider) {
      case AgentLlmProvider.google:
        return 'gemini-2.0-flash';
      case AgentLlmProvider.openai:
        return 'gpt-4o-mini';
    }
  }

  /// 默认 Base URL（根据 provider）
  String get defaultBaseUrl {
    switch (provider) {
      case AgentLlmProvider.google:
        return '';
      case AgentLlmProvider.openai:
        return 'https://api.openai.com/v1';
    }
  }

  /// 是否已配置 API Key
  bool get isConfigured => apiKey.isNotEmpty;

  /// 实际使用的模型名
  String get effectiveModel => model.isNotEmpty ? model : defaultModel;

  /// 实际使用的 Base URL
  String get effectiveBaseUrl => baseUrl.isNotEmpty ? baseUrl : defaultBaseUrl;

  /// 显示名称（无名称时用模型名）
  String get displayName =>
      name.isNotEmpty ? name : (model.isNotEmpty ? model : defaultModel);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'provider': provider.name,
      'apiKey': apiKey,
      'model': model,
      'baseUrl': baseUrl,
      'toolsEnabled': toolsEnabled,
      'showReasoning': showReasoning,
    };
  }

  factory AgentModel.fromJson(Map<String, dynamic> json) {
    return AgentModel(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      provider: AgentLlmProvider.values.firstWhere(
        (e) => e.name == json['provider'],
        orElse: () => AgentLlmProvider.google,
      ),
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      // 旧配置无此字段 → 默认启用，保持既有行为
      toolsEnabled: json['toolsEnabled'] as bool? ?? true,
      showReasoning: json['showReasoning'] as bool? ?? true,
    );
  }
}

/// 解码 `agent.models` 的存储原始值（**绝不抛**）。
///
/// 兼容三种历史形态（C6）：
/// * `List`（已解码的 typed JSON，当前格式）→ 逐条 [AgentModel.fromJson]；
/// * `String`（旧 `readString`/`writeString` 落盘的 JSON 字符串）→ 解码一次；
/// * `String` 再套一层字符串（历史双重编码）→ 再解码一次。
///
/// 非列表 / 非法 JSON / 损坏条目 → 跳过（返回空或部分列表）。
({List<AgentModel> models, bool fromLegacyString}) decodeAgentModelsValue(
  Object? raw,
) {
  final decoded = _decodeAgentModelsJson(raw);
  // 仅当历史字符串**成功解出列表**时才迁移；畸形数据保持原样（不覆盖用户数据）。
  final fromLegacyString = raw is String && decoded is List;
  if (decoded is! List) {
    return (models: <AgentModel>[], fromLegacyString: false);
  }
  final models = <AgentModel>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    try {
      models.add(AgentModel.fromJson(
        item.map((key, value) => MapEntry(key.toString(), value)),
      ));
    } catch (error) {
      debugPrint('[AgentModelStore] 跳过损坏模型条目: $error');
    }
  }
  return (models: models, fromLegacyString: fromLegacyString);
}

/// 把（可能是历史字符串编码的）原始值展开成 JSON 结构。
Object? _decodeAgentModelsJson(Object? raw) {
  var value = raw;
  // 最多展开两层：单层 JSON 字符串 + 历史双重编码。
  for (var depth = 0; depth < 2 && value is String; depth++) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final looksJson = text.startsWith('[') ||
        text.startsWith('{') ||
        text.startsWith('"');
    if (!looksJson) return null;
    try {
      value = jsonDecode(text);
    } catch (error) {
      debugPrint('[AgentModelStore] 模型列表 JSON 解析失败，按空列表处理: $error');
      return null;
    }
  }
  return value;
}

/// 模型存储管理器
/// 管理多个模型配置，支持选择当前使用的模型
/// 存储走统一 ConfigService/ConfigStore（key 见 ConfigKeys）
///
/// `agent.models` 注册为 `json` 类型（C6）：写入用 [ConfigStore.write] 落
/// `List<Map>`，读取用 [ConfigStore.readValue] 拿回 typed JSON；只有旧数据
/// （历史 `writeString` 编码的字符串）才走 [ConfigStore.readString] 兼容路径
/// 并在读取时**一次性**迁移为 typed 列表。
///
/// 该 store 是**全局共享单例**（[load] 返回同一实例）并继承 [ChangeNotifier]：
/// 设置页、备份恢复、AgentService 都监听同一份状态，配置外部变更（ConfigService
/// 事件）也会自动重新加载并通知，避免多处各持一份副本导致状态漂移。
class AgentModelStore extends ChangeNotifier {
  /// 全局共享实例（[load] 首次调用时创建）
  static AgentModelStore? _instance;

  /// 并发 [load] 去重
  static Future<AgentModelStore>? _loading;

  /// 所有模型配置
  List<AgentModel> models;

  /// 当前选中的模型 ID
  String? selectedId;

  /// reload 串行链：写入后再次 reload 必须读到最新配置，避免竞态
  Future<void> _reloadChain = Future<void>.value();

  /// 配置变更订阅
  StreamSubscription<ConfigChangeEvent>? _configSub;

  /// 配置变更防抖计时器
  Timer? _reloadTimer;

  /// 上次已应用的配置签名（用于跳过无变化通知）
  String? _signatureCache;

  /// 批量操作期间暂停通知（合并为一次）
  bool _suspendNotify = false;

  /// 是否已释放
  bool _disposed = false;

  AgentModelStore({List<AgentModel>? models, this.selectedId})
      : models = models ?? [];

  /// 当前选中的模型
  AgentModel? get selected =>
      selectedId == null ? null : _findById(selectedId!);

  AgentModel? _findById(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 获取共享 store（首次会读取配置并订阅变更）。
  ///
  /// 已存在实例时**必然**重新读取配置（保留「写存储后 load 能看到新值」的
  /// 语义），但返回的始终是同一实例。
  static Future<AgentModelStore> load() async {
    final existing = _instance;
    if (existing != null) {
      await existing.reload();
      return existing;
    }
    final loading = _loading;
    if (loading != null) return loading;
    final future = _createInstance();
    _loading = future;
    try {
      return await future;
    } finally {
      if (identical(_loading, future)) _loading = null;
    }
  }

  static Future<AgentModelStore> _createInstance() async {
    final store = AgentModelStore();
    await store._initialize();
    _instance = store;
    return store;
  }

  /// 首次初始化：读取配置并订阅配置变更。
  Future<void> _initialize() async {
    await reload();
    _configSub = ConfigService.instance.onChange.listen(
      (event) {
        if (event.key != ConfigKeys.agentModels &&
            event.key != ConfigKeys.agentSelectedModelId) {
          return;
        }
        // 防抖：一次操作可能触发多次写入，合并成一次 reload。
        _reloadTimer?.cancel();
        _reloadTimer = Timer(const Duration(milliseconds: 30), () {
          unawaited(reload());
        });
      },
      onError: (Object error, StackTrace stack) {
        debugPrint('[AgentModelStore] 配置变更订阅失败: $error');
      },
    );
  }

  /// 重新读取配置（串行化，避免并发 reload 互相覆盖）。
  Future<void> reload() {
    final next = _reloadChain.then((_) => _reloadFromConfig());
    _reloadChain = next.catchError((_) {});
    return next;
  }

  Future<void> _reloadFromConfig() async {
    final store = ConfigStore.instance;
    await store.initialize();
    final selected = await store.readString(ConfigKeys.agentSelectedModelId);
    // 不同后端对「未设置」返回 null 或默认空串；空串等价于无选中。
    final normalized = (selected == null || selected.isEmpty) ? null : selected;
    final loaded = await _readModels(store);
    final signature = _signatureFor(normalized, loaded);
    if (signature == _signatureCache) return;
    // 原地替换内容，保持外部持有的 models 引用有效。
    models
      ..clear()
      ..addAll(loaded);
    selectedId = normalized;
    _signatureCache = signature;
    _notify();
  }

  /// 由当前字段构造配置签名。
  String _signature() => _signatureFor(selectedId, models);

  /// 由指定选中 ID + 模型列表构造配置签名。
  String _signatureFor(String? selected, List<AgentModel> models) =>
      '${selected ?? ''}|${jsonEncode(models.map((m) => m.toJson()).toList())}';

  /// 通知监听者（批量/释放期间跳过）。
  void _notify() {
    if (!_suspendNotify && !_disposed) notifyListeners();
  }

  /// 批量执行并在结束时只通知一次。
  Future<T> batch<T>(Future<T> Function() action) async {
    final previous = _suspendNotify;
    _suspendNotify = true;
    try {
      return await action();
    } finally {
      _suspendNotify = previous;
      if (!previous) _notify();
    }
  }

  /// 读取模型列表并完成旧格式的一次性迁移。
  static Future<List<AgentModel>> _readModels(ConfigStore store) async {
    // 首选 typed JSON（List<Map>）；readValue 为 null 时才回退旧字符串 shim。
    Object? raw = await store.readValue(ConfigKeys.agentModels);
    if (raw == null || (raw is String && raw.trim().isEmpty)) {
      raw = await store.readString(ConfigKeys.agentModels);
    }
    final decoded = decodeAgentModelsValue(raw);
    if (decoded.fromLegacyString) {
      // 旧字符串编码 → 迁移为 typed List<Map>（只写一次；后续读走 readValue）。
      await _writeModels(store, decoded.models);
    }
    return decoded.models;
  }

  /// 保存到本地存储（一次写入，一次通知）
  Future<void> save() async {
    final store = ConfigStore.instance;
    await store.initialize();
    await _writeModels(store, models);
    if (selectedId != null) {
      await store.writeString(ConfigKeys.agentSelectedModelId, selectedId!);
    } else {
      await store.remove(ConfigKeys.agentSelectedModelId);
    }
    _signatureCache = _signature();
    _notify();
  }

  /// 以 typed JSON（`List<Map>`）写入模型列表。
  static Future<void> _writeModels(
    ConfigStore store,
    List<AgentModel> models,
  ) {
    return store.write(
      ConfigKeys.agentModels,
      models.map((e) => e.toJson()).toList(),
    );
  }

  /// 用备份数据恢复模型：按 id upsert（同 id 原位替换，新 id 追加）。
  ///
  /// [selectedId] 存在则选中；不存在或为空时回退到首个模型（非空时）。
  /// 只写一次配置并只通知一次。
  Future<void> restoreModels(
    List<AgentModel> incoming, {
    String? selectedId,
  }) async {
    for (final model in incoming) {
      final index = models.indexWhere((e) => e.id == model.id);
      if (index >= 0) {
        models[index] = model; // 同 id：原位更新，不产生重复
      } else {
        models.add(model);
      }
    }
    if (selectedId != null && models.any((m) => m.id == selectedId)) {
      this.selectedId = selectedId;
    } else if (models.isNotEmpty) {
      this.selectedId = models.first.id;
    } else {
      this.selectedId = null;
    }
    await save();
  }

  /// 添加模型（同 id 已存在则更新；未指定选中时自动选中）
  Future<void> add(AgentModel model, {bool select = true}) async {
    final index = models.indexWhere((e) => e.id == model.id);
    if (index >= 0) {
      models[index] = model; // 去重：同 id 更新而非重复添加
    } else {
      models.add(model);
    }
    if (select || selectedId == null) {
      selectedId = model.id;
    }
    await save();
  }

  /// 更新模型
  Future<void> update(AgentModel model) async {
    final index = models.indexWhere((e) => e.id == model.id);
    if (index >= 0) {
      models[index] = model;
    }
    await save();
  }

  /// 删除模型
  Future<void> remove(String id) async {
    models.removeWhere((e) => e.id == id);
    if (selectedId == id) {
      selectedId = models.isNotEmpty ? models.first.id : null;
    }
    await save();
  }

  /// 选择当前使用的模型（广播选中 ID + 持久化模型列表，然后通知监听者）
  Future<void> select(String id) async {
    selectedId = id;
    await ConfigService.instance.set(
      ConfigKeys.agentSelectedModelId,
      id,
      source: ConfigChangeSource.user,
    );
    await _persistModels();
    _signatureCache = _signature();
    _notify();
  }

  Future<void> _persistModels() async {
    await _writeModels(ConfigStore.instance, models);
  }

  /// 清空所有
  Future<void> clearAll() async {
    models.clear();
    selectedId = null;
    await save();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 释放订阅/计时器并标记已释放（供 [resetForTest] 使用）。
  void _disposeForTest() {
    _reloadTimer?.cancel();
    _reloadTimer = null;
    _configSub?.cancel();
    _configSub = null;
    _reloadChain = Future<void>.value();
    if (!_disposed) {
      dispose();
    }
  }

  /// 测试重置单例状态（释放旧实例，清空并发/串行链）。
  @visibleForTesting
  static void resetForTest() {
    final instance = _instance;
    _instance = null;
    _loading = null;
    instance?._disposeForTest();
  }
}

/// 生成唯一 ID
String generateModelId() {
  return '${DateTime.now().millisecondsSinceEpoch}';
}

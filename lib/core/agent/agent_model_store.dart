import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
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
class AgentModelStore {

  /// 所有模型配置
  List<AgentModel> models;

  /// 当前选中的模型 ID
  String? selectedId;

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

  /// 从本地存储加载（typed JSON，含 API Key 明文——供 LLM 客户端使用）
  static Future<AgentModelStore> load() async {
    final store = ConfigStore.instance;
    await store.initialize();
    final selected = await store.readString(ConfigKeys.agentSelectedModelId);
    return AgentModelStore(
      models: await _readModels(store),
      // 不同后端对「未设置」返回 null 或默认空串；空串等价于无选中。
      selectedId: (selected == null || selected.isEmpty) ? null : selected,
    );
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

  /// 保存到本地存储
  Future<void> save() async {
    final store = ConfigStore.instance;
    await store.initialize();
    await _writeModels(store, models);
    if (selectedId != null) {
      await store.writeString(ConfigKeys.agentSelectedModelId, selectedId!);
    } else {
      await store.remove(ConfigKeys.agentSelectedModelId);
    }
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

  /// 选择当前使用的模型（经 ConfigService 广播，AgentService 监听后主动重配）
  Future<void> select(String id) async {
    selectedId = id;
    await ConfigService.instance.set(
      ConfigKeys.agentSelectedModelId,
      id,
      source: ConfigChangeSource.user,
    );
    await _persistModels();
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
}

/// 生成唯一 ID
String generateModelId() {
  return '${DateTime.now().millisecondsSinceEpoch}';
}

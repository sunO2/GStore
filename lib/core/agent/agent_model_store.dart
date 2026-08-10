import 'dart:convert';
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

  AgentModel({
    required this.id,
    this.name = '',
    this.provider = AgentLlmProvider.google,
    this.apiKey = '',
    this.model = '',
    this.baseUrl = '',
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
    );
  }
}

/// 模型存储管理器
/// 管理多个模型配置，支持选择当前使用的模型
/// 存储走统一 ConfigService/ConfigStore（key 见 ConfigKeys）
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

  /// 从本地存储加载
  static Future<AgentModelStore> load() async {
    final store = ConfigStore.instance;
    await store.initialize();
    final raw = await store.readString(ConfigKeys.agentModels);
    List<AgentModel> models = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        models = list
            .map((e) => AgentModel.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        // 解析失败则返回空列表
      }
    }
    return AgentModelStore(
      models: models,
      selectedId: await store.readString(ConfigKeys.agentSelectedModelId),
    );
  }

  /// 保存到本地存储
  Future<void> save() async {
    final store = ConfigStore.instance;
    await store.initialize();
    final raw = jsonEncode(models.map((e) => e.toJson()).toList());
    await store.writeString(ConfigKeys.agentModels, raw);
    if (selectedId != null) {
      await store.writeString(ConfigKeys.agentSelectedModelId, selectedId!);
    } else {
      await store.remove(ConfigKeys.agentSelectedModelId);
    }
  }

  /// 添加模型（未指定选中时自动选中）
  Future<void> add(AgentModel model, {bool select = true}) async {
    models.add(model);
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
    final store = ConfigStore.instance;
    final raw = jsonEncode(models.map((e) => e.toJson()).toList());
    await store.writeString(ConfigKeys.agentModels, raw);
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

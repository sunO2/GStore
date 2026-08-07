import 'dart:convert';
import 'package:gstore/core/core.dart';
import '../channel/channel.dart';
import '../config/config_storage.dart';
import 'models/step_model.dart';
import 'models/workflow_model.dart';
import 'engine/workflow_engine.dart';

export 'models/step_model.dart';
export 'models/workflow_model.dart';
export 'engine/workflow_engine.dart';

/// 工作流管理器
class WorkflowManager {
  static final WorkflowManager instance = WorkflowManager._();
  WorkflowManager._();

  final WorkflowEngine _engine = WorkflowEngine();
  final List<WorkflowModel> _workflows = [];
  final Map<String, dynamic> _cache = {};

  ConfigStorage? _storage;
  static const String _storageKey = 'workflows_data';

  /// 初始化存储
  Future<void> initialize(ConfigStorage storage) async {
    _storage = storage;
    await _loadFromStorage();
  }

  /// 获取所有工作流
  List<WorkflowModel> get workflows => List.unmodifiable(_workflows);

  /// 获取工作流引擎
  WorkflowEngine get engine => _engine;

  /// 添加工作流
  void addWorkflow(WorkflowModel workflow) {
    _workflows.add(workflow);
    _saveToStorage();
  }

  /// 删除工作流
  void removeWorkflow(String id) {
    _workflows.removeWhere((w) => w.id == id);
    _saveToStorage();
  }

  /// 更新工作流
  void updateWorkflow(WorkflowModel workflow) {
    final index = _workflows.indexWhere((w) => w.id == workflow.id);
    if (index >= 0) {
      _workflows[index] = workflow;
      _saveToStorage();
    }
  }

  /// 获取工作流
  WorkflowModel? getWorkflow(String id) {
    try {
      return _workflows.firstWhere((w) => w.id == id);
    } catch (e) {
      return null;
    }
  }

  /// 根据渠道类型和函数名获取工作流
  List<WorkflowModel> getWorkflowsByChannelFunction(ChannelType channelType, String functionName) {
    return _workflows.where((w) =>
      w.channelType == channelType && w.functionName == functionName
    ).toList();
  }

  /// 执行工作流
  Future<WorkflowResult> executeWorkflow(
    String workflowId, {
    Map<String, dynamic>? inputParameters,
    Function(String stepId, StepOutput output)? onStepComplete,
  }) async {
    final workflow = getWorkflow(workflowId);
    if (workflow == null) {
      return WorkflowResult.failure('Workflow not found: $workflowId', Duration.zero);
    }
    return executeWorkflowDirect(workflow, inputParameters: inputParameters, onStepComplete: onStepComplete);
  }

  /// 直接执行工作流模型
  Future<WorkflowResult> executeWorkflowDirect(
    WorkflowModel workflow, {
    Map<String, dynamic>? inputParameters,
    Function(String stepId, StepOutput output)? onStepComplete,
  }) async {
    return _engine.execute(
      workflow,
      inputParameters: inputParameters,
      onStepComplete: onStepComplete,
    );
  }

  /// 导出所有工作流为 JSON
  String exportToJson() {
    return jsonEncode({
      'version': '1.0',
      'workflows': _workflows.map((w) => w.toJson()).toList(),
    });
  }

  /// 从 JSON 导入工作流
  void importFromJson(String jsonStr) {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final workflowsList = data['workflows'] as List<dynamic>?;
      if (workflowsList != null) {
        for (final w in workflowsList) {
          final workflow = WorkflowModel.fromJson(w as Map<String, dynamic>);
          // 如果已存在则更新，否则添加
          final existingIndex = _workflows.indexWhere((e) => e.id == workflow.id);
          if (existingIndex >= 0) {
            _workflows[existingIndex] = workflow;
          } else {
            _workflows.add(workflow);
          }
        }
        _saveToStorage();
      }
    } catch (e) {
      appLog.error('导入工作流失败: $e');
    }
  }

  /// 从存储加载
  Future<void> _loadFromStorage() async {
    if (_storage == null) return;

    try {
      final jsonStr = await _storage!.getString(_storageKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        importFromJson(jsonStr);
        appLog.info('工作流已从存储加载: ${_workflows.length} 个');
      }
    } catch (e) {
      appLog.error('加载工作流失败: $e');
    }
  }

  /// 保存到存储
  Future<void> _saveToStorage() async {
    if (_storage == null) return;

    try {
      final jsonStr = exportToJson();
      await _storage!.setString(_storageKey, jsonStr);
      appLog.info('工作流已保存: ${_workflows.length} 个');
    } catch (e) {
      appLog.error('保存工作流失败: $e');
    }
  }

  /// 手动保存（公开方法）
  Future<void> save() async {
    await _saveToStorage();
  }

  /// 缓存操作
  void cachePut(String key, dynamic value) {
    _cache[key] = value;
  }

  dynamic? cacheGet(String key) {
    return _cache[key];
  }

  void cacheClear() {
    _cache.clear();
  }
}

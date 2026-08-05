import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import '../../../core/channel/channel.dart';
import '../../../core/workflow/workflow.dart';
import '../../../core/workflow/models/step_position.dart';
import '../../../core/workflow/models/step_model.dart';
import '../../../core/workflow/models/workflow_model.dart';
import '../../../core/workflow/models/variable.dart';

/// 工作流设计器状态
class WorkflowDesignerState {
  /// 工作流列表
  final workflows = <WorkflowModel>[].obs;

  /// 当前选中的工作流
  final selectedWorkflow = Rx<WorkflowModel?>(null);

  /// 当前选中的步骤
  final selectedStep = Rx<StepConfig?>(null);

  /// 步骤在画布上的位置
  final stepPositions = <String, StepPosition>{}.obs;

  /// 是否正在执行
  final isExecuting = false.obs;

  /// 执行结果
  final executionResult = Rx<WorkflowResult?>(null);

  /// 撤销栈
  final undoStack = <WorkflowAction>[].obs;

  /// 重做栈
  final redoStack = <WorkflowAction>[].obs;
}

/// 工作流动作（用于撤销/重做）
abstract class WorkflowAction {
  final String workflowId;
  final DateTime timestamp;

  WorkflowAction({required this.workflowId}) : timestamp = DateTime.now();
}

class AddStepAction extends WorkflowAction {
  final StepConfig step;

  AddStepAction({required super.workflowId, required this.step});
}

class RemoveStepAction extends WorkflowAction {
  final StepConfig step;

  RemoveStepAction({required super.workflowId, required this.step});
}

class UpdateStepAction extends WorkflowAction {
  final StepConfig oldStep;
  final StepConfig newStep;

  UpdateStepAction({
    required super.workflowId,
    required this.oldStep,
    required this.newStep,
  });
}

/// 工作流设计器逻辑
class WorkflowDesignerLogic extends GetxController {
  final state = WorkflowDesignerState();
  final _uuid = const Uuid();

  @override
  void onInit() {
    super.onInit();
    _syncFromManager();
  }

  /// 从 WorkflowManager 同步工作流
  void _syncFromManager() {
    state.workflows.assignAll(WorkflowManager.instance.workflows);
    if (state.workflows.isNotEmpty && state.selectedWorkflow.value == null) {
      final wf = state.workflows.first;
      state.selectedWorkflow.value = wf;
      // 确保加载工作流的位置
      _loadWorkflowPositions(wf);
    }
  }

  /// 加载工作流的位置到状态中
  void _loadWorkflowPositions(WorkflowModel workflow) {
    state.stepPositions.clear();

    // 如果工作流有保存的位置，使用保存的位置
    if (workflow.stepPositions.isNotEmpty) {
      state.stepPositions.addAll(workflow.stepPositions);
    } else {
      // 计算居中的起始位置
      const canvasWidth = 2000.0;
      const canvasHeight = 2000.0;
      const startX = canvasWidth / 2 - 90;
      const startY = canvasHeight / 2 - 50;

      // 初始化所有步骤的位置
      for (var i = 0; i < workflow.steps.length; i++) {
        final step = workflow.steps[i];
        state.stepPositions[step.id] = StepPosition(
          x: startX + (i % 5) * 220,
          y: startY + (i ~/ 5) * 150,
        );
      }
    }
  }

  /// 加载默认工作流
  void _loadDefaultWorkflow() {
    if (state.workflows.isEmpty) {
      final defaultWorkflow = WorkflowModel(
        id: _uuid.v4(),
        name: 'New Workflow',
        description: 'A new workflow',
        steps: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      WorkflowManager.instance.addWorkflow(defaultWorkflow);
      state.workflows.add(defaultWorkflow);
      state.selectedWorkflow.value = defaultWorkflow;
    }
  }

  /// 创建新工作流
  void createWorkflow() {
    final workflow = WorkflowModel(
      id: _uuid.v4(),
      name: 'New Workflow ${state.workflows.length + 1}',
      description: '',
      steps: [],
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    WorkflowManager.instance.addWorkflow(workflow);
    state.workflows.add(workflow);
    state.selectedWorkflow.value = workflow;
    state.selectedStep.value = null;
  }

  /// 删除工作流
  void deleteWorkflow(String id) {
    WorkflowManager.instance.removeWorkflow(id);
    state.workflows.removeWhere((w) => w.id == id);
    if (state.selectedWorkflow.value?.id == id) {
      state.selectedWorkflow.value = state.workflows.isNotEmpty ? state.workflows.first : null;
    }
  }

  /// 保存工作流（手动保存）
  Future<void> saveWorkflow() async {
    await WorkflowManager.instance.save();
    Get.snackbar(
      'Saved',
      'Workflow saved successfully',
      duration: const Duration(seconds: 2),
    );
  }

  /// 导出当前工作流为 JSON
  String exportWorkflow() {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return '{}';
    return workflow.toJsonString();
  }

  /// 选择工作流
  void selectWorkflow(WorkflowModel workflow) {
    state.selectedWorkflow.value = workflow;
    state.selectedStep.value = null;
    // 加载工作流的位置
    _loadWorkflowPositions(workflow);
  }

  /// 添加步骤
  void addStep(StepType type, {double? x, double? y}) {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    // 获取上一个步骤（如果有）
    StepConfig? previousStep;
    if (workflow.steps.isNotEmpty) {
      previousStep = workflow.steps.last;
    }

    final step = StepConfig(
      id: _uuid.v4(),
      type: type,
      name: type.label,
      description: type.description,
      enabled: true,
      options: _getDefaultOptions(type),
      nextStepIds: [],
    );

    // 记录动作用于撤销
    _recordAction(AddStepAction(workflowId: workflow.id, step: step));

    // 添加步骤到工作流
    final updatedSteps = List<StepConfig>.from(workflow.steps)..add(step);

    // 如果有上一个步骤，连接它到新步骤
    if (previousStep != null) {
      final prevStepId = previousStep.id;
      final updatedPreviousStep = previousStep.copyWith(
        nextStepIds: [...previousStep.nextStepIds, step.id],
      );
      final prevIndex = updatedSteps.indexWhere((s) => s.id == prevStepId);
      if (prevIndex >= 0) {
        updatedSteps[prevIndex] = updatedPreviousStep;
      }
    }

    final updatedWorkflow = workflow.copyWith(
      steps: updatedSteps,
      updatedAt: DateTime.now(),
    );

    _updateWorkflow(updatedWorkflow);

    // 设置步骤位置
    final prevPosition = previousStep != null ? state.stepPositions[previousStep.id] : null;
    state.stepPositions[step.id] = StepPosition(
      x: x ?? (prevPosition?.x ?? 100) + 220,
      y: y ?? (prevPosition?.y ?? 100),
    );

    state.selectedStep.value = step;
  }

  /// 添加并行步骤
  void addParallelStep(String afterStepId, StepType type) {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    final afterIndex = workflow.steps.indexWhere((s) => s.id == afterStepId);
    if (afterIndex < 0) return;

    final afterStep = workflow.steps[afterIndex];
    final branchId = afterStep.branchId ?? 'main';

    final step = StepConfig(
      id: _uuid.v4(),
      type: type,
      name: type.label,
      description: type.description,
      enabled: true,
      options: _getDefaultOptions(type),
      branchId: branchId,
      nextStepIds: [],
    );

    _recordAction(AddStepAction(workflowId: workflow.id, step: step));

    final updatedSteps = List<StepConfig>.from(workflow.steps);
    updatedSteps.insert(afterIndex + 1, step);

    final updatedAfterStep = afterStep.copyWith(
      nextStepIds: [...afterStep.nextStepIds, step.id],
    );
    updatedSteps[afterIndex] = updatedAfterStep;

    final updatedWorkflow = workflow.copyWith(
      steps: updatedSteps,
      updatedAt: DateTime.now(),
    );

    _updateWorkflow(updatedWorkflow);

    final position = state.stepPositions[afterStepId];
    state.stepPositions[step.id] = StepPosition(
      x: (position?.x ?? 0) + 200,
      y: (position?.y ?? 0) + 50,
    );

    state.selectedStep.value = step;
  }

  /// 删除步骤
  void removeStep(String stepId) {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    final step = workflow.steps.firstWhere((s) => s.id == stepId);

    _recordAction(RemoveStepAction(workflowId: workflow.id, step: step));

    final updatedSteps = workflow.steps
        .where((s) => s.id != stepId)
        .map((s) {
          if (s.nextStepIds.contains(stepId)) {
            return s.copyWith(
              nextStepIds: s.nextStepIds.where((id) => id != stepId).toList(),
            );
          }
          return s;
        })
        .toList();

    final updatedWorkflow = workflow.copyWith(
      steps: updatedSteps,
      updatedAt: DateTime.now(),
    );

    _updateWorkflow(updatedWorkflow);
    state.stepPositions.remove(stepId);

    if (state.selectedStep.value?.id == stepId) {
      state.selectedStep.value = null;
    }
  }

  /// 更新步骤
  void updateStep(StepConfig step) {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    final oldStep = workflow.steps.firstWhere((s) => s.id == step.id);

    _recordAction(UpdateStepAction(
      workflowId: workflow.id,
      oldStep: oldStep,
      newStep: step,
    ));

    final updatedSteps = workflow.steps.map((s) => s.id == step.id ? step : s).toList();
    final updatedWorkflow = workflow.copyWith(
      steps: updatedSteps,
      updatedAt: DateTime.now(),
    );

    _updateWorkflow(updatedWorkflow);
    state.selectedStep.value = step;
  }

  /// 移除从当前步骤到目标步骤的连接
  void removeConnection(String fromStepId, String toStepId) {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    final fromStep = workflow.steps.firstWhere(
      (s) => s.id == fromStepId,
      orElse: () => workflow.steps.first,
    );

    if (!fromStep.nextStepIds.contains(toStepId)) return;

    final updatedStep = fromStep.copyWith(
      nextStepIds: fromStep.nextStepIds.where((id) => id != toStepId).toList(),
    );
    updateStep(updatedStep);
  }

  /// 选择步骤
  void selectStep(StepConfig? step) {
    state.selectedStep.value = step;
  }

  /// 更新步骤位置
  void updateStepPosition(String stepId, double x, double y) {
    state.stepPositions[stepId] = StepPosition(x: x, y: y);
    _savePositionsToWorkflow();
  }

  /// 保存视口状态
  void updateViewportState({double? scale, double? offsetX, double? offsetY}) {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    final updatedWorkflow = workflow.copyWith(
      viewportScale: scale ?? workflow.viewportScale,
      viewportOffsetX: offsetX ?? workflow.viewportOffsetX,
      viewportOffsetY: offsetY ?? workflow.viewportOffsetY,
      updatedAt: DateTime.now(),
    );
    _updateWorkflow(updatedWorkflow);
  }

  /// 将位置保存到工作流
  void _savePositionsToWorkflow() {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    final updatedWorkflow = workflow.copyWith(
      stepPositions: Map.from(state.stepPositions),
      updatedAt: DateTime.now(),
    );
    _updateWorkflow(updatedWorkflow);
  }

  /// 绑定到渠道函数
  void bindToChannelFunction(ChannelType channelType, String functionName) {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    final updatedWorkflow = workflow.copyWith(
      channelType: channelType,
      functionName: functionName,
      updatedAt: DateTime.now(),
    );

    _updateWorkflow(updatedWorkflow);
  }

  /// 解除渠道绑定
  void unbindChannelFunction() {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    final updatedWorkflow = workflow.copyWith(
      clearChannelBinding: true,
      updatedAt: DateTime.now(),
    );

    _updateWorkflow(updatedWorkflow);
  }

  /// 执行工作流
  Future<void> executeWorkflow() async {
    final workflow = state.selectedWorkflow.value;
    if (workflow == null) return;

    state.isExecuting.value = true;
    state.executionResult.value = null;

    try {
      final result = await WorkflowManager.instance.executeWorkflowDirect(
        workflow,
        onStepComplete: (stepId, output) {
          // 可以在这里更新 UI 显示步骤执行状态
        },
      );

      state.executionResult.value = result;
    } catch (e) {
      state.executionResult.value = WorkflowResult.failure(
        e.toString(),
        Duration.zero,
      );
    } finally {
      state.isExecuting.value = false;
    }
  }

  /// 撤销
  void undo() {
    if (state.undoStack.isEmpty) return;

    final action = state.undoStack.removeLast();
    state.redoStack.add(action);

    if (action is AddStepAction) {
      final workflow = state.selectedWorkflow.value;
      if (workflow != null && action.workflowId == workflow.id) {
        final updatedSteps = workflow.steps.where((s) => s.id != action.step.id).toList();
        final updatedWorkflow = workflow.copyWith(
          steps: updatedSteps,
          updatedAt: DateTime.now(),
        );
        _updateWorkflow(updatedWorkflow);
        state.stepPositions.remove(action.step.id);
      }
    } else if (action is RemoveStepAction) {
      final workflow = state.selectedWorkflow.value;
      if (workflow != null && action.workflowId == workflow.id) {
        final updatedSteps = List<StepConfig>.from(workflow.steps)..add(action.step);
        final updatedWorkflow = workflow.copyWith(
          steps: updatedSteps,
          updatedAt: DateTime.now(),
        );
        _updateWorkflow(updatedWorkflow);
      }
    } else if (action is UpdateStepAction) {
      final workflow = state.selectedWorkflow.value;
      if (workflow != null && action.workflowId == workflow.id) {
        final updatedSteps = workflow.steps.map((s) {
          return s.id == action.newStep.id ? action.oldStep : s;
        }).toList();
        final updatedWorkflow = workflow.copyWith(
          steps: updatedSteps,
          updatedAt: DateTime.now(),
        );
        _updateWorkflow(updatedWorkflow);
      }
    }
  }

  /// 重做
  void redo() {
    if (state.redoStack.isEmpty) return;

    final action = state.redoStack.removeLast();
    state.undoStack.add(action);

    if (action is AddStepAction) {
      final workflow = state.selectedWorkflow.value;
      if (workflow != null && action.workflowId == workflow.id) {
        final updatedSteps = List<StepConfig>.from(workflow.steps)..add(action.step);
        final updatedWorkflow = workflow.copyWith(
          steps: updatedSteps,
          updatedAt: DateTime.now(),
        );
        _updateWorkflow(updatedWorkflow);
      }
    } else if (action is RemoveStepAction) {
      final workflow = state.selectedWorkflow.value;
      if (workflow != null && action.workflowId == workflow.id) {
        final updatedSteps = workflow.steps.where((s) => s.id != action.step.id).toList();
        final updatedWorkflow = workflow.copyWith(
          steps: updatedSteps,
          updatedAt: DateTime.now(),
        );
        _updateWorkflow(updatedWorkflow);
        state.stepPositions.remove(action.step.id);
      }
    } else if (action is UpdateStepAction) {
      final workflow = state.selectedWorkflow.value;
      if (workflow != null && action.workflowId == workflow.id) {
        final updatedSteps = workflow.steps.map((s) {
          return s.id == action.oldStep.id ? action.newStep : s;
        }).toList();
        final updatedWorkflow = workflow.copyWith(
          steps: updatedSteps,
          updatedAt: DateTime.now(),
        );
        _updateWorkflow(updatedWorkflow);
      }
    }
  }

  /// 从 JSON 导入工作流
  void importWorkflow(String jsonStr) {
    try {
      final workflow = WorkflowModel.fromJsonString(jsonStr);
      final newWorkflow = workflow.copyWith(
        id: _uuid.v4(),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        clearChannelBinding: true,
      );
      WorkflowManager.instance.addWorkflow(newWorkflow);
      state.workflows.add(newWorkflow);
      state.selectedWorkflow.value = newWorkflow;
    } catch (e) {
      Get.snackbar('Import Failed', 'Invalid workflow config: $e');
    }
  }

  /// 更新工作流
  void _updateWorkflow(WorkflowModel workflow) {
    WorkflowManager.instance.updateWorkflow(workflow);
    final index = state.workflows.indexWhere((w) => w.id == workflow.id);
    if (index >= 0) {
      state.workflows[index] = workflow;
      state.selectedWorkflow.value = workflow;
    }
  }

  /// 记录动作
  void _recordAction(WorkflowAction action) {
    state.undoStack.add(action);
    state.redoStack.clear();

    if (state.undoStack.length > 50) {
      state.undoStack.removeAt(0);
    }
  }

  /// 获取步骤类型的默认配置
  Map<String, dynamic> _getDefaultOptions(StepType type) {
    // 通用输入输出配置
    const baseOptions = {
      'inputFrom': '',
      'inputPath': '',
      'outputVar': '',
    };

    switch (type) {
      // ========== 网络类 ==========
      case StepType.http_request:
        return {
          ...baseOptions,
          'url': '',
          'method': 'GET',
          'headers': '{}',
          'bodyType': 'none',
          'body': '',
          'queryParams': {},
          'authType': '',
          'authConfig': {},
          'verifySsl': true,
          'followRedirects': true,
          'maxRedirects': 5,
          'connectTimeout': 30,
          'readTimeout': 30,
          'writeTimeout': 30,
          'responsePath': '',
          'throwOnError': true,
        };

      // ========== 数据处理类 ==========
      case StepType.data_extract:
        return {
          ...baseOptions,
          'fields': [
            {'name': 'field1', 'path': '', 'description': 'Field 1'}
          ],
        };

      case StepType.data_transform:
        return {
          ...baseOptions,
          'mappings': [],
        };

      case StepType.data_filter:
        return {
          ...baseOptions,
          'field': '',
          'operator': 'eq',
          'value': '',
          'caseSensitive': false,
          'conditions': [],
          'logicOperator': 'and',
        };

      case StepType.data_sort:
        return {
          ...baseOptions,
          'fields': [],
        };

      case StepType.data_dedup:
        return {
          ...baseOptions,
          'fields': [],
          'caseSensitive': true,
          'keepFirst': true,
        };

      case StepType.data_batch:
        return {
          ...baseOptions,
          'batchSize': 10,
          'parallelism': 1,
        };

      // ========== 逻辑控制类 ==========
      case StepType.condition:
        return {
          ...baseOptions,
          'conditions': [],
          'logicOperator': 'and',
          'singleCondition': false,
          'field': '',
          'operator': 'eq',
          'value': '',
        };

      case StepType.switch_case:
        return {
          ...baseOptions,
          'expression': '',
          'cases': [],
          'defaultStepId': '',
        };

      case StepType.loop:
        return {
          ...baseOptions,
          'itemsPath': '',
          'maxIterations': 1000,
          'loopVar': 'item',
        };

      case StepType.parallel:
        return {
          ...baseOptions,
          'branches': [],
          'waitMode': 'all',
        };

      case StepType.merge:
        return {
          ...baseOptions,
          'waitMode': 'all',
          'outputMapping': {},
        };

      case StepType.delay:
        return {
          ...baseOptions,
          'seconds': 1,
        };

      // ========== 变量类 ==========
      case StepType.var_get:
        return {
          ...baseOptions,
          'varName': '',
          'defaultValue': null,
        };

      case StepType.var_set:
        return {
          ...baseOptions,
          'varName': '',
          'value': null,
          'isSecret': false,
        };

      case StepType.var_delete:
        return {
          ...baseOptions,
          'varName': '',
        };

      // ========== 外部集成类 ==========
      case StepType.database_read:
        return {
          ...baseOptions,
          'connectionId': '',
          'tableName': '',
          'tableAlias': '',
          'columns': [],
          'whereClause': '',
          'whereParams': {},
          'orderBy': '',
          'limit': 100,
        };

      case StepType.database_write:
        return {
          ...baseOptions,
          'connectionId': '',
          'tableName': '',
          'tableAlias': '',
          'inputSourceStepId': '__PREV__', // 数据来源步骤 ID
          'operation': 'insert', // insert, update, upsert
          'columns': [],
          'valuesSource': 'input', // input, static
          'staticValues': {},
          'whereClause': '',
          'onConflict': 'abort', // abort, ignore, replace
          'conflictTarget': '',
        };

      case StepType.database_create:
        return {
          ...baseOptions,
          'tableName': '',
          'ifNotExists': true, // 表不存在才创建
          'replaceExisting': false, // 是否替换已存在表
          'columns': [],
        };

      case StepType.database_query:
        return {
          ...baseOptions,
          'connectionId': '',
          'query': '',
          'params': {},
        };

      case StepType.cache_ops:
        return {
          ...baseOptions,
          'key': '',
          'operation': 'get',
          'value': null,
          'ttl': 3600,
        };

      case StepType.notification:
        return {
          ...baseOptions,
          'channel': 'default',
          'recipient': '',
          'message': '',
        };

      // ========== 工具类 ==========
      case StepType.log:
        return {
          ...baseOptions,
          'level': 'info',
          'message': '',
          'dataPath': '',
        };

      case StepType.assertion:
        return {
          ...baseOptions,
          'condition': '',
          'message': '断言失败',
        };

      case StepType.comment:
        return {
          ...baseOptions,
          'text': '',
        };
    }
  }
}

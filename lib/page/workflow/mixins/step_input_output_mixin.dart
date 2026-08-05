import 'package:flutter/material.dart';
import '../../../core/workflow/models/workflow_model.dart';

/// 输入来源类型
enum InputSourceType {
  /// 无输入
  none,
  /// 上一步
  previous,
  /// 指定步骤
  step,
  /// 上下文变量
  variable,
}

/// 输入输出配置 Mixin
/// 提供输入输出配置的通用UI和数据管理
mixin StepInputOutputMixin {
  /// 控制器映射
  Map<String, TextEditingController> get inputPathControllers;

  /// 获取输入来源类型
  InputSourceType getInputSourceType(String inputFrom) {
    if (inputFrom.isEmpty || inputFrom == '__PREV__') {
      return InputSourceType.previous;
    } else if (inputFrom.startsWith('var:')) {
      return InputSourceType.variable;
    } else {
      return InputSourceType.step;
    }
  }

  /// 获取变量名（从 var:xxx 格式中提取）
  String getVariableName(String inputFrom) {
    if (inputFrom.startsWith('var:')) {
      return inputFrom.substring(4);
    }
    return '';
  }

  /// 获取前置步骤列表
  List<StepConfig> getPreviousSteps(
    WorkflowModel workflow,
    StepConfig currentStep,
  ) {
    final previousSteps = <StepConfig>[];
    for (final step in workflow.steps) {
      if (step.id == currentStep.id) break;
      previousSteps.add(step);
    }
    return previousSteps;
  }

  /// 获取或创建输入路径的控制器
  TextEditingController getInputPathController(String stepId) {
    inputPathControllers.putIfAbsent(stepId, () => TextEditingController());
    return inputPathControllers[stepId]!;
  }

  /// 清理不再需要的控制器
  void cleanupInputPathControllers(List<String> activeStepIds) {
    inputPathControllers.removeWhere(
      (key, controller) {
        if (!activeStepIds.contains(key)) {
          controller.dispose();
          return true;
        }
        return false;
      },
    );
  }

  /// 获取输入来源类型的显示文本
  String getInputSourceTypeLabel(InputSourceType type) {
    switch (type) {
      case InputSourceType.none:
        return 'None';
      case InputSourceType.previous:
        return 'Previous Step';
      case InputSourceType.step:
        return 'Specific Step';
      case InputSourceType.variable:
        return 'Context Variable';
    }
  }

  /// 获取输入来源类型的下拉选项
  List<DropdownMenuItem<InputSourceType>> getInputSourceTypeItems() {
    return InputSourceType.values.map((type) {
      return DropdownMenuItem(
        value: type,
        child: Text(
          getInputSourceTypeLabel(type),
          style: const TextStyle(fontSize: 12),
        ),
      );
    }).toList();
  }
}

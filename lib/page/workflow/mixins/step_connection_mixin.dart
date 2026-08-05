import 'package:flutter/material.dart';
import '../../../core/workflow/models/workflow_model.dart';

/// 连接状态数据类
class StepConnectionState {
  final bool isConnecting;
  final String? fromStepId;
  final int version;

  const StepConnectionState({
    this.isConnecting = false,
    this.fromStepId,
    this.version = 0,
  });

  StepConnectionState copyWith({
    bool? isConnecting,
    String? fromStepId,
    int? version,
  }) {
    return StepConnectionState(
      isConnecting: isConnecting ?? this.isConnecting,
      fromStepId: fromStepId ?? this.fromStepId,
      version: version ?? this.version,
    );
  }
}

/// 步骤连接 Mixin
/// 提供连接模式下的状态管理和连接操作
mixin StepConnectionMixin {
  /// 节点尺寸（需与 StepNodeMixin 保持一致）
  static const double nodeWidth = 180.0;
  static const double nodeHeight = 100.0;

  /// 开始连接
  /// [fromStepId] 起始步骤ID
  StepConnectionState startConnection(String fromStepId) {
    return StepConnectionState(
      isConnecting: true,
      fromStepId: fromStepId,
      version: 1,
    );
  }

  /// 完成连接
  /// [toStepId] 目标步骤ID
  /// [fromStepId] 起始步骤ID
  /// [workflow] 当前工作流
  /// 返回完成连接后的状态（isConnecting=false）
  StepConnectionState completeConnection({
    required String toStepId,
    required String fromStepId,
    required WorkflowModel workflow,
  }) {
    if (fromStepId == toStepId) {
      return const StepConnectionState();
    }

    try {
      final fromStep = workflow.steps.firstWhere(
        (s) => s.id == fromStepId,
      );

      if (!fromStep.nextStepIds.contains(toStepId)) {
        // 连接不存在，标记需要更新
        return StepConnectionState(
          isConnecting: false,
          fromStepId: toStepId, // 携带目标ID用于后续处理
          version: 1,
        );
      }
    } catch (_) {}

    return const StepConnectionState();
  }

  /// 取消连接
  StepConnectionState cancelConnection() {
    return const StepConnectionState();
  }

  /// 检查节点是否有输入连接
  bool hasInputConnection(String stepId, WorkflowModel workflow) {
    for (final step in workflow.steps) {
      if (step.nextStepIds.contains(stepId)) {
        return true;
      }
    }
    return false;
  }

  /// 计算输入端口位置
  /// [position] 节点位置
  Offset getInputPortPosition(Offset position) {
    return Offset(
      position.dx - 8, // 左侧
      position.dy + nodeHeight / 2,
    );
  }

  /// 计算输出端口位置
  /// [position] 节点位置
  Offset getOutputPortPosition(Offset position) {
    return Offset(
      position.dx + nodeWidth + 8, // 右侧
      position.dy + nodeHeight / 2,
    );
  }
}

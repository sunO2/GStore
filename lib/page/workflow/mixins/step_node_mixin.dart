import 'package:flutter/material.dart';
import '../../../core/workflow/models/step_model.dart';
import '../../../core/workflow/models/step_position.dart';
import '../logic/workflow_designer_logic.dart';

/// 步骤节点 Mixin
/// 提供节点渲染的通用功能
mixin StepNodeMixin {
  /// 节点尺寸常量（需与 ConnectionLinePainter 保持一致）
  static const double nodeWidth = 180.0;
  static const double nodeHeight = 100.0;

  /// 获取步骤类型对应的图标
  IconData getStepIcon(StepType type) {
    switch (type) {
      // 网络类
      case StepType.http_request:
        return Icons.http;
      // 数据处理类
      case StepType.data_extract:
        return Icons.data_object;
      case StepType.data_transform:
        return Icons.transform;
      case StepType.data_filter:
        return Icons.filter_alt;
      case StepType.data_sort:
        return Icons.sort;
      case StepType.data_dedup:
        return Icons.filter_1;
      case StepType.data_batch:
        return Icons.batch_prediction;
      // 逻辑控制类
      case StepType.condition:
        return Icons.call_split;
      case StepType.switch_case:
        return Icons.switch_account;
      case StepType.loop:
        return Icons.loop;
      case StepType.parallel:
        return Icons.account_tree;
      case StepType.merge:
        return Icons.merge;
      case StepType.delay:
        return Icons.timer;
      // 变量类
      case StepType.var_get:
        return Icons.download;
      case StepType.var_set:
        return Icons.upload;
      case StepType.var_delete:
        return Icons.delete;
      // 外部集成类
      case StepType.database_read:
        return Icons.table_rows;
      case StepType.database_write:
        return Icons.table_chart;
      case StepType.database_create:
        return Icons.add_circle;
      case StepType.database_query:
        return Icons.storage;
      case StepType.cache_ops:
        return Icons.cached;
      case StepType.notification:
        return Icons.notifications;
      // 工具类
      case StepType.log:
        return Icons.note_add;
      case StepType.assertion:
        return Icons.check_circle;
      case StepType.comment:
        return Icons.comment;
    }
  }

  /// 获取步骤类型对应的颜色
  Color getStepColor(StepType type) {
    switch (type) {
      // 网络类 - 蓝色系
      case StepType.http_request:
        return Colors.blue;
      // 数据处理类 - 暖色系
      case StepType.data_extract:
        return Colors.orange;
      case StepType.data_transform:
        return Colors.pink;
      case StepType.data_filter:
        return Colors.red;
      case StepType.data_sort:
        return Colors.brown;
      case StepType.data_dedup:
        return Colors.cyan;
      case StepType.data_batch:
        return Colors.deepOrange;
      // 逻辑控制类 - 紫色系
      case StepType.condition:
        return Colors.purple;
      case StepType.switch_case:
        return Colors.deepPurple;
      case StepType.loop:
        return Colors.indigo;
      case StepType.parallel:
        return Colors.purpleAccent;
      case StepType.merge:
        return Colors.deepPurple;
      case StepType.delay:
        return Colors.blueGrey;
      // 变量类 - 绿色系
      case StepType.var_get:
        return Colors.green;
      case StepType.var_set:
        return Colors.teal;
      case StepType.var_delete:
        return Colors.redAccent;
      // 外部集成类 - 青绿色系
      case StepType.database_read:
        return Colors.teal;
      case StepType.database_write:
        return Colors.green;
      case StepType.database_create:
        return Colors.blue;
      case StepType.database_query:
        return Colors.cyan;
      case StepType.cache_ops:
        return Colors.amber;
      case StepType.notification:
        return Colors.lime;
      // 工具类 - 灰色系
      case StepType.log:
        return Colors.grey;
      case StepType.assertion:
        return Colors.amber;
      case StepType.comment:
        return Colors.blueGrey;
    }
  }

  /// 构建端口标签
  Widget buildPortTag(BuildContext context, String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 8,
          color: color,
          fontFamily: 'monospace',
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 获取步骤在画布上的位置
  /// 如果没有位置信息，返回默认位置
  Offset getStepPosition(
    String stepId,
    Map<String, StepPosition> positions,
    int index,
  ) {
    final position = positions[stepId];
    if (position != null) {
      return Offset(position.x, position.y);
    }
    // 默认位置：按顺序排列
    return Offset(
      100.0 + (index % 5) * 220.0,
      100.0 + (index ~/ 5) * 150.0,
    );
  }
}

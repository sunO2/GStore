import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../core/core.dart';
import '../../../core/workflow/models/workflow_model.dart';
import '../../../core/workflow/models/step_model.dart';
import '../logic/workflow_designer_logic.dart';
import '../extensions/step_options_extension.dart';

/// 步骤调试 Mixin
/// 提供调试对话框和值格式化功能
mixin StepDebugMixin {
  /// 格式化值用于显示
  String formatValue(dynamic value) {
    if (value == null) return 'null';
    if (value is String) {
      final str = value.length > 30 ? '${value.substring(0, 30)}...' : value;
      return '"$str"';
    }
    if (value is num) return value.toString();
    if (value is bool) return value.toString();
    if (value is List) return 'Array[${value.length}]';
    if (value is Map) {
      final keys = value.keys.toList();
      if (keys.isEmpty) return '{}';
      return '{${keys.take(5).join(', ')}${keys.length > 5 ? '...' : ''}}';
    }
    return value.toString();
  }

  /// 截断字符串
  String truncateString(String str, int maxLength) {
    if (str.length <= maxLength) return str;
    return '${str.substring(0, maxLength)}...';
  }

  /// 获取路径描述
  String getPathDescription(dynamic data, String path) {
    try {
      dynamic current = data;
      final parts = path.split('.');
      for (final part in parts) {
        if (part.startsWith('[') && part.endsWith(']')) {
          final index = int.parse(part.substring(1, part.length - 1));
          if (current is List && index < current.length) {
            current = current[index];
          } else {
            return 'Array index out of bounds';
          }
        } else if (current is Map) {
          current = current[part];
        } else {
          return 'Invalid path';
        }
      }
      return formatValue(current);
    } catch (e) {
      return 'Error: $e';
    }
  }

  /// 显示调试对话框
  Future<void> showStepDebugDialog({
    required BuildContext context,
    required StepConfig step,
    required StepOutput? output,
  }) async {
    // 获取该步骤的执行状态
    final executionResult = Get.find<WorkflowDesignerLogic>().state.executionResult.value;
    bool stepExecuted = false;
    bool stepSuccess = false;
    String? stepError;
    dynamic inputData;
    String? inputFrom;
    String? inputPath;
    String? outputVar;

    if (executionResult != null) {
      try {
        final stepResult = executionResult.stepOutputs.firstWhere(
          (o) => o.stepId == step.id,
        );
        stepExecuted = true;
        stepSuccess = stepResult.success;
        stepError = stepResult.error;
        inputData = stepResult.metadata?['_inputData'];
        inputFrom = stepResult.metadata?['_inputFrom'];
        inputPath = stepResult.metadata?['_inputPath'];
        outputVar = stepResult.metadata?['_outputVar'];
      } catch (_) {}
    }

    await Get.dialog(
      AlertDialog(
        title: Row(
          children: [
            Icon(
              getStepIcon(step.type),
              size: 20,
              color: getStepColor(step.type),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(step.name, style: const TextStyle(fontSize: 16))),
            if (stepExecuted)
              Icon(
                stepSuccess ? Icons.check_circle : Icons.error,
                size: 20,
                color: stepSuccess ? AppColors.success : AppColors.error,
              ),
          ],
        ),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 执行状态
                if (stepExecuted)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: stepSuccess
                          ? AppColors.success.withValues(alpha: 0.1)
                          : AppColors.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: stepSuccess
                            ? AppColors.success.withValues(alpha: 0.3)
                            : AppColors.error.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              stepSuccess ? Icons.check_circle : Icons.error,
                              size: 16,
                              color: stepSuccess ? AppColors.success : AppColors.error,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              stepSuccess ? 'Execution Successful' : 'Execution Failed',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: stepSuccess ? AppColors.success : AppColors.error,
                              ),
                            ),
                          ],
                        ),
                        if (stepError != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            stepError,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                if (stepExecuted) ...[
                  const SizedBox(height: AppSpacing.md),
                  const Divider(),
                  const SizedBox(height: AppSpacing.md),
                ],

                // 输入信息
                _buildDebugSection(
                  'Input',
                  Icons.input,
                  [
                    _buildDebugRow('Source', inputFrom ?? step.inputFrom ?? ''),
                    _buildDebugRow('Path', inputPath ?? step.inputPath ?? ''),
                    if (inputData != null)
                      _buildDebugRow('Data', formatValue(inputData)),
                  ],
                ),

                // 输出信息
                _buildDebugSection(
                  'Output',
                  Icons.output,
                  [
                    _buildDebugRow('Variable', outputVar ?? step.outputVar ?? ''),
                    if (output?.data != null)
                      _buildDebugRow('Data', formatValue(output!.data)),
                  ],
                ),

                // 选项信息
                _buildDebugSection(
                  'Options',
                  Icons.settings,
                  step.options.entries
                      .where((e) => !_isHiddenOption(e.key))
                      .map((e) => _buildDebugRow(e.key, formatValue(e.value)))
                      .toList(),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugSection(String title, IconData icon, List<Widget> children) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 4),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ...children,
        const SizedBox(height: AppSpacing.md),
      ],
    );
  }

  Widget _buildDebugRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isHiddenOption(String key) {
    // 隐藏一些不需要显示的选项
    const hiddenKeys = [
      'inputFrom',
      'inputPath',
      'outputVar',
      '_inputData',
      '_outputVar',
      '_inputFrom',
      '_inputPath',
    ];
    return hiddenKeys.contains(key);
  }

  /// 获取步骤图标
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

  /// 获取步骤颜色
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
}

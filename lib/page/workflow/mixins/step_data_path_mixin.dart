import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../../core/core.dart';
import '../../../core/workflow/models/workflow_model.dart';
import '../logic/workflow_designer_logic.dart';
import '../extensions/step_options_extension.dart';

/// 数据路径信息
class DataPathInfo {
  final String path;
  final String type;
  final String preview;

  DataPathInfo(this.path, this.type, this.preview);
}

/// 数据路径选择 Mixin
/// 提供数据路径提取和选择功能
mixin StepDataPathMixin {
  /// 从数据中提取所有可能的路径
  List<DataPathInfo> extractDataPathsWithInfo(dynamic data, [String prefix = '']) {
    final paths = <DataPathInfo>[];

    if (data == null) return paths;

    if (data is Map) {
      data.forEach((key, value) {
        final currentPath = prefix.isEmpty ? key.toString() : '$prefix.$key';
        paths.addAll(_extractFromValue(value, currentPath));
      });
    } else if (data is List) {
      for (var i = 0; i < data.length; i++) {
        final currentPath = '$prefix[$i]';
        paths.addAll(_extractFromValue(data[i], currentPath));
      }
    }

    return paths;
  }

  /// 从单个值中提取路径信息
  List<DataPathInfo> _extractFromValue(dynamic value, String path) {
    final paths = <DataPathInfo>[];

    // 添加当前路径
    paths.add(DataPathInfo(
      path,
      _getValueTypeName(value),
      _getValuePreview(value),
    ));

    // 如果是复合类型，递归提取子路径
    if (value is Map) {
      value.forEach((key, v) {
        final childPath = '$path.$key';
        paths.addAll(_extractFromValue(v, childPath));
      });
    } else if (value is List) {
      for (var i = 0; i < value.length && i < 10; i++) {
        final childPath = '$path[$i]';
        paths.addAll(_extractFromValue(value[i], childPath));
      }
    }

    return paths;
  }

  /// 获取值的类型名称
  String _getValueTypeName(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return 'String';
    if (value is int) return 'int';
    if (value is double) return 'num';
    if (value is bool) return 'bool';
    if (value is List) return 'Array';
    if (value is Map) return 'Object';
    return value.runtimeType.toString();
  }

  /// 获取值的预览
  String _getValuePreview(dynamic value) {
    if (value == null) return 'null';
    if (value is String) {
      final str = value.length > 20 ? '${value.substring(0, 20)}...' : value;
      return '"$str"';
    }
    if (value is num) return value.toString();
    if (value is bool) return value.toString();
    if (value is List) return 'Array[${value.length}]';
    if (value is Map) {
      final keys = value.keys.toList();
      if (keys.isEmpty) return '{}';
      return '{${keys.take(3).join(', ')}${keys.length > 3 ? '...' : ''}}';
    }
    return value.toString();
  }

  /// 获取类型对应的颜色
  Color getTypeColor(String type) {
    switch (type) {
      case 'String':
        return Colors.green;
      case 'num':
      case 'int':
      case 'double':
        return Colors.blue;
      case 'bool':
        return Colors.orange;
      case 'Array':
        return Colors.purple;
      case 'Object':
        return Colors.teal;
      case 'null':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  /// 显示数据路径选择器
  Future<void> showDataPathPicker({
    required BuildContext context,
    required WorkflowDesignerLogic logic,
    required StepConfig step,
    int? fieldIndex,
    TextEditingController? controller,
  }) async {
    // 获取源数据
    final executionResult = logic.state.executionResult.value;
    dynamic sourceData;

    final inputFrom = step.inputFrom;

    if (inputFrom == null || inputFrom.isEmpty) {
      return;
    }

    if (inputFrom.startsWith('var:')) {
      // 从 context 获取
      final varName = inputFrom.substring(4);
      if (executionResult != null) {
        for (final output in executionResult.stepOutputs.reversed) {
          if (output.metadata?['_outputVar'] == varName) {
            sourceData = output.metadata?['_inputData'] ?? output.data;
            break;
          }
        }
      }
    } else {
      // 从指定步骤获取
      final sourceStepId = inputFrom == '__PREV__'
          ? (executionResult != null && executionResult.stepOutputs.isNotEmpty
              ? executionResult.stepOutputs.last.stepId
              : null)
          : inputFrom;

      if (executionResult != null && sourceStepId != null) {
        try {
          final sourceOutput =
              executionResult.stepOutputs.firstWhere((o) => o.stepId == sourceStepId);
          sourceData = sourceOutput.metadata?['_inputData'] ?? sourceOutput.data;
        } catch (_) {}
      }
    }

    if (sourceData == null) {
      Get.snackbar(
        'No Data',
        'Execute the workflow first to get available data paths',
        duration: const Duration(seconds: 2),
      );
      return;
    }

    // 解析数据结构
    final pathInfos = extractDataPathsWithInfo(sourceData);

    if (pathInfos.isEmpty) {
      Get.snackbar(
        'No Paths',
        'No extractable paths found in data',
        duration: const Duration(seconds: 2),
      );
      return;
    }

    await Get.dialog(
      AlertDialog(
        title: const Text('Select Data Path'),
        content: SizedBox(
          width: 350,
          height: 400,
          child: ListView.builder(
            itemCount: pathInfos.length,
            itemBuilder: (context, index) {
              final pathInfo = pathInfos[index];
              return ListTile(
                dense: true,
                leading: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: getTypeColor(pathInfo.type).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    pathInfo.type,
                    style: TextStyle(
                      fontSize: 9,
                      color: getTypeColor(pathInfo.type),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                title: Text(
                  pathInfo.path,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                subtitle: Text(
                  pathInfo.preview,
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  if (fieldIndex != null) {
                    // 更新提取字段的 path
                    final fields = step.fields;
                    if (fieldIndex >= 0 && fieldIndex < fields.length) {
                      fields[fieldIndex]['path'] = pathInfo.path;
                      step.fields = fields;
                      logic.updateStep(step.copyWith(options: Map.from(step.options)));
                    }
                  } else {
                    // 更新 inputPath
                    final newOptions = Map<String, dynamic>.from(step.options);
                    newOptions['inputPath'] = pathInfo.path;
                    logic.updateStep(step.copyWith(options: newOptions));
                    if (controller != null) {
                      controller.text = pathInfo.path;
                    }
                  }
                  Get.back();
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

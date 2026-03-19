import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'logic.dart';
import 'state.dart';

class LogViewerPage extends StatelessWidget {
  const LogViewerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final logic = Get.put(LogViewerLogic());
    final state = logic.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('应用日志'),
        elevation: 0,
        actions: [
          // 级别筛选
          Obx(() => PopupMenuButton<LogLevel>(
                icon: _buildLevelIcon(state.selectedLevel.value),
                tooltip: '筛选日志级别',
                onSelected: (level) => logic.setLogLevel(level),
                itemBuilder: (context) => LogLevel.values.map((level) {
                  final isSelected = state.selectedLevel.value == level;
                  return CheckedPopupMenuItem(
                    value: level,
                    checked: isSelected,
                    child: Text(level.label),
                  );
                }).toList(),
              )),

          // 自动滚动
          Obx(() => IconButton(
                icon: Icon(
                  state.autoScroll.value ? Icons.arrow_downward : Icons.vertical_align_center,
                ),
                tooltip: state.autoScroll.value ? '自动滚动' : '手动滚动',
                onPressed: logic.toggleAutoScroll,
              )),

          // 清空日志
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空日志',
            onPressed: () {
              Get.defaultDialog(
                title: '清空日志',
                middleText: '确定要清空所有日志吗？',
                textConfirm: '清空',
                textCancel: '取消',
                onConfirm: () {
                  logic.clearLogs();
                  Get.back();
                },
              );
            },
          ),

          // 导出日志
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: '导出日志',
            onPressed: logic.exportLogs,
          ),
        ],
      ),
      body: Obx(() {
        final filteredLogs = logic.getFilteredLogs();

        if (filteredLogs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.bug_report_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  '暂无日志',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.grey,
                      ),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: filteredLogs.length,
          reverse: state.autoScroll.value,
          itemBuilder: (context, index) {
            final log = filteredLogs[index];
            return _buildLogItem(context, log);
          },
        );
      }),
    );
  }

  Widget _buildLevelIcon(LogLevel level) {
    Color color;
    switch (level) {
      case LogLevel.debug:
        color = Colors.grey;
        break;
      case LogLevel.info:
        color = Colors.blue;
        break;
      case LogLevel.warning:
        color = Colors.orange;
        break;
      case LogLevel.error:
        color = Colors.red;
        break;
      default:
        color = Colors.green;
    }

    return Icon(Icons.filter_list, color: color);
  }

  Widget _buildLogItem(BuildContext context, LogEntry log) {
    Color levelColor;
    IconData levelIcon;

    switch (log.level) {
      case LogLevel.debug:
        levelColor = Colors.grey;
        levelIcon = Icons.bug_report;
        break;
      case LogLevel.info:
        levelColor = Colors.blue;
        levelIcon = Icons.info;
        break;
      case LogLevel.warning:
        levelColor = Colors.orange;
        levelIcon = Icons.warning;
        break;
      case LogLevel.error:
        levelColor = Colors.red;
        levelIcon = Icons.error;
        break;
      default:
        levelColor = Colors.green;
        levelIcon = Icons.check_circle;
    }

    return InkWell(
      onLongPress: () => _copyLogToClipboard(context, log),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 时间戳
            Container(
              width: 60,
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                log.timeString,
                style: TextStyle(
                  fontSize: AppTypography.sizeXXS,
                  color: AppColors.grey600,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            // 级别图标
            Icon(levelIcon, color: levelColor, size: 14),
            const SizedBox(width: 8),
            // 日志消息
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    log.message,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: AppTypography.sizeXS,
                      color: levelColor,
                    ),
                  ),
                  if (log.data != null && log.data!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      _formatData(log.data!),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: AppTypography.sizeXXS,
                        color: Colors.grey[700],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 复制日志到剪贴板
  void _copyLogToClipboard(BuildContext context, LogEntry log) {
    final buffer = StringBuffer();
    buffer.writeln('${log.dateTimeString} [${log.level.name.toUpperCase()}] ${log.message}');
    if (log.data != null && log.data!.isNotEmpty) {
      buffer.writeln(_formatData(log.data!));
    }

    // 复制到剪贴板
    Clipboard.setData(ClipboardData(text: buffer.toString().trimRight()));

    Get.snackbar(
      '已复制',
      '日志已复制到剪贴板',
      icon: const Icon(Icons.check_circle, color: Colors.green),
      duration: const Duration(seconds: 1),
    );
  }

  String _formatData(Map<String, dynamic> data) {
    final buffer = StringBuffer();
    data.forEach((key, value) {
      buffer.writeln('$key: $value');
    });
    return buffer.toString().trimRight();
  }
}

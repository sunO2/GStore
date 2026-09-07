import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/logger/LogManager.dart';

import 'providers.dart';

class LogViewerPage extends ConsumerStatefulWidget {
  const LogViewerPage({super.key});

  @override
  ConsumerState<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends ConsumerState<LogViewerPage> {
  /// 列表滚动控制器（reverse 模式下 offset 0 = 底部 = 最新日志）。
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 新日志到达且开启自动滚动 → 贴底（reverse 下 jumpTo(0) = 最新）。
  void _maybeScrollToLatest() {
    if (!ref.read(autoScrollProvider)) return;
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredLogs = ref.watch(filteredLogsProvider);
    final autoScroll = ref.watch(autoScrollProvider);
    final level = ref.watch(logViewerFilterProvider);

    // 日志变更 → 自动滚动跟随最新（仅 autoScroll 开启时）
    ref.listen(filteredLogsProvider, (_, __) => _maybeScrollToLatest());

    return Scaffold(
      appBar: AppBar(
        title: const Text('应用日志'),
        elevation: 0,
        actions: [
          // 级别筛选
          PopupMenuButton<LogLevel>(
            icon: _buildLevelIcon(level),
            tooltip: '筛选日志级别',
            onSelected: (lv) =>
                ref.read(logViewerFilterProvider.notifier).set(lv),
            itemBuilder: (context) => LogLevel.values.map((lv) {
              final isSelected = level == lv;
              return CheckedPopupMenuItem(
                value: lv,
                checked: isSelected,
                child: Text(lv.label),
              );
            }).toList(),
          ),

          // 自动滚动（最新贴底跟随）
          IconButton(
            icon: Icon(
              autoScroll
                  ? Icons.arrow_downward
                  : Icons.vertical_align_center,
            ),
            tooltip: autoScroll ? '自动滚动' : '手动滚动',
            onPressed: () {
              ref.read(autoScrollProvider.notifier).toggle();
              // 开启自动滚动时立即贴底一次
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _maybeScrollToLatest();
              });
            },
          ),

          // 清空日志
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空日志',
            onPressed: () {
              AppDialogs.showDialog(
                title: '清空日志',
                content: '确定要清空所有日志吗？',
                confirmText: '清空',
                cancelText: '取消',
                isDangerous: true,
                onConfirm: LogManager.instance.clear,
              );
            },
          ),

          // 导出日志
          IconButton(
            icon: const Icon(Icons.file_download),
            tooltip: '导出日志',
            onPressed: () {
              final count = LogManager.instance.logs.length;
              AppDialogs.showSuccess('已导出 $count 条日志');
            },
          ),
        ],
      ),
      body: filteredLogs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bug_report_outlined,
                    size: 48,
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '暂无日志',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: filteredLogs.length,
              // 固定反转：offset 0 = 底部，显示最新日志
              reverse: true,
              itemBuilder: (context, index) {
                // 倒序取数：index 0（底部）渲染最新日志
                final log = filteredLogs[filteredLogs.length - 1 - index];
                return _LogItemView(log: log);
              },
            ),
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
}

/// 单条日志（点击长按复制）。
class _LogItemView extends StatelessWidget {
  const _LogItemView({required this.log});

  final LogEntry log;

  @override
  Widget build(BuildContext context) {
    final levelColor = _levelColor(log.level);
    final levelIcon = _levelIcon(log.level);

    return InkWell(
      onLongPress: () => _copyToClipboard(context),
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
                  color: Theme.of(context).colorScheme.outline,
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
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
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

  Future<void> _copyToClipboard(BuildContext context) async {
    final buffer = StringBuffer();
    buffer.writeln(
        '${log.dateTimeString} [${log.level.name.toUpperCase()}] ${log.message}');
    if (log.data != null && log.data!.isNotEmpty) {
      buffer.writeln(_formatData(log.data!));
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString().trimRight()));
    if (context.mounted) AppDialogs.showSuccess('日志已复制到剪贴板');
  }

  String _formatData(Map<String, dynamic> data) {
    final buffer = StringBuffer();
    data.forEach((key, value) {
      buffer.writeln('$key: $value');
    });
    return buffer.toString().trimRight();
  }

  static Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return Colors.grey;
      case LogLevel.info:
        return Colors.blue;
      case LogLevel.warning:
        return Colors.orange;
      case LogLevel.error:
        return Colors.red;
      default:
        return Colors.green;
    }
  }

  static IconData _levelIcon(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return Icons.bug_report;
      case LogLevel.info:
        return Icons.info;
      case LogLevel.warning:
        return Icons.warning;
      case LogLevel.error:
        return Icons.error;
      default:
        return Icons.check_circle;
    }
  }
}

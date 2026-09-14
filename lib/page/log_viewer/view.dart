import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
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
    final contentFilter = ref.watch(logViewerContentFilterProvider).trim();

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

          // 更多：下载日志 / target 过滤
          IconButton(
            icon: Icon(
              Icons.more_vert,
              // 过滤生效时高亮提示
              color: contentFilter.isEmpty
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
            tooltip: '更多',
            onPressed: _showMoreActions,
          ),
        ],
      ),
      body: Column(
        children: [
          // 内容过滤生效时的提示条（可一键清除）
          if (contentFilter.isNotEmpty)
            _ActiveFilterBar(
              keyword: contentFilter,
              onClear: () =>
                  ref.read(logViewerContentFilterProvider.notifier).clear(),
            ),
          Expanded(
            child: filteredLogs.isEmpty
                ? _buildEmptyState(
                    context,
                    hasFilter:
                        contentFilter.isNotEmpty || level != LogLevel.all,
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
          ),
        ],
      ),
    );
  }

  /// 空态（区分「暂无日志」与「无匹配日志」）
  Widget _buildEmptyState(BuildContext context, {required bool hasFilter}) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.bug_report_outlined,
            size: 48,
            color: scheme.primary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            hasFilter ? '无匹配日志' : '暂无日志',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.outline,
                ),
          ),
        ],
      ),
    );
  }

  /// 「更多」底部弹层：下载日志 / target 过滤
  Future<void> _showMoreActions() async {
    final keyword = ref.read(logViewerContentFilterProvider).trim();
    final action = await AppDialogs.showBottomSheet<String>(
      title: '更多',
      children: [
        Material(
          type: MaterialType.transparency,
          child: ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('下载日志'),
            subtitle: Text('导出当前 ${LogManager.instance.logs.length} 条日志'),
            onTap: () => AppDialogs.popSheet<String?>('download'),
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: ListTile(
            leading: const Icon(Icons.filter_alt_outlined),
            title: const Text('target 过滤'),
            subtitle: Text(
              keyword.isEmpty ? '按关键字过滤日志内容' : '已过滤：$keyword',
            ),
            trailing: keyword.isEmpty
                ? null
                : const Icon(Icons.check_circle_outline, size: 20),
            onTap: () => AppDialogs.popSheet<String?>('filter'),
          ),
        ),
      ],
    );

    if (!mounted || action == null) return;
    switch (action) {
      case 'download':
        await _exportLogs();
        break;
      case 'filter':
        await _showFilterSheet();
        break;
    }
  }

  /// 真实导出日志：系统保存对话框落地为 .txt 文件（与备份导出同机制）。
  Future<void> _exportLogs() async {
    final logs = LogManager.instance.logs;
    if (logs.isEmpty) {
      AppDialogs.showSnackbar('当前没有可导出的日志', title: '导出日志');
      return;
    }

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')[0];
    final fileName = 'gstore_log_$timestamp.txt';
    final content = LogManager.instance.exportToText();

    String? outputPath;
    try {
      outputPath = await FilePicker.platform.saveFile(
        dialogTitle: '保存日志文件',
        fileName: fileName,
        lockParentWindow: true,
        type: FileType.custom,
        allowedExtensions: ['txt'],
        bytes: Uint8List.fromList(utf8.encode(content)),
      );
    } catch (e) {
      appLog.error('LogViewer: 导出日志失败 - $e');
      AppDialogs.showError('导出日志失败: $e', title: '导出失败');
      return;
    }

    if (outputPath == null || outputPath.isEmpty) {
      AppDialogs.showSnackbar('您取消了导出操作', title: '已取消');
      return;
    }

    appLog.info('LogViewer: 日志已导出 - $outputPath（${logs.length} 条）');
    AppDialogs.showSuccess('已导出 ${logs.length} 条日志到：$outputPath');
  }

  /// target 过滤输入弹层（app bottom sheet 风格；空输入 = 清除过滤）
  Future<void> _showFilterSheet() async {
    final scheme = Theme.of(context).colorScheme;
    final capsuleBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.circle),
      borderSide: BorderSide.none,
    );
    // 用局部变量承接输入（TextFormField 自管理 controller，避免弹层退场动画
    // 期间仍重建 TextField 却已 dispose 外部 controller 导致 "used after disposed"）
    var input = ref.read(logViewerContentFilterProvider);

    final result = await AppDialogs.showBottomSheet<String>(
      title: 'target 过滤',
      children: [
        Padding(
          // children 无水平 padding（标题才带），内容整体补左右边距避免贴边
          padding: AppSpacing.onlyHorizontalLG,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('输入关键字，仅显示内容匹配的日志（不区分大小写）。'),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                initialValue: input,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (value) => input = value,
                onFieldSubmitted: (value) =>
                    AppDialogs.popSheet<String?>(value.trim()),
                decoration: InputDecoration(
                  labelText: '过滤内容',
                  hintText: '如 RUST- / repo / error',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: capsuleBorder,
                  enabledBorder: capsuleBorder,
                  focusedBorder: capsuleBorder,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    // 取消：返回 null，不改变现有过滤
                    onPressed: () => AppDialogs.popSheet<String?>(null),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                    // 清除过滤：返回空串
                    onPressed: () => AppDialogs.popSheet<String?>(''),
                    child: const Text('清除'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: () =>
                        AppDialogs.popSheet<String?>(input.trim()),
                    child: const Text('应用'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    if (result == null) return;
    ref.read(logViewerContentFilterProvider.notifier).set(result);
    // 过滤后贴底一次（reverse 列表 offset 0 = 最新）
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScrollToLatest());
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

/// 内容过滤生效提示条（显示关键字 + 一键清除）。
class _ActiveFilterBar extends StatelessWidget {
  const _ActiveFilterBar({required this.keyword, required this.onClear});

  final String keyword;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          Icon(Icons.filter_alt, size: AppTypography.iconSM, color: scheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '过滤：$keyword',
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: AppTypography.iconSM),
            tooltip: '清除过滤',
            visualDensity: VisualDensity.compact,
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

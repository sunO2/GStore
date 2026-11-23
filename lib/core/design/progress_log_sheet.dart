import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';

/// 通用「任务进度日志」底部弹层（基于统一骨架 [AppSheetScaffold]）。
///
/// 视觉与交互与其它底部弹层完全一致：统一背景/圆角/拖拽条、固定标题、
/// 限高内容区、固定操作区，底部系统导航区域由骨架的背景覆盖。
///
/// - 进行中：转圈，无操作按钮（由调用方以不可中断方式弹出）
/// - 成功：✓ + "完成"
/// - 失败：✗ + 红色错误日志 + "关闭"/"重试"
///
/// 备份（[BackupProgressSheet]）与 GitHub 登录检查共用本组件。
class ProgressLogSheet extends StatefulWidget {
  const ProgressLogSheet({
    super.key,
    required this.title,
    required this.task,
    this.icon = TablerIcons.activity,
  });

  final String title;

  /// 任务闭包：通过 [onLog] 输出进度；抛异常即视为失败
  final Future<void> Function(void Function(String message, {bool isError}) onLog)
      task;

  final IconData icon;

  @override
  State<ProgressLogSheet> createState() => _ProgressLogSheetState();
}

class _ProgressLogSheetState extends State<ProgressLogSheet> {
  final List<({String text, bool isError})> _logs = [];
  final ScrollController _scrollController = ScrollController();

  bool _running = true;
  bool _success = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _appendLog(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _logs.add((text: message, isError: isError));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  Future<void> _run() async {
    if (_logs.isNotEmpty || !_running) {
      setState(() {
        _logs.clear();
        _running = true;
        _success = false;
      });
    }
    try {
      await widget.task(_appendLog);
      if (!mounted) return;
      setState(() {
        _running = false;
        _success = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _logs.add((text: '失败: $e', isError: true));
        _running = false;
      });
      _scrollToBottom();
    }
  }

  void _retry() => _run();

  void _close() => Navigator.of(context).pop(_success);

  Widget _buildStatusIcon() {
    if (_running) return const AppLoading(size: AppLoadingSize.small);
    if (_success) {
      return const Icon(TablerIcons.circle_check_filled,
          color: AppColors.success, size: 24);
    }
    return const Icon(TablerIcons.alert_circle_filled,
        color: AppColors.error, size: 24);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 日志区固定高度 + 内部滚动（骨架不重复包滚动视图）
    final content = Container(
      height: 220,
      width: double.infinity,
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: AppRadius.allLG,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: ListView.builder(
        key: const ValueKey('progress-log-list'),
        controller: _scrollController,
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          final log = _logs[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Text(
              log.text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: log.isError
                    ? AppColors.error
                    : theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          );
        },
      ),
    );

    return AppSheetScaffold(
      title: widget.title,
      icon: Icon(widget.icon),
      headerTrailing: _buildStatusIcon(),
      content: content,
      // 内容自带固定高度滚动区，避免嵌套滚动
      scrollable: false,
      contentPadding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        0,
        AppSpacing.xl,
        0,
      ),
      actions: _buildActions(),
    );
  }

  List<Widget> _buildActions() {
    if (_running) return const <Widget>[];
    if (_success) {
      return [
        FilledButton(
          onPressed: _close,
          child: const Text('完成'),
        ),
      ];
    }
    return [
      TextButton(
        onPressed: _close,
        child: const Text('关闭'),
      ),
      FilledButton(
        onPressed: _retry,
        child: const Text('重试'),
      ),
    ];
  }
}

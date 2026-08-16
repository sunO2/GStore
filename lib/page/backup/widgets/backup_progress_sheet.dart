import 'package:flutter/material.dart';

import 'package:gstore/core/core.dart';

/// 备份/恢复动画进度面板
///
/// 仿更新管理日志流式输出：逐行日志 + 自动滚动 + 分级颜色 + 状态图标。
/// - 进行中：AppLoading 转圈，无关闭入口（配合 showModalBottomSheet
///   isDismissible: false / enableDrag: false 不可中断）
/// - 成功：✓ + "完成"（pop 返回 true）
/// - 失败：✗ + 红色错误日志 + "重试"/"关闭"（pop 返回 false）
///
/// 入场动画复用 showModalBottomSheet 自带的底部滑入过渡，不额外叠加。
class BackupProgressSheet extends StatefulWidget {
  /// 面板标题（如 '备份到网盘' / '从网盘恢复备份'）
  final String title;

  /// 任务闭包：接收 onLog 回调输出进度日志，完成或异常时结束
  final Future<void> Function(BackupLogCallback onLog) task;

  const BackupProgressSheet({
    super.key,
    required this.title,
    required this.task,
  });

  @override
  State<BackupProgressSheet> createState() => _BackupProgressSheetState();
}

class _BackupProgressSheetState extends State<BackupProgressSheet> {
  final List<({String text, bool isError})> _logs = [];
  final ScrollController _scrollController = ScrollController();

  bool _running = true;
  bool _success = false;
  bool _failed = false;

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

  /// onLog 回调：追加一行日志并自动滚动到底
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

  /// 执行任务（首跑与重试共用）
  Future<void> _run() async {
    if (_logs.isNotEmpty || !_running) {
      setState(() {
        _logs.clear();
        _running = true;
        _success = false;
        _failed = false;
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
        _failed = true;
      });
      _scrollToBottom();
    }
  }

  void _retry() => _run();

  void _close() => Navigator.of(context).pop(_success);

  Widget _buildStatusIcon() {
    if (_running) return const AppLoading(size: AppLoadingSize.small);
    if (_success) {
      return const Icon(Icons.check_circle, color: AppColors.success, size: 24);
    }
    return const Icon(Icons.error, color: AppColors.error, size: 24);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行 + 状态图标
            Row(
              children: [
                Icon(
                  Icons.cloud_outlined,
                  color: theme.colorScheme.primary,
                  size: AppTypography.iconMD,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
                _buildStatusIcon(),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            // 日志流式区（固定高度 + 自动滚动到底）
            Container(
              height: 200,
              width: double.infinity,
              padding: AppSpacing.allMD,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: AppRadius.allLG,
              ),
              child: ListView.builder(
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
            ),
            const SizedBox(height: AppSpacing.lg),
            // 操作按钮行（进行中不显示，防中断）
            SizedBox(width: double.infinity, child: _buildActions()),
          ],
        ),
      ),
    );
  }

  Widget _buildActions() {
    if (_running) return const SizedBox.shrink();
    if (_success) {
      return FilledButton(
        onPressed: _close,
        child: const Text('完成'),
      );
    }
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _retry,
            child: const Text('重试'),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: FilledButton(
            onPressed: _close,
            child: const Text('关闭'),
          ),
        ),
      ],
    );
  }
}

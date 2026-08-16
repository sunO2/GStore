import 'package:flutter/material.dart';

import 'package:gstore/core/core.dart';

/// 备份恢复面板（单面板三阶段全流程）
///
/// - 阶段1 准备：转圈 + 日志流（加载 WebDAV 配置 + 列出备份文件）；
///   可"取消"；失败 → 红色日志 + "重试"/"关闭"；空列表 → 红色
///   "未找到备份" + "关闭"
/// - 阶段2 选择：备份文件列表（Radio 单选）+ "开始恢复"（未选禁用）/"取消"
/// - 阶段3 恢复：转圈 + 日志流（restoreTask onLog），无取消入口；
///   成功 ✓ + "完成"（pop 返回 true）；失败 ✗ + "重试"/"关闭"（pop false）
///
/// 配合 showModalBottomSheet isDismissible: false / enableDrag: false 不可中断；
/// 入场动画复用 showModalBottomSheet 自带的底部滑入过渡。
class BackupRestoreSheet extends StatefulWidget {
  /// 面板标题（如 '从网盘恢复备份'）
  final String title;

  /// 阶段1：加载配置 + 列出备份文件；返回文件列表（调用方负责按时间倒序），
  /// 空列表 → 面板显示"未找到备份"；抛异常 → 面板失败态（重试/关闭）
  final Future<List<WebDavFile>> Function(BackupLogCallback onLog) prepareTask;

  /// 阶段3：恢复指定备份文件（日志流式输出）
  final Future<void> Function(WebDavFile file, BackupLogCallback onLog)
      restoreTask;

  const BackupRestoreSheet({
    super.key,
    required this.title,
    required this.prepareTask,
    required this.restoreTask,
  });

  @override
  State<BackupRestoreSheet> createState() => _BackupRestoreSheetState();
}

/// 面板阶段状态机
enum _RestoreState {
  /// 阶段1 准备中（转圈 + 日志）
  preparing,

  /// 阶段1 失败（红色日志 + 重试/关闭）
  prepareFailed,

  /// 阶段1 空列表（红色日志"未找到备份" + 关闭）
  noBackup,

  /// 阶段2 选择文件
  selecting,

  /// 阶段3 恢复中（转圈 + 日志）
  restoring,

  /// 阶段3 成功（✓ + 完成）
  restoreSuccess,

  /// 阶段3 失败（✗ + 重试/关闭）
  restoreFailed,
}

class _BackupRestoreSheetState extends State<BackupRestoreSheet> {
  final List<({String text, bool isError})> _logs = [];
  final ScrollController _scrollController = ScrollController();

  _RestoreState _state = _RestoreState.preparing;
  List<WebDavFile> _files = const [];
  WebDavFile? _selected;

  @override
  void initState() {
    super.initState();
    _runPrepare();
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

  /// 阶段1：加载配置 + 列出备份文件（首跑与重试共用）
  Future<void> _runPrepare() async {
    setState(() {
      _state = _RestoreState.preparing;
      _logs.clear();
    });
    try {
      final files = await widget.prepareTask(_appendLog);
      if (!mounted) return;
      if (files.isEmpty) {
        _appendLog('未找到备份', isError: true);
        setState(() => _state = _RestoreState.noBackup);
        return;
      }
      setState(() {
        _files = files;
        _selected = null;
        _state = _RestoreState.selecting;
      });
    } catch (e) {
      if (!mounted) return;
      _appendLog('失败: $e', isError: true);
      setState(() => _state = _RestoreState.prepareFailed);
      _scrollToBottom();
    }
  }

  /// 阶段3：恢复指定文件（首跑与重试共用）
  Future<void> _runRestore() async {
    final file = _selected;
    if (file == null) return;
    setState(() {
      _state = _RestoreState.restoring;
      _logs.clear();
    });
    try {
      await widget.restoreTask(file, _appendLog);
      if (!mounted) return;
      setState(() => _state = _RestoreState.restoreSuccess);
    } catch (e) {
      if (!mounted) return;
      _appendLog('失败: $e', isError: true);
      setState(() => _state = _RestoreState.restoreFailed);
      _scrollToBottom();
    }
  }

  /// 关闭面板；[success] 为面板结果（BackupLogic 用于刷新数据）
  void _close(bool success) => Navigator.of(context).pop(success);

  Widget _buildStatusIcon(ThemeData theme) {
    switch (_state) {
      case _RestoreState.preparing || _RestoreState.restoring:
        return const AppLoading(size: AppLoadingSize.small);
      case _RestoreState.restoreSuccess:
        return const Icon(Icons.check_circle,
            color: AppColors.success, size: 24);
      case _RestoreState.prepareFailed ||
            _RestoreState.noBackup ||
            _RestoreState.restoreFailed:
        return const Icon(Icons.error, color: AppColors.error, size: 24);
      case _RestoreState.selecting:
        return const SizedBox.shrink();
    }
  }

  /// 内容区：阶段2 文件列表；其余阶段日志流式区
  Widget _buildContent(ThemeData theme) {
    switch (_state) {
      case _RestoreState.selecting:
        return _buildFileList(theme);
      case _RestoreState.preparing ||
            _RestoreState.prepareFailed ||
            _RestoreState.noBackup ||
            _RestoreState.restoring ||
            _RestoreState.restoreSuccess ||
            _RestoreState.restoreFailed:
        return _buildLogArea(theme);
    }
  }

  /// 日志流式区（固定高度 + 自动滚动到底）
  Widget _buildLogArea(ThemeData theme) {
    return Container(
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
    );
  }

  /// 阶段2：备份文件列表（单选；每行始终显示清晰 radio 状态图标，
  /// 最新文件带"最新"标签）
  Widget _buildFileList(ThemeData theme) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 320),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: _files.length,
        itemBuilder: (context, index) {
          final file = _files[index];
          final isLatest = index == 0;
          final selected = _selected == file;
          return InkWell(
            onTap: () => setState(() => _selected = file),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                children: [
                  // radio 状态图标：未选中空心（灰）/ 选中实心（主题色）——始终可见
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: AppTypography.iconMD,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: AppTypography.weightMedium,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_formatDateTime(file.modified)} · ${file.formattedSize}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isLatest) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.15),
                        borderRadius: AppRadius.allSM,
                        border: Border.all(
                          color: AppColors.success.withValues(alpha: 0.5),
                          width: 1,
                        ),
                      ),
                      child: const Text(
                        '最新',
                        style: TextStyle(
                          fontSize: AppTypography.sizeXXS,
                          fontWeight: AppTypography.weightMedium,
                          color: AppColors.success,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  /// 操作按钮行（阶段3 恢复中不显示，防中断）
  Widget _buildActions() {
    switch (_state) {
      case _RestoreState.preparing:
        return SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => _close(false),
            child: const Text('取消'),
          ),
        );
      case _RestoreState.selecting:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _close(false),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FilledButton(
                onPressed: _selected == null ? null : _runRestore,
                child: const Text('开始恢复'),
              ),
            ),
          ],
        );
      case _RestoreState.prepareFailed:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _runPrepare,
                child: const Text('重试'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FilledButton(
                onPressed: () => _close(false),
                child: const Text('关闭'),
              ),
            ),
          ],
        );
      case _RestoreState.noBackup:
        return SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => _close(false),
            child: const Text('关闭'),
          ),
        );
      case _RestoreState.restoring:
        return const SizedBox.shrink();
      case _RestoreState.restoreSuccess:
        return SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => _close(true),
            child: const Text('完成'),
          ),
        );
      case _RestoreState.restoreFailed:
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _runRestore,
                child: const Text('重试'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FilledButton(
                onPressed: () => _close(false),
                child: const Text('关闭'),
              ),
            ),
          ],
        );
    }
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
                _buildStatusIcon(theme),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _buildContent(theme),
            const SizedBox(height: AppSpacing.lg),
            SizedBox(width: double.infinity, child: _buildActions()),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/core.dart';

import 'logic.dart';
import 'state.dart';

/// 已下载文件清理页：列出已完成且文件存在的下载，支持逐条 / 多选 / 全选删除。
class DownloadCleanPage extends ConsumerStatefulWidget {
  const DownloadCleanPage({super.key});

  @override
  ConsumerState<DownloadCleanPage> createState() => _DownloadCleanPageState();
}

class _DownloadCleanPageState extends ConsumerState<DownloadCleanPage> {
  /// 选中的文件路径集合。
  final Set<String> _selected = {};

  CacheManageNotifier get _notifier =>
      ref.read(cacheManageProvider.notifier);

  @override
  void initState() {
    super.initState();
    // Riverpod 禁止在 build/initState 期间修改 provider 状态，
    // 延迟到首帧构建完成后刷新下载列表
    Future.microtask(_notifier.loadDownloads);
  }

  bool get _allSelected {
    final items = ref.read(cacheManageProvider).downloads;
    return items.isNotEmpty && _selected.length == items.length;
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final ok = await AppDialogs.showConfirmDialog(
      title: '删除已下载文件',
      message: '确定删除选中的 $count 个文件吗？\n'
          '将直接从下载目录移除，此操作不可恢复。',
      confirmText: '删除',
      isDangerous: true,
    );
    if (ok != true) return;

    final paths = _selected.toList();
    final success = await _notifier.deleteDownloads(paths);
    if (!mounted) return;
    setState(() => _selected.clear());
    if (success > 0) {
      AppDialogs.showSuccess('已删除 $success 个下载文件');
    } else {
      AppDialogs.showError('删除失败，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(cacheManageProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('已下载文件')),
      body: (() {
        if (state.downloadsLoading && state.downloads.isEmpty) {
          return const LoadingState(message: '正在加载下载列表…');
        }
        if (state.downloads.isEmpty) {
          return const EmptyState(
            icon: Icons.download_done_outlined,
            message: '暂无已完成的下载文件',
          );
        }
        final items = state.downloads;
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final isSelected = _selected.contains(item.filePath);
            final isDeleting = state.deletingIds.contains(item.filePath);
            return ListTile(
              leading: Checkbox(
                value: isSelected,
                onChanged: isDeleting
                    ? null
                    : (checked) {
                        setState(() {
                          if (checked == true) {
                            _selected.add(item.filePath);
                          } else {
                            _selected.remove(item.filePath);
                          }
                        });
                      },
              ),
              title: Row(
                children: [
                  // APK 图标（内存字节），非 APK / 无图标用通用文件图标
                  _buildFileIcon(context, item),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(left: 48),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // APK：副标题含包名 + 版本
                    if (item.apkSubtitle != null) ...[
                      Text(
                        item.apkSubtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                    ],
                    Text(
                      '${item.fileName}\n'
                      '${_notifier.formatSize(item.size)} · '
                      '${_formatTime(item.modifiedAt)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              isThreeLine: true,
              trailing: isDeleting
                  ? const AppLoading(size: AppLoadingSize.small)
                  : IconButton(
                      icon: Icon(Icons.delete_outline,
                          color: theme.colorScheme.error),
                      tooltip: '删除该文件',
                      onPressed: () async {
                        setState(() {
                          _selected
                            ..clear()
                            ..add(item.filePath);
                        });
                        await _deleteSelected();
                      },
                    ),
              onTap: isDeleting
                  ? null
                  : () {
                      setState(() {
                        if (isSelected) {
                          _selected.remove(item.filePath);
                        } else {
                          _selected.add(item.filePath);
                        }
                      });
                    },
            );
          },
        );
      })(),
      // 底部操作栏：全选 + 删除选中（有选中才可点）
      bottomNavigationBar: state.downloads.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: AppSpacing.onlyHorizontalLG,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outlineVariant,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        setState(() {
                          if (_allSelected) {
                            _selected.clear();
                          } else {
                            _selected
                              ..clear()
                              ..addAll(state.downloads.map((e) => e.filePath));
                          }
                        });
                      },
                      child: Text(_allSelected ? '取消全选' : '全选'),
                    ),
                    const Spacer(),
                    Text(
                      '已选 ${_selected.length}',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        backgroundColor: theme.colorScheme.errorContainer,
                      ),
                      onPressed: _selected.isEmpty ? null : _deleteSelected,
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  /// 文件行图标：APK 且有图标字节 → 应用图标；否则通用文件图标。
  Widget _buildFileIcon(BuildContext context, DownloadedFileItem item) {
    final bytes = item.apkIconBytes;
    if (item.isApk && bytes != null && bytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Image.memory(
          bytes,
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackIcon(context, item),
        ),
      );
    }
    return _fallbackIcon(context, item);
  }

  Widget _fallbackIcon(BuildContext context, DownloadedFileItem item) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Icon(
        item.isApk ? Icons.android : Icons.insert_drive_file_outlined,
        size: 22,
        color: scheme.primary,
      ),
    );
  }

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    final local = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    if (now.year == local.year &&
        now.month == local.month &&
        now.day == local.day) {
      return '今天 ${two(local.hour)}:${two(local.minute)}';
    }
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

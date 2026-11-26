import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';

import 'workspace_picker.dart';

/// 当前工作区的文件列表弹层。
///
/// 输入胶囊下方的工作区 pill 点击后展示：
/// - 标题右侧「切换」：换工作区后原地刷新列表；
/// - 点击文件：在弹层内预览文本/图片；
/// - 返回按钮回到文件列表。
Future<void> showAgentWorkspaceFilesSheet(
  BuildContext context,
  AgentService service,
) {
  return AppSheet.showCustom<void>(
    context: context,
    builder: (sheetContext) => _WorkspaceFilesSheet(service: service),
  );
}

class _WorkspaceFilesSheet extends StatefulWidget {
  const _WorkspaceFilesSheet({required this.service});

  final AgentService service;

  @override
  State<_WorkspaceFilesSheet> createState() => _WorkspaceFilesSheetState();
}

class _WorkspaceFilesSheetState extends State<_WorkspaceFilesSheet> {
  AgentWorkspaceInfo? _workspace;
  AgentWorkspaceStats? _stats;
  List<AgentWorkspaceEntry> _files = const [];
  bool _loading = true;
  String? _error;

  AgentWorkspaceEntry? _preview;
  String? _previewText;
  Uint8List? _previewImage;
  int _previewBytes = 0;
  bool _previewTruncated = false;
  bool _previewBinary = false;
  bool _previewLoading = false;
  String? _previewError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _preview = null;
      _previewText = null;
      _previewImage = null;
      _previewError = null;
    });
    try {
      final workspace = widget.service.workspaceService;
      final info = await workspace.currentWorkspace();
      final stats = await workspace.stats();
      final entries = await workspace.listAll();
      final files = entries.where((entry) => !entry.isDirectory).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (!mounted) return;
      setState(() {
        _workspace = info;
        _stats = stats;
        _files = files;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取工作区失败：$error';
      });
    }
  }

  Future<void> _switchWorkspace() async {
    final info = await showAgentWorkspacePicker(context, widget.service);
    if (info == null || !mounted) return;
    try {
      final ok = await widget.service.setWorkspaceForCurrentSession(info.id);
      if (!ok) {
        if (mounted) AppDialogs.showError('生成中不能切换工作区');
        return;
      }
      await _load();
      if (mounted) AppDialogs.showSuccess('已切换到 ${info.name}');
    } catch (error) {
      if (mounted) AppDialogs.showError('切换工作区失败：$error');
    }
  }

  Future<void> _openPreview(AgentWorkspaceEntry entry) async {
    setState(() {
      _preview = entry;
      _previewLoading = true;
      _previewError = null;
      _previewText = null;
      _previewImage = null;
    });
    try {
      final workspace = widget.service.workspaceService;
      if (_isImage(entry.path)) {
        final bytes = await workspace.readBytes(entry.path);
        if (!mounted) return;
        setState(() {
          _previewImage = Uint8List.fromList(bytes);
          _previewBytes = bytes.length;
          _previewLoading = false;
        });
        return;
      }
      final result = await workspace.read(entry.path);
      if (!mounted) return;
      setState(() {
        _previewText = result.text;
        _previewBinary = result.binary;
        _previewBytes = result.bytes;
        _previewTruncated = result.truncated;
        _previewLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _previewLoading = false;
        _previewError = '读取失败：$error';
      });
    }
  }

  void _backToList() {
    setState(() {
      _preview = null;
      _previewText = null;
      _previewImage = null;
      _previewError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = _preview;
    final workspaceName = _workspace?.name ?? '当前工作区';

    if (preview != null) {
      return AppSheetScaffold(
        title: preview.path,
        subtitle: _previewSubtitle(),
        icon: const Icon(TablerIcons.file_text),
        maxHeightFactor: 0.85,
        headerTrailing: TextButton.icon(
          onPressed: _backToList,
          icon: const Icon(TablerIcons.arrow_left, size: 16),
          label: const Text('文件'),
        ),
        content: _buildPreview(theme, scheme),
      );
    }

    return AppSheetScaffold(
      title: workspaceName,
      subtitle: _stats == null
          ? null
          : '${_files.length} 个文件 · ${_formatBytes(_stats!.bytes)}',
      icon: Icon(
        _workspace?.isExternal == true
            ? TablerIcons.device_mobile
            : TablerIcons.folder,
      ),
      maxHeightFactor: 0.85,
      headerTrailing: TextButton.icon(
        onPressed: _switchWorkspace,
        icon: const Icon(TablerIcons.switch_horizontal, size: 16),
        label: const Text('切换'),
      ),
      content: _buildContent(theme, scheme),
    );
  }

  Widget _buildContent(ThemeData theme, ColorScheme scheme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: AppLoading(size: AppLoadingSize.medium)),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Text(
          _error!,
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
        ),
      );
    }
    if (_files.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          children: [
            Icon(
              TablerIcons.folder_off,
              size: AppTypography.iconXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '当前工作区为空',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '开启文件访问后，AI 可以通过 fileWrite 创建文件。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          for (var i = 0; i < _files.length; i++) ...[
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
              ),
              leading: Icon(
                _iconForPath(_files[i].path),
                color: scheme.primary,
              ),
              title: Text(
                _files[i].path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${_formatBytes(_files[i].bytes)} · '
                '${_formatTime(_files[i].modifiedAt)}',
              ),
              trailing: const Icon(TablerIcons.chevron_right),
              onTap: () => _openPreview(_files[i]),
            ),
            if (i != _files.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }

  Widget _buildPreview(ThemeData theme, ColorScheme scheme) {
    if (_previewLoading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(child: AppLoading(size: AppLoadingSize.medium)),
      );
    }
    if (_previewError != null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Text(
          _previewError!,
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
        ),
      );
    }
    if (_previewImage != null) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: ClipRRect(
          borderRadius: AppRadius.allMD,
          child: Image.memory(_previewImage!, fit: BoxFit.contain),
        ),
      );
    }
    if (_previewBinary || (_previewText ?? '').isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Text(
          _previewBinary
              ? '二进制文件（${_formatBytes(_previewBytes)}），暂不支持文本预览。'
              : '文件为空。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: SelectableText(
        _previewText!,
        style: theme.textTheme.bodySmall,
      ),
    );
  }

  String _previewSubtitle() {
    final parts = <String>[_formatBytes(_previewBytes)];
    if (_previewTruncated) parts.add('已截断');
    return parts.join(' · ');
  }

  static bool _isImage(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp');
  }

  static IconData _iconForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.md')) return TablerIcons.markdown;
    if (lower.endsWith('.json')) return TablerIcons.braces;
    if (_isImage(path)) return TablerIcons.photo;
    return TablerIcons.file_text;
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    return '$bytes B';
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    return '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

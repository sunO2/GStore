import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/editor/code_document_source.dart';
import 'package:gstore/page/code_editor/code_editor_page.dart';
import 'workspace_picker.dart';

/// AI 文件工作区：查看/开关/清空/预览。
class AgentWorkspacePage extends StatefulWidget {
  const AgentWorkspacePage({super.key});

  @override
  State<AgentWorkspacePage> createState() => _AgentWorkspacePageState();
}

enum _WorkspaceManageAction { clearFiles, removeWorkspace }

class _AgentWorkspacePageState extends State<AgentWorkspacePage> {
  AgentService? _service;
  bool _loading = true;
  List<AgentWorkspaceEntry> _entries = const [];
  AgentWorkspaceStats? _stats;
  List<AgentWorkspaceAuditEntry> _audit = const [];
  AgentWorkspaceInfo? _workspace;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = ModuleManager.instance.get<AgentService>();
    if (service == null) {
      if (mounted) {
        setState(() {
          _service = null;
          _loading = false;
        });
      }
      return;
    }
    try {
      final workspace = service.workspaceService;
      final info = await workspace.currentWorkspace();
      final stats = await workspace.stats();
      final entries = await workspace.listAll();
      final audit = await workspace.audit(limit: 10, workspaceId: info.id);
      if (!mounted) return;
      setState(() {
        _service = service;
        _stats = stats;
        _entries = entries;
        _audit = audit;
        _workspace = info;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppDialogs.showError('读取工作区失败：$error');
    }
  }

  Future<void> _toggleFileAccess(bool enabled) async {
    await _service?.setFileAccessEnabled(enabled);
    if (!mounted) return;
    setState(() {});
    AppDialogs.showSuccess(enabled ? '已允许 AI 读写工作区文件' : '已关闭 AI 文件访问');
  }

  Future<void> _manageWorkspace() async {
    final service = _service;
    final workspace = _workspace;
    if (service == null || workspace == null) return;
    final canRemove =
        workspace.id != AgentWorkspaceService.defaultWorkspaceId;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = _stats;

    final action = await AppDialogs.showContentSheet<_WorkspaceManageAction>(
      title: '管理工作区',
      subtitle: workspace.isExternal ? '外部目录（SAF）' : '应用内目录',
      icon: const Icon(TablerIcons.folder_cog),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前工作区：${workspace.name}',
            style: theme.textTheme.titleSmall,
          ),
          if (stats != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${stats.files} 个文件 · ${_formatBytes(stats.bytes)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          _buildManageExplanation(
            title: '清空文件',
            description: '删除当前工作区内的全部文件，工作区仍保留在列表中。',
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildManageExplanation(
            title: '移除工作区',
            description: workspace.isExternal
                ? '从工作区列表移除，并切换到默认工作区。'
                    '外部 SAF 目录只从列表移除，不会删除手机目录中的文件。'
                : '从工作区列表移除，并切换到默认工作区。'
                    '应用内工作区的私有文件会一并删除。',
          ),
          if (!canRemove) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              '默认工作区不可移除，只能清空文件。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.error,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<_WorkspaceManageAction>(null),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              AppDialogs.popSheet<_WorkspaceManageAction>(
                _WorkspaceManageAction.clearFiles,
              ),
          child: const Text('清空文件'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: canRemove
              ? () => AppDialogs.popSheet(
                    _WorkspaceManageAction.removeWorkspace,
                  )
              : null,
          child: const Text('移除工作区'),
        ),
      ],
    );

    if (!mounted || action == null) return;
    switch (action) {
      case _WorkspaceManageAction.clearFiles:
        await _clearWorkspaceFiles(service);
      case _WorkspaceManageAction.removeWorkspace:
        await _removeWorkspace(service);
    }
  }

  Widget _buildManageExplanation({
    required String title,
    required String description,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _clearWorkspaceFiles(AgentService service) async {
    try {
      await service.workspaceService.clear();
      await _load();
      if (mounted) AppDialogs.showSuccess('工作区文件已清空');
    } catch (error) {
      if (mounted) AppDialogs.showError('清空失败：$error');
    }
  }

  Future<void> _removeWorkspace(AgentService service) async {
    final workspace = _workspace;
    if (workspace == null) return;
    if (workspace.id == AgentWorkspaceService.defaultWorkspaceId) {
      if (mounted) AppDialogs.showError('默认工作区不可移除，只能清空文件');
      return;
    }
    try {
      final ok = await service.removeWorkspaceForCurrentSession(workspace.id);
      if (!ok) {
        if (mounted) AppDialogs.showError('生成中不能移除工作区');
        return;
      }
      await _load();
      if (mounted) {
        AppDialogs.showSuccess(
          '已移除工作区，当前为「${_workspace?.name ?? '默认工作区'}」',
        );
      }
    } catch (error) {
      if (mounted) AppDialogs.showError('移除工作区失败：$error');
    }
  }

  Future<void> _importFile() async {
    final service = _service;
    if (service == null) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: false,
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;
      await service.workspaceService.importFile(path);
      await _load();
      if (mounted) AppDialogs.showSuccess('文件已导入工作区');
    } catch (error) {
      if (mounted) AppDialogs.showError('导入失败：$error');
    }
  }

  Future<void> _exportFile(AgentWorkspaceEntry entry) async {
    final service = _service;
    if (service == null) return;
    try {
      final bytes = await service.workspaceService.exportBytes(entry.path);
      final name = entry.path.split('/').last;
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: '导出文件',
        fileName: name,
        bytes: Uint8List.fromList(bytes),
      );
      if (saved != null && mounted) {
        AppDialogs.showSuccess('已导出到 $saved');
      }
    } catch (error) {
      if (mounted) AppDialogs.showError('导出失败：$error');
    }
  }

  Future<void> _deleteFile(AgentWorkspaceEntry entry) async {
    final service = _service;
    if (service == null) return;
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除文件',
      message: entry.path,
      isDangerous: true,
      confirmText: '删除',
    );
    if (ok != true) return;
    try {
      await service.workspaceService.deleteFile(entry.path);
      await _load();
      if (mounted) AppDialogs.showSuccess('文件已删除');
    } catch (error) {
      if (mounted) AppDialogs.showError('删除失败：$error');
    }
  }

  Future<void> _chooseWorkspace() async {
    final service = _service;
    if (service == null) return;
    final info = await showAgentWorkspacePicker(context, service);
    if (info == null || !mounted) return;
    try {
      final ok = await service.setWorkspaceForCurrentSession(info.id);
      if (!ok) {
        if (mounted) AppDialogs.showError('生成中不能切换工作区');
        return;
      }
      await _load();
      if (mounted) AppDialogs.showSuccess('已切换工作区');
    } catch (error) {
      if (mounted) AppDialogs.showError('切换工作区失败：$error');
    }
  }

  Future<void> _preview(AgentWorkspaceEntry entry) async {
    final service = _service;
    if (service == null) return;
    final lower = entry.path.toLowerCase();
    final isImage = lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp');
    if (isImage) {
      final localPath =
          await service.workspaceService.localPathFor(entry.path);
      final Widget image;
      if (localPath != null) {
        image = Image.file(File(localPath), fit: BoxFit.contain);
      } else {
        final bytes = await service.workspaceService.readBytes(entry.path);
        image = Image.memory(Uint8List.fromList(bytes), fit: BoxFit.contain);
      }
      await AppDialogs.showContentSheet(
        title: entry.path,
        content: ClipRRect(
          borderRadius: AppRadius.allMD,
          child: InteractiveViewer(
            maxScale: 4,
            child: image,
          ),
        ),
      );
      return;
    }
    await Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CodeEditorPage(
          source: CodeDocumentSource.workspace(
            service.workspaceService,
            entry.path,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件工作区'),
        actions: [
          IconButton(
            tooltip: '导入文件',
            icon: const Icon(TablerIcons.upload),
            onPressed: service == null ? null : _importFile,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(TablerIcons.refresh),
            onPressed: _load,
          ),
          IconButton(
            tooltip: '管理工作区',
            icon: const Icon(TablerIcons.trash),
            onPressed: service == null ? null : _manageWorkspace,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: AppLoading(size: AppLoadingSize.medium))
          : service == null
              ? _buildUnavailable(context)
              : _buildBody(context, service),
    );
  }

  Widget _buildUnavailable(BuildContext context) {
    return Center(
      child: Text(
        'Agent 模块未启用',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }

  Widget _buildBody(BuildContext context, AgentService service) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = _stats;
    final files = _entries.where((e) => !e.isDirectory).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: AppRadius.allMD,
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: ListTile(
              leading: Icon(
                TablerIcons.folder_open,
                color: scheme.primary,
              ),
              title: Text(_workspace?.name ?? '默认工作区'),
              subtitle: Text(
                _workspace?.isExternal == true
                    ? '外部目录（SAF）· 点击切换'
                    : '应用内目录 · 点击切换',
              ),
              trailing: const Icon(TablerIcons.switch_horizontal),
              onTap: _chooseWorkspace,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: AppRadius.allMD,
              side: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: ValueListenableBuilder<bool>(
              valueListenable: service.fileAccessEnabled,
              builder: (context, enabled, _) => SwitchListTile(
                value: enabled,
                onChanged: _toggleFileAccess,
                secondary: Icon(
                  TablerIcons.folder,
                  color: scheme.primary,
                ),
                title: const Text('允许 AI 读写文件'),
                subtitle: Text(
                  enabled
                      ? 'AI 只能访问此工作区；写/创建会逐次确认'
                      : '文件工具不会下发给模型',
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (stats != null)
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: AppRadius.allMD,
                side: BorderSide(
                  color: scheme.outlineVariant.withValues(alpha: 0.5),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          TablerIcons.database,
                          size: AppTypography.iconMD,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          '${stats.files} / ${stats.maxFiles} 个文件',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const Spacer(),
                        Text(
                          '${_formatBytes(stats.bytes)} / ${_formatBytes(stats.maxBytes)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    ClipRRect(
                      borderRadius: AppRadius.allXS,
                      child: LinearProgressIndicator(
                        value: stats.ratio,
                        minHeight: 6,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '文件',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (files.isEmpty)
            Card(
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Center(
                  child: Text(
                    '工作区为空。开启文件访问后，AI 可以通过 fileWrite 创建文件。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            Card(
              elevation: 0,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < files.length; i++) ...[
                    ListTile(
                      leading: Icon(
                        _iconForPath(files[i].path),
                        color: scheme.primary,
                      ),
                      title: Text(
                        files[i].path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_formatBytes(files[i].bytes)} · '
                        '${_formatTime(files[i].modifiedAt)}',
                      ),
                      trailing: PopupMenuButton<String>(
                        tooltip: '文件操作',
                        onSelected: (value) {
                          if (value == 'export') {
                            _exportFile(files[i]);
                          } else if (value == 'delete') {
                            _deleteFile(files[i]);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'export',
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(TablerIcons.download),
                              title: Text('导出'),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(TablerIcons.trash),
                              title: Text('删除'),
                            ),
                          ),
                        ],
                      ),
                      onTap: () => _preview(files[i]),
                    ),
                    if (i != files.length - 1) const Divider(height: 1),
                  ],
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '最近操作（当前工作区）',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_audit.isEmpty)
            Text(
              '暂无记录',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          else
            Card(
              elevation: 0,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < _audit.length; i++) ...[
                    ListTile(
                      dense: true,
                      leading: Icon(
                        _audit[i].ok
                            ? TablerIcons.circle_check
                            : TablerIcons.alert_circle,
                        size: AppTypography.iconMD,
                        color: _audit[i].ok ? scheme.primary : scheme.error,
                      ),
                      title: Text('${_audit[i].action}  ${_audit[i].path}'),
                      subtitle: Text(
                        '${_formatTime(_audit[i].time)}'
                        '${_audit[i].bytes > 0 ? ' · ${_formatBytes(_audit[i].bytes)}' : ''}',
                      ),
                    ),
                    if (i != _audit.length - 1) const Divider(height: 1),
                  ],
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }

  IconData _iconForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.md')) return TablerIcons.markdown;
    if (lower.endsWith('.json')) return TablerIcons.braces;
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp')) {
      return TablerIcons.photo;
    }
    return TablerIcons.file_text;
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    return '$bytes B';
  }

  String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';

/// 镜像配置弹层的返回值
class MirrorConfigResult {
  const MirrorConfigResult({required this.mirrors, required this.useMirrors});

  final List<FdroidMirror> mirrors;
  final bool useMirrors;
}

/// 源 → 镜像配置（镜像**从属于源**，可逐个启用/禁用，并有源级回退开关）
///
/// 层级：源（仓库身份）= repoUrl + 指纹；镜像只是它的从属配置，不是独立源。
///
/// 呈现：统一底部弹层（[AppSheetScaffold]）——内容超出限高时自动内部滚动。
class MirrorConfigDialog extends StatefulWidget {
  const MirrorConfigDialog({super.key, required this.source});

  final FdroidSource source;

  static Future<MirrorConfigResult?> show(BuildContext context, FdroidSource source) {
    return AppSheet.showCustom<MirrorConfigResult>(
      context: context,
      builder: (_) => MirrorConfigDialog(source: source),
    );
  }

  @override
  State<MirrorConfigDialog> createState() => _MirrorConfigDialogState();
}

class _MirrorConfigDialogState extends State<MirrorConfigDialog> {
  late List<FdroidMirror> _mirrors;
  late bool _useMirrors;
  final _addController = TextEditingController();
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _mirrors = List.of(widget.source.mirrors);
    _useMirrors = widget.source.useMirrors;
  }

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  int get _enabledCount => _mirrors.where((m) => m.enabled).length;

  void _toggle(int index, bool value) {
    setState(() => _mirrors[index] = _mirrors[index].copyWith(enabled: value));
  }

  void _remove(int index) {
    setState(() => _mirrors.removeAt(index));
  }

  /// 手动添加一条镜像（已存在则忽略）
  void _add() {
    final url = _addController.text.trim();
    if (url.isEmpty) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      AppDialogs.showError('镜像地址需以 http:// 或 https:// 开头');
      return;
    }
    if (_mirrors.any((m) => m.url == url)) {
      AppDialogs.showError('该镜像已在列表中');
      return;
    }
    setState(() {
      _mirrors.add(FdroidMirror(url: url));
      _addController.clear();
    });
  }

  /// 从索引声明的镜像导入（源身份不变，只是补全可用镜像）
  Future<void> _importFromIndex() async {
    setState(() => _importing = true);
    try {
      final meta = await FdroidRustRepoManager.getRepoMeta();
      final declared = (meta?['mirrors'] as List?)?.whereType<String>().toList() ?? const [];
      final existing = _mirrors.map((m) => m.url).toSet();
      final added = <FdroidMirror>[
        for (final url in declared)
          if (!existing.contains(url)) FdroidMirror(url: url, fromIndex: true),
      ];
      if (!mounted) return;
      if (added.isEmpty) {
        AppDialogs.showError('索引中没有新的镜像（共 ${declared.length} 条声明）');
      } else {
        setState(() => _mirrors.addAll(added));
        AppDialogs.showSuccess('已从索引导入 ${added.length} 条镜像');
      }
    } catch (e) {
      AppDialogs.showError('导入失败: $e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSheetScaffold(
      title: '配置镜像',
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _useMirrors,
            onChanged: (v) => setState(() => _useMirrors = v),
            title: const Text('启用镜像回退'),
            subtitle: Text(
              _useMirrors
                  ? '优先尝试下方已启用的镜像，全部失败再回退到源地址'
                  : '只使用源地址（镜像配置保留但不生效）',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: AppSpacing.onlyVerticalSM,
            child: Text(
              '镜像列表 · 共 ${_mirrors.length} 条，已启用 $_enabledCount 条',
              style: theme.textTheme.labelMedium,
            ),
          ),
          if (_mirrors.isEmpty)
            Padding(
              padding: AppSpacing.onlyVerticalMD,
              child: Text('暂无镜像，可在下方添加或从索引导入',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
            )
          else
            // 列表随弹层内容区一起滚动（不做嵌套滚动）
            for (var i = 0; i < _mirrors.length; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(_mirrors[i].url,
                    style: AppTypography.code.copyWith(fontSize: 11)),
                subtitle: Text(
                  _mirrors[i].fromIndex ? '来自索引声明' : '手动添加',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: _mirrors[i].enabled,
                      onChanged: _useMirrors ? (v) => _toggle(i, v) : null,
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => _remove(i),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addController,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'https://mirror.example.com/fdroid/repo',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              IconButton(
                tooltip: '添加镜像',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: _add,
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: _importing
                  ? const SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_download_outlined, size: 18),
              label: const Text('从索引导入'),
              onPressed: _importing ? null : _importFromIndex,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            MirrorConfigResult(mirrors: _mirrors, useMirrors: _useMirrors),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

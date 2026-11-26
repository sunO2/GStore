import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:re_editor/re_editor.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/editor/app_code_language.dart';
import 'package:gstore/core/editor/code_document_source.dart';

/// 通用文本编辑/预览页。
///
/// 支持 [CodeDocumentSource] 的四种来源：
/// - 内存文本（保存时把编辑结果 pop 回上一页）
/// - 本地 File / filePath
/// - URI（file:// 可编辑；http(s)://、data: 只读）
/// - AI 工作区文件（经 [AgentWorkspaceService] 读取/写回）
///
/// 只读/编辑由 [CodeDocument.editable] 与 [readOnly] 共同决定。
class CodeEditorPage extends StatefulWidget {
  const CodeEditorPage({
    super.key,
    required this.source,
    this.readOnly,
    this.language,
    this.showLineNumbers = true,
    this.onSaved,
  });

  final CodeDocumentSource source;

  /// 强制只读/编辑；null 时默认只读（可编辑来源会显示编辑按钮）。
  final bool? readOnly;

  /// 显式语言；null 时按 [CodeDocument.filePath] 推断。
  final AppCodeLanguage? language;

  final bool showLineNumbers;

  /// 保存成功后的回调（内存文本来源不会触发，直接 pop 结果）。
  final ValueChanged<String>? onSaved;

  @override
  State<CodeEditorPage> createState() => _CodeEditorPageState();
}

enum _CodeEditorMenuAction { zoomIn, zoomOut, resetFontSize }

class _CodeEditorPageState extends State<CodeEditorPage> {
  CodeDocument? _document;
  CodeLineEditingController? _controller;
  Object? _loadError;
  bool _loading = true;
  bool _saving = false;
  bool _readOnly = true;
  bool _dirty = false;
  bool _showLineNumbers = true;

  late final double _baseFontSize;
  late final ValueNotifier<double> _fontSize;

  @override
  void initState() {
    super.initState();
    _baseFontSize = AppTypography.code.fontSize ?? 14;
    _fontSize = ValueNotifier<double>(_baseFontSize);
    _showLineNumbers = widget.showLineNumbers;
    _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _fontSize.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _dirty = false;
    });
    try {
      final document = await widget.source.load();
      if (!mounted) return;

      final old = _controller;
      final controller = CodeLineEditingController.fromText(document.text);
      setState(() {
        _document = document;
        _controller = controller;
        // 默认只读预览；显式 readOnly: false 才直接进入编辑。
        // 不可编辑来源（截断/二进制/只读 URI）始终只读。
        _readOnly = !document.editable || (widget.readOnly ?? true);
        _loading = false;
      });
      // 旧 controller 仍可能被当前帧的 AppCodeView 引用，延后一帧释放。
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  void _resetFontSize() {
    _fontSize.value = _baseFontSize;
  }

  void _handleMenuAction(_CodeEditorMenuAction action) {
    switch (action) {
      case _CodeEditorMenuAction.zoomIn:
        _fontSize.value = (_fontSize.value + 1).clamp(9.0, 32.0).toDouble();
      case _CodeEditorMenuAction.zoomOut:
        _fontSize.value = (_fontSize.value - 1).clamp(9.0, 32.0).toDouble();
      case _CodeEditorMenuAction.resetFontSize:
        _resetFontSize();
    }
  }

  Future<void> _save() async {
    final document = _document;
    final controller = _controller;
    if (document == null || controller == null || _saving) return;

    final text = controller.text;
    final save = document.save;
    if (save == null) {
      // 内存文本/不可写来源：把编辑结果交回上一页。
      setState(() => _dirty = false);
      Navigator.of(context).pop(text);
      return;
    }

    setState(() => _saving = true);
    try {
      await save(text);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
        _readOnly = true;
      });
      widget.onSaved?.call(text);
      AppDialogs.showSuccess('已保存');
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppDialogs.showError('保存失败：$error');
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await AppDialogs.showConfirmSheet(
      title: '放弃修改？',
      message: '当前修改尚未保存，返回后将丢失。',
      confirmText: '放弃',
      cancelText: '继续编辑',
      isDangerous: true,
    );
    if (discard == true && mounted) {
      setState(() => _dirty = false);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final document = _document;
    final editable = document?.editable == true;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            document?.title ?? widget.source.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: _showLineNumbers ? '隐藏行号' : '显示行号',
              icon: const Icon(TablerIcons.list_numbers),
              onPressed: () {
                setState(() => _showLineNumbers = !_showLineNumbers);
              },
            ),
            PopupMenuButton<_CodeEditorMenuAction>(
              tooltip: '字号',
              icon: const Icon(TablerIcons.zoom_in),
              onSelected: _handleMenuAction,
              itemBuilder: (context) {
                final percent =
                    ((_fontSize.value / _baseFontSize) * 100).round();
                return <PopupMenuEntry<_CodeEditorMenuAction>>[
                  const PopupMenuItem(
                    value: _CodeEditorMenuAction.zoomIn,
                    child: Text('放大字号'),
                  ),
                  const PopupMenuItem(
                    value: _CodeEditorMenuAction.zoomOut,
                    child: Text('缩小字号'),
                  ),
                  PopupMenuItem(
                    value: _CodeEditorMenuAction.resetFontSize,
                    child: Text('重置字号（$percent%）'),
                  ),
                ];
              },
            ),
            if (editable)
              IconButton(
                tooltip: _readOnly ? '编辑' : '保存',
                onPressed: _saving
                    ? null
                    : (_readOnly
                        ? () => setState(() => _readOnly = false)
                        : _save),
                icon: _saving
                    ? const AppLoading(size: AppLoadingSize.small)
                    : Icon(
                        _readOnly
                            ? TablerIcons.edit
                            : TablerIcons.device_floppy,
                      ),
              ),
          ],
        ),
        body: _buildBody(theme, scheme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme scheme) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }

    final error = _loadError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                TablerIcons.alert_triangle,
                size: AppTypography.iconXXL,
                color: scheme.error,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '$error',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton.tonal(
                onPressed: _load,
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final document = _document;
    final controller = _controller;
    if (document == null || controller == null) {
      return const SizedBox.shrink();
    }

    return Column(
      children: [
        if (document.truncated) _buildTruncatedBanner(theme, scheme, document),
        Expanded(
          child: SafeArea(
            top: false,
            child: AppCodeView(
              text: document.text,
              controller: controller,
              filePath: document.filePath,
              language: widget.language,
              readOnly: _readOnly,
              showLineNumbers: _showLineNumbers,
              fontSizeNotifier: _fontSize,
              onChanged: _readOnly
                  ? null
                  : (_) {
                      if (!_dirty) setState(() => _dirty = true);
                    },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTruncatedBanner(
    ThemeData theme,
    ColorScheme scheme,
    CodeDocument document,
  ) {
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(
              TablerIcons.info_circle,
              size: AppTypography.iconSM,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '文件较大，仅显示前 ${_formatBytes(document.bytes)}，已禁用编辑',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSecondaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
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

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/design/app_spacing.dart';

/// 阶段 B：对话内联 A2UI surface。
///
/// 接收流式解析出的原始 A2UI 消息（可增量追加），通过 [MessageProcessor]
/// 维护 surface，并用 [A2uiSurface] 原生渲染。
class A2uiInlineCard extends StatefulWidget {
  const A2uiInlineCard({
    super.key,
    required this.messages,
    required this.revision,
    this.enabled = true,
    this.onAction,
  });

  final List<Map<String, Object?>> messages;
  final int revision;
  final bool enabled;
  final ValueChanged<A2uiRendererAction>? onAction;

  @override
  State<A2uiInlineCard> createState() => _A2uiInlineCardState();
}

class _A2uiInlineCardState extends State<A2uiInlineCard> {
  MessageProcessor<ComponentImplementation>? _processor;
  final List<SurfaceModel<ComponentImplementation>> _surfaces = [];
  int _applied = 0;
  A2uiError? _error;
  A2uiRendererAction? _lastAction;

  @override
  void initState() {
    super.initState();
    _processor = MessageProcessor<ComponentImplementation>(
      catalogs: [basicCatalog(locale: 'zh-CN')],
    )..model.onSurfaceCreated.subscribe((surface) {
        if (mounted) setState(() => _surfaces.add(surface));
      });
    _processor!.model.onSurfaceDeleted.subscribe((surfaceId) {
      if (mounted) {
        setState(() => _surfaces.removeWhere((s) => s.id == surfaceId));
      }
    });
    _processor!.model.onAction.subscribe((action) {
      if (!mounted) return;
      setState(() => _lastAction = action);
      if (widget.enabled) widget.onAction?.call(action);
    });
    _applyNewMessages();
  }

  @override
  void didUpdateWidget(covariant A2uiInlineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision ||
        widget.messages.length > _applied) {
      _applyNewMessages();
    }
  }

  @override
  void dispose() {
    _processor?.dispose();
    _processor = null;
    super.dispose();
  }

  void _applyNewMessages() {
    final processor = _processor;
    if (processor == null || _applied >= widget.messages.length) return;
    final batch = widget.messages.sublist(_applied);
    try {
      processor.processMessages(batch);
      _applied = widget.messages.length;
      _error = null;
    } on A2uiError catch (error) {
      _error = error;
      _applied = widget.messages.length;
    } catch (error) {
      _error = A2uiError('A2UI 渲染失败：$error', code: 'RENDER_ERROR');
      _applied = widget.messages.length;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final error = _error;
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.xs),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(TablerIcons.layout_grid, size: 16, color: scheme.primary),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  '生成式界面',
                  style: textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'A2UI',
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${error.code}: ${error.message}',
              style: textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ] else if (_surfaces.isEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '正在准备界面…',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ] else ...[
            const SizedBox(height: AppSpacing.sm),
            IgnorePointer(
              ignoring: !widget.enabled || _lastAction != null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final surface in _surfaces)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: A2uiSurface(
                        key: ObjectKey(surface),
                        surface: surface,
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Icon(
                _lastAction == null
                    ? TablerIcons.pointer
                    : TablerIcons.circle_check,
                size: 13,
                color: _lastAction == null
                    ? scheme.onSurfaceVariant
                    : scheme.primary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _lastAction == null
                      ? (widget.enabled ? '操作会回传给 AI' : 'AI 正在回复，暂不可操作')
                      : '已提交：${_lastAction!.name}，等待 AI 响应',
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

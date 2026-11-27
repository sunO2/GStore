import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/design/app_spacing.dart';

/// 对话内联的 A2UI 工具卡片（阶段 A）。
///
/// 只负责渲染工具参数里的 A2UI payload；action 由外层回传给 Agent。
class A2uiToolCard extends StatefulWidget {
  const A2uiToolCard({
    super.key,
    required this.payload,
    this.title,
    this.enabled = true,
    this.onAction,
  });

  /// A2UI v1.0 消息数组 JSON。
  final String payload;
  final String? title;

  /// 生成中/不可交互时为 false。
  final bool enabled;

  /// 用户操作回传；为 null 时只在本卡片展示。
  final ValueChanged<A2uiRendererAction>? onAction;

  @override
  State<A2uiToolCard> createState() => _A2uiToolCardState();
}

class _A2uiToolCardState extends State<A2uiToolCard> {
  MessageProcessor<ComponentImplementation>? _processor;
  final List<SurfaceModel<ComponentImplementation>> _surfaces = [];
  A2uiRendererAction? _lastAction;
  A2uiError? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _processor?.dispose();
    _processor = null;
    super.dispose();
  }

  void _load() {
    try {
      final decoded = jsonDecode(widget.payload);
      final processor = MessageProcessor<ComponentImplementation>(
        catalogs: [basicCatalog(locale: 'zh-CN')],
      );
      processor.model.onSurfaceCreated.subscribe((surface) {
        if (mounted) setState(() => _surfaces.add(surface));
      });
      processor.model.onSurfaceDeleted.subscribe((surfaceId) {
        if (mounted) {
          setState(() => _surfaces.removeWhere((s) => s.id == surfaceId));
        }
      });
      processor.model.onAction.subscribe((action) {
        if (!mounted) return;
        setState(() => _lastAction = action);
        if (widget.enabled) widget.onAction?.call(action);
      });
      processor.processMessages(decoded);
      _processor = processor;
    } on A2uiError catch (error) {
      _error = error;
    } on FormatException catch (error) {
      _error = A2uiError('payload 不是合法 JSON：$error', code: 'INVALID_JSON');
    } catch (error) {
      _error = A2uiError('A2UI 渲染失败：$error', code: 'RENDER_ERROR');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final error = _error;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
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
              Icon(TablerIcons.layout_grid, size: 18, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  widget.title?.trim().isNotEmpty == true
                      ? widget.title!.trim()
                      : '生成式界面',
                  style: textTheme.titleSmall?.copyWith(
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
          const SizedBox(height: AppSpacing.sm),
          if (error != null)
            Text(
              '${error.code}: ${error.message}',
              style: textTheme.bodySmall?.copyWith(color: scheme.error),
            )
          else if (_surfaces.isEmpty)
            Text(
              '正在准备界面…',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          else
            IgnorePointer(
              ignoring: !widget.enabled,
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
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Icon(
                _lastAction == null
                    ? TablerIcons.pointer
                    : TablerIcons.circle_check,
                size: 14,
                color: _lastAction == null
                    ? scheme.onSurfaceVariant
                    : scheme.primary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  _lastAction == null
                      ? (widget.enabled
                          ? '按钮操作会作为消息回传给 AI'
                          : 'AI 正在回复，暂不可操作')
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

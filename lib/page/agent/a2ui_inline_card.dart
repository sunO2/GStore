import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:gstore/core/agent/a2ui_payload_normalizer.dart';
import 'package:gstore/core/design/app_spacing.dart';

import 'a2ui_surface_shell.dart';

/// 阶段 B：对话内联 A2UI surface。
///
/// 接收流式解析出的原始 A2UI 消息（可增量追加），通过 [MessageProcessor]
/// 维护 surface，并用 [A2uiSurface] 原生渲染。外观与工具式卡片共用
/// [A2uiSurfaceShell]，保证两条路径视觉一致。
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
    final batch = normalizeA2uiBindings(widget.messages.sublist(_applied));
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
    return A2uiSurfaceShell(
      margin: const EdgeInsets.only(top: AppSpacing.sm),
      enabled: widget.enabled,
      lastActionName: _lastAction?.name,
      errorText: error == null ? null : '${error.code}: ${error.message}',
      child: _surfaces.isEmpty
          ? Text(
              '正在准备界面…',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            )
          : IgnorePointer(
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
    );
  }
}

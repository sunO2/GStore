import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_spacing.dart';

import 'a2ui_surface_shell.dart';

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
    final title = widget.title?.trim();
    return A2uiSurfaceShell(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      title: title == null || title.isEmpty ? '生成式界面' : title,
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

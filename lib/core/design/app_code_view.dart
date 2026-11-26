import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import 'package:gstore/core/design/app_colors.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/editor/app_code_language.dart';
import 'package:gstore/core/editor/app_code_theme.dart';

/// 统一代码视图：只读预览 / 编辑共用。
///
/// - 默认只读；[readOnly] 为 false 时作为编辑器使用。
/// - 双指 pinch 调整字号（不改整体缩放，行号/折叠/光标会一起重排）。
/// - 桌面端 Ctrl/Cmd + 滚轮也可调整字号。
/// - [fontSizeNotifier] 可由页面持有，便于 AppBar 的 +/-/重置按钮联动。
class AppCodeView extends StatefulWidget {
  const AppCodeView({
    super.key,
    this.text = '',
    this.controller,
    this.filePath,
    this.language,
    this.readOnly = true,
    this.showLineNumbers = true,
    this.wordWrap = false,
    this.dark = false,
    this.fontSizeNotifier,
    this.initialFontSize,
    this.minFontSize = 9,
    this.maxFontSize = 32,
    this.maxHighlightBytes = 256 * 1024,
    this.padding = const EdgeInsets.all(AppSpacing.sm),
    this.hint,
    this.verticalScrollController,
    this.onChanged,
    this.onFontSizeChanged,
  });

  /// 只读内容；当传入 [controller] 时由 controller 负责内容。
  final String text;

  /// 可选外部 controller（编辑页持有，便于保存时读取全文）。
  final CodeLineEditingController? controller;

  /// 用于按扩展名推断语言。
  final String? filePath;

  /// 显式语言（优先于 [filePath] 推断）。
  final AppCodeLanguage? language;

  final bool readOnly;
  final bool showLineNumbers;
  final bool wordWrap;

  /// 使用深色代码表面/语法主题（README/AI 消息里的代码块）。
  final bool dark;

  /// 外部字号控制器；不传则组件内部维护。
  final ValueNotifier<double>? fontSizeNotifier;

  /// 内部维护字号时的初始值。
  final double? initialFontSize;

  final double minFontSize;
  final double maxFontSize;

  /// 超过该字节数不做语法高亮（仍正常显示文本）。
  final int maxHighlightBytes;

  final EdgeInsetsGeometry padding;

  /// 空内容占位文案（编辑模式的 hint）。
  final String? hint;

  /// 可选纵向滚动控制器；嵌入 `NestedScrollView` 时传
  /// `PrimaryScrollController.maybeOf(context)`，让代码滚动驱动外层
  /// SliverAppBar 收起。
  final ScrollController? verticalScrollController;

  /// 编辑内容变化回调（参数为当前全文）。
  final ValueChanged<String>? onChanged;

  /// 字号变化回调（pinch / Ctrl+滚轮）。
  final ValueChanged<double>? onFontSizeChanged;

  @override
  State<AppCodeView> createState() => _AppCodeViewState();
}

/// 移动端长按/桌面右键的默认菜单：复制/全选；编辑模式额外提供剪切/粘贴。
class _AppCodeSelectionToolbar implements SelectionToolbarController {
  _AppCodeSelectionToolbar({required this.readOnly});

  final bool readOnly;

  ValueNotifier<bool>? _visibility;

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    _visibility = visibility;
    showMenu<void>(
      context: context,
      position: RelativeRect.fromSize(
        anchors.primaryAnchor & const Size(160, double.infinity),
        MediaQuery.of(context).size,
      ),
      items: <PopupMenuEntry<void>>[
        if (!readOnly)
          PopupMenuItem<void>(
            onTap: () {
              controller.cut();
              _visibility?.value = false;
            },
            child: const Text('剪切'),
          ),
        PopupMenuItem<void>(
          onTap: () {
            controller.copy();
            _visibility?.value = false;
          },
          child: const Text('复制'),
        ),
        if (!readOnly)
          PopupMenuItem<void>(
            onTap: () {
              controller.paste();
              _visibility?.value = false;
            },
            child: const Text('粘贴'),
          ),
        PopupMenuItem<void>(
          onTap: () {
            controller.selectAll();
            _visibility?.value = false;
          },
          child: const Text('全选'),
        ),
      ],
    ).then((_) => visibility.value = false);
  }

  @override
  void hide(BuildContext context) {
    _visibility?.value = false;
  }
}

/// 深色代码表面：复用现有 AppColors 代码编辑器令牌，语法色由深色 ColorScheme 派生。
ColorScheme _darkCodeScheme(ColorScheme base) {
  return ColorScheme.fromSeed(
    seedColor: base.primary,
    brightness: Brightness.dark,
  ).copyWith(
    surface: AppColors.codeEditorBackground,
    onSurface: AppColors.codeEditorText,
    onSurfaceVariant: AppColors.codeEditorText.withValues(alpha: 0.65),
    surfaceContainerHighest: AppColors.codeEditorToolbar,
    outlineVariant: AppColors.codeEditorBorder,
  );
}

class _AppCodeViewState extends State<AppCodeView> {
  CodeLineEditingController? _ownedController;
  late ValueNotifier<double> _fontSize;
  late bool _ownsFontSize;
  ScrollController? _horizontalScrollController;

  final Map<int, Offset> _pointers = {};
  double? _pinchStartDistance;
  double _pinchStartFontSize = 0;

  CodeLineEditingController get _controller =>
      widget.controller ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    _ownedController = widget.controller == null
        ? CodeLineEditingController.fromText(widget.text)
        : null;
    _ownsFontSize = widget.fontSizeNotifier == null;
    _fontSize = widget.fontSizeNotifier ??
        ValueNotifier<double>(_clampFontSize(
          widget.initialFontSize ?? AppTypography.code.fontSize ?? 14,
        ));
  }

  @override
  void didUpdateWidget(AppCodeView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller == null) {
        _ownedController?.dispose();
        _ownedController = null;
      }
      if (widget.controller == null) {
        _ownedController = CodeLineEditingController.fromText(widget.text);
      }
    } else if (widget.controller == null &&
        oldWidget.text != widget.text &&
        _ownedController?.text != widget.text) {
      _ownedController!.text = widget.text;
    }

    if (oldWidget.fontSizeNotifier != widget.fontSizeNotifier) {
      if (_ownsFontSize) _fontSize.dispose();
      _ownsFontSize = widget.fontSizeNotifier == null;
      _fontSize = widget.fontSizeNotifier ??
          ValueNotifier<double>(_clampFontSize(
            widget.initialFontSize ?? AppTypography.code.fontSize ?? 14,
          ));
    }
  }

  @override
  void dispose() {
    _horizontalScrollController?.dispose();
    _ownedController?.dispose();
    if (_ownsFontSize) _fontSize.dispose();
    super.dispose();
  }

  double _clampFontSize(double value) =>
      value.clamp(widget.minFontSize, widget.maxFontSize).toDouble();

  void _setFontSize(double value) {
    final next = _clampFontSize(value);
    if ((next - _fontSize.value).abs() < 0.01) return;
    _fontSize.value = next;
    widget.onFontSizeChanged?.call(next);
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.position;
    if (_pointers.length == 2) {
      final points = _pointers.values.toList(growable: false);
      _pinchStartDistance = (points[0] - points[1]).distance;
      _pinchStartFontSize = _fontSize.value;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.position;

    final start = _pinchStartDistance;
    if (_pointers.length < 2 || start == null || start <= 0) return;

    final points = _pointers.values.toList(growable: false);
    final distance = (points[0] - points[1]).distance;
    _setFontSize(_pinchStartFontSize * distance / start);
  }

  void _onPointerEnd(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) {
      _pinchStartDistance = null;
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      return;
    }
    _setFontSize(_fontSize.value - event.scrollDelta.dy * 0.05);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme =
        widget.dark ? _darkCodeScheme(theme.colorScheme) : theme.colorScheme;
    final effectiveTheme = identical(scheme, theme.colorScheme)
        ? theme
        : theme.copyWith(colorScheme: scheme);
    final language =
        widget.language ?? AppCodeLanguage.forPath(widget.filePath);
    final vertical = widget.verticalScrollController;
    final scrollController = vertical == null
        ? null
        : CodeScrollController(
            verticalScroller: vertical,
            horizontalScroller: _horizontalScrollController ??=
                ScrollController(),
          );

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      onPointerSignal: _onPointerSignal,
      child: ValueListenableBuilder<double>(
        valueListenable: _fontSize,
        builder: (context, fontSize, _) {
          return Theme(
            data: effectiveTheme,
            child: CodeEditor(
              controller: _controller,
              scrollController: scrollController,
              readOnly: widget.readOnly,
              showCursorWhenReadOnly: false,
              wordWrap: widget.wordWrap,
              padding: widget.padding,
              hint: widget.hint,
              clipBehavior: Clip.hardEdge,
              style: CodeEditorStyle(
                fontSize: fontSize,
                fontFamily: AppTypography.code.fontFamily,
                fontHeight: AppTypography.code.height,
                textColor: scheme.onSurface,
                backgroundColor: scheme.surface,
                selectionColor: scheme.primary.withValues(alpha: 0.24),
                cursorColor: scheme.primary,
                cursorLineColor: scheme.primaryContainer,
                highlightColor: scheme.primaryContainer.withValues(alpha: 0.5),
                codeTheme: language == null
                    ? null
                    : CodeHighlightTheme(
                        languages: {
                          language.name: CodeHighlightThemeMode(
                            mode: language.mode,
                            maxSize: widget.maxHighlightBytes,
                            maxLineLength: 16 * 1024,
                          ),
                        },
                        theme: appCodeTheme(scheme),
                      ),
              ),
              indicatorBuilder: widget.showLineNumbers
                  ? (context, editingController, chunkController, notifier) {
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DefaultCodeLineNumber(
                            controller: editingController,
                            notifier: notifier,
                          ),
                          if (language != null)
                            DefaultCodeChunkIndicator(
                              width: 20,
                              controller: chunkController,
                              notifier: notifier,
                            ),
                        ],
                      );
                    }
                  : null,
              toolbarController: _AppCodeSelectionToolbar(
                readOnly: widget.readOnly,
              ),
              onChanged: widget.onChanged == null
                  ? null
                  : (_) => widget.onChanged!(_controller.text),
            ),
          );
        },
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'app_borders.dart';
import 'app_colors.dart';
import 'app_radius.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

/// ============================================================================
/// GStore 统一底部弹层骨架（BottomSheet）
/// ============================================================================
///
/// 这是全应用**唯一**的弹层骨架。所有「确认框 / 提示框 / 选择器 / 表单」都必须
/// 通过本骨架（或 [AppDialogs] 里的语义化封装）呈现，**禁止**再直接使用
/// `showDialog` + `AlertDialog`，也不要手写 `showModalBottomSheet`。
///
/// ## 为什么统一用 BottomSheet（而不是 AlertDialog）
/// - 单手可达：操作按钮固定在屏幕底部拇指区，符合移动端交互习惯；
/// - 风格统一：圆角、拖拽条、标题、按钮全部取自设计令牌（app_radius /
///   app_spacing / app_typography），随主题（浅色/深色/边框风格）自动切换；
/// - 内容自适应：内容过长时自动「限高 + 内部滚动」，不会顶出屏幕、不会溢出。
///
/// ## 布局结构
/// ```
/// ┌────────────────────────────────┐
/// │              ▁▁▁▁               │  ← 拖拽指示条（showHandle）
/// │  [icon]  标题                   │  ← 标题区（固定，不随内容滚动）
/// │         副标题                  │
/// │ ────────────────────────────── │
/// │  内容区（超出限高时内部滚动）   │  ← Flexible + SingleChildScrollView
/// │                                │
/// │ ────────────────────────────── │
/// │                  [取消] [确认]  │  ← 操作区（固定，不随内容滚动）
/// └────────────────────────────────┘
/// ```
///
/// ## 接入方式（推荐从 [AppDialogs] 的语义化方法入手）
/// ```dart
/// // 1) 确认/危险操作框
/// final ok = await AppDialogs.showConfirmSheet(
///   title: '清空日志',
///   message: '确定要清空所有日志吗？',
///   confirmText: '清空',
///   isDangerous: true,
/// );
///
/// // 2) 单按钮提示框
/// await AppDialogs.showAlertSheet(
///   title: '提示',
///   message: '当前没有可用的搜索渠道',
/// );
///
/// // 3) 自定义内容（内容过长会自动内部滚动）
/// await AppDialogs.showContentSheet(
///   title: '配置镜像',
///   content: Column(children: [ ... ]),
///   actions: [ TextButton(onPressed: ..., child: const Text('取消')) ],
/// );
/// ```
///
/// ## 直接使用（需要自定义更多呈现参数时）
/// ```dart
/// final result = await AppSheet.show<String>(
///   context: context,
///   title: '更多',
///   content: Column(children: [ ... ]),
/// );
/// ```
///
/// 只要调用方遵守「标题用 [AppSheetScaffold.title]、操作按钮用
/// [AppSheetScaffold.actions]」，长内容无需任何额外处理即可获得内部滚动。
class AppSheet {
  AppSheet._();

  /// 弹出统一风格的底部弹层，返回关闭时的结果（点击遮罩/下拉关闭返回 null）。
  ///
  /// - [content]：内容区；内容超出 [maxHeightFactor] 限高时自动内部滚动。
  /// - [actions]：底部操作按钮（固定在底部，不随内容滚动）；不传则不显示操作区。
  /// - [scrollable]：内容区是否包裹滚动视图（默认 true）。若内容自带固定高度
  ///   滚动区（如 ListView），可传 false 避免嵌套滚动。
  /// - [maxHeightFactor]：弹层最大高度占屏幕高度比例（默认 0.8）。
  /// - [isDismissible] / [enableDrag]：点击遮罩 / 下拉是否可关闭（默认均可）。
  static Future<T?> show<T>({
    required BuildContext context,
    String? title,
    String? subtitle,
    Widget? icon,
    Color? iconColor,
    Widget? content,
    List<Widget> actions = const <Widget>[],
    bool scrollable = true,
    bool showHandle = true,
    double maxHeightFactor = 0.8,
    bool isDismissible = true,
    bool enableDrag = true,
    bool useRootNavigator = false,
    EdgeInsetsGeometry? contentPadding,
  }) {
    return showCustom<T>(
      context: context,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      useRootNavigator: useRootNavigator,
      builder: (sheetContext) => AppSheetScaffold(
        title: title,
        subtitle: subtitle,
        icon: icon,
        iconColor: iconColor,
        content: content,
        actions: actions,
        scrollable: scrollable,
        showHandle: showHandle,
        maxHeightFactor: maxHeightFactor,
        contentPadding: contentPadding,
      ),
    );
  }

  /// 自定义弹层：由调用方自行返回弹层主体（通常是 [AppSheetScaffold]）。
  ///
  /// 用于「弹层内容需要访问自身 context 才能关闭 / 返回结果」的有状态表单，
  /// 调用方在 [builder] 返回的组件里用 `Navigator.of(context).pop(result)` 关闭。
  ///
  /// 注意：仍走统一的透明背景 + 键盘上推处理，风格与 [show] 一致。
  static Future<T?> showCustom<T>({
    required BuildContext context,
    required WidgetBuilder builder,
    bool isDismissible = true,
    bool enableDrag = true,
    bool useRootNavigator = false,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: isDismissible,
      enableDrag: enableDrag,
      useRootNavigator: useRootNavigator,
      // 键盘弹出时整体上推，输入框不会被遮挡
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
        ),
        child: builder(sheetContext),
      ),
    );
  }
}

/// 统一弹层骨架：拖拽条 + 标题 + （限高可滚动）内容 + 固定操作区。
///
/// 通常不需要直接实例化，用 [AppSheet.show] / [AppDialogs] 即可；
/// 需要在页面内嵌（例如作为某个自定义 route 的内容）时才直接使用。
class AppSheetScaffold extends StatelessWidget {
  const AppSheetScaffold({
    super.key,
    this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.content,
    this.actions = const <Widget>[],
    this.scrollable = true,
    this.showHandle = true,
    this.maxHeightFactor = 0.8,
    this.contentPadding,
  });

  /// 标题（固定区，不随内容滚动）
  final String? title;

  /// 副标题（可选，位于标题下方）
  final String? subtitle;

  /// 标题左侧图标（可选）
  final Widget? icon;

  /// 图标颜色（默认主题 primary）
  final Color? iconColor;

  /// 内容区；超限时内部滚动
  final Widget? content;

  /// 底部操作按钮区（固定，不随内容滚动）
  final List<Widget> actions;

  /// 内容区是否包裹滚动视图（内容自带滚动区时传 false）
  final bool scrollable;

  /// 是否显示顶部拖拽指示条
  final bool showHandle;

  /// 弹层最大高度占屏幕高度比例
  final double maxHeightFactor;

  /// 内容区额外内边距
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = MediaQuery.of(context);
    // 限高：内容再长也不顶出屏幕，超出部分由内容区内部滚动消化
    final maxHeight = media.size.height * maxHeightFactor;

    final hasHeader = title != null || subtitle != null || icon != null;

    Widget? contentWidget;
    if (content != null) {
      final padded = contentPadding == null
          ? content!
          : Padding(padding: contentPadding!, child: content!);
      contentWidget = scrollable ? SingleChildScrollView(child: padded) : padded;
    }

    return Container(
      decoration: BoxDecoration(
        color: scheme.dialogSurface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.xxl),
        ),
        border: Border(
          top: AppBorders.sideOf(context, color: scheme.borderLight),
        ),
      ),
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部拖拽指示条（视觉提示可下拉关闭）
          if (showHandle)
            Center(
              child: Container(
                margin: AppSpacing.onlyVerticalMD,
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: AppRadius.allXS,
                ),
              ),
            ),

          // 标题区（固定）
          if (hasHeader)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl,
                AppSpacing.lg,
                AppSpacing.xl,
                AppSpacing.md,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (icon != null) ...[
                    IconTheme(
                      data: IconThemeData(
                        color: iconColor ?? scheme.primary,
                        size: AppTypography.iconXL,
                      ),
                      child: icon!,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  if (title != null || subtitle != null)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (title != null)
                            Text(
                              title!,
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: AppTypography.weightSemiBold,
                              ),
                            ),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(
                                top: AppSpacing.xs,
                              ),
                              child: Text(
                                subtitle!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

          // 内容区：Flexible 让内容超限时收缩并由 SingleChildScrollView 内部滚动
          if (contentWidget != null) Flexible(child: contentWidget),

          // 操作区（固定，不随内容滚动）
          if (actions.isNotEmpty)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.md,
                  AppSpacing.xl,
                  AppSpacing.lg,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: _withGaps(actions),
                ),
              ),
            )
          else
            SizedBox(height: AppSpacing.lg + media.padding.bottom),
        ],
      ),
    );
  }

  /// 操作按钮之间插入统一间距
  static List<Widget> _withGaps(List<Widget> items) {
    final spaced = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) spaced.add(const SizedBox(width: AppSpacing.sm));
      spaced.add(items[i]);
    }
    return spaced;
  }
}

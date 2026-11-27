// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';

/// A2UI 表面的统一视觉层。
///
/// 工具式（renderA2ui）与内联（对话正文）两条路径都通过 [A2uiSurfaceShell]
/// 渲染，保证标题、边框、圆角、状态行完全一致；[A2uiSurfaceTheme] 再把
/// A2UI 基础组件（Card / Button / Divider / Tab / CheckBox / Slider…）的
/// 默认样式收编到 GStore 设计系统，避免"卡片里套另一套 Material 皮肤"。
class A2uiSurfaceShell extends StatelessWidget {
  const A2uiSurfaceShell({
    super.key,
    required this.child,
    this.title = '生成式界面',
    this.enabled = true,
    this.lastActionName,
    this.errorText,
    this.margin,
  });

  /// 表面内容（surface、错误提示或占位）。
  final Widget child;

  /// 卡片标题；默认「生成式界面」。
  final String title;

  /// 是否可交互；生成中/已提交后为 false。
  final bool enabled;

  /// 最近一次已提交的 action 名；非空时状态行显示"已提交"。
  final String? lastActionName;

  /// 解析/渲染错误文案；会显示在内容区。
  final String? errorText;

  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final submitted = lastActionName != null;
    final status = errorText != null
        ? '界面渲染失败'
        : submitted
            ? '已提交：$lastActionName，等待 AI 响应'
            : enabled
                ? '界面操作会作为消息回传给 AI'
                : 'AI 正在回复，暂不可操作';

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(AppRadius.radiusCard),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  TablerIcons.layout_grid,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.circle),
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
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: errorText != null
                ? Text(
                    errorText!,
                    style: textTheme.bodySmall?.copyWith(color: scheme.error),
                  )
                : A2uiSurfaceTheme(child: child),
          ),
          Divider(
            height: 1,
            thickness: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  submitted ? TablerIcons.circle_check : TablerIcons.pointer,
                  size: 14,
                  color: submitted ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    status,
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 把 A2UI 基础组件的默认样式收编到 GStore 设计系统。
///
/// 只覆盖"看起来不一致"的部件：卡片改为无边框浅色块（外层 shell 已有边框与
/// 圆角，避免双层边框）、按钮统一圆角/字号、分隔线/标签页/勾选/滑杆用主题
/// 色，输入框沿用全局 InputDecoration。
class A2uiSurfaceTheme extends StatelessWidget {
  const A2uiSurfaceTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final scheme = base.colorScheme;
    final textTheme = base.textTheme;
    final radius = BorderRadius.circular(AppRadius.md);
    final buttonShape = RoundedRectangleBorder(borderRadius: radius);
    const buttonPadding =
        EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm);

    return Theme(
      data: base.copyWith(
        // A2UI Card 只是分组容器：用浅色块而不是第二层边框。
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            elevation: 0,
            padding: buttonPadding,
            shape: buttonShape,
            textStyle: textTheme.labelLarge,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            elevation: 0,
            padding: buttonPadding,
            shape: buttonShape,
            textStyle: textTheme.labelLarge,
            side: BorderSide(color: scheme.outline),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            padding: buttonPadding,
            shape: buttonShape,
            textStyle: textTheme.labelLarge,
          ),
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outlineVariant,
          thickness: 1,
          space: AppSpacing.md,
        ),
        tabBarTheme: TabBarThemeData(
          labelColor: scheme.primary,
          unselectedLabelColor: scheme.onSurfaceVariant,
          indicatorColor: scheme.primary,
          indicatorSize: TabBarIndicatorSize.label,
          dividerColor: scheme.outlineVariant.withValues(alpha: 0.4),
          labelStyle: textTheme.labelLarge,
          unselectedLabelStyle: textTheme.labelLarge,
        ),
        checkboxTheme: CheckboxThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
          side: BorderSide(color: scheme.outline, width: 1.4),
        ),
        sliderTheme: base.sliderTheme.copyWith(
          activeTrackColor: scheme.primary,
          inactiveTrackColor: scheme.outlineVariant,
          thumbColor: scheme.primary,
          overlayColor: scheme.primary.withValues(alpha: 0.12),
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
        ),
      ),
      child: child,
    );
  }
}

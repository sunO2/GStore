import 'dart:io';
import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

/// Reusable UI components that follow the app design system
///
/// This library provides pre-built components that ensure consistency
/// across the application while reducing code duplication.

import 'app_borders.dart';
import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_radius.dart';
import 'app_shadows.dart';
import 'app_typography.dart';
import 'app_animations.dart';
import 'app_dialogs.dart';
import 'app_sheet.dart';

// ========== AppCard ==========
/// Unified card component with consistent styling
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.backgroundColor,
    this.elevation,
    this.borderRadius,
    this.onTap,
    this.onLongPress,
    this.border,
    this.shadowColor,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? backgroundColor;
  final double? elevation;
  final BorderRadius? borderRadius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BoxBorder? border;
  final Color? shadowColor;

  @override
  Widget build(BuildContext context) {
    // 从主题中获取卡片样式
    final theme = Theme.of(context);
    final cardTheme = theme.cardTheme;

    // 确定形状：优先使用自定义边框，然后是自定义圆角，最后是主题形状
    OutlinedBorder? effectiveShape;
    if (border != null) {
      // 如果指定了边框，创建新的形状
      effectiveShape = RoundedRectangleBorder(
        borderRadius: borderRadius ?? AppRadius.allLG,
        side: border is BorderSide
            ? border as BorderSide
            : AppBorders.sideOf(context),
      );
    } else if (borderRadius != null) {
      // 如果只指定了圆角，保持主题的边框样式
      if (cardTheme.shape is RoundedRectangleBorder) {
        final themeShape = cardTheme.shape as RoundedRectangleBorder;
        effectiveShape = RoundedRectangleBorder(
          borderRadius: borderRadius!,
          side: themeShape.side,
        );
      } else {
        effectiveShape = RoundedRectangleBorder(
          borderRadius: borderRadius!,
        );
      }
    } else if (cardTheme.shape is OutlinedBorder) {
      // 如果主题形状是 OutlinedBorder，使用它
      effectiveShape = cardTheme.shape as OutlinedBorder;
    } else {
      // 否则使用默认形状
      effectiveShape = null;
    }

    // 使用主题中的 Card widget，它会自动应用主题设置
    final card = Card(
      margin: margin,
      elevation: elevation ?? cardTheme.elevation ?? 0,
      color: backgroundColor ?? cardTheme.color,
      shape: effectiveShape,
      shadowColor: shadowColor,
      child: Padding(
        padding: padding ?? AppSpacing.cardPadding,
        child: child,
      ),
    );

    if (onTap != null || onLongPress != null) {
      return InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: card,
      );
    }

    return card;
  }
}

// ========== AppButton ==========
/// Unified button component with consistent styling
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.onLongPress,
    this.style = AppButtonStyle.primary,
    this.size = AppButtonSize.medium,
    this.icon,
    this.iconPosition = AppButtonIconPosition.left,
    this.isFullWidth = false,
    this.isLoading = false,
    this.isDisabled = false,
  });

  final String text;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;
  final AppButtonStyle style;
  final AppButtonSize size;
  final IconData? icon;
  final AppButtonIconPosition iconPosition;
  final bool isFullWidth;
  final bool isLoading;
  final bool isDisabled;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null && !isDisabled && !isLoading;

    Widget buildChild() {
      if (isLoading) {
        return AppLoading(
          size: AppLoadingSize.small,
          color: _getForegroundColor(),
        );
      }

      if (icon != null) {
        final iconWidget = Icon(icon, size: _getButtonIconSize());
        final textWidget = Text(
          text,
          style: _getTextStyle(),
        );

        return Row(
          mainAxisSize: isFullWidth ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: iconPosition == AppButtonIconPosition.left
              ? [iconWidget, const SizedBox(width: AppSpacing.sm), textWidget]
              : [textWidget, const SizedBox(width: AppSpacing.sm), iconWidget],
        );
      }

      return Text(
        text,
        style: _getTextStyle(),
        textAlign: TextAlign.center,
      );
    }

    return SizedBox(
      width: isFullWidth ? double.infinity : null,
      child: _buildButton(context, isEnabled, buildChild()),
    );
  }

  Widget _buildButton(BuildContext context, bool isEnabled, Widget child) {
    final padding = _getButtonPadding();

    switch (style) {
      case AppButtonStyle.primary:
        return ElevatedButton(
          onPressed: isEnabled ? onPressed : null,
          onLongPress: isEnabled ? onLongPress : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: _getBackgroundColor(),
            foregroundColor: _getForegroundColor(),
            disabledBackgroundColor: AppColors.grey300,
            disabledForegroundColor: AppColors.grey600,
            padding: padding,
            shape: RoundedRectangleBorder(
              borderRadius: _getBorderRadius(),
            ),
            elevation: 0,
          ),
          child: child,
        );

      case AppButtonStyle.secondary:
        return OutlinedButton(
          onPressed: isEnabled ? onPressed : null,
          onLongPress: isEnabled ? onLongPress : null,
          style: OutlinedButton.styleFrom(
            foregroundColor: _getForegroundColor(),
            disabledForegroundColor: AppColors.grey600,
            padding: padding,
            side: BorderSide(color: _getBorderColor()),
            shape: RoundedRectangleBorder(
              borderRadius: _getBorderRadius(),
            ),
          ),
          child: child,
        );

      case AppButtonStyle.text:
        return TextButton(
          onPressed: isEnabled ? onPressed : null,
          onLongPress: isEnabled ? onLongPress : null,
          style: TextButton.styleFrom(
            foregroundColor: _getForegroundColor(),
            disabledForegroundColor: AppColors.grey600,
            padding: padding,
            shape: RoundedRectangleBorder(
              borderRadius: _getBorderRadius(),
            ),
          ),
          child: child,
        );

      case AppButtonStyle.danger:
        return ElevatedButton(
          onPressed: isEnabled ? onPressed : null,
          onLongPress: isEnabled ? onLongPress : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.error,
            foregroundColor: AppColors.white,
            disabledBackgroundColor: AppColors.grey300,
            disabledForegroundColor: AppColors.grey600,
            padding: padding,
            shape: RoundedRectangleBorder(
              borderRadius: _getBorderRadius(),
            ),
            elevation: 0,
          ),
          child: child,
        );
    }
  }

  Color _getBackgroundColor() {
    switch (style) {
      case AppButtonStyle.primary:
        return AppColors.primary;
      case AppButtonStyle.danger:
        return AppColors.error;
      default:
        return AppColors.transparent;
    }
  }

  Color _getForegroundColor() {
    switch (style) {
      case AppButtonStyle.primary:
      case AppButtonStyle.danger:
        return AppColors.white;
      case AppButtonStyle.secondary:
      case AppButtonStyle.text:
        return AppColors.primary;
    }
  }

  Color _getBorderColor() {
    return AppColors.primary;
  }

  BorderRadius _getBorderRadius() {
    return AppRadius.allSM;
  }

  EdgeInsets _getButtonPadding() {
    switch (size) {
      case AppButtonSize.small:
        return AppSpacing.horizontalMD_verticalSM;
      case AppButtonSize.medium:
        return AppSpacing.buttonPadding;
      case AppButtonSize.large:
        return AppSpacing.horizontalXXL_verticalMD;
    }
  }

  TextStyle _getTextStyle() {
    switch (size) {
      case AppButtonSize.small:
        return AppTypography.labelMedium;
      case AppButtonSize.medium:
        return AppTypography.labelLarge;
      case AppButtonSize.large:
        return AppTypography.titleMedium.copyWith(
          fontSize: AppTypography.sizeMD,
        );
    }
  }

  double _getButtonIconSize() {
    switch (size) {
      case AppButtonSize.small:
        return AppTypography.iconSM;
      case AppButtonSize.medium:
        return AppTypography.iconMD;
      case AppButtonSize.large:
        return AppTypography.iconLG;
    }
  }
}

enum AppButtonStyle { primary, secondary, text, danger }
enum AppButtonSize { small, medium, large }
enum AppButtonIconPosition { left, right }

// ========== AppTextField ==========
/// Unified text field component with consistent styling
class AppTextField extends StatefulWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.errorText,
    this.helperText,
    this.prefixIcon,
    this.suffixIcon,
    this.onSuffixIconPressed,
    this.obscureText = false,
    this.enabled = true,
    this.readOnly = false,
    this.maxLines = 1,
    this.minLines,
    this.maxLength,
    this.keyboardType,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.textCapitalization = TextCapitalization.none,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final String? errorText;
  final String? helperText;
  final IconData? prefixIcon;
  final IconData? suffixIcon;
  final VoidCallback? onSuffixIconPressed;
  final bool obscureText;
  final bool enabled;
  final bool readOnly;
  final int maxLines;
  final int? minLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final TextCapitalization textCapitalization;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _obscureText;

  @override
  void initState() {
    super.initState();
    _obscureText = widget.obscureText;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TextField(
      controller: widget.controller,
      obscureText: _obscureText,
      enabled: widget.enabled,
      readOnly: widget.readOnly,
      maxLines: widget.obscureText ? 1 : widget.maxLines,
      minLines: widget.minLines,
      maxLength: widget.maxLength,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      textCapitalization: widget.textCapitalization,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      onTap: widget.onTap,
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        errorText: widget.errorText,
        helperText: widget.helperText,
        prefixIcon: widget.prefixIcon != null ? Icon(widget.prefixIcon) : null,
        suffixIcon: _buildSuffixIcon(),
        hintStyle: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        border: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: AppBorders.sideOf(context, color: scheme.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: AppBorders.sideOf(context, color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: AppBorders.sideOf(context, color: scheme.outlineVariant),
        ),
        filled: true,
        fillColor: widget.enabled
            ? scheme.surfaceContainerHighest
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        contentPadding: AppSpacing.inputFieldPadding,
        counterText: '',
      ),
    );
  }

  Widget? _buildSuffixIcon() {
    if (widget.obscureText) {
      return IconButton(
        icon: Icon(_obscureText ? TablerIcons.eye_off : TablerIcons.eye),
        onPressed: () {
          setState(() {
            _obscureText = !_obscureText;
          });
        },
      );
    }

    if (widget.suffixIcon != null) {
      return IconButton(
        icon: Icon(widget.suffixIcon),
        onPressed: widget.onSuffixIconPressed,
      );
    }

    return null;
  }
}

// ========== EmptyState ==========
/// Unified empty state component
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon,
    this.actionLabel,
    this.onActionPressed,
  });

  final String message;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onActionPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: AppTypography.iconXXXL,
                color: AppColors.grey400,
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            Text(
              message,
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onActionPressed != null) ...[
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                text: actionLabel!,
                onPressed: onActionPressed,
                style: AppButtonStyle.secondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ========== ErrorState ==========
/// Unified error state component
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.retryLabel,
    this.onRetryPressed,
  });

  final String message;
  final String? retryLabel;
  final VoidCallback? onRetryPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              TablerIcons.alert_circle,
              size: AppTypography.iconXXXL,
              color: AppColors.error,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              message,
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            if (retryLabel != null && onRetryPressed != null) ...[
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                text: retryLabel!,
                onPressed: onRetryPressed,
                style: AppButtonStyle.secondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ========== InfoCard ==========
/// Information card with icon
class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.message,
    this.type = InfoCardType.info,
    this.onTap,
  });

  final String message;
  final InfoCardType type;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final config = _getConfig();

    return AppCard(
      padding: AppSpacing.horizontalMD_verticalSM,
      backgroundColor: config.backgroundColor,
      border: Border.all(color: config.borderColor),
      borderRadius: AppRadius.allMD,
      onTap: onTap,
      child: Row(
        children: [
          Icon(
            config.icon,
            color: config.iconColor,
            size: AppTypography.iconMD,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: AppTypography.bodySmall.copyWith(
                color: config.textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  _InfoCardConfig _getConfig() {
    switch (type) {
      case InfoCardType.info:
        return _InfoCardConfig(
          icon: TablerIcons.info_circle,
          iconColor: AppColors.info,
          backgroundColor: AppColors.infoLight,
          borderColor: AppColors.info,
          textColor: AppColors.infoDark,
        );
      case InfoCardType.success:
        return _InfoCardConfig(
          icon: TablerIcons.circle_check,
          iconColor: AppColors.success,
          backgroundColor: AppColors.successLight,
          borderColor: AppColors.success,
          textColor: AppColors.successDark,
        );
      case InfoCardType.warning:
        return _InfoCardConfig(
          icon: TablerIcons.alert_triangle,
          iconColor: AppColors.warning,
          backgroundColor: AppColors.warningLight,
          borderColor: AppColors.warning,
          textColor: AppColors.warningDark,
        );
      case InfoCardType.error:
        return _InfoCardConfig(
          icon: TablerIcons.alert_circle,
          iconColor: AppColors.error,
          backgroundColor: AppColors.errorLight,
          borderColor: AppColors.error,
          textColor: AppColors.errorDark,
        );
    }
  }
}

enum InfoCardType { info, success, warning, error }

class _InfoCardConfig {
  final IconData icon;
  final Color iconColor;
  final Color backgroundColor;
  final Color borderColor;
  final Color textColor;

  _InfoCardConfig({
    required this.icon,
    required this.iconColor,
    required this.backgroundColor,
    required this.borderColor,
    required this.textColor,
  });
}

// ========== AppSegmentedButton ==========

/// 统一的分段式按钮组件
///
/// 遵循 GStore 设计规范的分段式按钮，提供一致的视觉效果
///
/// 示例：
/// ```dart
/// AppSegmentedButton<AppThemeMode>(
///   value: themeMode,
///   segments: [
///     AppSegment(value: AppThemeMode.system, label: '系统', icon: TablerIcons.brightness_auto),
///     AppSegment(value: AppThemeMode.light, label: '浅色', icon: TablerIcons.sun),
///     AppSegment(value: AppThemeMode.dark, label: '深色', icon: TablerIcons.moon),
///   ],
///   onChanged: (AppThemeMode mode) => setThemeMode(mode),
/// )
/// ```
class AppSegmentedButton<T> extends StatelessWidget {
  const AppSegmentedButton({
    super.key,
    required this.value,
    required this.segments,
    required this.onChanged,
    this.enabled = true,
    this.density,
  });

  /// 当前选中的值
  final T value;

  /// 分段选项列表
  final List<AppSegment<T>> segments;

  /// 选择变化回调
  final ValueChanged<T> onChanged;

  /// 是否启用
  final bool enabled;

  /// 紧凑度（如 AppBar 内使用 [VisualDensity.compact]；null = 保持默认外观）
  final VisualDensity? density;

  /// 标题同行药丸的**统一中等尺寸**令牌（路由模式 / 应用分流共用）。
  ///
  /// 取 [VisualDensity] 的中等档（-2，介于紧凑下限 -4 与 Material 默认 0 之间），
  /// 使药丸与标题同排的同时保持清晰可点的触控尺寸；
  /// 两处调用点必须引用本常量，避免各自散落魔法密度值。
  static const VisualDensity mediumDensity = VisualDensity(
    horizontal: -2,
    vertical: -2,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final themeSide = AppBorders.sideOf(context);

    return SegmentedButton<T>(
      segments: segments
          .map(
            (segment) => ButtonSegment<T>(
              value: segment.value,
              label: Text(segment.label, key: segment.key),
              icon: segment.icon != null
                  ? Icon(segment.icon, size: AppTypography.iconSM)
                  : null,
            ),
          )
          .toList(),
      selected: {value},
      onSelectionChanged: enabled
          ? (Set<T> newSelection) {
              if (newSelection.isNotEmpty) {
                onChanged(newSelection.first);
              }
            }
          : null,
      style: ButtonStyle(
        // 紧凑度（SegmentedButton 仅通过 style 支持 visualDensity）：
        // null = 不覆盖，保留默认密度（既有调用点外观零变化）
        visualDensity: density,
        // 背景色
        backgroundColor: WidgetStateProperty.resolveWith<Color?>(
          (states) {
            if (!enabled) {
              return colorScheme.surfaceContainerHighest.withOpacity(0.3);
            }
            if (states.contains(WidgetState.selected)) {
              return colorScheme.primaryContainer;
            }
            return Colors.transparent;
          },
        ),
        // 前景色（文字/图标）
        foregroundColor: WidgetStateProperty.resolveWith<Color?>(
          (states) {
            if (!enabled) {
              return colorScheme.onSurface.withOpacity(0.38);
            }
            if (states.contains(WidgetState.selected)) {
              return colorScheme.onPrimaryContainer;
            }
            return colorScheme.onSurface;
          },
        ),
        // 边框（宽度/透明度随主题 borderStyle；无边框档保留 0.5 最小边框，
        // 分段可识别性，颜色回退 outlineVariant 随主题）
        side: WidgetStateProperty.all<BorderSide>(
          BorderSide(
            color: themeSide.style == BorderStyle.none
                ? colorScheme.outlineVariant
                : themeSide.color,
            width: themeSide.width < 0.5 ? 0.5 : themeSide.width,
          ),
        ),
      ),
    );
  }
}

/// 分段选项数据类
///
/// 用于定义分段式按钮的每个选项
class AppSegment<T> {
  const AppSegment({
    required this.value,
    required this.label,
    this.icon,
    this.key,
  });

  /// 选项的值
  final T value;

  /// 选项的标签文本
  final String label;

  /// 选项的图标（可选）
  final IconData? icon;

  /// 选项标签的挂载 key（可选，用于测试 / 语义定位，不参与分段逻辑）。
  final Key? key;
}

// ========== AppTabBar ==========

/// 统一的可滚动标签栏
///
/// 与 [AppSegmentedButton] 的关键区别：本组件基于 Material [TabBar] 且
/// `isScrollable: true`，每个标签宽度由自身文本内容决定，选中较宽的标签
/// **不会**强制拉伸其余标签（消除分段按钮等宽回流问题）。
///
/// - 自行持有 [TabController]，无需外层 `DefaultTabController`。
/// - 仅用户点按标签时触发 [onChanged]；外部 [value] 的程序化变更只同步选中态，
///   不触发回调（供发送后自动切换等场景使用）。
/// - [AppSegment.key] 透传给渲染出的 [Tab]，使 `find.byKey` / `getSize` 可用。
///
/// 示例：
/// ```dart
/// AppTabBar<MyTab>(
///   value: tab,
///   segments: const [
///     AppSegment(value: MyTab.a, label: 'A', key: Key('tab-a')),
///     AppSegment(value: MyTab.b, label: 'B', key: Key('tab-b')),
///   ],
///   onChanged: (t) => setState(() => tab = t),
/// )
/// ```
class AppTabBar<T> extends StatefulWidget {
  const AppTabBar({
    super.key,
    required this.value,
    required this.segments,
    required this.onChanged,
  });

  /// 当前选中值
  final T value;

  /// 标签列表（顺序即渲染顺序）
  final List<AppSegment<T>> segments;

  /// 用户点按标签时的回调
  final ValueChanged<T> onChanged;

  @override
  State<AppTabBar<T>> createState() => _AppTabBarState<T>();
}

class _AppTabBarState<T> extends State<AppTabBar<T>>
    with SingleTickerProviderStateMixin {
  late TabController _controller;

  int _indexOf(T value) {
    final index = widget.segments.indexWhere((segment) => segment.value == value);
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _controller = TabController(
      length: widget.segments.length,
      initialIndex: _indexOf(widget.value),
      vsync: this,
    );
  }

  @override
  void didUpdateWidget(covariant AppTabBar<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.segments.length != oldWidget.segments.length) {
      _controller.dispose();
      _controller = TabController(
        length: widget.segments.length,
        initialIndex: _indexOf(widget.value),
        vsync: this,
      );
      return;
    }
    // 程序化 value 变更：仅同步选中索引，绝不触发 onChanged。
    if (widget.value != oldWidget.value) {
      final target = _indexOf(widget.value);
      if (target != _controller.index) {
        _controller.index = target;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return TabBar(
      controller: _controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      indicatorColor: colorScheme.primary,
      labelColor: colorScheme.primary,
      unselectedLabelColor: colorScheme.onSurfaceVariant,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: colorScheme.outlineVariant,
      onTap: (index) => widget.onChanged(widget.segments[index].value),
      tabs: [
        for (final segment in widget.segments)
          Tab(key: segment.key, text: segment.label),
      ],
    );
  }
}

// ========== AppPillToggle ==========

/// 小型内容尺寸的两态药丸切换
///
/// 用于响应视图「格式化 / 原始」这类紧凑二元切换：
/// - 宽度随内容（无 `Expanded`、不强制等宽），切换选中不会改变任何宽度；
/// - 选中态使用 `primaryContainer` / `onPrimaryContainer`；
/// - 不注入勾选图标（区别于 Material `SegmentedButton`）。
class AppPillToggle<T> extends StatelessWidget {
  const AppPillToggle({
    super.key,
    required this.value,
    required this.segments,
    required this.onChanged,
    this.enabled = true,
  });

  /// 当前选中值
  final T value;

  /// 选项列表
  final List<AppSegment<T>> segments;

  /// 选择变化回调
  final ValueChanged<T> onChanged;

  /// 是否启用
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final segment in segments) _buildSegment(context, segment),
      ],
    );
  }

  Widget _buildSegment(BuildContext context, AppSegment<T> segment) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = segment.value == value;

    return InkWell(
      key: segment.key,
      borderRadius: AppRadius.allCircle,
      onTap: enabled ? () => onChanged(segment.value) : null,
      child: Container(
        padding: AppSpacing.horizontalSM_verticalXS,
        decoration: BoxDecoration(
          color: selected ? colorScheme.primaryContainer : null,
          borderRadius: AppRadius.allCircle,
        ),
        child: Text(
          segment.label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: !enabled
                ? colorScheme.onSurface.withValues(alpha: 0.38)
                : selected
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

// ========== AppLoading ==========

/// 统一的莫比乌斯环 Loading 组件
///
/// 提供两种尺寸：
/// - [AppLoadingSize.small]: 组件内 loading（小尺寸，如按钮内）
/// - [AppLoadingSize.medium]: 页面内 loading（中等尺寸，如列表加载）
/// - [AppLoadingSize.large]: 全屏 loading（大尺寸，如页面加载）
///
/// 示例：
/// ```dart
/// // 组件内 loading
/// AppLoading(size: AppLoadingSize.small)
///
/// // 页面 loading
/// AppLoading(size: AppLoadingSize.medium)
///
/// // 全屏 loading
/// AppLoading(size: AppLoadingSize.large)
/// ```
class AppLoading extends StatefulWidget {
  const AppLoading({
    super.key,
    this.size = AppLoadingSize.medium,
    this.color,
  });

  /// Loading 尺寸
  final AppLoadingSize size;

  /// Loading 颜色（默认使用主题色）
  final Color? color;

  @override
  State<AppLoading> createState() => _AppLoadingState();
}

class _AppLoadingState extends State<AppLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _completedCycles = 0.0; // 已完成的循环次数
  double _lastValue = 0.0; // 上一次的值

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000), // 3秒一圈
    );

    _controller.addListener(() {
      final currentValue = _controller.value;
      // value 递减 = 完成一圈：立即累加（无需 setState——
      // AnimatedBuilder 已监听 _controller，同帧重建读到新值，
      // progress 严格连续，消除弧起点回跳/水平位置亮线）
      if (currentValue < _lastValue) {
        _completedCycles += 1.0;
      }
      _lastValue = currentValue;
    });

    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = _getSize();
    final strokeWidth = _getStrokeWidth();
    final defaultColor = Theme.of(context).colorScheme.primary;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // 使用累积的总进度 = 已完成的循环数 + 当前周期值
        final progress = _completedCycles + _controller.value;
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            size: Size(size, size),
            painter: _ElegantRingPainter(
              color: widget.color ?? defaultColor,
              strokeWidth: strokeWidth,
              progress: progress,
            ),
          ),
        );
      },
    );
  }

  double _getSize() {
    switch (widget.size) {
      case AppLoadingSize.small:
        return 24;
      case AppLoadingSize.medium:
        return 48;
      case AppLoadingSize.large:
        return 64;
    }
  }

  double _getStrokeWidth() {
    switch (widget.size) {
      case AppLoadingSize.small:
        return 2;
      case AppLoadingSize.medium:
        return 3;
      case AppLoadingSize.large:
        return 4;
    }
  }
}

/// Loading 尺寸枚举
enum AppLoadingSize { small, medium, large }

/// 优雅的圆环旋转绘制器
///
/// 绘制多段弧线以不同速度旋转，类似 iOS 风格的加载动画
/// 支持动态呼吸颜色效果
class _ElegantRingPainter extends CustomPainter {
  _ElegantRingPainter({
    required this.color,
    required this.strokeWidth,
    required this.progress,
  });

  final Color color;
  final double strokeWidth;
  final double progress;

  /// 计算呼吸颜色
  ///
  /// 基于进度值在主色和辅助色之间平滑过渡
  Color _computeBreathingColor(double baseProgress, double alpha) {
    // 使用多个正弦波叠加创建更自然的呼吸效果
    final breathe1 = math.sin(baseProgress * math.pi * 2); // 主呼吸周期
    final breathe2 = math.sin(baseProgress * math.pi * 3 + math.pi / 4); // 次呼吸周期
    final breathe3 = math.sin(baseProgress * math.pi * 5 + math.pi / 2); // 快速变化

    // 混合呼吸值，创造随机感
    final breathe = (breathe1 * 0.5 + breathe2 * 0.3 + breathe3 * 0.2);

    // 色相偏移（创造彩虹般的渐变）- 增加范围让效果更明显
    final hueShift = breathe * 50; // ±50度的色相偏移

    // 亮度变化 - 增加范围
    final brightnessShift = breathe * 0.2; // ±20%的亮度变化

    // 饱和度变化 - 增加色彩鲜艳度
    final saturationShift = breathe * 0.15; // ±15%的饱和度变化

    // 将 HSL 转换回 Color
    final hsl = HSLColor.fromColor(color);
    final newHsl = hsl
        .withHue((hsl.hue + hueShift) % 360) // 使用模运算确保在0-360范围内循环
        .withLightness((hsl.lightness + brightnessShift).clamp(0.2, 0.9))
        .withSaturation((hsl.saturation + saturationShift).clamp(0.3, 1.0));

    return newHsl.withAlpha(alpha).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // 主旋转弧线（较长，旋转速度正常）
    final mainArcAngle = progress * 2 * math.pi;
    final mainArcStart = mainArcAngle;
    final mainArcSweep = math.pi * 1.5; // 270度

    final mainRect = Rect.fromCircle(center: center, radius: radius);

    // 呼吸基色
    final breatheColor = _computeBreathingColor(progress, 1.0);
    final glowColor = breatheColor.withAlpha(90);

    // 光晕：弧线下的柔和辉光（模糊层）
    // 固定全圆无缝色环：startAngle 固定 0、endAngle 固定 2π，首尾同色无缝衔接，
    // 避免 clamp 在"弧尾跨画布 0°"时 t 突变到最亮色造成 3 点钟横向割裂线
    final glowPaint = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi,
        colors: [
          glowColor,
          glowColor.withAlpha(20),
          glowColor.withAlpha(0),
          glowColor,
        ],
        stops: const [0.0, 0.4, 0.8, 1.0],
      ).createShader(mainRect)
      ..strokeWidth = strokeWidth * 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, strokeWidth);

    canvas.drawArc(mainRect, mainArcStart, mainArcSweep, false, glowPaint);

    // 主弧线：固定全圆无缝色环（亮→暗→亮），弧扫过固定色环实现流光拖尾，
    // 无 clamp 边界跳变（第一圈 startAngle<2π 时的 3 点钟割裂线已消除）
    final mainPaint = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi,
        colors: [
          breatheColor,
          breatheColor.withAlpha(200),
          breatheColor.withAlpha(20),
          breatheColor,
        ],
        stops: const [0.0, 0.3, 0.7, 1.0], // 亮→暗→亮 无缝环
      ).createShader(mainRect)
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(mainRect, mainArcStart, mainArcSweep, false, mainPaint);

    // 次要弧线（较短，反向旋转）
    final secondaryAngle = -mainArcAngle * 1.5;
    final secondaryStart = secondaryAngle;
    final secondarySweep = math.pi * 0.8; // 144度
    final secondaryRadius = radius * 0.75;

    // 使用连续的弧度值计算颜色，避免跳跃
    final continuousSecondaryCycle = secondaryAngle.abs() / (2 * math.pi);
    final secondaryColor = _computeBreathingColor(continuousSecondaryCycle, 0.7);

    final secondaryRect =
        Rect.fromCircle(center: center, radius: secondaryRadius);
    final secondaryPaint = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi, // 固定全圆无缝色环，避免 clamp 跳变（弧扫过固定色环）
        colors: [
          secondaryColor,
          secondaryColor.withAlpha(40),
          secondaryColor,
        ],
        stops: const [0.0, 0.5, 1.0], // 亮→暗→亮 无缝环
      ).createShader(secondaryRect)
      ..strokeWidth = strokeWidth * 0.75
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
        secondaryRect, secondaryStart, secondarySweep, false, secondaryPaint);

    // 小弧线（最小，正向旋转）
    final smallAngle = mainArcAngle * 2.0;
    final smallStart = smallAngle;
    final smallSweep = math.pi * 0.5; // 90度
    final smallRadius = radius * 0.5;

    // 使用连续的弧度值计算颜色，避免跳跃
    final continuousSmallCycle = smallAngle.abs() / (2 * math.pi);
    final smallColor = _computeBreathingColor(continuousSmallCycle, 0.4);

    final smallRect = Rect.fromCircle(center: center, radius: smallRadius);
    final smallPaint = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi, // 固定全圆无缝色环，避免 clamp 跳变（弧扫过固定色环）
        colors: [
          smallColor,
          smallColor.withAlpha(30),
          smallColor,
        ],
        stops: const [0.0, 0.5, 1.0], // 亮→暗→亮 无缝环
      ).createShader(smallRect)
      ..strokeWidth = strokeWidth * 0.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(smallRect, smallStart, smallSweep, false, smallPaint);

    // 中心点（装饰，带呼吸效果）
    // 使用 mainArcAngle 而不是 progress 来保持呼吸效果的连续性
    // 将弧度归一化到一个连续的周期，避免循环时的跳跃
    final continuousCycle = mainArcAngle / (2 * math.pi); // 连续的周期值（0, 1, 2, 3...）
    final dotBreathe = (math.sin(continuousCycle * math.pi * 2) + 1) / 2; // 0-1，连续无跳跃
    final dotAlpha = 0.25 + 0.45 * dotBreathe; // 0.25-0.7
    final dotPaint = Paint()
      ..color = _computeBreathingColor(continuousCycle % 1.0, dotAlpha)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, strokeWidth * 0.8, dotPaint);

    // 中心点外圈光晕（脉冲扩散）
    final pulseRadius = strokeWidth * 0.8 + (dotBreathe * strokeWidth * 1.6);
    final pulsePaint = Paint()
      ..color = _computeBreathingColor(continuousCycle % 1.0, 0.25)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, pulseRadius, pulsePaint);
  }

  @override
  bool shouldRepaint(_ElegantRingPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.progress != progress;
  }
}

// ========== LoadingState (Updated) ==========

/// Unified loading state component（使用新的 AppLoading）
class LoadingState extends StatelessWidget {
  const LoadingState({
    super.key,
    this.message,
  });

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const AppLoading(size: AppLoadingSize.large),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              message!,
              style: AppTypography.bodyMedium.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// AliIcon（COLR 彩色字体）染色图标
/// AliIcon 字体包含 COLR/CPAL 表，自带黑色填充，不响应 IconTheme 颜色。
/// 使用 ColorFiltered 强制染色，使图标在夜间模式等场景下颜色正常。
class ColoredAliIcon extends StatelessWidget {
  /// 图标数据（AliIcon 系列）
  final IconData icon;

  /// 图标大小
  final double size;

  /// 图标颜色（默认使用 onSurface）
  final Color? color;

  const ColoredAliIcon({
    super.key,
    required this.icon,
    this.size = 24,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Theme.of(context).colorScheme.onSurface;
    return ColorFiltered(
      colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcATop),
      child: Icon(icon, size: size),
    );
  }
}

/// 红点角标（叠加在功能入口图标右上角）
/// count > 0 时显示，count > 99 显示 "99+"
class AppBadge extends StatelessWidget {
  /// 红点数量（<=0 不显示）
  final int count;

  /// 被叠加的内容（图标等）
  final Widget child;

  /// 红点颜色（默认 error 红）
  final Color? color;

  /// 是否显示数字（false 仅显示圆点，count>0 即显示）
  final bool showCount;

  /// 圆点模式的最大数字
  final int maxCount;

  const AppBadge({
    super.key,
    required this.count,
    required this.child,
    this.color,
    this.showCount = true,
    this.maxCount = 99,
  });

  @override
  Widget build(BuildContext context) {
    final badgeColor = color ?? Theme.of(context).colorScheme.error;
    final visible = count > 0;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (visible)
          Positioned(
            top: -4,
            right: -8,
            child: showCount
                ? Container(
                    constraints: const BoxConstraints(minWidth: 16),
                    height: 16,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      color: badgeColor,
                      borderRadius: BorderRadius.circular(8),
                      border: AppBorders.all(
                        context,
                        color: Theme.of(context).colorScheme.surface,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      count > maxCount ? '$maxCount+' : '$count',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onError,
                        height: 1,
                      ),
                    ),
                  )
                : Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: badgeColor,
                      shape: BoxShape.circle,
                      border: AppBorders.all(
                        context,
                        color: Theme.of(context).colorScheme.surface,
                      ),
                    ),
                  ),
          ),
      ],
    );
  }
}

/// 统一应用图标组件
/// 支持：网络 URL（CachedNetworkImage）、本地文件路径（FileImage）、默认图标
class AppIcon extends StatelessWidget {
  /// 图标地址：http(s):// 网络 URL 或本地文件路径（/ 或 file:// 开头）
  final String? url;

  /// 图标尺寸
  final double width;
  final double height;

  /// 圆角
  final double borderRadius;

  /// 填充方式
  final BoxFit fit;

  /// 是否显示默认图标（url 为空时）
  final bool showDefaultIcon;

  const AppIcon({
    super.key,
    this.url,
    this.width = 48,
    this.height = 48,
    this.borderRadius = 8,
    this.fit = BoxFit.cover,
    this.showDefaultIcon = true,
  });

  /// 是否为本地文件路径
  bool get _isLocalPath {
    if (url == null || url!.isEmpty) return false;
    return url!.startsWith('/') || url!.startsWith('file://');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 空地址 → 默认图标
    if (url == null || url!.isEmpty) {
      return _default(scheme);
    }

    final clip = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: _isLocalPath
          // 本地文件路径（如应用图标缓存 app_icons/*.png）
          ? Image.file(
              File(url!.startsWith('file://') ? url!.substring(7) : url!),
              width: width,
              height: height,
              fit: fit,
              errorBuilder: (_, __, ___) => _default(scheme),
            )
          // 网络 URL
          : CachedNetworkImage(
              imageUrl: url!,
              width: width,
              height: height,
              fit: fit,
              placeholder: (_, __) => Container(
                width: width,
                height: height,
                color: scheme.surfaceContainerHighest,
              ),
              errorWidget: (_, __, ___) => _default(scheme),
            ),
    );

    if (!showDefaultIcon && url == null) {
      return clip;
    }
    return clip;
  }

  /// 默认图标（安卓）
  Widget _default(ColorScheme scheme) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: const Icon(TablerIcons.brand_android, color: Colors.grey),
    );
  }
}

// ========== AppEditableField ==========

/// [AppEditableField] 的呈现方式。
enum AppEditableFieldMode {
  /// 只读展示：换行文本最多约 4 行 + 省略号；空值显示 hint；整行可点按。
  display,

  /// 行内自增高：`TextField(minLines: 1, maxLines: null)`。
  inline,

  /// 弹层编辑：点按后在统一底部弹层内用大输入框编辑（完成 / 取消 + 全屏升级）。
  sheet,

  /// 行内编辑 + 尾部展开：行内 [TextField]（可 [AppEditableField.dense] /
  /// [AppEditableField.borderless]）+ 尾部展开按钮，点按进入既有底部弹层。
  inlineExpandable,
}

/// 弹层内工具栏槽位构造器。
///
/// 传入当前编辑面的 controller（sheet 打开时为本地草稿），
/// 方便工具栏把「插入变量 / 粘贴 / 清空」落到正在编辑的值上。
typedef AppEditableFieldToolbarBuilder = Widget Function(
  BuildContext context,
  TextEditingController controller,
);

/// 自适应可编辑字段（设计系统原语）
///
/// 按 [AppEditableFieldMode] 呈现同一份绑定值：
/// - [AppEditableFieldMode.display]：只读换行展示（限 [displayMaxLines] 行 + 省略号）；
/// - [AppEditableFieldMode.inline]：行内自增高输入框；
/// - [AppEditableFieldMode.inlineExpandable]：行内输入框 + 尾部展开按钮，
///   点按展开进入与 [AppEditableFieldMode.sheet] 相同的底部弹层；
/// - [AppEditableFieldMode.sheet]：点按展开统一底部弹层（大输入框 + 完成/取消 +
///   全屏升级），未确认前不修改绑定值。
///
/// 绑定 [controller] 即业务值；弹层 / 全屏打开期间 [AppEditableFieldState]
/// 会把「激活 controller」切到本地草稿，[AppEditableFieldState.insertAtCursor]
/// 与聚焦都落在当前编辑面，确保「插入变量」不会写错值。
class AppEditableField extends StatefulWidget {
  const AppEditableField({
    super.key,
    required this.controller,
    this.mode = AppEditableFieldMode.display,
    this.onSubmitted,
    this.onTap,
    this.textInputAction = TextInputAction.done,
    this.hintText,
    this.label,
    this.toolbarBuilder,
    this.displayMaxLines = 4,
    this.dense = false,
    this.borderless = false,
    this.style,
    this.commitOnBlur = false,
    this.expandKey,
  });

  /// 绑定的业务 controller（唯一真值来源）。
  final TextEditingController controller;

  /// 呈现方式，默认只读展示。
  final AppEditableFieldMode mode;

  /// 提交回调；在草稿写回 [controller] 并关闭编辑面之后触发。
  final ValueChanged<String>? onSubmitted;

  /// display 模式下的整行点按回调（sheet 模式下点按固定用于打开弹层）。
  final VoidCallback? onTap;

  /// 输入动作，默认 `TextInputAction.done`。
  final TextInputAction textInputAction;

  /// 空值提示文案。
  final String? hintText;

  /// 字段标签（inline 作 labelText，sheet 作标题）。
  final String? label;

  /// 弹层内工具栏槽位（可选）。
  final AppEditableFieldToolbarBuilder? toolbarBuilder;

  /// display 模式最大行数，默认 4。
  final int displayMaxLines;

  /// 紧凑密度：`inline` / `inlineExpandable` 的输入框 `isDense`，默认 false。
  final bool dense;

  /// 无边框：`inline` / `inlineExpandable` 使用 `InputBorder.none` 且不填充，默认 false。
  final bool borderless;

  /// 行内输入框样式（如 `AppTypography.code` 等宽），默认继承主题。
  final TextStyle? style;

  /// 失焦提交：行内输入在失焦且文本自本次聚焦后发生变化时，触发一次
  /// [onSubmitted]（同一次焦点周期内只提交一次），默认 false。
  final bool commitOnBlur;

  /// 展开按钮的 Key，默认 `Key('request-editor-field-expand')`。
  final Key? expandKey;

  @override
  AppEditableFieldState createState() => AppEditableFieldState();
}

/// [AppEditableField] 的状态：持有「激活 controller」并路由插入/聚焦。
class AppEditableFieldState extends State<AppEditableField> {
  final FocusNode _inlineFocus = FocusNode();

  // 弹层 / 全屏共用的本地草稿与其 focus。
  //
  // 注意：草稿与 focus 由本 State 长期持有、仅在本 widget dispose 时释放。
  // 不能在弹层 pop 后立即 dispose —— `AppSheet.showCustom` 的 Future 在动画
  // 退场前就完成，退场期间 TextField 仍会重建并引用该 focus。
  final TextEditingController _draft = TextEditingController();
  final FocusNode _draftFocus = FocusNode();
  bool _sheetOpen = false;

  // commitOnBlur：本次聚焦开始时的文本快照 + 「已变化」标记。
  // 聚焦时记录快照并复位标记；失焦且标记为真时提交一次，防止重复追加。
  String _focusStartText = '';
  bool _textChangedSinceFocus = false;

  bool get _commitOnBlurActive =>
      widget.commitOnBlur &&
      (widget.mode == AppEditableFieldMode.inline ||
          widget.mode == AppEditableFieldMode.inlineExpandable);

  @override
  void initState() {
    super.initState();
    _inlineFocus.addListener(_onInlineFocusChanged);
    widget.controller.addListener(_onControllerChanged);
  }

  /// 行内文本变化：仅当聚焦中且与本次聚焦快照不同，标记为「已变化」。
  void _onControllerChanged() {
    if (!_commitOnBlurActive) return;
    if (_inlineFocus.hasFocus &&
        widget.controller.text != _focusStartText) {
      _textChangedSinceFocus = true;
    }
  }

  /// 行内焦点变化：聚焦记快照并复位；失焦且已变化则提交一次。
  void _onInlineFocusChanged() {
    if (!_commitOnBlurActive) return;
    if (_inlineFocus.hasFocus) {
      _focusStartText = widget.controller.text;
      _textChangedSinceFocus = false;
    } else if (_textChangedSinceFocus) {
      _textChangedSinceFocus = false;
      widget.onSubmitted?.call(widget.controller.text);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _inlineFocus.removeListener(_onInlineFocusChanged);
    _inlineFocus.dispose();
    _draftFocus.dispose();
    _draft.dispose();
    super.dispose();
  }

  /// 当前激活的 controller：
  /// 空闲时为绑定 controller；sheet / 全屏打开时为本地草稿 controller。
  TextEditingController get activeController =>
      _sheetOpen ? _draft : widget.controller;

  /// 聚焦当前激活的编辑面（inline 输入框 / 弹层草稿）。
  void focus() {
    if (_sheetOpen) {
      _draftFocus.requestFocus();
    } else {
      _inlineFocus.requestFocus();
    }
  }

  /// 在激活 controller 的当前选区处插入 [text]（选中内容会被替换）。
  void insertAtCursor(String text) {
    final target = activeController;
    final value = target.value;
    final selection = value.selection;
    final start =
        selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final newText = value.text.replaceRange(start, end, text);
    target.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  /// 打开统一底部弹层编辑（复制当前值为本地草稿）。
  Future<void> _openSheet() async {
    if (_sheetOpen) return;
    _draft.text = widget.controller.text;
    setState(() => _sheetOpen = true);
    try {
      await AppSheet.showCustom<String>(
        context: context,
        builder: (sheetContext) => _buildSheet(sheetContext),
      );
    } finally {
      if (mounted) setState(() => _sheetOpen = false);
    }
  }

  Widget _buildSheet(BuildContext sheetContext) {
    final theme = Theme.of(sheetContext);
    final scheme = theme.colorScheme;
    return AppSheetScaffold(
      key: const Key('request-editor-field-sheet'),
      title: widget.label,
      headerTrailing: IconButton(
        key: const Key('request-editor-field-fullscreen'),
        tooltip: '全屏编辑',
        icon: const Icon(Icons.open_in_full),
        onPressed: () => _openFullScreen(sheetContext),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.toolbarBuilder != null) ...[
            widget.toolbarBuilder!(sheetContext, _draft),
            const SizedBox(height: AppSpacing.sm),
          ],
          TextField(
            key: const Key('request-editor-field-sheet-input'),
            controller: _draft,
            focusNode: _draftFocus,
            autofocus: true,
            minLines: 6,
            maxLines: null,
            textInputAction: widget.textInputAction,
            decoration: InputDecoration(
              hintText: widget.hintText,
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: scheme.inputFill,
            ),
            onSubmitted: (_) => _commitSheet(sheetContext),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('request-editor-field-sheet-cancel'),
          onPressed: () => Navigator.of(sheetContext).pop(null),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('request-editor-field-sheet-confirm'),
          onPressed: () => _commitSheet(sheetContext),
          child: const Text('完成'),
        ),
      ],
    );
  }

  /// 提交弹层草稿：先写回绑定 controller，再关闭弹层，最后触发 [onSubmitted]。
  void _commitSheet(BuildContext sheetContext) {
    final text = _draft.text;
    widget.controller.text = text;
    Navigator.of(sheetContext).pop(text);
    widget.onSubmitted?.call(text);
  }

  /// 从弹层升级到全屏编辑；返回的文本写回弹层草稿（不直接改绑定值）。
  ///
  /// 使用弹层自身的 navigator（`rootNavigator: false`），全屏 route 叠在弹层之上，
  /// 返回后弹层与草稿都存活。
  Future<void> _openFullScreen(BuildContext sheetContext) async {
    final result =
        await Navigator.of(sheetContext, rootNavigator: false).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => _AppEditableFullScreen(
          initialText: _draft.text,
          title: widget.label,
          hintText: widget.hintText,
          textInputAction: widget.textInputAction,
        ),
      ),
    );
    if (result != null) {
      _draft.text = result;
    }
  }

  Widget _buildInline(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: widget.controller,
      focusNode: _inlineFocus,
      minLines: 1,
      maxLines: null,
      style: widget.style,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        hintText: widget.hintText,
        labelText: widget.label,
        isDense: widget.dense,
        contentPadding: (widget.dense || widget.borderless)
            ? AppSpacing.inputFieldPadding
            : null,
        border: widget.borderless
            ? InputBorder.none
            : const OutlineInputBorder(),
        filled: !widget.borderless,
        fillColor: widget.borderless ? null : scheme.inputFill,
      ),
    );
  }

  /// 行内编辑 + 尾部展开按钮：点按展开进入既有底部弹层（`_openSheet`）。
  Widget _buildInlineExpandable(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: widget.controller,
            focusNode: _inlineFocus,
            minLines: 1,
            maxLines: null,
            style: widget.style,
            textInputAction: widget.textInputAction,
            onSubmitted: widget.onSubmitted,
            decoration: InputDecoration(
              hintText: widget.hintText,
              labelText: widget.label,
              isDense: widget.dense,
              contentPadding: AppSpacing.inputFieldPadding,
              border: widget.borderless
                  ? InputBorder.none
                  : const OutlineInputBorder(),
              filled: !widget.borderless,
              fillColor: widget.borderless ? null : scheme.inputFill,
            ),
          ),
        ),
        IconButton(
          key: widget.expandKey ?? const Key('request-editor-field-expand'),
          tooltip: '展开编辑',
          icon: const Icon(Icons.open_in_full),
          iconSize: AppTypography.iconMD,
          padding: EdgeInsets.zero,
          // 与行尾动作槽位对齐：占位宽度取 AppSpacing.huge(40)，而非
          // IconButton 默认的 48——否则会挤占窄屏下可编辑值区的宽度。
          constraints: const BoxConstraints.tightFor(
            width: AppSpacing.huge,
            height: AppSpacing.huge,
          ),
          visualDensity: VisualDensity.compact,
          onPressed: _openSheet,
        ),
      ],
    );
  }

  Widget _buildDisplay(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onTap = widget.mode == AppEditableFieldMode.sheet
        ? _openSheet
        : widget.onTap;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final isEmpty = value.text.isEmpty;
        final display = isEmpty ? (widget.hintText ?? '') : value.text;
        return Semantics(
          button: onTap != null,
          label: display,
          child: InkWell(
            key: const Key('request-editor-field-display'),
            borderRadius: AppRadius.allSM,
            onTap: onTap,
            child: Padding(
              padding: AppSpacing.allSM,
              child: Text(
                display,
                maxLines: widget.displayMaxLines,
                overflow: TextOverflow.ellipsis,
                // 可选 [AppEditableField.style] 覆盖展示字号（如 KV 预览用更小
                // 的 bodySmall）；未传时维持既有 bodyMedium，行为零变化。
                style: (widget.style ?? theme.textTheme.bodyMedium)?.copyWith(
                  color: isEmpty ? scheme.onSurfaceVariant : scheme.onSurface,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.mode) {
      case AppEditableFieldMode.inline:
        return _buildInline(context);
      case AppEditableFieldMode.inlineExpandable:
        return _buildInlineExpandable(context);
      case AppEditableFieldMode.display:
      case AppEditableFieldMode.sheet:
        return _buildDisplay(context);
    }
  }
}

/// 全屏编辑 route：自带 [Scaffold] + [PopScope] 脏值守卫。
///
/// 确认时把文本 pop 回弹层（由弹层写回草稿）；返回键 / 手势在脏值时先确认放弃。
class _AppEditableFullScreen extends StatefulWidget {
  const _AppEditableFullScreen({
    required this.initialText,
    this.title,
    this.hintText,
    this.textInputAction = TextInputAction.done,
  });

  final String initialText;
  final String? title;
  final String? hintText;
  final TextInputAction textInputAction;

  @override
  State<_AppEditableFullScreen> createState() =>
      _AppEditableFullScreenState();
}

class _AppEditableFullScreenState extends State<_AppEditableFullScreen> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _focus = FocusNode();
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _dirty => _controller.text != widget.initialText;

  void _confirm() {
    Navigator.of(context).pop(_controller.text);
  }

  Future<void> _handlePop() async {
    final discard = await AppDialogs.showConfirmSheet(
      title: '放弃未保存的修改？',
      message: '全屏编辑的内容尚未应用，返回后将丢失。',
      confirmText: '放弃',
      cancelText: '继续编辑',
      isDangerous: true,
    );
    if (!mounted) return;
    if (discard == true) Navigator.of(context).pop(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handlePop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title ?? '编辑'),
          actions: [
            TextButton(
              key: const Key('request-editor-field-fullscreen-done'),
              onPressed: _confirm,
              child: const Text('完成'),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: AppSpacing.allLG,
            child: TextField(
              key: const Key('request-editor-field-fullscreen-input'),
              controller: _controller,
              focusNode: _focus,
              autofocus: true,
              minLines: 6,
              maxLines: null,
              textInputAction: widget.textInputAction,
              decoration: InputDecoration(
                hintText: widget.hintText,
                border: const OutlineInputBorder(),
                filled: true,
                fillColor: scheme.inputFill,
              ),
              onSubmitted: (_) => _confirm(),
            ),
          ),
        ),
      ),
    );
  }
}

// ========== AppEditorToolbar ==========

/// 就地编辑动作行（设计系统原语）。
///
/// 绑定一个外部 [controller]，提供：
/// - 粘贴：从系统剪贴板读取纯文本并插入当前选区；
/// - 清空：清空 [controller]；
/// - 插入：当 [insertText] 非空时显示按钮，把该文本插入当前选区（选中内容被替换）；
/// - 格式化：[onFormat] 回调槽位（具体格式化行为由调用方拥有，如 JSON 美化）；
/// - 上一个 / 下一个字段：[onPrevious] / [onNext] 回调槽位（聚焦切换由调用方拥有）。
///
/// 本组件**只**渲染一行紧凑动作，不叠加任何 `viewInsets` 内边距、不在键盘上方
/// 叠加任何浮层；弹层内边距由 `AppSheet`/`AppSheetScaffold` 负责。
class AppEditorToolbar extends StatelessWidget {
  const AppEditorToolbar({
    super.key,
    required this.controller,
    this.insertText,
    this.onFormat,
    this.onPrevious,
    this.onNext,
  });

  /// 绑定的编辑 controller（插入 / 清空都落在它身上）。
  final TextEditingController controller;

  /// 插入动作要写入的文本；为 null 时不渲染插入按钮。
  final String? insertText;

  /// 格式化回调槽位；为 null 时不渲染格式化按钮。
  final VoidCallback? onFormat;

  /// 跳到上一个字段的回调；为 null 时不渲染上一个按钮。
  final VoidCallback? onPrevious;

  /// 跳到下一个字段的回调；为 null 时不渲染下一个按钮。
  final VoidCallback? onNext;

  /// 在 [controller] 的当前选区处插入 [text]（选中内容被替换）。
  ///
  /// 选区无效（如从未聚焦的 controller）时追加到文本末尾——这样空 controller
  /// 上插入等价于赋值。供本工具栏与 [AppSuggestionChips] 复用。
  static void insertAtCursor(TextEditingController controller, String text) {
    final value = controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final newText = value.text.replaceRange(start, end, text);
    controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    insertAtCursor(controller, text);
  }

  Widget _action({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      icon: Icon(icon),
      iconSize: AppTypography.iconMD,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final insert = insertText;
    return Wrap(
      spacing: AppSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (onPrevious != null)
          _action(
            key: const Key('editor-toolbar-prev'),
            icon: TablerIcons.chevron_left,
            tooltip: '上一个字段',
            onPressed: onPrevious!,
          ),
        if (onNext != null)
          _action(
            key: const Key('editor-toolbar-next'),
            icon: TablerIcons.chevron_right,
            tooltip: '下一个字段',
            onPressed: onNext!,
          ),
        _action(
          key: const Key('editor-toolbar-paste'),
          icon: TablerIcons.clipboard,
          tooltip: '粘贴',
          onPressed: _paste,
        ),
        if (insert != null)
          _action(
            key: const Key('editor-toolbar-insert'),
            icon: TablerIcons.variable,
            tooltip: '插入',
            onPressed: () => insertAtCursor(controller, insert),
          ),
        if (onFormat != null)
          _action(
            key: const Key('editor-toolbar-format'),
            icon: TablerIcons.braces,
            tooltip: '格式化',
            onPressed: onFormat!,
          ),
        _action(
          key: const Key('editor-toolbar-clear'),
          icon: TablerIcons.eraser,
          tooltip: '清空',
          onPressed: controller.clear,
        ),
      ],
    );
  }
}

// ========== AppSuggestionChips ==========

/// 建议值快捷 chips（设计系统原语）。
///
/// 把 [suggestions] 渲染为一组紧凑的 `ActionChip`；点按其中一个会把该值插入
/// [controller] 的当前选区（等价于「赋值 / 插入」，见
/// [AppEditorToolbar.insertAtCursor]），并通过 [onSelected] 通知调用方。
///
/// [suggestions] 为空时渲染 [SizedBox.shrink]（不产生空行、不抛异常）。
class AppSuggestionChips extends StatelessWidget {
  const AppSuggestionChips(
    this.suggestions, {
    super.key,
    required this.controller,
    this.onSelected,
  });

  /// 建议值列表。
  final List<String> suggestions;

  /// 点按 chip 时接收插入值的编辑 controller。
  final TextEditingController controller;

  /// 点按 chip 时的附加回调（如标记脏值）；在写入 controller 之后触发。
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final suggestion in suggestions)
          ActionChip(
            key: Key('editor-suggestion-chip-$suggestion'),
            label: Text(suggestion),
            labelStyle: theme.textTheme.labelMedium,
            visualDensity: VisualDensity.compact,
            onPressed: () {
              AppEditorToolbar.insertAtCursor(controller, suggestion);
              onSelected?.call(suggestion);
            },
          ),
      ],
    );
  }
}

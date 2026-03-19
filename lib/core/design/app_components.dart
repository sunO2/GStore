import 'package:flutter/material.dart';

/// Reusable UI components that follow the app design system
///
/// This library provides pre-built components that ensure consistency
/// across the application while reducing code duplication.

import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_radius.dart';
import 'app_shadows.dart';
import 'app_typography.dart';

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
            : BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
                width: 1,
              ),
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
        return SizedBox(
          width: _getButtonIconSize(),
          height: _getButtonIconSize(),
          child: const CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation(Colors.white),
          ),
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
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        errorText: widget.errorText,
        helperText: widget.helperText,
        prefixIcon: widget.prefixIcon != null ? Icon(widget.prefixIcon) : null,
        suffixIcon: _buildSuffixIcon(),
        border: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: const BorderSide(color: AppColors.borderPrimary),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: const BorderSide(color: AppColors.borderPrimary),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: const BorderSide(color: AppColors.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: const BorderSide(color: AppColors.error, width: 2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.allSM,
          borderSide: const BorderSide(color: AppColors.borderSecondary),
        ),
        filled: true,
        fillColor: widget.enabled ? AppColors.surface : AppColors.grey100,
        contentPadding: AppSpacing.inputFieldPadding,
        counterText: '',
      ),
    );
  }

  Widget? _buildSuffixIcon() {
    if (widget.obscureText) {
      return IconButton(
        icon: Icon(_obscureText ? Icons.visibility_off : Icons.visibility),
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

// ========== LoadingState ==========
/// Unified loading state component
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
          const CircularProgressIndicator(),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.md),
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
              Icons.error_outline,
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
          icon: Icons.info_outline,
          iconColor: AppColors.info,
          backgroundColor: AppColors.infoLight,
          borderColor: AppColors.info,
          textColor: AppColors.infoDark,
        );
      case InfoCardType.success:
        return _InfoCardConfig(
          icon: Icons.check_circle_outline,
          iconColor: AppColors.success,
          backgroundColor: AppColors.successLight,
          borderColor: AppColors.success,
          textColor: AppColors.successDark,
        );
      case InfoCardType.warning:
        return _InfoCardConfig(
          icon: Icons.warning_amber_outlined,
          iconColor: AppColors.warning,
          backgroundColor: AppColors.warningLight,
          borderColor: AppColors.warning,
          textColor: AppColors.warningDark,
        );
      case InfoCardType.error:
        return _InfoCardConfig(
          icon: Icons.error_outline,
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
///     AppSegment(value: AppThemeMode.system, label: '系统', icon: Icons.brightness_auto),
///     AppSegment(value: AppThemeMode.light, label: '浅色', icon: Icons.light_mode),
///     AppSegment(value: AppThemeMode.dark, label: '深色', icon: Icons.dark_mode),
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
  });

  /// 当前选中的值
  final T value;

  /// 分段选项列表
  final List<AppSegment<T>> segments;

  /// 选择变化回调
  final ValueChanged<T> onChanged;

  /// 是否启用
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SegmentedButton<T>(
      segments: segments
          .map(
            (segment) => ButtonSegment<T>(
              value: segment.value,
              label: Text(segment.label),
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
        // 边框
        side: WidgetStateProperty.all<BorderSide>(
          BorderSide(
            color: colorScheme.outlineVariant.withOpacity(0.5),
            width: 1,
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
  });

  /// 选项的值
  final T value;

  /// 选项的标签文本
  final String label;

  /// 选项的图标（可选）
  final IconData? icon;
}

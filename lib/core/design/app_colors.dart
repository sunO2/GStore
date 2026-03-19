import 'package:flutter/material.dart';

/// App color system
/// Provides consistent colors across the application with semantic meaning
class AppColors {
  AppColors._();

  // ========== Opacity Levels ==========
  static const int alphaHigh = 255;
  static const int alphaMedium = 180;
  static const int alphaLow = 130;
  static const int alphaLower = 80;
  static const int alphaLowest = 30;

  static const int withAlphaHigh = 255;
  static const int withAlphaMedium = 180;
  static const int withAlphaLow = 130;
  static const int withAlphaLower = 80;
  static const int withAlphaLowest = 30;

  // ========== Grey Scale ==========
  /// Light mode grey scale
  static const Color grey50 = Color(0xFFFAFAFA);
  static const Color grey100 = Color(0xFFF5F5F5);
  static const Color grey200 = Color(0xFFEEEEEE);
  static const Color grey300 = Color(0xFFE0E0E0);
  static const Color grey400 = Color(0xFFBDBDBD);
  static const Color grey500 = Color(0xFF9E9E9E);
  static const Color grey600 = Color(0xFF757575);
  static const Color grey700 = Color(0xFF616161);
  static const Color grey800 = Color(0xFF424242);
  static const Color grey900 = Color(0xFF212121);

  // ========== Semantic Text Colors ==========
  /// Primary text - highest emphasis
  static const Color textPrimary = Color(0xFF212121);
  /// Secondary text - medium emphasis
  static const Color textSecondary = Color(0xFF757575);
  /// Tertiary text - lowest emphasis
  static const Color textTertiary = Color(0xFF9E9E9E);
  /// Text on dark backgrounds
  static const Color textOnDark = Color(0xFFFFFFFF);
  /// Text on primary color backgrounds
  static const Color textOnPrimary = Color(0xFFFFFFFF);
  /// Disabled text
  static const Color textDisabled = Color(0xFFBDBDBD);

  // ========== Semantic Background Colors ==========
  /// Main background color
  static const Color background = Color(0xFFFAFAFA);
  /// Card/surface background
  static const Color surface = Color(0xFFFFFFFF);
  /// Alternative background for contrast
  static const Color backgroundAlt = Color(0xFFF5F5F5);
  /// Overlay background
  static const Color overlay = Color(0x80000000);

  // ========== Border & Divider Colors ==========
  /// Primary border color
  static const Color borderPrimary = Color(0xFFE0E0E0);
  /// Secondary border color
  static const Color borderSecondary = Color(0xFFEEEEEE);
  /// Focus border color
  static const Color borderFocus = Color(0xFF2196F3);
  /// Error border color
  static const Color borderError = Color(0xFFF44336);
  /// Divider color
  static const Color divider = Color(0xFFE0E0E0);

  // ========== Status Colors ==========
  /// Success state - green
  static const Color success = Color(0xFF4CAF50);
  static const Color successLight = Color(0xFFE8F5E9);
  static const Color successDark = Color(0xFF388E3C);

  /// Error state - red
  static const Color error = Color(0xFFF44336);
  static const Color errorLight = Color(0xFFFFEBEE);
  static const Color errorDark = Color(0xFFD32F2F);

  /// Warning state - orange
  static const Color warning = Color(0xFFFF9800);
  static const Color warningLight = Color(0xFFFFF3E0);
  static const Color warningDark = Color(0xFFF57C00);

  /// Info state - blue
  static const Color info = Color(0xFF2196F3);
  static const Color infoLight = Color(0xFFE3F2FD);
  static const Color infoDark = Color(0xFF1976D2);

  // ========== Primary Brand Colors ==========
  /// App primary color - blue
  static const Color primary = Color(0xFF2196F3);
  static const Color primaryLight = Color(0xFF64B5F6);
  static const Color primaryDark = Color(0xFF1976D2);

  /// Accent color
  static const Color accent = Color(0xFFFF9800);
  static const Color accentLight = Color(0xFFFFB74D);
  static const Color accentDark = Color(0xFFF57C00);

  // ========== Channel Brand Colors ==========
  /// GitHub brand color
  static const Color githubBrand = Color(0xFF24292E);
  static const Color githubBrandLight = Color(0xFF54AEFF);
  static const Color githubBrandDark = Color(0xFF1B1F23);

  /// F-Droid brand color
  static const Color fdroidBrand = Color(0xFF1976D2);
  static const Color fdroidBrandLight = Color(0xFF64B5F6);
  static const Color fdroidBrandDark = Color(0xFF0D47A1);

  /// Vivo brand color
  static const Color vivoBrand = Color(0xFF4155D0);
  static const Color vivoBrandLight = Color(0xFF7C8FE8);
  static const Color vivoBrandDark = Color(0xFF2A3A8C);

  /// Local DB brand color
  static const Color localDbBrand = Color(0xFF2196F3);
  static const Color localDbBrandLight = Color(0xFF64B5F6);
  static const Color localDbBrandDark = Color(0xFF1976D2);

  /// HTTP channel brand color
  static const Color httpBrand = Color(0xFFFF9800);
  static const Color httpBrandLight = Color(0xFFFFB74D);
  static const Color httpBrandDark = Color(0xFFF57C00);

  // ========== Common Material Colors ==========
  /// Red
  static const Color red = Color(0xFFF44336);
  static const Color redLight = Color(0xFFEF5350);
  static const Color redDark = Color(0xFFE53935);

  /// Pink
  static const Color pink = Color(0xFFE91E63);
  static const Color pinkLight = Color(0xFFEC407A);
  static const Color pinkDark = Color(0xFFD81B60);

  /// Purple
  static const Color purple = Color(0xFF9C27B0);
  static const Color purpleLight = Color(0xFFAB47BC);
  static const Color purpleDark = Color(0xFF8E24AA);

  /// Deep Purple
  static const Color deepPurple = Color(0xFF673AB7);
  static const Color deepPurpleLight = Color(0xFF7E57C2);
  static const Color deepPurpleDark = Color(0xFF5E35B1);

  /// Indigo
  static const Color indigo = Color(0xFF3F51B5);
  static const Color indigoLight = Color(0xFF5C6BC0);
  static const Color indigoDark = Color(0xFF3949AB);

  /// Blue
  static const Color blue = Color(0xFF2196F3);
  static const Color blueLight = Color(0xFF42A5F5);
  static const Color blueDark = Color(0xFF1E88E5);

  /// Light Blue
  static const Color lightBlue = Color(0xFF03A9F4);
  static const Color lightBlueLight = Color(0xFF29B6F6);
  static const Color lightBlueDark = Color(0xFF039BE5);

  /// Cyan
  static const Color cyan = Color(0xFF00BCD4);
  static const Color cyanLight = Color(0xFF26C6DA);
  static const Color cyanDark = Color(0xFF00ACC1);

  /// Teal
  static const Color teal = Color(0xFF009688);
  static const Color tealLight = Color(0xFF26A69A);
  static const Color tealDark = Color(0xFF00897B);

  /// Green
  static const Color green = Color(0xFF4CAF50);
  static const Color greenLight = Color(0xFF66BB6A);
  static const Color greenDark = Color(0xFF43A047);

  /// Light Green
  static const Color lightGreen = Color(0xFF8BC34A);
  static const Color lightGreenLight = Color(0xFF9CCC65);
  static const Color lightGreenDark = Color(0xFF7CB342);

  /// Lime
  static const Color lime = Color(0xFFCDDC39);
  static const Color limeLight = Color(0xFFD4E157);
  static const Color limeDark = Color(0xFFC0CA33);

  /// Yellow
  static const Color yellow = Color(0xFFFFEB3B);
  static const Color yellowLight = Color(0xFFFFEE58);
  static const Color yellowDark = Color(0xFFFDD835);

  /// Amber
  static const Color amber = Color(0xFFFFC107);
  static const Color amberLight = Color(0xFFFFCA28);
  static const Color amberDark = Color(0xFFFFB300);

  /// Orange
  static const Color orange = Color(0xFFFF9800);
  static const Color orangeLight = Color(0xFFFFA726);
  static const Color orangeDark = Color(0xFFF57C00);

  /// Deep Orange
  static const Color deepOrange = Color(0xFFFF5722);
  static const Color deepOrangeLight = Color(0xFFFF7043);
  static const Color deepOrangeDark = Color(0xFFE64A19);

  /// Brown
  static const Color brown = Color(0xFF795548);
  static const Color brownLight = Color(0xFF8D6E63);
  static const Color brownDark = Color(0xFF6D4C41);

  /// Blue Grey
  static const Color blueGrey = Color(0xFF607D8B);
  static const Color blueGreyLight = Color(0xFF78909C);
  static const Color blueGreyDark = Color(0xFF546E7A);

  // ========== Special Colors ==========
  /// Transparent color
  static const Color transparent = Color(0x00000000);

  /// Black
  static const Color black = Color(0xFF000000);

  /// White
  static const Color white = Color(0xFFFFFFFF);

  // ========== Code Editor Colors ==========
  /// Code editor background - dark theme
  static const Color codeEditorBackground = Color(0xFF1E1E1E);
  /// Code editor toolbar background
  static const Color codeEditorToolbar = Color(0xFF2D2D2D);
  /// Code editor text - light theme
  static const Color codeEditorText = Color(0xFFD4D4D4);
  /// Code editor border
  static const Color codeEditorBorder = Color(0xFF3E3E3E);

  // ========== Helper Methods ==========

  /// Get color with opacity
  static Color withOpacity(Color color, double opacity) {
    return color.withOpacity(opacity);
  }

  /// Get color with alpha value
  static Color withAlphaValue(Color color, int alpha) {
    return color.withAlpha(alpha);
  }

  /// Get channel brand color by channel type
  static Color getChannelBrandColor(String channelType) {
    switch (channelType.toLowerCase()) {
      case 'github':
        return githubBrand;
      case 'fdroid':
        return fdroidBrand;
      case 'vivo':
        return vivoBrand;
      case 'localdb':
      case 'local_db':
        return localDbBrand;
      case 'http':
        return httpBrand;
      default:
        return primary;
    }
  }

  /// Get light version of channel brand color
  static Color getChannelBrandColorLight(String channelType) {
    switch (channelType.toLowerCase()) {
      case 'github':
        return githubBrandLight;
      case 'fdroid':
        return fdroidBrandLight;
      case 'vivo':
        return vivoBrandLight;
      case 'localdb':
      case 'local_db':
        return localDbBrandLight;
      case 'http':
        return httpBrandLight;
      default:
        return primaryLight;
    }
  }

  /// Get dark version of channel brand color
  static Color getChannelBrandColorDark(String channelType) {
    switch (channelType.toLowerCase()) {
      case 'github':
        return githubBrandDark;
      case 'fdroid':
        return fdroidBrandDark;
      case 'vivo':
        return vivoBrandDark;
      case 'localdb':
      case 'local_db':
        return localDbBrandDark;
      case 'http':
        return httpBrandDark;
      default:
        return primaryDark;
    }
  }

  // ========== Dynamic Color Extensions ==========

  /// Get dynamic background color based on theme
  /// 使用 Theme.of(context).colorScheme.surfaceContainerLowest 替代
  @Deprecated('Use Theme.of(context).colorScheme.surfaceContainerLowest instead')
  static Color getBackground(BuildContext context) {
    return Theme.of(context).colorScheme.surfaceContainerLowest;
  }

  /// Get dynamic surface color based on theme
  /// 使用 Theme.of(context).colorScheme.surface 替代
  @Deprecated('Use Theme.of(context).colorScheme.surface instead')
  static Color getSurface(BuildContext context) {
    return Theme.of(context).colorScheme.surface;
  }

  /// Get dynamic primary color based on theme
  /// 使用 Theme.of(context).colorScheme.primary 替代
  @Deprecated('Use Theme.of(context).colorScheme.primary instead')
  static Color getPrimary(BuildContext context) {
    return Theme.of(context).colorScheme.primary;
  }

  /// Get dynamic on-primary color based on theme
  /// 使用 Theme.of(context).colorScheme.onPrimary 替代
  @Deprecated('Use Theme.of(context).colorScheme.onPrimary instead')
  static Color getOnPrimary(BuildContext context) {
    return Theme.of(context).colorScheme.onPrimary;
  }

  /// Get dynamic error color based on theme
  /// 使用 Theme.of(context).colorScheme.error 替代
  @Deprecated('Use Theme.of(context).colorScheme.error instead')
  static Color getError(BuildContext context) {
    return Theme.of(context).colorScheme.error;
  }

  /// Get dynamic outline color based on theme
  /// 使用 Theme.of(context).colorScheme.outline 替代
  @Deprecated('Use Theme.of(context).colorScheme.outline instead')
  static Color getOutline(BuildContext context) {
    return Theme.of(context).colorScheme.outline;
  }
}

/// ColorScheme extensions for dynamic color utilities
///
/// 提供便捷方法从 ColorScheme 获取常用颜色组合
///
/// 示例：
/// ```dart
/// final theme = Theme.of(context);
/// final colorScheme = theme.colorScheme;
///
/// // 获取背景色（自动适配亮暗主题）
/// final bgColor = colorScheme.background;  // surfaceContainerLowest / surface
///
/// // 获取卡片色
/// final cardColor = colorScheme.card;      // surface / surfaceContainerLow
///
/// // 获取文字色
/// final textColor = colorScheme.onBackground; // onSurface / onSurface
/// ```
extension ColorSchemeExtensions on ColorScheme {
  // ========== Background Colors ==========

  /// 背景色 - 自动适配亮暗模式
  /// 亮色：surfaceContainerLowest，暗色：surface
  Color get background => brightness == Brightness.light
      ? surfaceContainerLowest
      : surface;

  /// 卡片色 - 自动适配亮暗模式
  /// 亮色：surface，暗色：surfaceContainerLow
  Color get card => brightness == Brightness.light
      ? surface
      : surfaceContainerLow;

  /// 对话框色 - 自动适配亮暗模式
  /// 亮色：surface，暗色：surfaceContainerLow
  Color get dialogSurface => brightness == Brightness.light
      ? surface
      : surfaceContainerLow;

  /// 输入框填充色 - 两种模式相同
  Color get inputFill => surfaceContainerHighest;

  /// 悬停背景色 - 主色的 8%
  Color get hoverOverlay => primary.withOpacity(0.08);

  /// 焦点背景色 - 主色的 12%
  Color get focusOverlay => primary.withOpacity(0.12);

  /// 按下背景色 - 主色的 16%
  Color get pressedOverlay => primary.withOpacity(0.16);

  // ========== Text Colors ==========

  /// 主要文字色 - 自动适配亮暗模式
  Color get textPrimary => onSurface;

  /// 次要文字色 - 自动适配亮暗模式（70% 透明度）
  Color get textSecondary => onSurfaceVariant.withOpacity(0.7);

  /// 辅助文字色 - 自动适配亮暗模式（50% 透明度）
  Color get textTertiary => onSurfaceVariant.withOpacity(0.5);

  /// 禁用文字色 - 自动适配亮暗模式（38% 透明度）
  Color get textDisabled => onSurface.withOpacity(0.38);

  // ========== Border Colors ==========

  /// 标准边框色 - 自动适配亮暗模式
  /// 亮色：50% 透明度，暗色：100% 不透明（outline 已包含透明度）
  Color get borderStandard => brightness == Brightness.light
      ? outline.withOpacity(0.5)
      : outline.withOpacity(0.3);

  /// 淡边框色 - 自动适配亮暗模式
  /// 亮色：50% 透明度，暗色：30% 透明度
  Color get borderLight => brightness == Brightness.light
      ? outlineVariant.withOpacity(0.5)
      : outlineVariant.withOpacity(0.3);

  /// 焦点边框色 - 主色，不透明
  Color get borderFocus => primary;

  /// 错误边框色 - 错误色，不透明
  Color get borderError => error;

  // ========== Container Colors ==========

  /// 主色容器 - 用于标签、徽章等
  Color get primaryContainerBadge => primaryContainer.withOpacity(0.5);

  /// 次要色容器 - 用于次要强调
  Color get secondaryContainerBadge => secondaryContainer.withOpacity(0.5);

  /// 错误容器 - 用于错误提示背景
  Color get errorContainerBackground => errorContainer.withOpacity(0.5);

  /// 成功色 - 使用主色（绿色调时）或 tertiary
  Color get successColor => brightness == Brightness.light
      ? primary
      : primary;

  // ========== Status Colors with Opacity ==========

  /// 成功背景色（淡）
  Color get successBackground => primary.withOpacity(0.15);

  /// 错误背景色（淡）
  Color get errorBackground => error.withOpacity(0.15);

  /// 警告背景色（淡）
  Color get warningBackground => tertiary.withOpacity(0.15);

  /// 信息背景色（淡）
  Color get infoBackground => secondary.withOpacity(0.15);
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/theme/app_theme_config.dart';

/// Builder for creating app themes with design tokens
///
/// 设计规范已完全集成到主题系统中
/// 使用时通过 Theme.of(context) 获取，无需硬编码
///
/// 示例：
/// ```dart
/// // 文字样式 - 自动适配亮暗主题
/// Text('标题', style: Theme.of(context).textTheme.titleLarge)
/// Text('正文', style: Theme.of(context).textTheme.bodyMedium)
///
/// // 颜色 - 自动适配亮暗主题
/// Container(color: Theme.of(context).colorScheme.primary)
/// Text('主要文字', style: TextStyle(color: Theme.of(context).colorScheme.onSurface))
/// ```
class ThemeDataBuilder {
  ThemeDataBuilder._();

  // ========== 颜色语义化映射 ==========

  /// 将语义化颜色映射到 ColorScheme
  /// 这些颜色会自动适配亮色/暗色主题
  static const Color _textPrimaryLight = Color(0xFF212121);
  static const Color _textSecondaryLight = Color(0xFF757575);
  static const Color _textTertiaryLight = Color(0xFF9E9E9E);
  static const Color _textPrimaryDark = Color(0xFFFFFFFF);
  static const Color _textSecondaryDark = Color(0xB2FFFFFF); // 70% opacity
  static const Color _textTertiaryDark = Color(0x80FFFFFF);  // 50% opacity

  // ========== 文字主题构建 ==========

  /// 构建完整的 TextTheme（亮色）
  static TextTheme buildLightTextTheme(ColorScheme colorScheme, [double fontScale = 1.0]) {
    return TextTheme(
      // ========== Display 系列（超大标题）==========
      displayLarge: TextStyle(
        fontSize: AppTypography.sizeHuge * fontScale,
        fontWeight: AppTypography.weightBold,
        height: AppTypography.heightTight,
        letterSpacing: AppTypography.spacingTight,
        color: colorScheme.onSurface,
      ),
      displayMedium: TextStyle(
        fontSize: AppTypography.sizeXXXL * fontScale,
        fontWeight: AppTypography.weightBold,
        height: AppTypography.heightTight,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),
      displaySmall: TextStyle(
        fontSize: AppTypography.sizeXXL * fontScale,
        fontWeight: AppTypography.weightSemiBold,
        height: AppTypography.heightSnug,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),

      // ========== Headline 系列（页面标题）==========
      headlineLarge: TextStyle(
        fontSize: AppTypography.sizeXL * fontScale,
        fontWeight: AppTypography.weightSemiBold,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),
      headlineMedium: TextStyle(
        fontSize: AppTypography.sizeLG * fontScale,
        fontWeight: AppTypography.weightSemiBold,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),
      headlineSmall: TextStyle(
        fontSize: AppTypography.sizeMD * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: _textPrimaryLight, // 主要文字
      ),

      // ========== Title 系列（卡片标题）==========
      titleLarge: TextStyle(
        fontSize: AppTypography.sizeMD * fontScale,
        fontWeight: AppTypography.weightSemiBold,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: AppTypography.sizeMD * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: _textPrimaryLight, // 主要文字（应用名称）
      ),
      titleSmall: TextStyle(
        fontSize: AppTypography.sizeSM * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingWide,
        color: _textPrimaryLight, // 主要文字（小标题）
      ),

      // ========== Body 系列（正文）==========
      bodyLarge: TextStyle(
        fontSize: AppTypography.sizeMD * fontScale,
        fontWeight: AppTypography.weightRegular,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: _textPrimaryLight, // 主要文字（大正文）
      ),
      bodyMedium: TextStyle(
        fontSize: AppTypography.sizeSM * fontScale,
        fontWeight: AppTypography.weightRegular,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: _textSecondaryLight, // 次要文字（应用描述）
      ),
      bodySmall: TextStyle(
        fontSize: AppTypography.sizeXS * fontScale,
        fontWeight: AppTypography.weightRegular,
        height: AppTypography.heightRelaxed,
        letterSpacing: AppTypography.spacingWide,
        color: _textSecondaryLight, // 次要文字（小正文）
      ),

      // ========== Label 系列（标签/按钮）==========
      labelLarge: TextStyle(
        fontSize: AppTypography.sizeSM * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingWide,
        color: colorScheme.onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: AppTypography.sizeXS * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingWide,
        color: _textTertiaryLight, // 辅助文字（标签）
      ),
      labelSmall: TextStyle(
        fontSize: AppTypography.sizeXXS * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingWider,
        color: _textTertiaryLight, // 辅助文字（小标签）
      ),
    );
  }

  /// 构建完整的 TextTheme（暗色）
  static TextTheme buildDarkTextTheme(ColorScheme colorScheme, [double fontScale = 1.0]) {
    return TextTheme(
      // ========== Display 系列（超大标题）==========
      displayLarge: TextStyle(
        fontSize: AppTypography.sizeHuge * fontScale,
        fontWeight: AppTypography.weightBold,
        height: AppTypography.heightTight,
        letterSpacing: AppTypography.spacingTight,
        color: colorScheme.onSurface,
      ),
      displayMedium: TextStyle(
        fontSize: AppTypography.sizeXXXL * fontScale,
        fontWeight: AppTypography.weightBold,
        height: AppTypography.heightTight,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),
      displaySmall: TextStyle(
        fontSize: AppTypography.sizeXXL * fontScale,
        fontWeight: AppTypography.weightSemiBold,
        height: AppTypography.heightSnug,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),

      // ========== Headline 系列（页面标题）==========
      headlineLarge: TextStyle(
        fontSize: AppTypography.sizeXL * fontScale,
        fontWeight: AppTypography.weightSemiBold,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),
      headlineMedium: TextStyle(
        fontSize: AppTypography.sizeLG * fontScale,
        fontWeight: AppTypography.weightSemiBold,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),
      headlineSmall: TextStyle(
        fontSize: AppTypography.sizeMD * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: _textPrimaryDark, // 主要文字
      ),

      // ========== Title 系列（卡片标题）==========
      titleLarge: TextStyle(
        fontSize: AppTypography.sizeMD * fontScale,
        fontWeight: AppTypography.weightSemiBold,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: colorScheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: AppTypography.sizeMD * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: _textPrimaryDark, // 主要文字（应用名称）
      ),
      titleSmall: TextStyle(
        fontSize: AppTypography.sizeSM * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingWide,
        color: _textPrimaryDark, // 主要文字（小标题）
      ),

      // ========== Body 系列（正文）==========
      bodyLarge: TextStyle(
        fontSize: AppTypography.sizeMD * fontScale,
        fontWeight: AppTypography.weightRegular,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: _textPrimaryDark, // 主要文字（大正文）
      ),
      bodyMedium: TextStyle(
        fontSize: AppTypography.sizeSM * fontScale,
        fontWeight: AppTypography.weightRegular,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingNormal,
        color: _textSecondaryDark, // 次要文字（应用描述）
      ),
      bodySmall: TextStyle(
        fontSize: AppTypography.sizeXS * fontScale,
        fontWeight: AppTypography.weightRegular,
        height: AppTypography.heightRelaxed,
        letterSpacing: AppTypography.spacingWide,
        color: _textSecondaryDark, // 次要文字（小正文）
      ),

      // ========== Label 系列（标签/按钮）==========
      labelLarge: TextStyle(
        fontSize: AppTypography.sizeSM * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingWide,
        color: colorScheme.onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: AppTypography.sizeXS * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingWide,
        color: _textTertiaryDark, // 辅助文字（标签）
      ),
      labelSmall: TextStyle(
        fontSize: AppTypography.sizeXXS * fontScale,
        fontWeight: AppTypography.weightMedium,
        height: AppTypography.heightNormal,
        letterSpacing: AppTypography.spacingWider,
        color: _textTertiaryDark, // 辅助文字（小标签）
      ),
    );
  }

  // ========== 完整主题构建 ==========

  /// Build light theme with complete text styles
  static ThemeData buildLightTheme(
    ColorScheme? dynamicColorScheme, {
    AppThemeConfig? config,
  }) {
    // 使用 ColorSchemeGenerator 生成 ColorScheme
    final colorScheme = ColorSchemeGenerator.generate(
      brightness: Brightness.light,
      config: config ?? AppThemeConfig.default_,
      dynamicColorScheme: dynamicColorScheme,
    );

    final fontScale = config?.fontScale ?? 1.0;
    final radiusScale = config?.radiusScale ?? 1.0;
    final borderWidth = config?.borderWidth ?? 1.0;
    final borderOpacity = config?.borderOpacity ?? 0.5;

    final textTheme = buildLightTextTheme(colorScheme, fontScale);

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      brightness: Brightness.light,
      textTheme: textTheme, // 完整的文字主题

      // 扁平化风格：使用 secondaryContainer 调淡 65% 的纯色作为背景
      scaffoldBackgroundColor: _lightenColor(colorScheme.secondaryContainer, 0.65),

      // App bar theme - 扁平化
      appBarTheme: AppBarTheme(
        centerTitle: false, // 标题在左侧
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: _lightenColor(colorScheme.secondaryContainer, 0.65),
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.headlineLarge, // 使用更大的标题字号
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarBrightness: Brightness.light,
          statusBarIconBrightness: Brightness.dark,
        ),
      ),

      // Card theme - 扁平化，无阴影，纯白
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          side: BorderSide(
            color: colorScheme.outlineVariant.withOpacity(borderOpacity),
            width: borderWidth,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.all(0),
      ),

      // Navigation bar theme
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _lightenColor(colorScheme.secondaryContainer, 0.65),
        elevation: 0,
        height: 80,
        indicatorColor: colorScheme.primaryContainer,
      ),

      // Navigation rail theme (for larger screens)
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: _lightenColor(colorScheme.secondaryContainer, 0.65),
        elevation: 0,
      ),

      // Elevated button theme - 扁平化
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: AppSpacing.onlyHorizontalMD,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          ),
          textStyle: textTheme.labelLarge,
          foregroundColor: colorScheme.onPrimary,
          backgroundColor: colorScheme.primary,
        ),
      ),

      // Outlined button theme
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: AppSpacing.onlyHorizontalMD,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          ),
          textStyle: textTheme.labelLarge,
          foregroundColor: colorScheme.primary,
          side: BorderSide(
            color: colorScheme.outline,
            width: borderWidth,
          ),
        ),
      ),

      // Text button theme
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: AppSpacing.onlyHorizontalMD,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          ),
          textStyle: textTheme.labelLarge,
          foregroundColor: colorScheme.primary,
        ),
      ),

      // Input decoration theme
      inputDecorationTheme: InputDecorationTheme(
        contentPadding: AppSpacing.allMD,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          borderSide: BorderSide(
            color: colorScheme.outline,
            width: borderWidth,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          borderSide: BorderSide(
            color: colorScheme.outline,
            width: borderWidth,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          borderSide: BorderSide(
            color: colorScheme.primary,
            width: borderWidth * 2,
          ),
        ),
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),

      // Dialog theme - 扁平化
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
        ),
        elevation: 0,
        backgroundColor: colorScheme.surface,
        titleTextStyle: textTheme.headlineSmall,
        contentTextStyle: textTheme.bodyMedium,
      ),

      // Bottom sheet theme - 扁平化
      bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl * radiusScale),
          ),
        ),
        elevation: 0,
        backgroundColor: colorScheme.surface,
        modalBackgroundColor: colorScheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
      ),

      // Divider theme
      dividerTheme: DividerThemeData(
        thickness: borderWidth,
        space: 1,
        color: colorScheme.outlineVariant.withOpacity(borderOpacity),
      ),

      // ListTile theme - 扁平化
      listTileTheme: ListTileThemeData(
        contentPadding: AppSpacing.horizontalLG_verticalMD,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
        ),
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodySmall,
      ),

      // Chip theme - 扁平化
      chipTheme: ChipThemeData(
        labelStyle: textTheme.labelMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          side: BorderSide.none,
        ),
        elevation: 0,
        backgroundColor: colorScheme.surfaceContainerHighest,
        selectedColor: colorScheme.primaryContainer,
      ),

      // Snack bar theme - 扁平化
      snackBarTheme: SnackBarThemeData(
        contentTextStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: colorScheme.surfaceContainerHigh,
      ),

      // Floating action button theme - 扁平化
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
        ),
      ),

      // Switch theme - 扁平化
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return colorScheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primaryContainer;
          }
          return colorScheme.surfaceContainerHighest;
        }),
      ),

      // Checkbox theme - 扁平化
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(colorScheme.onPrimary),
        side: BorderSide(
          color: colorScheme.outline,
          width: borderWidth,
        ),
      ),

      // Radio theme - 扁平化
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return Colors.transparent;
        }),
      ),
    );
  }

  /// Build dark theme with complete text styles
  static ThemeData buildDarkTheme(
    ColorScheme? dynamicColorScheme, {
    AppThemeConfig? config,
  }) {
    // 使用 ColorSchemeGenerator 生成 ColorScheme
    final colorScheme = ColorSchemeGenerator.generate(
      brightness: Brightness.dark,
      config: config ?? AppThemeConfig.default_,
      dynamicColorScheme: dynamicColorScheme,
    );

    final fontScale = config?.fontScale ?? 1.0;
    final radiusScale = config?.radiusScale ?? 1.0;
    final borderWidth = config?.borderWidth ?? 1.0;
    final borderOpacity = config?.borderOpacity ?? 0.3; // 暗色模式边框更透明

    final textTheme = buildDarkTextTheme(colorScheme, fontScale);

    return ThemeData(
      colorScheme: colorScheme,
      useMaterial3: true,
      brightness: Brightness.dark,
      textTheme: textTheme, // 完整的文字主题

      // 扁平化风格：使用 secondaryContainer 调淡 65% 的纯色作为背景
      scaffoldBackgroundColor: _darkenColor(colorScheme.secondaryContainer, 0.65),

      // App bar theme - 扁平化
      appBarTheme: AppBarTheme(
        centerTitle: false, // 标题在左侧
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: _darkenColor(colorScheme.secondaryContainer, 0.65),
        foregroundColor: colorScheme.onSurface,
        titleTextStyle: textTheme.headlineLarge, // 使用更大的标题字号
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarBrightness: Brightness.dark,
          statusBarIconBrightness: Brightness.light,
        ),
      ),

      // Card theme - 扁平化，无阴影，深色
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          side: BorderSide(
            color: colorScheme.outlineVariant.withOpacity(borderOpacity),
            width: borderWidth,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.all(0),
      ),

      // Navigation bar theme
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: _darkenColor(colorScheme.secondaryContainer, 0.65),
        elevation: 0,
        height: 80,
        indicatorColor: colorScheme.primaryContainer,
      ),

      // Navigation rail theme (for larger screens)
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: _darkenColor(colorScheme.secondaryContainer, 0.65),
        elevation: 0,
      ),

      // Elevated button theme - 扁平化
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: AppSpacing.onlyHorizontalMD,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          ),
          textStyle: textTheme.labelLarge,
          foregroundColor: colorScheme.onPrimary,
          backgroundColor: colorScheme.primary,
        ),
      ),

      // Outlined button theme
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: AppSpacing.onlyHorizontalMD,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          ),
          textStyle: textTheme.labelLarge,
          foregroundColor: colorScheme.primary,
          side: BorderSide(
            color: colorScheme.outline,
            width: borderWidth,
          ),
        ),
      ),

      // Text button theme
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: AppSpacing.onlyHorizontalMD,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          ),
          textStyle: textTheme.labelLarge,
          foregroundColor: colorScheme.primary,
        ),
      ),

      // Input decoration theme
      inputDecorationTheme: InputDecorationTheme(
        contentPadding: AppSpacing.allMD,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          borderSide: BorderSide(
            color: colorScheme.outline,
            width: borderWidth,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          borderSide: BorderSide(
            color: colorScheme.outline,
            width: borderWidth,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          borderSide: BorderSide(
            color: colorScheme.primary,
            width: borderWidth * 2,
          ),
        ),
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest,
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),

      // Dialog theme - 扁平化
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
        ),
        elevation: 0,
        backgroundColor: colorScheme.surfaceContainerLow,
        titleTextStyle: textTheme.headlineSmall,
        contentTextStyle: textTheme.bodyMedium,
      ),

      // Bottom sheet theme - 扁平化
      bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl * radiusScale),
          ),
        ),
        elevation: 0,
        backgroundColor: colorScheme.surfaceContainerLow,
        modalBackgroundColor: colorScheme.surface,
        clipBehavior: Clip.antiAlias,
      ),

      // Divider theme
      dividerTheme: DividerThemeData(
        thickness: borderWidth,
        space: 1,
        color: colorScheme.outlineVariant.withOpacity(borderOpacity),
      ),

      // ListTile theme - 扁平化
      listTileTheme: ListTileThemeData(
        contentPadding: AppSpacing.horizontalLG_verticalMD,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
        ),
        titleTextStyle: textTheme.titleMedium,
        subtitleTextStyle: textTheme.bodySmall,
      ),

      // Chip theme - 扁平化
      chipTheme: ChipThemeData(
        labelStyle: textTheme.labelMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
          side: BorderSide.none,
        ),
        elevation: 0,
        backgroundColor: colorScheme.surfaceContainerHighest,
        selectedColor: colorScheme.primaryContainer,
      ),

      // Snack bar theme - 扁平化
      snackBarTheme: SnackBarThemeData(
        contentTextStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: colorScheme.surfaceContainerHigh,
      ),

      // Floating action button theme - 扁平化
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_getRadiusValue(AppRadius.lg, radiusScale)),
        ),
      ),

      // Switch theme - 扁平化
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return colorScheme.outline;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primaryContainer;
          }
          return colorScheme.surfaceContainerHighest;
        }),
      ),

      // Checkbox theme - 扁平化
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(colorScheme.onPrimary),
        side: BorderSide(
          color: colorScheme.outline,
          width: borderWidth,
        ),
      ),

      // Radio theme - 扁平化
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return Colors.transparent;
        }),
      ),
    );
  }

  /// 根据缩放系数获取圆角值
  static double _getRadiusValue(double baseRadius, double scale) {
    if (scale == 0) return 0;
    if (scale == 1) return baseRadius;
    return baseRadius * scale;
  }

  /// 将颜色调淡（用于亮色模式）
  ///
  /// [color] 原始颜色
  /// [factor] 调淡系数 (0.0-1.0)，0.65 表示 65% 的淡化效果
  static Color _lightenColor(Color color, double factor) {
    assert(factor >= 0.0 && factor <= 1.0);

    final hsl = HSLColor.fromColor(color);
    // 通过提高亮度来模拟淡化效果
    // factor 越大，颜色越淡
    final lightness = hsl.lightness + (1.0 - hsl.lightness) * factor;

    return hsl.withLightness(lightness.clamp(0.0, 1.0)).toColor();
  }

  /// 将颜色调深（用于暗色模式）
  ///
  /// [color] 原始颜色
  /// [factor] 调深系数 (0.0-1.0)，0.65 表示 65% 的调深效果
  static Color _darkenColor(Color color, double factor) {
    assert(factor >= 0.0 && factor <= 1.0);

    final hsl = HSLColor.fromColor(color);
    // 通过降低亮度来模拟淡化效果（在暗色背景下）
    // factor 越大，颜色越接近背景色
    final lightness = hsl.lightness * (1.0 - factor);

    return hsl.withLightness(lightness.clamp(0.0, 1.0)).toColor();
  }
}

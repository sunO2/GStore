import 'package:flutter/material.dart';

/// 主题模式枚举
enum AppThemeMode {
  /// 跟随系统
  system,
  /// 浅色模式
  light,
  /// 深色模式
  dark;

  String get displayName {
    switch (this) {
      case AppThemeMode.system:
        return '跟随系统';
      case AppThemeMode.light:
        return '浅色模式';
      case AppThemeMode.dark:
        return '深色模式';
    }
  }

  ThemeMode toThemeMode() {
    switch (this) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }

  static AppThemeMode fromThemeMode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return AppThemeMode.system;
      case ThemeMode.light:
        return AppThemeMode.light;
      case ThemeMode.dark:
        return AppThemeMode.dark;
    }
  }
}

/// 自定义主题配置
///
/// 支持自定义主题颜色、字体风格、圆角等
/// 所有配置项都有默认值，null 表示使用动态色或设计令牌
class AppThemeConfig {
  /// 是否使用自定义颜色（false = 使用壁纸动态色）
  final bool useCustomColors;

  /// 自定义主色种子颜色
  final Color? seedColor;

  /// 自定义主色（直接设置，不生成调色板）
  final Color? primaryColor;

  /// 自定义次要色
  final Color? secondaryColor;

  /// 自定义第三色
  final Color? tertiaryColor;

  /// 字体风格
  final AppFontStyle fontStyle;

  /// 圆角风格
  final AppRadiusStyle radiusStyle;

  /// 边框风格
  final AppBorderStyle borderStyle;

  const AppThemeConfig({
    this.useCustomColors = false,
    this.seedColor,
    this.primaryColor,
    this.secondaryColor,
    this.tertiaryColor,
    this.fontStyle = AppFontStyle.default_,
    this.radiusStyle = AppRadiusStyle.default_,
    this.borderStyle = AppBorderStyle.default_,
  });

  /// 默认配置（使用动态色）
  static const AppThemeConfig default_ = AppThemeConfig();

  /// 从 JSON 创建
  factory AppThemeConfig.fromJson(Map<String, dynamic> json) {
    return AppThemeConfig(
      useCustomColors: json['useCustomColors'] ?? false,
      seedColor: json['seedColor'] != null
          ? Color(int.parse(json['seedColor'], radix: 16))
          : null,
      primaryColor: json['primaryColor'] != null
          ? Color(int.parse(json['primaryColor'], radix: 16))
          : null,
      secondaryColor: json['secondaryColor'] != null
          ? Color(int.parse(json['secondaryColor'], radix: 16))
          : null,
      tertiaryColor: json['tertiaryColor'] != null
          ? Color(int.parse(json['tertiaryColor'], radix: 16))
          : null,
      fontStyle: AppFontStyle.values[json['fontStyle'] ?? 0],
      radiusStyle: AppRadiusStyle.values[json['radiusStyle'] ?? 0],
      borderStyle: AppBorderStyle.values[json['borderStyle'] ?? 0],
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'useCustomColors': useCustomColors,
      'seedColor': seedColor?.value.toRadixString(16).padLeft(8, '0'),
      'primaryColor': primaryColor?.value.toRadixString(16).padLeft(8, '0'),
      'secondaryColor': secondaryColor?.value.toRadixString(16).padLeft(8, '0'),
      'tertiaryColor': tertiaryColor?.value.toRadixString(16).padLeft(8, '0'),
      'fontStyle': fontStyle.index,
      'radiusStyle': radiusStyle.index,
      'borderStyle': borderStyle.index,
    };
  }

  /// 复制并修改部分属性
  AppThemeConfig copyWith({
    bool? useCustomColors,
    Color? seedColor,
    Color? primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
    AppFontStyle? fontStyle,
    AppRadiusStyle? radiusStyle,
    AppBorderStyle? borderStyle,
  }) {
    return AppThemeConfig(
      useCustomColors: useCustomColors ?? this.useCustomColors,
      seedColor: seedColor ?? this.seedColor,
      primaryColor: primaryColor ?? this.primaryColor,
      secondaryColor: secondaryColor ?? this.secondaryColor,
      tertiaryColor: tertiaryColor ?? this.tertiaryColor,
      fontStyle: fontStyle ?? this.fontStyle,
      radiusStyle: radiusStyle ?? this.radiusStyle,
      borderStyle: borderStyle ?? this.borderStyle,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppThemeConfig &&
        other.useCustomColors == useCustomColors &&
        other.seedColor == seedColor &&
        other.primaryColor == primaryColor &&
        other.secondaryColor == secondaryColor &&
        other.tertiaryColor == tertiaryColor &&
        other.fontStyle == fontStyle &&
        other.radiusStyle == radiusStyle &&
        other.borderStyle == borderStyle;
  }

  @override
  int get hashCode {
    return Object.hash(
      useCustomColors,
      seedColor,
      primaryColor,
      secondaryColor,
      tertiaryColor,
      fontStyle,
      radiusStyle,
      borderStyle,
    );
  }
}

/// 字体风格枚举
enum AppFontStyle {
  /// 默认（设计令牌）
  default_,

  /// 紧凑（小字号，紧凑行高）
  compact,

  /// 标准（默认）
  standard,

  /// 宽松（大字号，宽松行高）
  spacious,

  /// 大号（无障碍）
  large;
}

/// 圆角风格枚举
enum AppRadiusStyle {
  /// 默认（设计令牌）
  default_,

  /// 方形（无圆角）
  square,

  /// 轻微圆角（小圆角）
  slight,

  /// 标准（默认）
  standard,

  /// 圆润（大圆角）
  rounded,

  /// 圆形（最大圆角）
  circular;
}

/// 边框风格枚举
enum AppBorderStyle {
  /// 默认（设计令牌）
  default_,

  /// 无边框
  none,

  /// 轻细（细边框，低透明度）
  light,

  /// 标准（默认）
  standard,

  /// 粗犷（粗边框，高透明度）
  bold;
}

/// 主题配置扩展
extension AppThemeConfigExtension on AppThemeConfig {
  /// 获取缩放系数
  double get fontScale {
    switch (fontStyle) {
      case AppFontStyle.default_:
      case AppFontStyle.standard:
        return 1.0;
      case AppFontStyle.compact:
        return 0.9;
      case AppFontStyle.spacious:
        return 1.1;
      case AppFontStyle.large:
        return 1.2;
    }
  }

  /// 获取圆角缩放系数
  double get radiusScale {
    switch (radiusStyle) {
      case AppRadiusStyle.default_:
      case AppRadiusStyle.standard:
        return 1.0;
      case AppRadiusStyle.square:
        return 0.0;
      case AppRadiusStyle.slight:
        return 0.5;
      case AppRadiusStyle.rounded:
        return 1.5;
      case AppRadiusStyle.circular:
        return 2.0;
    }
  }

  /// 获取边框宽度
  double get borderWidth {
    switch (borderStyle) {
      case AppBorderStyle.default_:
      case AppBorderStyle.standard:
        return 1.0;
      case AppBorderStyle.none:
        return 0.0;
      case AppBorderStyle.light:
        return 0.5;
      case AppBorderStyle.bold:
        return 1.5;
    }
  }

  /// 获取边框透明度
  double get borderOpacity {
    switch (borderStyle) {
      case AppBorderStyle.default_:
      case AppBorderStyle.standard:
        return 0.6;
      case AppBorderStyle.none:
        return 0.0;
      case AppBorderStyle.light:
        return 0.3;
      case AppBorderStyle.bold:
        return 0.7;
    }
  }
}

/// ColorScheme 生成器
class ColorSchemeGenerator {
  /// 生成 ColorScheme
  static ColorScheme generate({
    required Brightness brightness,
    required AppThemeConfig config,
    ColorScheme? dynamicColorScheme,
  }) {
    // 如果使用自定义颜色
    if (config.useCustomColors) {
      // 如果指定了主色，直接使用
      if (config.primaryColor != null) {
        return _generateCustomColorScheme(
          brightness: brightness,
          primaryColor: config.primaryColor!,
          secondaryColor: config.secondaryColor,
          tertiaryColor: config.tertiaryColor,
        );
      }

      // 如果指定了种子色，从种子色生成
      if (config.seedColor != null) {
        return ColorScheme.fromSeed(
          seedColor: config.seedColor!,
          brightness: brightness,
        );
      }
    }

    // 使用动态色（壁纸提取的颜色）
    return dynamicColorScheme ??
        ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: brightness,
        );
  }

  /// 生成自定义 ColorScheme（直接指定颜色）
  static ColorScheme _generateCustomColorScheme({
    required Brightness brightness,
    required Color primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
  }) {
    // 使用 fromSeed 从主色生成完整的 Material 3 色系
    // 这样可以确保 secondaryContainer 等容器色有丰富的色阶
    final baseScheme = ColorScheme.fromSeed(
      seedColor: primaryColor,
      brightness: brightness,
    );

    // 如果用户指定了 secondary 或 tertiary，需要覆盖默认值
    // 但保留其他 Material 3 自动生成的颜色
    if (secondaryColor == null && tertiaryColor == null) {
      // 没有自定义 secondary/tertiary，直接使用生成的完整色板
      return baseScheme;
    }

    // 有自定义颜色，从 seedColor 生成并覆盖
    // 注意：fromSeed 会生成完整的色板，我们只需要覆盖指定的颜色
    return ColorScheme.fromSeed(
      seedColor: primaryColor,
      secondary: secondaryColor,
      tertiary: tertiaryColor,
      brightness: brightness,
    );
  }
}

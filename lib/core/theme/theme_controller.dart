import 'package:flutter/material.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_state_store.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// Theme controller 门面（兼容 IThemeService）。
///
/// 权威状态在 [ThemeStateStore]；本类仅转发调用，不再持有第二份状态。
class ThemeController implements IThemeService {
  static ThemeController? _instance;

  static ThemeController get instance => _instance ??= ThemeController();

  /// 测试可自由构造自建实例；生产统一走 [instance]
  ThemeController();

  /// The current theme mode
  @override
  AppThemeMode get themeMode => ThemeStateStore.instance.state.value.mode;

  /// The ThemeMode value for MaterialApp
  ThemeMode get themeModeValue => themeMode.toThemeMode();

  /// The current theme config
  @override
  AppThemeConfig get themeConfig => ThemeStateStore.instance.state.value.config;

  /// 模块初始化时调用：交给共享存储幂等初始化。
  void initialize() {
    ThemeStateStore.instance.initialize();
  }

  /// Set the theme mode and persist it
  @override
  Future<void> setThemeMode(AppThemeMode mode) {
    return ThemeStateStore.instance.setThemeMode(mode);
  }

  /// Set the theme config and persist it
  Future<void> setThemeConfig(AppThemeConfig config) {
    return ThemeStateStore.instance.setThemeConfig(config);
  }

  /// Toggle between light and dark mode
  /// If currently in system mode, switch to light
  @override
  Future<void> toggleTheme() {
    return ThemeStateStore.instance.toggleTheme();
  }

  /// 重置为主题默认配置（使用动态色）
  @override
  Future<void> resetToDefault() {
    return ThemeStateStore.instance.resetToDefault();
  }

  /// 设置自定义颜色主题
  @override
  Future<void> setCustomColorTheme({
    required Color primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
  }) {
    return ThemeStateStore.instance.setCustomColorTheme(
      primaryColor: primaryColor,
      secondaryColor: secondaryColor,
      tertiaryColor: tertiaryColor,
    );
  }

  /// 设置字体风格
  Future<void> setFontStyle(AppFontStyle fontStyle) {
    return ThemeStateStore.instance.setFontStyle(fontStyle);
  }

  /// 设置圆角风格
  Future<void> setRadiusStyle(AppRadiusStyle radiusStyle) {
    return ThemeStateStore.instance.setRadiusStyle(radiusStyle);
  }

  /// 设置边框风格
  Future<void> setBorderStyle(AppBorderStyle borderStyle) {
    return ThemeStateStore.instance.setBorderStyle(borderStyle);
  }

  /// 切换是否使用自定义颜色
  Future<void> toggleCustomColors() {
    return ThemeStateStore.instance.toggleCustomColors();
  }

  /// 门面释放：共享存储保持存活，无本地资源需清理。
  void dispose() {}
}

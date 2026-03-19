import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/config/providers/theme_config_provider.dart';

/// Theme controller for managing app theme persistence and customization
/// Uses ConfigProvider system to store the user's theme preference
class ThemeController extends GetxController {
  final Rx<AppThemeMode> _themeMode = AppThemeMode.system.obs;
  final Rx<AppThemeConfig> _themeConfig = AppThemeConfig.default_.obs;

  // 配置提供者（延迟加载）
  final _themeConfigProvider = Rxn<ThemeConfigProvider>();

  /// 获取主题配置提供者
  ThemeConfigProvider get _provider {
    _themeConfigProvider.value ??= ConfigInitializer.getThemeConfigProvider();
    return _themeConfigProvider.value!;
  }

  /// The current theme mode
  AppThemeMode get themeMode => _themeMode.value;

  /// The ThemeMode value for MaterialApp
  ThemeMode get themeModeValue => _themeMode.value.toThemeMode();

  /// Stream of theme mode changes
  Rx<AppThemeMode> get themeModeStream => _themeMode;

  /// The current theme config
  AppThemeConfig get themeConfig => _themeConfig.value;

  /// Stream of theme config changes
  Rx<AppThemeConfig> get themeConfigStream => _themeConfig;

  @override
  void onInit() {
    super.onInit();
    _loadThemeMode();
    _loadThemeConfig();

    // 直接订阅配置变化（不使用 ever，因为 provider 可能已经初始化）
    _subscribeToConfigChanges(_provider);
  }

  /// 订阅配置变化
  void _subscribeToConfigChanges(ThemeConfigProvider provider) {
    // 监听主题配置变化
    provider.themeConfigStream.listen((config) {
      _themeConfig.value = config;
    });

    // 监听主题模式变化
    provider.watchMode().listen((mode) {
      _themeMode.value = mode;
    });
  }

  /// Load the saved theme mode from ThemeConfigProvider
  Future<void> _loadThemeMode() async {
    try {
      final mode = await _provider.loadMode();
      if (mode != null) {
        _themeMode.value = mode;
      }
    } catch (e) {
      // If loading fails, default to system theme
      _themeMode.value = AppThemeMode.system;
    }
  }

  /// Load the saved theme config from ThemeConfigProvider
  Future<void> _loadThemeConfig() async {
    try {
      final config = await _provider.load();
      if (config != null) {
        _themeConfig.value = config;
      }
    } catch (e) {
      // If loading fails, default to default config
      _themeConfig.value = AppThemeConfig.default_;
    }
  }

  /// Set the theme mode and persist it
  Future<void> setThemeMode(AppThemeMode mode) async {
    await _provider.saveMode(mode);
    _themeMode.value = mode;
  }

  /// Set the theme config and persist it
  Future<void> setThemeConfig(AppThemeConfig config) async {
    await _provider.save(config);
    _themeConfig.value = config;
  }

  /// Toggle between light and dark mode
  /// If currently in system mode, switch to light
  Future<void> toggleTheme() async {
    final newMode = switch (_themeMode.value) {
      AppThemeMode.system => AppThemeMode.light,
      AppThemeMode.light => AppThemeMode.dark,
      AppThemeMode.dark => AppThemeMode.light,
    };
    await setThemeMode(newMode);
  }

  /// 重置为主题默认配置（使用动态色）
  Future<void> resetToDefault() async {
    await _provider.resetToDefault();
    _themeConfig.value = AppThemeConfig.default_;
  }

  /// 设置自定义颜色主题
  Future<void> setCustomColorTheme({
    required Color primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
  }) async {
    // Provider 会创建配置并保存，更新会通过订阅自动同步
    await _provider.setCustomColorTheme(
      primaryColor: primaryColor,
      secondaryColor: secondaryColor,
      tertiaryColor: tertiaryColor,
    );
  }

  /// 设置字体风格
  Future<void> setFontStyle(AppFontStyle fontStyle) async {
    await _provider.setFontStyle(fontStyle);
    // 更新会通过订阅自动同步
  }

  /// 设置圆角风格
  Future<void> setRadiusStyle(AppRadiusStyle radiusStyle) async {
    await _provider.setRadiusStyle(radiusStyle);
    // 更新会通过订阅自动同步
  }

  /// 设置边框风格
  Future<void> setBorderStyle(AppBorderStyle borderStyle) async {
    await _provider.setBorderStyle(borderStyle);
    // 更新会通过订阅自动同步
  }

  /// 切换是否使用自定义颜色
  Future<void> toggleCustomColors() async {
    // 只调用 provider 的方法，它会自动保存并触发更新
    // 更新会通过 _subscribeToConfigChanges 中的订阅同步到 _themeConfig
    await _provider.toggleCustomColors();
  }
}

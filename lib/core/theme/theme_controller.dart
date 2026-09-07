import 'dart:async';
import 'package:flutter/material.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/providers/theme_config_provider.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// Theme controller for managing app theme persistence and customization
/// Uses ConfigProvider system to store the user's theme preference
class ThemeController implements IThemeService {
  static ThemeController? _instance;

  static ThemeController get instance => _instance ??= ThemeController();

  /// 测试可自由构造自建实例；生产统一走 [instance]
  ThemeController();

  AppThemeMode _themeMode = AppThemeMode.system;
  AppThemeConfig _themeConfig = AppThemeConfig.default_;

  // 配置提供者（延迟加载）
  ThemeConfigProvider? _themeConfigProvider;

  /// 订阅集合（dispose 时清理）
  final List<StreamSubscription> _subscriptions = [];

  /// 获取主题配置提供者
  ThemeConfigProvider get _provider {
    _themeConfigProvider ??= ConfigInitializer.getThemeConfigProvider();
    return _themeConfigProvider!;
  }

  /// The current theme mode
  @override
  AppThemeMode get themeMode => _themeMode;

  /// The ThemeMode value for MaterialApp
  ThemeMode get themeModeValue => _themeMode.toThemeMode();

  /// The current theme config
  @override
  AppThemeConfig get themeConfig => _themeConfig;

  /// 模块初始化时调用（替代 GetX onInit）：加载持久化配置并订阅变化
  void initialize() {
    _loadThemeMode();
    _loadThemeConfig();

    // 直接订阅配置变化（不使用 ever，因为 provider 可能已经初始化）
    // provider 未注册（如测试环境）时容错跳过，ConfigService 订阅始终生效
    try {
      _subscribeToConfigChanges(_provider);
    } catch (_) {
      // ConfigInitializer 未初始化时跳过 provider 订阅
    }

    // 订阅统一 ConfigService：Agent/外部写入配置后主动响应
    _subscribeToConfigService();
  }

  /// 订阅配置变化
  void _subscribeToConfigChanges(ThemeConfigProvider provider) {
    // 监听主题配置变化
    _subscriptions.add(
      provider.themeConfigStream.listen((config) {
        _themeConfig = config;
      }),
    );

    // 监听主题模式变化
    _subscriptions.add(
      provider.watchMode().listen((mode) {
        _themeMode = mode;
      }),
    );
  }

  /// 订阅统一 ConfigService 变化（配置写入 → 主题主动响应）
  void _subscribeToConfigService() {
    _subscriptions.add(
      ConfigService.instance.onChange.listen((event) {
        switch (event.key) {
          case ConfigKeys.themeMode:
            final v = event.newValue;
            if (v is int && v >= 0 && v < AppThemeMode.values.length) {
              _themeMode = AppThemeMode.values[v];
            }
          case ConfigKeys.themeConfig:
            final v = event.newValue;
            if (v is Map<String, dynamic>) {
              try {
                _themeConfig = AppThemeConfig.fromJson(v);
              } catch (_) {
                // 解析失败保持当前配置
              }
            }
        }
      }),
    );
  }

  /// Load the saved theme mode from ThemeConfigProvider
  Future<void> _loadThemeMode() async {
    try {
      final mode = await _provider.loadMode();
      if (mode != null) {
        _themeMode = mode;
      }
    } catch (e) {
      // If loading fails, default to system theme
      _themeMode = AppThemeMode.system;
    }
  }

  /// Load the saved theme config from ThemeConfigProvider
  Future<void> _loadThemeConfig() async {
    try {
      final config = await _provider.load();
      if (config != null) {
        _themeConfig = config;
      }
    } catch (e) {
      // If loading fails, default to default config
      _themeConfig = AppThemeConfig.default_;
    }
  }

  /// Set the theme mode and persist it
  @override
  Future<void> setThemeMode(AppThemeMode mode) async {
    await ConfigService.instance.set(
      ConfigKeys.themeMode,
      mode.index,
      source: ConfigChangeSource.user,
    );
    _themeMode = mode;
  }

  /// Set the theme config and persist it
  Future<void> setThemeConfig(AppThemeConfig config) async {
    await ConfigService.instance.set(
      ConfigKeys.themeConfig,
      config.toJson(),
      source: ConfigChangeSource.user,
    );
    _themeConfig = config;
  }

  /// Toggle between light and dark mode
  /// If currently in system mode, switch to light
  @override
  Future<void> toggleTheme() async {
    final newMode = switch (_themeMode) {
      AppThemeMode.system => AppThemeMode.light,
      AppThemeMode.light => AppThemeMode.dark,
      AppThemeMode.dark => AppThemeMode.light,
    };
    await setThemeMode(newMode);
  }

  /// 重置为主题默认配置（使用动态色）
  @override
  Future<void> resetToDefault() async {
    await ConfigService.instance.reset(
      ConfigKeys.themeConfig,
      source: ConfigChangeSource.user,
    );
    await ConfigService.instance.set(
      ConfigKeys.themeMode,
      AppThemeMode.system.index,
      source: ConfigChangeSource.user,
    );
    _themeConfig = AppThemeConfig.default_;
    _themeMode = AppThemeMode.system;
  }

  /// 设置自定义颜色主题
  @override
  Future<void> setCustomColorTheme({
    required Color primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
  }) async {
    final config = AppThemeConfig(
      useCustomColors: true,
      primaryColor: primaryColor,
      secondaryColor: secondaryColor,
      tertiaryColor: tertiaryColor,
      fontStyle: _themeConfig.fontStyle,
      radiusStyle: _themeConfig.radiusStyle,
      borderStyle: _themeConfig.borderStyle,
    );
    await setThemeConfig(config);
  }

  /// 设置字体风格
  Future<void> setFontStyle(AppFontStyle fontStyle) async {
    await setThemeConfig(_themeConfig.copyWith(fontStyle: fontStyle));
  }

  /// 设置圆角风格
  Future<void> setRadiusStyle(AppRadiusStyle radiusStyle) async {
    await setThemeConfig(_themeConfig.copyWith(radiusStyle: radiusStyle));
  }

  /// 设置边框风格
  Future<void> setBorderStyle(AppBorderStyle borderStyle) async {
    await setThemeConfig(_themeConfig.copyWith(borderStyle: borderStyle));
  }

  /// 切换是否使用自定义颜色
  Future<void> toggleCustomColors() async {
    final newValue = !_themeConfig.useCustomColors;
    await setThemeConfig(_themeConfig.copyWith(useCustomColors: newValue));
  }

  /// 释放订阅（模块下线/测试重置时调用）
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }
}

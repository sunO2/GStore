import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// Theme controller for managing app theme persistence and customization
/// Uses the unified ConfigService to store the user's theme preference
class ThemeController implements IThemeService {
  static ThemeController? _instance;

  static ThemeController get instance => _instance ??= ThemeController();

  /// 测试可自由构造自建实例；生产统一走 [instance]
  ThemeController();

  AppThemeMode _themeMode = AppThemeMode.system;
  AppThemeConfig _themeConfig = AppThemeConfig.default_;

  /// 订阅集合（dispose 时清理）
  final List<StreamSubscription> _subscriptions = [];

  /// 状态世代：显式写入 / 外部事件应用自增；启动异步读取仅在世代未变化
  ///（且未 dispose）时落地，避免晚到初值覆盖更新写入。
  int _stateGeneration = 0;
  bool _disposed = false;

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
    _disposed = false;
    _stateGeneration = 0;
    _loadThemeMode();
    _loadThemeConfig();

    // 订阅统一 ConfigService：Agent/外部写入配置后主动响应
    _subscribeToConfigService();
  }

  /// 订阅统一 ConfigService 变化（配置写入 → 主题主动响应）
  void _subscribeToConfigService() {
    _subscriptions.add(
      ConfigService.instance.onChange.listen((event) {
        switch (event.key) {
          case ConfigKeys.themeMode:
            final mode = _modeFromValue(event.newValue);
            if (mode != null) {
              _stateGeneration++;
              _themeMode = mode;
            }
          case ConfigKeys.themeConfig:
            final config = _parseThemeConfig(event.newValue);
            if (config != null) {
              _stateGeneration++;
              _themeConfig = config;
            }
        }
      }),
    );
  }

  bool _canApply(int generation) =>
      !_disposed && generation == _stateGeneration;

  /// 从 ConfigService 加载持久化主题模式
  Future<void> _loadThemeMode() async {
    final generation = _stateGeneration;
    try {
      final mode = _modeFromValue(
        await ConfigService.instance.getRaw(ConfigKeys.themeMode),
      );
      if (!_canApply(generation)) return;
      if (mode != null) {
        _themeMode = mode;
      }
    } catch (e) {
      if (!_canApply(generation)) return;
      // If loading fails, default to system theme
      _themeMode = AppThemeMode.system;
    }
  }

  /// 从 ConfigService 加载持久化主题配置
  Future<void> _loadThemeConfig() async {
    final generation = _stateGeneration;
    try {
      final config = _parseThemeConfig(
        await ConfigService.instance.getRaw(ConfigKeys.themeConfig),
      );
      if (!_canApply(generation)) return;
      if (config != null) {
        _themeConfig = config;
      }
    } catch (e) {
      if (!_canApply(generation)) return;
      // If loading fails, default to default config
      _themeConfig = AppThemeConfig.default_;
    }
  }

  static AppThemeMode? _modeFromValue(Object? value) {
    if (value is int && value >= 0 && value < AppThemeMode.values.length) {
      return AppThemeMode.values[value];
    }
    return null;
  }

  /// 宽容解析主题 JSON；格式损坏时返回 null（保持当前状态）。
  static AppThemeConfig? _parseThemeConfig(Object? value) {
    Object? decoded = value;
    if (decoded is String) {
      if (decoded.trim().isEmpty) return null;
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return null;
      }
    }
    if (decoded is! Map) return null;
    try {
      return AppThemeConfig.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  /// Set the theme mode and persist it
  @override
  Future<void> setThemeMode(AppThemeMode mode) async {
    _stateGeneration++;
    await ConfigService.instance.set(
      ConfigKeys.themeMode,
      mode.index,
      source: ConfigChangeSource.user,
    );
    _themeMode = mode;
  }

  /// Set the theme config and persist it
  Future<void> setThemeConfig(AppThemeConfig config) async {
    _stateGeneration++;
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
    _stateGeneration++;
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
    _disposed = true;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
  }
}

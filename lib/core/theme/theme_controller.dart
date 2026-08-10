import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/providers/theme_config_provider.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// Theme controller for managing app theme persistence and customization
/// Uses ConfigProvider system to store the user's theme preference
class ThemeController extends GetxController implements IThemeService {
  final Rx<AppThemeMode> _themeMode = AppThemeMode.system.obs;
  final Rx<AppThemeConfig> _themeConfig = AppThemeConfig.default_.obs;

  // 配置提供者（延迟加载）
  final _themeConfigProvider = Rxn<ThemeConfigProvider>();

  /// 订阅集合（dispose 时清理）
  final List<StreamSubscription> _subscriptions = [];

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
        _themeConfig.value = config;
      }),
    );

    // 监听主题模式变化
    _subscriptions.add(
      provider.watchMode().listen((mode) {
        _themeMode.value = mode;
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
              _themeMode.value = AppThemeMode.values[v];
            }
          case ConfigKeys.themeConfig:
            final v = event.newValue;
            if (v is Map<String, dynamic>) {
              try {
                _themeConfig.value = AppThemeConfig.fromJson(v);
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
    await ConfigService.instance.set(
      ConfigKeys.themeMode,
      mode.index,
      source: ConfigChangeSource.user,
    );
    _themeMode.value = mode;
  }

  /// Set the theme config and persist it
  Future<void> setThemeConfig(AppThemeConfig config) async {
    await ConfigService.instance.set(
      ConfigKeys.themeConfig,
      config.toJson(),
      source: ConfigChangeSource.user,
    );
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
    await ConfigService.instance.reset(
      ConfigKeys.themeConfig,
      source: ConfigChangeSource.user,
    );
    await ConfigService.instance.set(
      ConfigKeys.themeMode,
      AppThemeMode.system.index,
      source: ConfigChangeSource.user,
    );
    _themeConfig.value = AppThemeConfig.default_;
    _themeMode.value = AppThemeMode.system;
  }

  /// 设置自定义颜色主题
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
      fontStyle: _themeConfig.value.fontStyle,
      radiusStyle: _themeConfig.value.radiusStyle,
      borderStyle: _themeConfig.value.borderStyle,
    );
    await setThemeConfig(config);
  }

  /// 设置字体风格
  Future<void> setFontStyle(AppFontStyle fontStyle) async {
    await setThemeConfig(_themeConfig.value.copyWith(fontStyle: fontStyle));
  }

  /// 设置圆角风格
  Future<void> setRadiusStyle(AppRadiusStyle radiusStyle) async {
    await setThemeConfig(_themeConfig.value.copyWith(radiusStyle: radiusStyle));
  }

  /// 设置边框风格
  Future<void> setBorderStyle(AppBorderStyle borderStyle) async {
    await setThemeConfig(_themeConfig.value.copyWith(borderStyle: borderStyle));
  }

  /// 切换是否使用自定义颜色
  Future<void> toggleCustomColors() async {
    final newValue = !_themeConfig.value.useCustomColors;
    await setThemeConfig(_themeConfig.value.copyWith(useCustomColors: newValue));
  }

  @override
  void onClose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    super.onClose();
  }
}

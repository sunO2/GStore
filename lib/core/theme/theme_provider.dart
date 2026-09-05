import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/config/config_initializer.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/providers/theme_config_provider.dart';
import 'package:gstore/core/theme/app_theme_config.dart';

/// 主题运行时状态（Riverpod 主状态源）。
class ThemeState {
  const ThemeState({
    this.mode = AppThemeMode.system,
    this.config = AppThemeConfig.default_,
  });

  final AppThemeMode mode;
  final AppThemeConfig config;

  /// MaterialApp 用的 ThemeMode。
  ThemeMode get themeModeValue => mode.toThemeMode();

  ThemeState copyWith({AppThemeMode? mode, AppThemeConfig? config}) {
    return ThemeState(
      mode: mode ?? this.mode,
      config: config ?? this.config,
    );
  }
}

/// 主题逻辑（Riverpod Notifier）
///
/// 权威状态 = 本 Notifier；持久化 = ConfigService（写 → ThemeConfigProvider
/// save → onChange 广播）。启动时从 ThemeConfigProvider 读持久化值，
/// 之后订阅 ConfigService.onChange：Agent / GetX 兼容壳 / 备份恢复等
/// 外部写入统一经 onChange 回流同步到本状态。
class ThemeNotifier extends Notifier<ThemeState> {
  StreamSubscription<ConfigChangeEvent>? _configSub;

  ThemeConfigProvider get _provider {
    // 配置系统启动前（测试/首帧）可能未注册 → 兜底默认
    try {
      return ConfigInitializer.getThemeConfigProvider();
    } catch (_) {
      throw StateError(
        'ThemeConfigProvider 未注册（ConfigInitializer.initialize() 未调用）',
      );
    }
  }

  @override
  ThemeState build() {
    // 异步读取持久化初值（provider 未就绪时保持默认，读取成功后更新）
    _loadPersisted();
    // 订阅统一 ConfigService：Agent/外部写入配置后主动响应
    _configSub = ConfigService.instance.onChange.listen(_onConfigChange);
    ref.onDispose(() => _configSub?.cancel());
    return const ThemeState();
  }

  Future<void> _loadPersisted() async {
    try {
      final provider = _provider;
      final mode = await provider.loadMode();
      final config = await provider.load();
      state = ThemeState(
        mode: mode ?? AppThemeMode.system,
        config: config ?? AppThemeConfig.default_,
      );
    } catch (_) {
      // 读取失败保持默认
    }
  }

  /// 配置写入事件 → 同步主题状态（外部写入的唯一收敛入口）。
  void _onConfigChange(ConfigChangeEvent event) {
    switch (event.key) {
      case ConfigKeys.themeMode:
        final v = event.newValue;
        if (v is int && v >= 0 && v < AppThemeMode.values.length) {
          state = state.copyWith(mode: AppThemeMode.values[v]);
        }
      case ConfigKeys.themeConfig:
        final v = event.newValue;
        if (v is Map<String, dynamic>) {
          try {
            state = state.copyWith(config: AppThemeConfig.fromJson(v));
          } catch (_) {
            // 解析失败保持当前配置
          }
        }
    }
  }

  /// 设置主题模式并持久化。
  Future<void> setThemeMode(AppThemeMode mode) async {
    await ConfigService.instance.set(
      ConfigKeys.themeMode,
      mode.index,
      source: ConfigChangeSource.user,
    );
    // 立即生效（onChange 为异步 broadcast，避免 UI 延迟一帧）
    state = state.copyWith(mode: mode);
  }

  /// 设置主题配置并持久化。
  Future<void> setThemeConfig(AppThemeConfig config) async {
    await ConfigService.instance.set(
      ConfigKeys.themeConfig,
      config.toJson(),
      source: ConfigChangeSource.user,
    );
    state = state.copyWith(config: config);
  }

  /// 切换深浅色（system → light → dark → light）。
  Future<void> toggleTheme() async {
    final newMode = switch (state.mode) {
      AppThemeMode.system => AppThemeMode.light,
      AppThemeMode.light => AppThemeMode.dark,
      AppThemeMode.dark => AppThemeMode.light,
    };
    await setThemeMode(newMode);
  }

  /// 重置为主题默认配置（使用动态色 + 跟随系统）。
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
    state = const ThemeState();
  }

  /// 设置自定义颜色主题。
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
      fontStyle: state.config.fontStyle,
      radiusStyle: state.config.radiusStyle,
      borderStyle: state.config.borderStyle,
    );
    await setThemeConfig(config);
  }

  /// 设置字体风格。
  Future<void> setFontStyle(AppFontStyle fontStyle) async {
    await setThemeConfig(state.config.copyWith(fontStyle: fontStyle));
  }

  /// 设置圆角风格。
  Future<void> setRadiusStyle(AppRadiusStyle radiusStyle) async {
    await setThemeConfig(state.config.copyWith(radiusStyle: radiusStyle));
  }

  /// 设置边框风格。
  Future<void> setBorderStyle(AppBorderStyle borderStyle) async {
    await setThemeConfig(state.config.copyWith(borderStyle: borderStyle));
  }

  /// 切换是否使用自定义颜色。
  Future<void> toggleCustomColors() async {
    await setThemeConfig(
      state.config.copyWith(useCustomColors: !state.config.useCustomColors),
    );
  }
}

/// 主题 Provider（权威运行时状态）。
final themeProvider = NotifierProvider<ThemeNotifier, ThemeState>(
  ThemeNotifier.new,
);

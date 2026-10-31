import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
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
/// 权威状态 = 本 Notifier；持久化 = ConfigService（`theme.mode` /
/// `theme.config`）。启动时从 ConfigService 读持久化值，之后订阅
/// ConfigService.onChange：Agent / GetX 兼容壳 / 备份恢复等外部写入统一经
/// onChange 回流同步到本状态。
class ThemeNotifier extends Notifier<ThemeState> {
  StreamSubscription<ConfigChangeEvent>? _configSub;

  /// 状态世代：每次显式写入 / 外部事件应用都自增；启动异步读取只在世代
  /// 未变化时落地，避免晚到的初值覆盖更新的写入。
  int _stateGeneration = 0;
  bool _disposed = false;

  @override
  ThemeState build() {
    _disposed = false;
    _stateGeneration = 0;
    // 异步读取持久化初值（配置系统未就绪时保持默认，读取成功后更新）
    _loadPersisted();
    // 订阅统一 ConfigService：Agent/外部写入配置后主动响应
    _configSub = ConfigService.instance.onChange.listen(_onConfigChange);
    ref.onDispose(() {
      _disposed = true;
      _configSub?.cancel();
    });
    return const ThemeState();
  }

  /// 该次启动读取是否仍可落地（未被更新写入/销毁超越）。
  bool _canApply(int generation) =>
      !_disposed && generation == _stateGeneration;

  Future<void> _loadPersisted() async {
    final generation = _stateGeneration;
    try {
      final service = ConfigService.instance;
      final modeValue = await service.getRaw(ConfigKeys.themeMode);
      final configValue = await service.getRaw(ConfigKeys.themeConfig);
      if (!_canApply(generation)) return;

      final mode = _modeFromValue(modeValue);
      final config = _parseThemeConfig(configValue);
      if (mode == null && config == null) return;
      state = state.copyWith(mode: mode, config: config);
    } catch (_) {
      // 读取失败保持默认
    }
  }

  /// 配置写入事件 → 同步主题状态（外部写入的唯一收敛入口）。
  void _onConfigChange(ConfigChangeEvent event) {
    switch (event.key) {
      case ConfigKeys.themeMode:
        final mode = _modeFromValue(event.newValue);
        if (mode != null) {
          _stateGeneration++;
          state = state.copyWith(mode: mode);
        }
      case ConfigKeys.themeConfig:
        final config = _parseThemeConfig(event.newValue);
        if (config != null) {
          _stateGeneration++;
          state = state.copyWith(config: config);
        }
    }
  }

  static AppThemeMode? _modeFromValue(Object? value) {
    if (value is int && value >= 0 && value < AppThemeMode.values.length) {
      return AppThemeMode.values[value];
    }
    return null;
  }

  /// 宽容解析主题 JSON：Map 或 JSON 字符串；格式损坏时返回 null（保持旧状态）。
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
      // 字段损坏（如非法颜色/枚举索引）→ 保持当前配置
      return null;
    }
  }

  /// 设置主题模式并持久化。
  Future<void> setThemeMode(AppThemeMode mode) async {
    _stateGeneration++;
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
    _stateGeneration++;
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

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_config_normalizer.dart';

/// 主题运行时状态（共享权威状态快照）。
class ThemeState {
  const ThemeState({
    this.mode = AppThemeMode.system,
    this.config = AppThemeConfig.default_,
  });

  /// 当前主题模式。
  final AppThemeMode mode;

  /// 当前主题配置。
  final AppThemeConfig config;

  /// MaterialApp 用的 ThemeMode。
  ThemeMode get themeModeValue => mode.toThemeMode();

  /// 复制并修改部分字段。
  ThemeState copyWith({AppThemeMode? mode, AppThemeConfig? config}) {
    return ThemeState(
      mode: mode ?? this.mode,
      config: config ?? this.config,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ThemeState && other.mode == mode && other.config == config;
  }

  @override
  int get hashCode => Object.hash(mode, config);
}

/// 主题状态共享存储（单例）。
///
/// 这是主题运行时状态的**唯一权威来源**：`ThemeNotifier`（Riverpod）与
/// `ThemeController`（IThemeService 兼容壳）都只是它的消费者/门面。
/// 持久化仍走 ConfigService（`theme.mode` / `theme.config`），外部写入通过
/// `ConfigService.onChange` 回流到本存储。
class ThemeStateStore {
  ThemeStateStore._();

  /// 全局单例。
  static final ThemeStateStore instance = ThemeStateStore._();

  /// 当前主题状态（UI 通过 ValueNotifier 监听）。
  final ValueNotifier<ThemeState> state = ValueNotifier(const ThemeState());

  StreamSubscription<ConfigChangeEvent>? _configSub;
  bool _initialized = false;
  bool _disposed = false;

  /// 状态世代：每次显式写入/外部事件应用都自增；启动异步读取只在世代未变化
  /// 时落地，避免晚到的初值覆盖更新的写入。
  int _stateGeneration = 0;

  /// 幂等初始化：读取持久化初值并订阅 ConfigService 变化。
  void initialize() {
    if (_initialized || _disposed) return;
    _initialized = true;
    _loadPersisted();
    _configSub = ConfigService.instance.onChange.listen(
      _onConfigChange,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('ThemeStateStore: 配置变更订阅异常: $error');
      },
    );
  }

  /// 读取持久化主题初值；失败时保持默认状态。
  Future<void> _loadPersisted() async {
    final generation = _stateGeneration;
    try {
      final service = ConfigService.instance;
      final modeValue = await service.getRaw(ConfigKeys.themeMode);
      final configValue = await service.getRaw(ConfigKeys.themeConfig);
      if (generation != _stateGeneration) return;

      _applyMode(_modeFromValue(modeValue));
      _applyConfig(ThemeConfigNormalizer.parse(configValue));
    } catch (error) {
      // 读取失败保持默认（配置系统可能尚未就绪）。
      debugPrint('ThemeStateStore: 读取持久化主题失败: $error');
    }
  }

  /// 配置写入事件 → 同步主题状态（外部写入的唯一收敛入口）。
  void _onConfigChange(ConfigChangeEvent event) {
    switch (event.key) {
      case ConfigKeys.themeMode:
        final mode = _modeFromValue(event.newValue);
        if (mode != null) {
          _stateGeneration++;
          _applyMode(mode);
        }
      case ConfigKeys.themeConfig:
        final config = ThemeConfigNormalizer.parse(event.newValue);
        if (config != null) {
          _stateGeneration++;
          _applyConfig(config);
        } else {
          debugPrint('ThemeStateStore: 主题配置解析失败，保持当前状态');
        }
    }
  }

  static AppThemeMode? _modeFromValue(Object? value) {
    if (value is int && value >= 0 && value < AppThemeMode.values.length) {
      return AppThemeMode.values[value];
    }
    return null;
  }

  /// 设置主题模式并持久化；成功后立即读回配置源值应用。
  Future<void> setThemeMode(AppThemeMode mode) async {
    _stateGeneration++;
    final result = await ConfigService.instance.set(
      ConfigKeys.themeMode,
      mode.index,
      source: ConfigChangeSource.user,
    );
    if (!result.success) return;

    final value = await ConfigService.instance.getRaw(ConfigKeys.themeMode);
    _applyMode(_modeFromValue(value));
  }

  /// 立即应用主题模式，再异步持久化（UI 切换专用）。
  ///
  /// [setThemeMode] 会等待 Rust 配置写入 + 读回后才翻转界面；首次写入（配置
  /// 模块刚就绪/DB 冷启动）实测可达 ~1s，表现为点击后界面长时间无反应。
  /// 换肤是有明确用户意图的瞬时操作：先改内存状态让揭示动画立刻开始，写入
  /// 失败只记日志（本次会话保持新主题，下次启动回落到持久化值）。
  Future<void> setThemeModeOptimistic(AppThemeMode mode) async {
    _stateGeneration++;
    _applyMode(mode);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.themeMode,
        mode.index,
        source: ConfigChangeSource.user,
      );
      if (!result.success) {
        debugPrint('ThemeStateStore: 主题持久化失败（界面保持已切换）');
      }
    } catch (error) {
      debugPrint('ThemeStateStore: 主题持久化异常（界面保持已切换） - $error');
    }
  }

  /// 设置主题配置并持久化；成功后立即读回配置源值应用。
  Future<void> setThemeConfig(AppThemeConfig config) async {
    _stateGeneration++;
    final result = await ConfigService.instance.set(
      ConfigKeys.themeConfig,
      config.toJson(),
      source: ConfigChangeSource.user,
    );
    if (!result.success) return;

    final value = await ConfigService.instance.getRaw(ConfigKeys.themeConfig);
    _applyConfig(ThemeConfigNormalizer.parse(value));
  }

  /// 切换深浅色（system → light → dark → light）。
  Future<void> toggleTheme() async {
    final newMode = switch (state.value.mode) {
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

    final modeValue = await ConfigService.instance.getRaw(ConfigKeys.themeMode);
    final configValue =
        await ConfigService.instance.getRaw(ConfigKeys.themeConfig);
    _applyMode(_modeFromValue(modeValue));
    _applyConfig(ThemeConfigNormalizer.parse(configValue));
  }

  /// 设置自定义颜色主题（字体/圆角/边框沿用当前配置）。
  Future<void> setCustomColorTheme({
    required Color primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
  }) async {
    final current = state.value.config;
    await setThemeConfig(
      AppThemeConfig(
        useCustomColors: true,
        primaryColor: primaryColor,
        secondaryColor: secondaryColor,
        tertiaryColor: tertiaryColor,
        fontStyle: current.fontStyle,
        radiusStyle: current.radiusStyle,
        borderStyle: current.borderStyle,
      ),
    );
  }

  /// 设置字体风格。
  Future<void> setFontStyle(AppFontStyle style) async {
    await setThemeConfig(state.value.config.copyWith(fontStyle: style));
  }

  /// 设置圆角风格。
  Future<void> setRadiusStyle(AppRadiusStyle style) async {
    await setThemeConfig(state.value.config.copyWith(radiusStyle: style));
  }

  /// 设置边框风格。
  Future<void> setBorderStyle(AppBorderStyle style) async {
    await setThemeConfig(state.value.config.copyWith(borderStyle: style));
  }

  /// 切换是否使用自定义颜色。
  Future<void> toggleCustomColors() async {
    final config = state.value.config;
    await setThemeConfig(
      config.copyWith(useCustomColors: !config.useCustomColors),
    );
  }

  /// 将部分 JSON 补丁与当前配置合并、规范化后设置。
  Future<bool> applyThemeConfigJson(Map<String, dynamic> patch) async {
    final merged = <String, dynamic>{
      ...state.value.config.toJson(),
      ...patch,
    };

    // 补丁显式给出颜色但未声明 useCustomColors 时，视为开启自定义颜色
    // （当前配置里的 false 不应掩盖补丁意图）。
    final hasColorPatch = patch.entries.any(
      (entry) =>
          ThemeConfigNormalizer.colorKeys.contains(entry.key) &&
          entry.value != null,
    );
    if (hasColorPatch && !patch.containsKey('useCustomColors')) {
      merged['useCustomColors'] = true;
    }

    final normalized = ThemeConfigNormalizer.normalizeJson(merged);
    final parsed = ThemeConfigNormalizer.parse(normalized);
    if (parsed == null) return false;

    await setThemeConfig(parsed);
    return true;
  }

  /// 应用主题模式（null 忽略；未变化时不触发通知）。
  void _applyMode(AppThemeMode? mode) {
    if (mode == null) return;
    final current = state.value;
    if (current.mode == mode) return;
    state.value = current.copyWith(mode: mode);
  }

  /// 应用主题配置（null 忽略；未变化时不触发通知）。
  void _applyConfig(AppThemeConfig? config) {
    if (config == null) return;
    final current = state.value;
    if (current.config == config) return;
    state.value = current.copyWith(config: config);
  }

  /// 测试重置：取消订阅、清空世代与状态，但不销毁 ValueNotifier。
  void resetForTest() {
    _configSub?.cancel();
    _configSub = null;
    _initialized = false;
    _disposed = false;
    _stateGeneration = 0;
    state.value = const ThemeState();
  }

  /// 释放订阅（单例本身保持存活，ValueNotifier 不关闭）。
  void dispose() {
    _disposed = true;
    _configSub?.cancel();
    _configSub = null;
    _initialized = false;
  }
}

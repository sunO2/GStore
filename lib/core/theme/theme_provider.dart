import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_state_store.dart';

export 'theme_state_store.dart' show ThemeState;

/// 主题逻辑（Riverpod 消费者）
///
/// 权威状态已下沉到 [ThemeStateStore]（共享单例）；本 Notifier 只负责把
/// 共享状态同步进 Riverpod，供沿用 `themeProvider` 的 UI 继续使用。
/// 持久化仍走 ConfigService（`theme.mode` / `theme.config`）。
class ThemeNotifier extends Notifier<ThemeState> {
  @override
  ThemeState build() {
    final store = ThemeStateStore.instance;
    store.initialize();

    void sync() => state = store.state.value;

    store.state.addListener(sync);
    ref.onDispose(() => store.state.removeListener(sync));
    return store.state.value;
  }

  /// 设置主题模式并持久化。
  Future<void> setThemeMode(AppThemeMode mode) {
    return ThemeStateStore.instance.setThemeMode(mode);
  }

  /// 设置主题配置并持久化。
  Future<void> setThemeConfig(AppThemeConfig config) {
    return ThemeStateStore.instance.setThemeConfig(config);
  }

  /// 切换深浅色（system → light → dark → light）。
  Future<void> toggleTheme() {
    return ThemeStateStore.instance.toggleTheme();
  }

  /// 重置为主题默认配置（使用动态色 + 跟随系统）。
  Future<void> resetToDefault() {
    return ThemeStateStore.instance.resetToDefault();
  }

  /// 设置自定义颜色主题。
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

  /// 设置字体风格。
  Future<void> setFontStyle(AppFontStyle style) {
    return ThemeStateStore.instance.setFontStyle(style);
  }

  /// 设置圆角风格。
  Future<void> setRadiusStyle(AppRadiusStyle style) {
    return ThemeStateStore.instance.setRadiusStyle(style);
  }

  /// 设置边框风格。
  Future<void> setBorderStyle(AppBorderStyle style) {
    return ThemeStateStore.instance.setBorderStyle(style);
  }

  /// 切换是否使用自定义颜色。
  Future<void> toggleCustomColors() {
    return ThemeStateStore.instance.toggleCustomColors();
  }
}

/// 主题 Provider（Riverpod 主状态入口）。
final themeProvider = NotifierProvider<ThemeNotifier, ThemeState>(
  ThemeNotifier.new,
);

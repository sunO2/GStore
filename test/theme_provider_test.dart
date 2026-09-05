import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_manager.dart';
import 'package:gstore/core/config/providers/theme_config_provider.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(storages: [
      MemoryConfigStorage(),
      MemoryConfigStorage(),
    ]);
    ConfigRegistry.registerAll(ConfigService.instance);
    // 注册 ThemeConfigProvider：主题模式/配置经桥接 provider 持久化
    ConfigManager.instance
        .registerProvider(ThemeConfigProvider(MemoryConfigStorage()));
  });

  tearDown(() {
    ConfigManager.instance.unregisterProvider('theme_config');
  });

  group('themeProvider（Riverpod 主题权威状态）', () {
    test('默认状态：跟随系统 + 默认配置', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(themeProvider);
      expect(state.mode, AppThemeMode.system);
      expect(state.config, AppThemeConfig.default_);
    });

    test('setThemeMode → 状态立即更新 + ConfigService 持久化', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(themeProvider.notifier).setThemeMode(
            AppThemeMode.dark,
          );

      expect(container.read(themeProvider).mode, AppThemeMode.dark);
      expect(
        await ConfigService.instance.getRaw(ConfigKeys.themeMode),
        AppThemeMode.dark.index,
      );
    });

    test('外部 ConfigService 写入（Agent/兼容壳）→ onChange 回流同步', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 先建立订阅
      expect(container.read(themeProvider).mode, AppThemeMode.system);

      // 模拟 Agent/ThemeController 壳经 ConfigService 改主题模式
      await ConfigService.instance.set(
        ConfigKeys.themeMode,
        AppThemeMode.light.index,
        source: ConfigChangeSource.agent,
      );
      // onChange 异步广播 → 等待事件回流
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(container.read(themeProvider).mode, AppThemeMode.light);
    });

    test('toggleTheme: system → light → dark → light', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(themeProvider.notifier);

      await notifier.toggleTheme();
      expect(container.read(themeProvider).mode, AppThemeMode.light);

      await notifier.toggleTheme();
      expect(container.read(themeProvider).mode, AppThemeMode.dark);

      await notifier.toggleTheme();
      expect(container.read(themeProvider).mode, AppThemeMode.light);
    });

    test('setFontStyle/setRadiusStyle 基于当前配置 copyWith', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(themeProvider.notifier);

      await notifier.setFontStyle(AppFontStyle.large);
      expect(
        container.read(themeProvider).config.fontStyle,
        AppFontStyle.large,
      );

      await notifier.setRadiusStyle(AppRadiusStyle.circular);
      expect(
        container.read(themeProvider).config.radiusStyle,
        AppRadiusStyle.circular,
      );
      // 其它字段保持默认
      expect(
        container.read(themeProvider).config.useCustomColors,
        false,
      );
    });

    test('resetToDefault → 回到跟随系统 + 默认配置', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(themeProvider.notifier);

      await notifier.setThemeMode(AppThemeMode.dark);
      await notifier.setCustomColorTheme(primaryColor: const Color(0xFF1976D2));
      expect(container.read(themeProvider).mode, AppThemeMode.dark);

      await notifier.resetToDefault();

      expect(container.read(themeProvider).mode, AppThemeMode.system);
      expect(
        container.read(themeProvider).config,
        AppThemeConfig.default_,
      );
    });
  });
}

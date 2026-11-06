import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_state_store.dart';

/// 等待异步配置事件/持久化读取回流。
Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 40));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = ThemeStateStore.instance;

  setUp(() async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(
      storages: <ConfigStorage>[
        MemoryConfigStorage(),
        MemoryConfigStorage(),
      ],
    );
    ConfigRegistry.registerAll(ConfigService.instance);
    store.resetForTest();
  });

  tearDown(() {
    store.resetForTest();
  });

  group('ThemeStateStore', () {
    test('initialize 后加载持久化默认值', () async {
      store.initialize();
      await _settle();

      expect(store.state.value.mode, AppThemeMode.system);
      expect(store.state.value.config, AppThemeConfig.default_);
    });

    test('setThemeMode(dark) → 状态立即更新且持久化为 2', () async {
      store.initialize();
      await _settle();

      await store.setThemeMode(AppThemeMode.dark);

      expect(store.state.value.mode, AppThemeMode.dark);
      expect(
        await ConfigService.instance.getRaw(ConfigKeys.themeMode),
        AppThemeMode.dark.index,
      );
    });

    test('setThemeConfig 自定义颜色 → 状态与持久化 JSON 正确', () async {
      store.initialize();
      await _settle();

      await store.setThemeConfig(
        const AppThemeConfig(
          useCustomColors: true,
          primaryColor: Color(0xFF1976D2),
        ),
      );

      expect(store.state.value.config.useCustomColors, isTrue);
      expect(store.state.value.config.primaryColor, const Color(0xFF1976D2));

      final raw =
          await ConfigService.instance.getRaw(ConfigKeys.themeConfig) as Map;
      expect((raw['primaryColor'] as String).toLowerCase(), 'ff1976d2');
    });

    test('外部写入 themeMode → onChange 回流同步', () async {
      store.initialize();
      await _settle();

      await ConfigService.instance.set(
        ConfigKeys.themeMode,
        AppThemeMode.light.index,
        source: ConfigChangeSource.agent,
      );
      await _settle();

      expect(store.state.value.mode, AppThemeMode.light);
    });

    test('外部写入 themeConfig(fontStyle:large) → onChange 回流同步', () async {
      store.initialize();
      await _settle();

      await ConfigService.instance.set(
        ConfigKeys.themeConfig,
        <String, dynamic>{'fontStyle': AppFontStyle.large.index},
        source: ConfigChangeSource.agent,
      );
      await _settle();

      expect(store.state.value.config.fontStyle, AppFontStyle.large);
    });

    test('非法配置 fontStyle:99 → 状态保持不变', () async {
      store.initialize();
      await _settle();
      final before = store.state.value;

      await ConfigService.instance.set(
        ConfigKeys.themeConfig,
        <String, dynamic>{'fontStyle': 99},
        source: ConfigChangeSource.agent,
      );
      await _settle();

      expect(store.state.value, before);
    });

    test('applyThemeConfigJson 补丁开启自定义颜色', () async {
      store.initialize();
      await _settle();

      final ok = await store.applyThemeConfigJson(
        <String, dynamic>{'primaryColor': '#1976D2'},
      );

      expect(ok, isTrue);
      expect(store.state.value.config.useCustomColors, isTrue);
      expect(store.state.value.config.primaryColor, const Color(0xFF1976D2));
    });

    test('resetToDefault → 回到默认状态', () async {
      store.initialize();
      await _settle();
      await store.setThemeMode(AppThemeMode.dark);
      await store.setCustomColorTheme(
        primaryColor: const Color(0xFF1976D2),
      );

      await store.resetToDefault();

      expect(store.state.value.mode, AppThemeMode.system);
      expect(store.state.value.config, AppThemeConfig.default_);
    });
  });
}

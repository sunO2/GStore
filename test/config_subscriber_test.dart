import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(storages: [
      MemoryConfigStorage(),
      MemoryConfigStorage(),
    ]);
    ConfigRegistry.registerAll(ConfigService.instance);
  });

  group('主题订阅者响应（配置写入 → 功能主动更新）', () {
    test('theme_mode 写入后 ThemeController 自动切换', () async {
      // 初始化主题控制器（内部订阅 ConfigService）
      final controller = ThemeController();
      controller.onInit();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(controller.themeMode, AppThemeMode.system);

      // 模拟 Agent/UI 通过 ConfigService 修改主题模式
      await ConfigService.instance.set(
        ConfigKeys.themeMode,
        AppThemeMode.dark.index,
        source: ConfigChangeSource.agent,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(controller.themeMode, AppThemeMode.dark);

      controller.onClose();
    });

    test('theme_mode 写入浅色模式', () async {
      final controller = ThemeController();
      controller.onInit();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await ConfigService.instance.set(
        ConfigKeys.themeMode,
        AppThemeMode.light.index,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(controller.themeMode, AppThemeMode.light);

      controller.onClose();
    });

    test('通过 ThemeController.setThemeMode 写入后配置可读', () async {
      final controller = ThemeController();
      controller.onInit();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await controller.setThemeMode(AppThemeMode.dark);
      expect(controller.themeMode, AppThemeMode.dark);

      // 配置已持久化到统一存储
      final saved = await ConfigService.instance.getT<int>(ConfigKeys.themeMode);
      expect(saved, AppThemeMode.dark.index);

      controller.onClose();
    });

    test('theme_config 写入后 ThemeController 配置同步', () async {
      final controller = ThemeController();
      controller.onInit();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final config = AppThemeConfig(
        useCustomColors: true,
        primaryColor: const Color(0xFF1976D2),
      );
      await controller.setThemeConfig(config);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(controller.themeConfig.useCustomColors, true);
      expect(controller.themeConfig.primaryColor, const Color(0xFF1976D2));

      controller.onClose();
    });
  });
}

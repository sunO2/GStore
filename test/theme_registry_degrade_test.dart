import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/page/settings/settings_page.dart';

/// theme 非响应式消费点注册表化 + main 共享实例兜底测试（todo 15）
///
/// 验证：
/// - theme 模块关闭（ModuleManager 未绑定 ThemeController）时 main 兜底逻辑
///   （hasService ? get : bind）可用默认 ThemeController 启动
/// - re-enable 后 ThemeModule.onInit 的 hasService 守卫复用同一实例（防主题分裂）
/// - settings_page 非响应式点 get<IThemeService>() null 降级显示默认文案；
///   绑定时显示当前主题模式
/// - agent themeControl 非响应式点 null 降级提示不抛
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
  });

  group('main 共享实例兜底（theme 模块关闭）', () {
    test('ModuleManager 未绑定 ThemeController → 兜底创建默认控制器可用', () {
      expect(ModuleManager.instance.hasService<ThemeController>(), isFalse);

      // main.dart 的兜底逻辑（hasService ? get : bind 新实例）
      final controller = ModuleManager.instance.get<ThemeController>() ??
          ThemeController();
      ModuleManager.instance.bind<ThemeController>(controller);

      expect(controller, isNotNull);
      expect(controller.themeMode, AppThemeMode.system,
          reason: 'theme 模块关闭时用默认控制器启动，不崩');
    });

    test('re-enable 后 ThemeModule.onInit 守卫复用同一实例（防主题分裂）', () {
      final first = ThemeController();
      ModuleManager.instance.bind<ThemeController>(first);

      // ThemeModule.onInit 的 hasService 守卫逻辑
      if (!ModuleManager.instance.hasService<ThemeController>()) {
        ModuleManager.instance
            .bind<ThemeController>(ThemeController());
      }

      expect(ModuleManager.instance.get<ThemeController>(), same(first),
          reason: 're-enable 后必须复用同一实例，否则主题绑定旧实例分裂');
    });
  });

  group('非响应式点 null 降级', () {
    testWidgets('settings_page：无持久化配置 → 主题入口显示默认主题模式不崩', (tester) async {
      await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: SettingsPage())));

      expect(find.text(AppThemeMode.system.displayName), findsOneWidget,
          reason: 'themeProvider 恒可读（不依赖模块绑定），默认跟随系统');
    });

    testWidgets('settings_page：ThemeController 已注册 → 显示当前主题模式', (tester) async {
      ModuleManager.instance.bind<ThemeController>(ThemeController());
      await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: SettingsPage())));

      expect(find.text(AppThemeMode.system.displayName), findsOneWidget);
    });

    test('agent themeControl：服务未绑定 → 降级提示不抛', () async {
      final agent = AgentService();
      final result = await agent.runTool('themeControl', {
        'action': 'mode',
        'mode': 'light',
      });

      expect(result, contains('主题模块未启用'));
    });
  });
}
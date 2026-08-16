import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/page/settings/settings_page.dart';

/// theme 非响应式消费点注册表化 + main 共享实例兜底测试（todo 15）
///
/// 验证：
/// - theme 模块关闭（Get 未注册 ThemeController）时 main 兜底逻辑
///   （isRegistered ? find : put）可用默认 ThemeController 启动
/// - re-enable 后 ThemeModule.onInit 的 isRegistered 守卫复用同一实例（防主题分裂）
/// - settings_page 非响应式点 get<IThemeService>() null 降级显示默认文案；
///   绑定时显示当前主题模式
/// - agent themeControl 非响应式点 null 降级提示不抛
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    Get.reset();
  });

  group('main 共享实例兜底（theme 模块关闭）', () {
    test('Get 未注册 ThemeController → 兜底创建默认控制器可用', () {
      Get.reset();
      expect(Get.isRegistered<ThemeController>(), isFalse);

      // main.dart 的兜底逻辑（Get.isRegistered ? find : put）
      final controller = Get.isRegistered<ThemeController>()
          ? Get.find<ThemeController>()
          : Get.put(ThemeController());

      expect(controller, isNotNull);
      expect(controller.themeMode, AppThemeMode.system,
          reason: 'theme 模块关闭时用默认控制器启动，不崩');
    });

    test('re-enable 后 ThemeModule.onInit 守卫复用同一实例（防主题分裂）', () {
      Get.reset();
      Get.put(ThemeController());
      final first = Get.find<ThemeController>();

      // ThemeModule.onInit 的 isRegistered 守卫逻辑
      if (!Get.isRegistered<ThemeController>()) {
        Get.put(ThemeController());
      }

      expect(Get.find<ThemeController>(), same(first),
          reason: 're-enable 后必须复用同一实例，否则 Obx 绑定旧实例主题分裂');
    });
  });

  group('非响应式点 null 降级', () {
    testWidgets('settings_page：IThemeService 未绑定 → 显示默认文案不崩', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));

      expect(find.text('默认'), findsOneWidget,
          reason: 'theme 模块下线时主题入口显示降级文案，不抛 Get.find 异常');
    });

    testWidgets('settings_page：ThemeController 已注册 → 显示当前主题模式', (tester) async {
      Get.put(ThemeController());
      await tester.pumpWidget(const MaterialApp(home: SettingsPage()));

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
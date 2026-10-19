import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/page/home/tab/mine/view.dart';

/// plan todo 8：`MinePage` 作为「设置」tab。
///
/// 覆盖：
/// - 页面暴露 tab 标签常量 `MinePage.tabLabel == '设置'`；
/// - AppBar 渲染「设置」标签；
/// - 既有入口保留：工具卡「工具」「性能监控」+ 快捷功能卡「设置」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = ModuleManager.instance;

  setUp(() async {
    await manager.clear();
    // 页面依赖（ThemeController/UserManager 经 ModuleManager 注册表取用）
    manager.bind<ThemeController>(ThemeController());
    manager.bind<UserManager>(UserManager.instance);
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(const {});
  });

  Future<void> pumpMinePage(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const MinePage(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  group('MinePage 作为「设置」tab', () {
    test('tab 标签常量为 设置', () {
      expect(MinePage.tabLabel, '设置');
    });

    testWidgets('AppBar 渲染「设置」标签', (tester) async {
      await pumpMinePage(tester);

      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('设置')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('保留既有入口：工具 / 性能监控 / 设置', (tester) async {
      await pumpMinePage(tester);

      // 工具卡标题 + 性能监控入口
      expect(find.text('工具'), findsOneWidget);
      expect(find.text('性能监控'), findsOneWidget);

      // 快捷功能卡的「设置」入口（ListTile）
      expect(
        find.ancestor(of: find.text('设置'), matching: find.byType(ListTile)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}

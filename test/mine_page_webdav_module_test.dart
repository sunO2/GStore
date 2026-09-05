import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/core/theme/theme_controller.dart';
import 'package:gstore/page/backup/logic.dart';
import 'package:gstore/page/home/tab/mine/view.dart';

/// 我的页 webdav 模块上下线响应测试
///
/// 验证（todo 10，契约 8/9）：
/// - webdav 模块在线 + 已配置 → 备份入口（展开箭头 / WebDAV 区域 / 按钮）可见
/// - webdav 模块下线（unregister 事件）→ 备份入口隐藏
/// - webdav 模块上线（activate 事件）→ 备份入口恢复
/// - dispose 取消订阅：页面销毁后模块事件不再触发界面更新、无异常
///
/// 状态流转：ModuleManager 事件 → MinePage._webdavModuleOnline → UI 显示/隐藏。

/// 测试用 webdav 模块（无依赖、无副作用）
class TestWebDavModule extends AppModule {
  @override
  String get moduleName => 'webdav';

  @override
  int get priority => 10;

  @override
  Future<void> onRegister(ModuleContext context) async {}

  @override
  Future<void> onUnregister(ModuleContext context) async {}
}

/// 预置 WebDAV 配置：mock flutter_secure_storage 平台接口（hasConfig 结果可控）
void _mockWebDavConfig({required bool hasConfig}) {
  FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
    hasConfig
        ? const {
            'webdav_url': 'https://example.com/dav',
            'webdav_username': 'user',
            'webdav_password': 'pass',
          }
        : const {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = ModuleManager.instance;

  setUp(() async {
    // 清理上个用例的页面控制器（onClose 取消订阅，防跨用例泄漏）
    Get.delete<BackupLogic>(force: true);
    Get.delete<ThemeController>(force: true);
    Get.delete<UserManager>(force: true);
    if (!Get.isRegistered<ThemeController>()) {
      Get.put(ThemeController());
    }
    if (!Get.isRegistered<UserManager>()) {
      Get.put(UserManager.instance);
    }

    // 重置模块注册中心；webdav 模块初始在线（registered + initialized）
    await manager.clear();
    manager.registerKnownModules(() => [TestWebDavModule()]);
    await manager.activate(TestWebDavModule());
    expect(manager.isModuleEnabled('webdav'), isTrue);
    expect(manager.isInitialized('webdav'), isTrue);

    _mockWebDavConfig(hasConfig: true);
  });

  tearDown(() {
    Get.delete<BackupLogic>(force: true);
    Get.delete<ThemeController>(force: true);
    Get.delete<UserManager>(force: true);
  });

  /// 备份卡（'备份管理' 标题所在的 Card）
  Finder backupCard() =>
      find.ancestor(of: find.text('备份管理'), matching: find.byType(Card));

  /// 备份卡内的展开箭头（仅 webdav 入口可见时存在）
  Finder arrowIn(Finder card) =>
      find.descendant(of: card, matching: find.byIcon(Icons.expand_more));

  /// 泵起我的页并等异步初始化（_checkWebDavConfig + BackupLogic）完成
  Future<void> pumpMinePage(WidgetTester tester) async {
    await tester.pumpWidget(
        const ProviderScope(child: GetMaterialApp(home: MinePage())));
    await tester.pumpAndSettle();
  }

  group('我的页 webdav 模块上下线响应', () {
    testWidgets('webdav 在线 + 有配置 → 备份入口（箭头/区域/按钮）可见', (tester) async {
      await pumpMinePage(tester);

      expect(arrowIn(backupCard()), findsOneWidget);
      expect(find.text('WebDAV 云端备份'), findsOneWidget);
      expect(find.text('备份到网盘'), findsOneWidget);
      expect(find.text('从网盘恢复'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('webdav 下线 → 入口隐藏；上线恢复 → 重新可见', (tester) async {
      await pumpMinePage(tester);
      expect(find.text('WebDAV 云端备份'), findsOneWidget);

      // 下线：unregister → unregistered 事件 → 备份入口隐藏
      await manager.setModuleEnabled('webdav', false);
      // 事件经 broadcast 异步投递：第一次 pump 投递（markNeedsBuild），第二次绘制重建帧
      await tester.pump();
      await tester.pump();
      expect(manager.isModuleEnabled('webdav'), isFalse);
      expect(arrowIn(backupCard()), findsNothing);
      expect(find.text('WebDAV 云端备份'), findsNothing);
      expect(find.text('备份到网盘'), findsNothing);
      expect(find.text('从网盘恢复'), findsNothing);

      // 上线：activate → registered 事件 → 备份入口恢复
      await manager.setModuleEnabled('webdav', true);
      await tester.pump();
      await tester.pump();
      expect(manager.isModuleEnabled('webdav'), isTrue);
      expect(arrowIn(backupCard()), findsOneWidget);
      expect(find.text('WebDAV 云端备份'), findsOneWidget);
      expect(find.text('备份到网盘'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dispose 后模块事件不再触发界面更新（订阅取消，无异常）', (tester) async {
      await pumpMinePage(tester);

      // 销毁页面：dispose 应取消 _moduleSub 订阅
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      // 模块下线事件：若订阅未取消，回调走 mounted 守卫兜底，也不得抛异常
      await manager.setModuleEnabled('webdav', false);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);

      // 再次上线同样无异常
      await manager.setModuleEnabled('webdav', true);
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}

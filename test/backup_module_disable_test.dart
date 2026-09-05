import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/page/backup/logic.dart';
import 'package:gstore/page/backup/view.dart';
import 'package:gstore/page/home/tab/mine/view.dart';

/// 无依赖桩模块（补齐 backup 的 db/config/channel 依赖声明）
class _StubModule extends AppModule {
  _StubModule(this.moduleName);

  @override
  final String moduleName;
}

/// 备份模块纳入模块管理 + 消费方注册表化降级测试
///
/// 验证：
/// ① BackupModule 上线（onRegister）后 get<IBackupService>() 返回实例
/// ② backup 禁用（setModuleEnabled(false)）→ onUnregister 解绑 → get<IBackupService>() null
/// ③ BackupLogic 服务 null 时本地备份/恢复/导入操作短路提示「备份模块未启用」，不发起实际操作
/// ④ 我的页备份卡随 backup 上下线显隐（widget）
/// ⑤ 备份页下线显示「备份模块未启用」占位（widget）
/// ⑥ agent 备份工具服务 null 降级返回提示不抛
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = ModuleManager.instance;

  /// 注入服务绑定上下文（模拟 main.dart 装配）
  void injectBindingContext() {
    manager.injectContext(ModuleContext(
      config: null,
      bindService: (type, impl) => manager.bindByType(type, impl),
      unbindService: (type) => manager.unbindByType(type),
      manager: manager,
    ));
  }

  /// 注册并初始化 backup 模块（依赖用无副作用桩模块补齐）
  Future<void> registerBackupModule() async {
    await manager.registerModule(_StubModule('db'));
    await manager.registerModule(_StubModule('config'));
    await manager.registerModule(_StubModule('channel'));
    await manager.registerModule(BackupModule());
    await manager.initializeModule('backup');
  }

  setUp(() async {
    await manager.clear();
    manager.injectContext(null);
    Get.reset();
  });

  group('BackupModule 管理 IBackupService（注册表化）', () {
    test('① 模块注册+初始化后 get<IBackupService>() 返回实例（bind 生效）', () async {
      injectBindingContext();
      await registerBackupModule();

      expect(manager.get<IBackupService>(), same(BackupService.instance),
          reason: 'onRegister 应按类型绑定 BackupService.instance');
    });

    test('② backup 禁用（setModuleEnabled(false)）→ unbind → get<IBackupService>() null',
        () async {
      injectBindingContext();
      await registerBackupModule();
      expect(manager.get<IBackupService>(), isNotNull,
          reason: '上线后服务应已绑定');

      final ok = await manager.setModuleEnabled('backup', false);
      expect(ok, isTrue);
      expect(manager.hasModule('backup'), isFalse);
      expect(manager.get<IBackupService>(), isNull,
          reason: '下线后服务应已解绑（消费方降级）');
    });
  });

  group('BackupLogic 服务 null 降级', () {
    /// 环境：AppDialogs snackbar 需要 MaterialApp + scaffoldMessengerKey
    Future<BuildContext> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const Scaffold(body: SizedBox()),
      ));
      return tester.element(find.byType(Scaffold));
    }

    testWidgets('③ 服务 null 时 exportCompressed 短路提示「备份模块未启用」，不执行导出', (tester) async {
      final context = await pumpApp(tester);

      final logic = BackupLogic();
      expect(ModuleManager.instance.get<IBackupService>(), isNull,
          reason: '前置：未绑定 IBackupService');

      unawaited(logic.exportCompressed(context));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('备份模块未启用'), findsOneWidget);
      expect(logic.state.isExporting.value, isFalse,
          reason: '不应进入导出流程');
      expect(tester.takeException(), isNull);
    });

    testWidgets('③b 服务 null 时 importFromFile 短路提示，不弹进度框不置位', (tester) async {
      final context = await pumpApp(tester);

      final logic = BackupLogic();
      unawaited(logic.importFromFile(context, '/tmp/nonexistent.gz'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('备份模块未启用'), findsOneWidget);
      expect(logic.state.isImporting.value, isFalse,
          reason: '不应进入导入流程');
      expect(tester.takeException(), isNull);
    });

    test('③c 服务 null 时 loadStatistics 短路不抛', () async {
      final logic = BackupLogic();
      await logic.loadStatistics();

      expect(logic.state.errorMessage.value, isEmpty,
          reason: '不应触发真实统计加载');
      expect(logic.state.statistics.value, isNull);
    });
  });

  group('我的页备份卡随 backup 上下线显隐（widget）', () {
    setUp(() async {
      injectBindingContext();
      // 提供备份模块清单（setModuleEnabled(true) 重新激活时查找）
      manager.registerKnownModules(() => [BackupModule()]);
      await registerBackupModule();
      expect(manager.isModuleEnabled('backup'), isTrue);

      // 清理解析页面依赖
      Get.delete<BackupLogic>(force: true);
      Get.delete<ThemeController>(force: true);
      Get.delete<UserManager>(force: true);
      if (!Get.isRegistered<ThemeController>()) Get.put(ThemeController());
      if (!Get.isRegistered<UserManager>()) Get.put(UserManager.instance);

      // 防 flutter_secure_storage 真实 channel 挂起
      const channel =
          MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
    });

    tearDown(() {
      Get.delete<BackupLogic>(force: true);
      Get.delete<ThemeController>(force: true);
      Get.delete<UserManager>(force: true);
    });

    Future<void> pumpMinePage(WidgetTester tester) async {
      await tester.pumpWidget(
          const ProviderScope(child: GetMaterialApp(home: MinePage())));
      await tester.pumpAndSettle();
    }

    testWidgets('④ backup 在线 → 备份卡可见；下线 → 隐藏；上线 → 恢复', (tester) async {
      await pumpMinePage(tester);
      expect(find.text('备份管理'), findsOneWidget);

      // 下线：unregister → unregistered 事件 → 备份卡隐藏
      await manager.setModuleEnabled('backup', false);
      await tester.pump();
      await tester.pump();
      expect(manager.isModuleEnabled('backup'), isFalse);
      expect(find.text('备份管理'), findsNothing);

      // 上线：activate → registered 事件 → 备份卡恢复
      await manager.setModuleEnabled('backup', true);
      await tester.pump();
      await tester.pump();
      expect(manager.isModuleEnabled('backup'), isTrue);
      expect(find.text('备份管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('备份页下线占位（widget）', () {
    testWidgets('⑤ backup 下线 → 页面显示「备份模块未启用」占位，正常内容不渲染', (tester) async {
      injectBindingContext();
      await registerBackupModule();
      await manager.setModuleEnabled('backup', false);
      expect(manager.get<IBackupService>(), isNull);

      Get.delete<BackupLogic>(force: true);
      await tester.pumpWidget(GetMaterialApp(
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: const BackupPage(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('备份模块未启用'), findsOneWidget);
      expect(find.text('本地备份'), findsNothing,
          reason: '下线时不应渲染备份功能卡片');
      expect(tester.takeException(), isNull);
    });
  });

  group('Agent 备份工具降级', () {
    test('⑥ IBackupService 未绑定 → 备份工具返回「备份模块未启用」不抛', () async {
      final agent = AgentService();
      expect(ModuleManager.instance.get<IBackupService>(), isNull,
          reason: '前置：未绑定 IBackupService');

      final result = await agent.runTool('backup', {'action': 'export'});
      expect(result, contains('备份模块未启用'));

      final importResult =
          await agent.runTool('backup', {'action': 'import', 'filePath': ''});
      expect(importResult, contains('备份模块未启用'));
    });
  });
}

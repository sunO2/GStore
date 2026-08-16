import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/fdroid/FdroidRepoManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/page/fdroid_repo/logic.dart';

/// FdroidRepoLogic 注册表注入 + 下线降级测试（todo 13）
///
/// 验证：
/// - `ModuleManager.get<IFdroidRepoService>()` 未绑定（fdroid 模块下线）时
///   onInit 不订阅不抛、置「F-Droid 模块未启用」错误提示（页面空状态）；
///   loadRepository / searchApps 短路提示不抛
/// - 服务已绑定（真实 FdroidRepoManager 实例）时不降级：onInit 正常订阅、
///   不置「未启用」提示
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    Get.reset();
    // 页面内不读 secure storage；此处仅为防御性 mock（fake-async 环境下防挂起）
    const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  /// 环境：AppDialogs snackbar 需要 MaterialApp + scaffoldMessengerKey
  Future<BuildContext> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: SizedBox()),
    ));
    return tester.element(find.byType(Scaffold));
  }

  group('模块未绑定（get<IFdroidRepoService>() null）→ 安全降级', () {
    test('onInit：短路置「F-Droid 模块未启用」错误提示，不订阅不抛', () {
      final logic = FdroidRepoLogic();
      Get.put(logic);
      expect(logic.state.errorMessage.value, contains('未启用'));
    });

    testWidgets('loadRepository：提示「F-Droid 模块未启用」不抛', (tester) async {
      await pumpApp(tester);

      final logic = FdroidRepoLogic();
      Get.put(logic);
      unawaited(logic.loadRepository());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('F-Droid 模块未启用'), findsWidgets);
    });

    testWidgets('searchApps：提示「F-Droid 模块未启用」且不置搜索状态', (tester) async {
      await pumpApp(tester);

      final logic = FdroidRepoLogic();
      Get.put(logic);
      unawaited(logic.searchApps('termux'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('F-Droid 模块未启用'), findsWidgets);
      expect(logic.state.isSearching.value, isFalse);
      expect(logic.state.searchResults, isEmpty);
    });
  });

  group('服务已绑定（FdroidRepoManager）→ 不降级', () {
    test('onInit：绑定真实管理器时不置「未启用」提示', () async {
      ModuleManager.instance
          .bind<IFdroidRepoService>(FdroidRepoManager.instance);

      final logic = FdroidRepoLogic();
      Get.put(logic);
      // 等待异步 _initData 完成（测试环境无 Rust FFI，内部已捕获降级）
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(logic.state.errorMessage.value, isNot(contains('未启用')));
    });
  });
}

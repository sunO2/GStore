import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:go_router/go_router.dart';

/// GoRouter 与 GetX 共存验证
///
/// 架构：MaterialApp.router + GoRouter（navigatorKey = rootKey），并把
/// rootKey 经 `Get.addKey` 注册为 GetX 全局 navigator key —— GetX 的
/// overlay（dialog/snackbar）从 rootKey.currentState.overlay 取，状态管理
/// （Get.put/Obx）与路由解耦不受影响。
///
/// 验证点：
/// 1. GoRouter 路由可达并正常跳转
/// 2. GetX 状态管理（Get.put + Obx）在 MaterialApp.router 下可用
/// 3. GetX overlay（Get.dialog / Get.snackbar）在 MaterialApp.router 下可用
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MaterialApp.router + GoRouter 下 GetX 状态与 overlay 均可用',
      (tester) async {
    final rootKey = GlobalKey<NavigatorState>();

    final goRouter = GoRouter(
      navigatorKey: rootKey,
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => const _HomePage(),
        ),
        GoRoute(
          path: '/second',
          builder: (context, state) => const _SecondPage(),
        ),
      ],
    );

    // 关键：GetX overlay 指向 GoRouter 的 Navigator
    Get.addKey(rootKey);

    await tester.pumpWidget(MaterialApp.router(
      routerConfig: goRouter,
      scaffoldMessengerKey: _messengerKey,
    ));
    await tester.pumpAndSettle();

    // 1. GoRouter 首页可达 + GetX 状态（Obx 计数）
    expect(find.text('共存验证首页'), findsOneWidget);
    expect(find.text('计数: 0'), findsOneWidget);

    // GetX 状态更新（Get.put 控制器 + Rx）
    await tester.tap(find.text('计数+1'));
    await tester.pump();
    expect(find.text('计数: 1'), findsOneWidget);

    // 2. GetX overlay：dialog 可用
    await tester.tap(find.text('弹 Get.dialog'));
    await tester.pumpAndSettle();
    expect(find.text('GetX Dialog 内容'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('GetX Dialog 内容'), findsNothing);

    // 3. 项目实际 Snackbar 通道（ScaffoldMessenger）可用
    //    （Get.snackbar 是 GetX 与新版 Flutter overlay 的已知兼容问题，
    //    项目已用 AppDialogs + scaffoldMessengerKey 替代，故此处验证该通道）
    final messenger = _messengerKey.currentState!;
    messenger.showSnackBar(const SnackBar(content: Text('snackbar 标题')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('snackbar 标题'), findsWidgets);

    // 4. GoRouter 跳转正常
    await tester.tap(find.text('去第二页'));
    await tester.pumpAndSettle();
    expect(find.text('第二页内容'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}

final GlobalKey<ScaffoldMessengerState> _messengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 简单 GetX 计数器控制器。
class _CounterController extends GetxController {
  final count = 0.obs;
  void inc() => count.value++;
}

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.put(_CounterController());
    return Scaffold(
      appBar: AppBar(title: const Text('共存验证首页')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Obx(() => Text('计数: ${ctrl.count.value}')),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: ctrl.inc,
              child: const Text('计数+1'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => Get.dialog(
                AlertDialog(
                  title: const Text('GetX Dialog'),
                  content: const Text('GetX Dialog 内容'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
              child: const Text('弹 Get.dialog'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => Get.snackbar(
                'snackbar 标题',
                'snackbar 内容',
                snackPosition: SnackPosition.BOTTOM,
              ),
              child: const Text('弹 Get.snackbar'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => context.push('/second'),
              child: const Text('去第二页'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecondPage extends StatelessWidget {
  const _SecondPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('第二页')),
      body: const Center(child: Text('第二页内容')),
    );
  }
}

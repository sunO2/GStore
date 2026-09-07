import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// GoRouter 与 MaterialApp.router 共存验证
///
/// 架构：MaterialApp.router + GoRouter（navigatorKey = appNavigatorKey），
/// 项目 overlay（dialog/snackbar）经 navigatorKey / scaffoldMessengerKey 呈现。
///
/// 验证点：
/// 1. GoRouter 路由可达并正常跳转
/// 2. 普通 showDialog 在 MaterialApp.router 下可用
/// 3. ScaffoldMessenger Snackbar 通道（AppDialogs 同款）可用
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'MaterialApp.router + GoRouter 下 Navigator/overlay/snackbar 均可用',
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

    await tester.pumpWidget(MaterialApp.router(
      routerConfig: goRouter,
      scaffoldMessengerKey: _messengerKey,
    ));
    await tester.pumpAndSettle();

    // 1. GoRouter 首页可达
    expect(find.text('共存验证首页'), findsOneWidget);

    // 2. overlay：showDialog 可用
    await tester.tap(find.text('弹 Dialog'));
    await tester.pumpAndSettle();
    expect(find.text('Dialog 内容'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('Dialog 内容'), findsNothing);

    // 3. ScaffoldMessenger Snackbar 通道（AppDialogs 同款）可用
    final messenger = _messengerKey.currentState!;
    messenger.showSnackBar(const SnackBar(content: Text('snackbar 标题')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('snackbar 标题'), findsWidgets);

    // 1b. GoRouter 跳转正常
    await tester.tap(find.text('去第二页'));
    await tester.pumpAndSettle();
    expect(find.text('第二页内容'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}

final GlobalKey<ScaffoldMessengerState> _messengerKey =
    GlobalKey<ScaffoldMessengerState>();

class _HomePage extends StatefulWidget {
  const _HomePage();

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  int _count = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('共存验证首页')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('计数: $_count'),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => setState(() => _count++),
              child: const Text('计数+1'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Dialog'),
                  content: const Text('Dialog 内容'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
              child: const Text('弹 Dialog'),
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
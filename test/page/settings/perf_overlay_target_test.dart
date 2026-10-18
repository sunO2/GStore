import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/perf/perf_overlay_controller.dart';
import 'package:gstore/core/perf/perf_target_store.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/page/settings/settings_page.dart';

/// 已安装应用来源假实现：直接返回注入列表，避免真实 `installed_apps` 通道
/// 在 widget 测试无宿主时永久挂起。
class _FakeAppService extends ThirdPartyPerfService {
  _FakeAppService(this.apps);

  final List<AppTarget> apps;

  @override
  Future<List<AppTarget>> listInstalledApps() async => apps;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PerfOverlayController.channelName);

  void installHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  testWidgets('显示持久化的监控目标 label', (tester) async {
    installHandler((call) async => false);

    final store = InMemoryPerfTargetStore(
      const PerfPinnedTarget(package: 'com.example.app', label: '示例应用'),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PerfOverlayTile(targetStore: store)),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('perf_overlay_target')), findsOneWidget);
    expect(find.text('监控目标'), findsOneWidget);
    expect(find.text('示例应用'), findsOneWidget);
    expect(find.byKey(const Key('perf_overlay_target_pick')), findsOneWidget);
  });

  testWidgets('无目标时提示未选择', (tester) async {
    installHandler((call) async => false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PerfOverlayTile(targetStore: InMemoryPerfTargetStore())),
      ),
    );
    await tester.pump();

    expect(find.textContaining('未选择'), findsOneWidget);
  });

  testWidgets('选择目标：打开弹层 → 选中应用 → 更新 label 并调用 setTarget', (tester) async {
    final calls = <MethodCall>[];
    installHandler((call) async {
      calls.add(call);
      return true;
    });

    final store = InMemoryPerfTargetStore();
    final service = _FakeAppService(const [
      AppTarget(package: 'com.example.game', label: '示例游戏'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PerfOverlayTile(targetStore: store, service: service),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('perf_overlay_target_pick')));
    await tester.pumpAndSettle();

    expect(find.text('选择监控目标'), findsOneWidget);
    expect(find.text('示例游戏'), findsOneWidget);

    await tester.tap(find.text('示例游戏'));
    await tester.pumpAndSettle();

    expect(find.text('选择监控目标'), findsNothing);
    expect(find.text('示例游戏'), findsOneWidget);

    final saved = await store.load();
    expect(saved?.package, 'com.example.game');
    expect(saved?.label, '示例游戏');
    expect(
      calls.any(
        (c) => c.method == 'setTarget' && c.arguments?['package'] == 'com.example.game',
      ),
      isTrue,
    );
  });
}

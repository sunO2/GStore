import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/perf/perf_overlay_controller.dart';
import 'package:gstore/page/perf/perf_overlay_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PerfOverlayController.channelName);
  late List<MethodCall> calls;

  void installHandler(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  List<String> methods() => calls.map((c) => c.method).toList();

  setUp(() => calls = <MethodCall>[]);
  tearDown(() => installHandler(null));

  testWidgets('权限拒绝：开关保持关闭且不调用原生 start', (tester) async {
    installHandler((call) async {
      calls.add(call);
      return false;
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PerfOverlayTile())),
    );
    await tester.pump();

    final switchFinder = find.byKey(const Key('perf_overlay_switch'));
    expect(switchFinder, findsOneWidget);
    expect(find.textContaining('显示在其他应用上层'), findsOneWidget);

    final before = tester.widget<SwitchListTile>(switchFinder);
    expect(before.value, isFalse);
    expect(before.onChanged, isNotNull);

    await tester.tap(switchFinder);
    await tester.pump();
    await tester.pump();

    expect(methods(), contains('requestPermission'));
    expect(methods(), isNot(contains('start')));

    final after = tester.widget<SwitchListTile>(switchFinder);
    expect(after.value, isFalse);
  });

  testWidgets('已授权且未运行：subtitle 提示可开启，开关为关', (tester) async {
    installHandler((call) async {
      calls.add(call);
      if (call.method == 'isPermissionGranted') return true;
      return false; // isRunning → false
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PerfOverlayTile())),
    );
    await tester.pump();

    expect(find.textContaining('可拖动'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(
      find.byKey(const Key('perf_overlay_switch')),
    );
    expect(tile.value, isFalse);
  });

  testWidgets('运行中：显示模式选择器，切换调用原生 setMode', (tester) async {
    installHandler((call) async {
      calls.add(call);
      switch (call.method) {
        case 'isPermissionGranted':
          return true;
        case 'isRunning':
          return true;
        case 'getMode':
          return PerfOverlayController.modeCompact;
        case 'setMode':
          return true;
        default:
          return false;
      }
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PerfOverlayTile())),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('perf_overlay_mode')), findsOneWidget);
    expect(find.text('显示模式'), findsOneWidget);

    await tester.tap(find.byKey(const Key('perf_overlay_mode_expanded')));
    await tester.pumpAndSettle();

    final setModeCall = calls.firstWhere((c) => c.method == 'setMode');
    expect(setModeCall.arguments, <String, Object?>{
      'mode': PerfOverlayController.modeExpanded,
    });
  });

  testWidgets('运行中：四种模式可选，选择前台调用原生 setMode', (tester) async {
    installHandler((call) async {
      calls.add(call);
      switch (call.method) {
        case 'isPermissionGranted':
          return true;
        case 'isRunning':
          return true;
        case 'getMode':
          return PerfOverlayController.modeCompact;
        case 'setMode':
          return true;
        default:
          return false;
      }
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PerfOverlayTile())),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('perf_overlay_mode_compact')), findsOneWidget);
    expect(find.byKey(const Key('perf_overlay_mode_expanded')), findsOneWidget);
    expect(find.byKey(const Key('perf_overlay_mode_target')), findsOneWidget);
    expect(find.byKey(const Key('perf_overlay_mode_live')), findsOneWidget);
    expect(find.text('目标专注'), findsOneWidget);
    expect(find.text('前台'), findsOneWidget);

    await tester.tap(find.byKey(const Key('perf_overlay_mode_live')));
    await tester.pumpAndSettle();

    final setModeCall = calls.firstWhere((c) => c.method == 'setMode');
    expect(setModeCall.arguments, <String, Object?>{
      'mode': PerfOverlayController.modeLive,
    });
  });

  testWidgets('未运行：不显示模式选择器', (tester) async {
    installHandler((call) async {
      calls.add(call);
      if (call.method == 'isPermissionGranted') return true;
      if (call.method == 'getMode') return PerfOverlayController.modeCompact;
      return false; // isRunning → false
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PerfOverlayTile())),
    );
    await tester.pump();

    expect(find.byKey(const Key('perf_overlay_mode')), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shizuku_api/shizuku_api.dart';

import 'package:gstore/compent/line_chart.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/page/perf/third_party_section.dart';

/// 假 Shizuku：可编程 binder / 授权状态，不触达平台通道。
class _FakeShizuku extends ShizukuApi {
  _FakeShizuku({this.binder = true, this.granted = true});

  final bool binder;
  final bool granted;

  @override
  Future<bool?> pingBinder() async => binder;

  @override
  Future<bool?> checkPermission() async => granted;

  @override
  Future<bool?> requestPermission() async => granted;

  @override
  Future<String?> runCommand(String command) async => null;
}

/// 假服务：绕过 `installed_apps` 平台通道，返回固定应用与启动耗时结果。
class _StartupService extends ThirdPartyPerfService {
  _StartupService({bool binder = true, bool granted = true})
      : super(
          runner: (cmd) async => null,
          shizukuApi: _FakeShizuku(binder: binder, granted: granted),
        );

  @override
  Future<List<AppTarget>> listInstalledApps() async => const <AppTarget>[
        AppTarget(package: 'com.example.app', label: '示例应用'),
      ];

  @override
  Future<PerfStartupResult?> measureStartup(
    String package, {
    required bool cold,
  }) async =>
      PerfStartupResult(
        status: 'ok',
        activity: 'com.example.app/.MainActivity',
        thisTimeMs: 800,
        totalTimeMs: 1234,
        waitTimeMs: 1250,
        mode: cold ? 'cold' : 'warm',
      );
}

/// 测试宿主：挂载全局 navigatorKey（统一弹层）与 scaffoldMessengerKey（Snackbar）。
Widget _harness(ThirdPartyPerfService service) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(
        body: SingleChildScrollView(
          child: ThirdPartyAppSection(service: service),
        ),
      ),
    );

/// 放大视口，确保底部「启动耗时」卡在可点击区域内。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 8000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 推进若干帧完成异步检测（不用 pumpAndSettle：统一弹层 / AppLoading 动画会超时）。
Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _selectApp(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('perf_third_party_pick')));
  await _settleAsync(tester);
  await tester.tap(find.text('示例应用'));
  await _settleAsync(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('冷启动：确认弹层 → 测量 → 渲染结果与折线', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_harness(_StartupService()));
    await _settleAsync(tester);
    await _selectApp(tester);

    // 未测量：按钮可点（已授权 + 已选目标）。
    final coldBefore =
        tester.widget<FilledButton>(find.byKey(const Key('perf_startup_cold')));
    expect(coldBefore.onPressed, isNotNull);
    expect(find.text('尚未测量'), findsOneWidget);

    // 点「测冷启动」→ 确认弹层（控制动作）。
    await tester.tap(find.byKey(const Key('perf_startup_cold')));
    await _settleAsync(tester);
    expect(find.text('测量冷启动？'), findsOneWidget);
    expect(find.textContaining('将强制停止并重新拉起'), findsOneWidget);

    // 确认 → 测量 → 渲染结果。
    await tester.tap(find.text('开始测量'));
    await _settleAsync(tester);

    expect(find.text('启动耗时'), findsOneWidget);
    expect(find.text('1234 ms'), findsOneWidget); // TotalTime
    expect(find.text('800 ms'), findsOneWidget); // ThisTime
    expect(find.text('1250 ms'), findsOneWidget); // WaitTime
    expect(find.text('冷启动'), findsOneWidget);
    expect(find.textContaining('MainActivity'), findsOneWidget);
    expect(find.byType(LineChart), findsWidgets);
    expect(find.text('尚未测量'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Shizuku 不可用 → 启动耗时按钮禁用', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_harness(_StartupService(binder: false)));
    await _settleAsync(tester);

    expect(find.text('启动耗时'), findsOneWidget);
    final cold =
        tester.widget<FilledButton>(find.byKey(const Key('perf_startup_cold')));
    final warm =
        tester.widget<FilledButton>(find.byKey(const Key('perf_startup_warm')));
    expect(cold.onPressed, isNull);
    expect(warm.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未选择目标 → 启动耗时按钮禁用', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_harness(_StartupService()));
    await _settleAsync(tester);

    expect(find.text('未选择应用'), findsOneWidget);
    final cold =
        tester.widget<FilledButton>(find.byKey(const Key('perf_startup_cold')));
    expect(cold.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}

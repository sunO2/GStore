import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shizuku_api/shizuku_api.dart';

import 'package:gstore/core/perf/perf_alert_service.dart';
import 'package:gstore/core/perf/perf_alert_settings.dart';
import 'package:gstore/core/perf/third_party_perf_service.dart';
import 'package:gstore/page/perf/third_party_section.dart';

/// 假 Shizuku：不触达平台通道。
class _FakeShizuku extends ShizukuApi {
  @override
  Future<bool?> pingBinder() async => false;

  @override
  Future<bool?> checkPermission() async => false;

  @override
  Future<bool?> requestPermission() async => false;

  @override
  Future<String?> runCommand(String command) async => null;
}

/// 假服务：绕过 `installed_apps` 平台通道（测试环境无宿主，调用会挂起）。
class _FakeService extends ThirdPartyPerfService {
  _FakeService()
      : super(
          runner: (cmd) async => null,
          shizukuApi: _FakeShizuku(),
        );

  @override
  Future<List<AppTarget>> listInstalledApps() async => const <AppTarget>[];
}

/// 记录型告警出口。
class _RecordingNotifier implements PerfAlertNotifier {
  final List<PerfAlert> banners = <PerfAlert>[];
  final List<PerfAlert> notifications = <PerfAlert>[];

  @override
  Future<void> showBanner(PerfAlert alert) async => banners.add(alert);

  @override
  Future<void> notify(PerfAlert alert) async => notifications.add(alert);
}

Widget _harness({
  required PerfAlertSettingsStore store,
  PerfAlertNotifier? notifier,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ThirdPartyAppSection(
            service: _FakeService(),
            alertStore: store,
            alertNotifier: notifier ?? _RecordingNotifier(),
          ),
        ),
      ),
    );

/// 放大视口，确保告警卡阈值行在可点击区域内。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 推进若干帧完成异步检测（不用 pumpAndSettle：AppLoading 无限动画会超时）。
Future<void> _settleAsync(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('渲染告警卡：开关 + 当前阈值', (tester) async {
    _useTallViewport(tester);
    await tester.pumpWidget(_harness(store: InMemoryPerfAlertSettingsStore()));
    await _settleAsync(tester);

    expect(find.text('告警'), findsOneWidget);
    expect(find.text('启用告警'), findsOneWidget);
    expect(find.text('系统通知'), findsOneWidget);
    expect(find.text('应用内横幅'), findsOneWidget);
    expect(find.byKey(const Key('perf_alert_enabled')), findsOneWidget);
    expect(find.byKey(const Key('perf_alert_notify')), findsOneWidget);
    expect(find.byKey(const Key('perf_alert_banner')), findsOneWidget);

    // 默认阈值。
    expect(find.text('≥ 80%'), findsOneWidget);
    expect(find.text('≥ 45 °C'), findsOneWidget);
    expect(find.text('≥ 5%'), findsOneWidget);
    expect(find.text('< 50 fps'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('开启总开关并切换通知开关：持久化生效', (tester) async {
    _useTallViewport(tester);
    final store = InMemoryPerfAlertSettingsStore();
    await tester.pumpWidget(_harness(store: store));
    await _settleAsync(tester);

    // 默认关闭 → 通知/横幅开关禁用。
    final notifyBefore =
        tester.widget<Switch>(find.byKey(const Key('perf_alert_notify')));
    expect(notifyBefore.onChanged, isNull);

    await tester.tap(find.byKey(const Key('perf_alert_enabled')));
    await tester.pump();

    expect((await store.load())!.enabled, isTrue);
    final notifyAfter =
        tester.widget<Switch>(find.byKey(const Key('perf_alert_notify')));
    expect(notifyAfter.onChanged, isNotNull);

    await tester.tap(find.byKey(const Key('perf_alert_notify')));
    await tester.pump();
    expect((await store.load())!.notify, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点按阈值行 → 弹层编辑 → 保存后更新并持久化', (tester) async {
    _useTallViewport(tester);
    final store = InMemoryPerfAlertSettingsStore();
    await tester.pumpWidget(_harness(store: store));
    await _settleAsync(tester);

    await tester.tap(find.byKey(const Key('perf_alert_threshold_cpu')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const Key('perf_alert_threshold_input')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('perf_alert_threshold_input')),
      '95',
    );
    await tester.tap(find.byKey(const Key('perf_alert_threshold_save')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('≥ 95%'), findsOneWidget);
    expect((await store.load())!.cpuPercent, 95);
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_history_recorder.dart';
import 'package:gstore/core/perf/battery_history_store.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/page/perf/battery_diagnostics_card.dart';

/// scene-to-gstore-parity Task 3：电池诊断卡片 widget 测试。
///
/// 全部 seam 注入：`reading`（[BatteryReport]）/ `sources` /
/// `recorder`（真 [BatteryHistoryRecorder] + 假 sampler + [InMemoryBatteryHistoryStore]），
/// **不触碰 FFI / 平台通道 / 真机**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 铺满大视口（展开后字段较多）。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget harness(Widget card) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: card)));

  /// 采样器：固定返回 [sample]（`null` → no_reading）；不启动定时器（延迟 1h）。
  BatteryHistoryRecorder makeRecorder({BatteryHistorySample? sample}) {
    final recorder = BatteryHistoryRecorder(
      store: InMemoryBatteryHistoryStore(),
      sampler: () async => sample,
      initialDelay: const Duration(hours: 1),
      interval: const Duration(hours: 1),
    );
    addTearDown(recorder.dispose);
    return recorder;
  }

  BatteryReport reading({double? current = 100, double? voltage = 4.0}) =>
      BatteryReport(
        present: true,
        basePath: '/sys/class/power_supply/battery',
        capacityPercent: 80,
        voltageV: voltage,
        currentMa: current,
        temperatureC: 30.5,
        status: 'Discharging',
        health: 'Good',
      );

  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('battery_diagnostics_toggle')));
    await tester.pump();
  }

  testWidgets('展开后渲染读数 / 数据源 / 采样器计数，正常态无原因提示',
      (tester) async {
    useTallViewport(tester);
    final recorder = makeRecorder(
      sample: const BatteryHistorySample(
        status: 3,
        screenOn: true,
        temperatureC: 30,
        currentMa: 100,
        voltageV: 4.0,
        capacityPercent: 50,
        package: 'com.x',
      ),
    );
    recorder.start();
    await recorder.sampleOnce(); // 落库 1 条，lastSkipReason='stored'
    expect(recorder.insertedCount, 1);

    await tester.pumpWidget(harness(BatteryDiagnosticsCard(
      reading: reading(),
      sources: const <String>{'sysfs', 'battery_manager'},
      recorder: recorder,
    )));
    await tester.pump();
    await expand(tester);

    expect(find.byKey(const Key('battery_diagnostics_card')), findsOneWidget);
    expect(find.text('电池诊断'), findsOneWidget);
    // 读数
    expect(find.text('已检测'), findsOneWidget);
    expect(find.text('battery_manager, sysfs'), findsOneWidget);
    expect(find.text('/sys/class/power_supply/battery'), findsOneWidget);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('4.00 V'), findsOneWidget);
    expect(find.text('100.0 mA'), findsOneWidget);
    expect(find.text('30.5 °C'), findsOneWidget);
    expect(find.text('Discharging'), findsOneWidget);
    expect(find.text('Good'), findsOneWidget);
    // 采样器
    expect(find.text('是'), findsOneWidget); // isRecording
    expect(find.text('1'), findsWidgets); // insertedCount
    expect(find.text('stored'), findsOneWidget); // lastSkipReason
    expect(find.textContaining('状态 3'), findsOneWidget); // lastSample

    // 无任何原因提示。
    expect(find.textContaining('采样器未运行'), findsNothing);
    expect(find.textContaining('电流/电压缺失'), findsNothing);
    expect(find.textContaining('读数不完整'), findsNothing);
    expect(find.textContaining('尚无有效落库样本'), findsNothing);

    recorder.stop(); // 取消采样定时器（避免测试结束仍 pending）
    expect(tester.takeException(), isNull);
  });

  testWidgets('电流/电压缺失 → SELinux 提示', (tester) async {
    useTallViewport(tester);
    final recorder = makeRecorder(
      sample: const BatteryHistorySample(
        status: 3,
        screenOn: true,
        currentMa: 100,
        voltageV: 4.0,
      ),
    );
    recorder.start();
    await recorder.sampleOnce(); // 采样中 + 已落库 → 只剩「字段缺失」提示

    await tester.pumpWidget(harness(BatteryDiagnosticsCard(
      reading: reading(current: null),
      recorder: recorder,
    )));
    await tester.pump();

    expect(
      find.text('电流/电压缺失（sysfs 被 SELinux 限制？尝试授权 Shizuku）'),
      findsOneWidget,
    );

    recorder.stop();
    expect(tester.takeException(), isNull);
  });

  testWidgets('采样器未运行 → 提示（且不误报字段缺失）', (tester) async {
    useTallViewport(tester);
    final recorder = makeRecorder(); // 未 start

    await tester.pumpWidget(harness(BatteryDiagnosticsCard(
      reading: reading(),
      recorder: recorder,
    )));
    await tester.pump();

    expect(find.text('采样器未运行（main() 未启动？）'), findsOneWidget);
    expect(find.textContaining('电流/电压缺失'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('最近一拍不完整 → 「已跳过」提示', (tester) async {
    useTallViewport(tester);
    final recorder = makeRecorder(
      // 亮屏但无电量 / 无功率对 → 门控拒绝 → incomplete。
      sample: const BatteryHistorySample(status: 3, screenOn: true),
    );
    recorder.start();
    await recorder.sampleOnce();
    expect(recorder.lastSkipReason, 'incomplete');

    await tester.pumpWidget(harness(BatteryDiagnosticsCard(
      reading: reading(),
      recorder: recorder,
    )));
    await tester.pump();

    expect(find.text('读数不完整，已跳过'), findsOneWidget);

    recorder.stop();
    expect(tester.takeException(), isNull);
  });

  testWidgets('采样中但零落库 → 「尚无有效落库样本」提示', (tester) async {
    useTallViewport(tester);
    final recorder = makeRecorder();
    recorder.start(); // recording=true，count=0，lastSkipReason=null

    await tester.pumpWidget(harness(BatteryDiagnosticsCard(
      reading: reading(),
      recorder: recorder,
    )));
    await tester.pump();

    expect(find.text('尚无有效落库样本'), findsOneWidget);

    recorder.stop();
    expect(tester.takeException(), isNull);
  });

  test('batteryDiagnosticsHints：按优先级返回适用提示', () {
    // 未运行 + 无读数 → 仅「未运行」（无电池不误报字段缺失）。
    expect(
      batteryDiagnosticsHints(reading: null, recorder: null),
      <String>['采样器未运行（main() 未启动？）'],
    );

    // 有电池但电流 / 电压缺失 + 未运行 → 两条，未运行在前。
    final hints = batteryDiagnosticsHints(
      reading: BatteryReport(present: true, capacityPercent: 50),
      recorder: null,
    );
    expect(hints, <String>[
      '采样器未运行（main() 未启动？）',
      '电流/电压缺失（sysfs 被 SELinux 限制？尝试授权 Shizuku）',
    ]);
  });
}

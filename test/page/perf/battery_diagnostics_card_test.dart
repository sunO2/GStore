import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/battery_history_recorder.dart';
import 'package:gstore/core/perf/battery_history_store.dart';
import 'package:gstore/core/perf/battery_source.dart';
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
      reading: const BatteryReport(present: true, capacityPercent: 50),
      recorder: null,
    );
    expect(hints, <String>[
      '采样器未运行（main() 未启动？）',
      '电流/电压缺失（sysfs 被 SELinux 限制？尝试授权 Shizuku）',
    ]);
  });

  // ==================== 逐源读取（手动） ====================

  /// 25 行原始输出（便于验证只看末 20 行）。
  String rawDumpsys() =>
      List<String>.generate(25, (i) => '  line-${i + 1}: ${i + 1}').join('\n');

  BatterySourceDiagnostic sysfsDiagnostic() => const BatterySourceDiagnostic(
        source: 'sysfs',
        reading: BatteryReading(
          present: true,
          capacityPercent: 80,
          voltageV: 4.0,
          currentMa: 100,
          temperatureC: 30.5,
          statusLabel: 'Discharging',
          sources: <String>{'sysfs'},
        ),
      );

  BatterySourceDiagnostic batteryManagerDiagnostic() =>
      const BatterySourceDiagnostic(
        source: 'battery_manager',
        reading: BatteryReading(
          present: true,
          capacityPercent: 81,
          voltageV: 4.01,
          currentMa: 101,
          temperatureC: 30.6,
          statusLabel: 'Charging',
          interactive: true,
          sources: <String>{'battery_manager'},
        ),
      );

  BatterySourceDiagnostic dumpsysDiagnostic() => BatterySourceDiagnostic(
        source: 'dumpsys',
        reading: const BatteryReading(
          present: true,
          capacityPercent: 82,
          sources: <String>{'dumpsys'},
        ),
        raw: rawDumpsys(),
      );

  testWidgets('逐源读取：按需触发 loader 一次，渲染三源 + 可折叠原始输出',
      (tester) async {
    useTallViewport(tester);
    final recorder = makeRecorder();
    var calls = 0;

    await tester.pumpWidget(harness(BatteryDiagnosticsCard(
      reading: reading(),
      recorder: recorder,
      diagnosticsLoader: () async {
        calls++;
        return <BatterySourceDiagnostic>[
          sysfsDiagnostic(),
          batteryManagerDiagnostic(),
          dumpsysDiagnostic(),
        ];
      },
    )));
    await expand(tester);

    // 未点击前绝不自发读取。
    expect(calls, 0);
    expect(find.byKey(const Key('battery_diagnostics_source_sysfs')),
        findsNothing);

    await tester.tap(find.byKey(const Key('battery_diagnostics_run')));
    await tester.pump();
    await tester.pump();

    expect(calls, 1);
    expect(find.byKey(const Key('battery_diagnostics_loading')), findsNothing);
    for (final source in <String>['sysfs', 'battery_manager', 'dumpsys']) {
      expect(
        find.byKey(Key('battery_diagnostics_source_$source')),
        findsOneWidget,
      );
    }
    // 摘要：present / 电量 / 电压 / 电流 / 温度 / status / interactive。
    expect(find.textContaining('present · 电量 80%'), findsOneWidget);
    expect(find.textContaining('电压 4.00 V'), findsOneWidget);
    expect(find.textContaining('电流 100.0 mA'), findsOneWidget);
    expect(find.textContaining('温度 30.5 °C'), findsOneWidget);
    expect(find.textContaining('status Discharging'), findsOneWidget);
    expect(find.textContaining('interactive 是'), findsOneWidget);

    // 原始输出默认折叠；展开后仅显示末 20 行。
    expect(
      find.byKey(const Key('battery_diagnostics_raw_output_dumpsys')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('battery_diagnostics_raw_dumpsys')));
    await tester.pump();
    expect(
      find.byKey(const Key('battery_diagnostics_raw_output_dumpsys')),
      findsOneWidget,
    );
    expect(find.textContaining('line-25: 25'), findsOneWidget);
    expect(find.textContaining('line-6: 6'), findsOneWidget);
    expect(find.textContaining('line-5: 5'), findsNothing);
    expect(find.textContaining('line-1: 1'), findsNothing);

    // 收起 → 再次展开：诊断结果被重置。
    await expand(tester); // 收起
    expect(find.byKey(const Key('battery_diagnostics_source_sysfs')),
        findsNothing);
    await expand(tester); // 展开
    expect(find.byKey(const Key('battery_diagnostics_source_sysfs')),
        findsNothing);
    expect(calls, 1);

    expect(tester.takeException(), isNull);
  });

  testWidgets('逐源读取：渲染源 error，且 loader 抛出时显示错误行', (tester) async {
    useTallViewport(tester);
    final recorder = makeRecorder();

    await tester.pumpWidget(harness(BatteryDiagnosticsCard(
      reading: reading(),
      recorder: recorder,
      diagnosticsLoader: () async => <BatterySourceDiagnostic>[
        const BatterySourceDiagnostic(
          source: 'sysfs',
          error: 'MissingPluginException(boom)',
        ),
      ],
    )));
    await expand(tester);
    await tester.tap(find.byKey(const Key('battery_diagnostics_run')));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('battery_diagnostics_source_error_sysfs')),
      findsOneWidget,
    );
    expect(find.textContaining('MissingPluginException(boom)'), findsOneWidget);
    expect(find.textContaining('无读数'), findsOneWidget);

    // loader 抛异常（生产实现绝不抛出，但 UI 仍需兜底）。
    await tester.pumpWidget(harness(BatteryDiagnosticsCard(
      key: UniqueKey(),
      reading: reading(),
      recorder: recorder,
      diagnosticsLoader: () async => throw StateError('loader boom'),
    )));
    await expand(tester);
    await tester.tap(find.byKey(const Key('battery_diagnostics_run')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('battery_diagnostics_error')), findsOneWidget);
    expect(find.textContaining('loader boom'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('逐源读取：读取期间显示 loading，完成后替换为结果', (tester) async {
    useTallViewport(tester);
    final recorder = makeRecorder();
    final completer = Completer<List<BatterySourceDiagnostic>>();
    var calls = 0;

    await tester.pumpWidget(harness(BatteryDiagnosticsCard(
      reading: reading(),
      recorder: recorder,
      diagnosticsLoader: () {
        calls++;
        return completer.future;
      },
    )));
    await expand(tester);
    await tester.tap(find.byKey(const Key('battery_diagnostics_run')));
    await tester.pump();

    expect(find.byKey(const Key('battery_diagnostics_loading')), findsOneWidget);
    expect(find.text('读取中…'), findsOneWidget);
    // loading 期间按钮禁用，重复点击不会并发读取。
    await tester.tap(find.byKey(const Key('battery_diagnostics_run')));
    await tester.pump();
    expect(calls, 1);

    completer.complete(<BatterySourceDiagnostic>[sysfsDiagnostic()]);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('battery_diagnostics_loading')), findsNothing);
    expect(find.byKey(const Key('battery_diagnostics_source_sysfs')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('batteryDiagnosticsRawTail：仅保留末 N 行并去掉尾部空行', () {
    final raw = List<String>.generate(30, (i) => 'L${i + 1}').join('\n');
    final tail = batteryDiagnosticsRawTail('$raw\n\n');
    final lines = tail.split('\n');
    expect(lines, hasLength(kBatteryDiagnosticsRawTailLines));
    expect(lines.first, 'L11');
    expect(lines.last, 'L30');

    expect(batteryDiagnosticsRawTail('a\nb\n'), 'a\nb');
    expect(batteryDiagnosticsRawTail('only'), 'only');
  });
}

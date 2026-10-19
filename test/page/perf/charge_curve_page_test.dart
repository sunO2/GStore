import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/charge_history.dart';
import 'package:gstore/core/perf/charge_history_store.dart';
import 'package:gstore/page/perf/charge_curve_page.dart';

/// scene-to-gstore-parity todo 22：充电曲线页 widget 测试。
///
/// 数据源注入 [InMemoryChargeHistoryStore]（避开 `shared_preferences` 通道）。
/// 页面无弹层，故 harness 用纯 [MaterialApp]。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget harness(ChargeHistoryStore store) =>
      MaterialApp(home: ChargeCurvePage(store: store));

  /// 推进若干帧（不用 pumpAndSettle：[AppLoading] 无限动画会超时）。
  Future<void> pump(WidgetTester tester, [int frames = 20]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  ChargeRecord rec({
    required int time,
    required int session,
    required int capacity,
    int current = 100,
    double voltage = 4.0,
    double temperature = 30,
  }) =>
      ChargeRecord(
        time: time,
        session: session,
        current: current,
        voltage: voltage,
        capacity: capacity,
        temperature: temperature,
      );

  /// 单会话（session 2）；容量 20/50/90，电流/温度递增。
  InMemoryChargeHistoryStore singleSession() => InMemoryChargeHistoryStore(
        seed: <ChargeRecord>[
          rec(time: 2000, session: 2, capacity: 20, current: 100, temperature: 30),
          rec(time: 3000, session: 2, capacity: 50, current: 200, temperature: 35),
          rec(time: 4000, session: 2, capacity: 90, current: 300, temperature: 40),
        ],
      );

  /// 两会话：session 1 较早（容量 10~20），session 2 较新（容量 30~80）。
  InMemoryChargeHistoryStore twoSessions() => InMemoryChargeHistoryStore(
        seed: <ChargeRecord>[
          rec(time: 1000, session: 1, capacity: 10, current: 120),
          rec(time: 1500, session: 1, capacity: 20, current: 150),
          rec(time: 5000, session: 2, capacity: 30, current: 200),
          rec(time: 6000, session: 2, capacity: 80, current: 320),
        ],
      );

  testWidgets('空 store → 空提示 + 三张空图表，无异常', (tester) async {
    await tester.pumpWidget(harness(InMemoryChargeHistoryStore()));
    await pump(tester);

    expect(find.byKey(const Key('charge_curve_empty')), findsOneWidget);
    expect(find.byKey(const Key('charge_curve_chart_current')), findsOneWidget);
    expect(
      find.byKey(const Key('charge_curve_chart_temperature')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('charge_curve_chart_power')), findsOneWidget);
    // 单会话 / 空数据不渲染会话选择器。
    expect(
      find.byKey(const Key('charge_curve_session_picker')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('单会话 → 三张图表渲染 + 容量范围，无空提示', (tester) async {
    await tester.pumpWidget(harness(singleSession()));
    await pump(tester);

    expect(find.byKey(const Key('charge_curve_empty')), findsNothing);
    expect(find.byKey(const Key('charge_curve_chart_current')), findsOneWidget);
    expect(
      find.byKey(const Key('charge_curve_chart_temperature')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('charge_curve_chart_power')), findsOneWidget);
    expect(find.text('电流 · 容量'), findsOneWidget);
    expect(find.text('温度 · 容量'), findsOneWidget);
    expect(find.text('功率 · 容量'), findsOneWidget);
    expect(find.text('横轴：容量 20 ~ 90%'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多会话 → 选择器可选，切换后容量范围更新', (tester) async {
    await tester.pumpWidget(harness(twoSessions()));
    await pump(tester);

    expect(
      find.byKey(const Key('charge_curve_session_picker')),
      findsOneWidget,
    );
    // 默认最新会话 = session 2（容量 30~80）。
    expect(find.text('横轴：容量 30 ~ 80%'), findsWidgets);

    await tester.tap(find.byKey(const Key('charge_curve_session_picker')));
    await pump(tester);
    await tester.tap(find.textContaining('会话 1').last);
    await pump(tester);

    // 切换到 session 1（容量 10~20）。
    expect(find.text('横轴：容量 10 ~ 20%'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  test('chargeCurveSeries：按会话过滤并按容量升序', () {
    final records = <ChargeRecord>[
      rec(time: 3000, session: 2, capacity: 90),
      rec(time: 1000, session: 1, capacity: 5),
      rec(time: 2000, session: 2, capacity: 20),
      rec(time: 4000, session: 2, capacity: 50),
    ];
    final series = chargeCurveSeries(records, session: 2);

    expect(series.map((r) => r.capacity).toList(), [20, 50, 90]);
    expect(series.map((r) => r.session).toSet(), {2});
    expect(chargeCurveSeries(records, session: 99), isEmpty);
  });
}

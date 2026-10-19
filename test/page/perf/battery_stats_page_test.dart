import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/perf/battery_history.dart';
import 'package:gstore/core/perf/battery_history_store.dart';
import 'package:gstore/page/perf/battery_stats_page.dart';

/// scene-to-gstore-parity todo 20：耗电统计页 widget 测试。
///
/// 数据源注入 [InMemoryBatteryHistoryStore]（避开 `shared_preferences` 通道）；
/// 弹层经全局 `appNavigatorKey` / Snackbar 经 `scaffoldMessengerKey`（[AppDialogs]）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget harness(BatteryHistoryStore store) => MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: BatteryStatsPage(store: store),
      );

  /// 推进若干帧（不用 pumpAndSettle：[AppLoading] 无限动画会超时）。
  Future<void> pump(WidgetTester tester, [int frames = 20]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  /// 一条屏幕点亮、放电(status=3)的有效功耗样本。
  BatteryHistoryRecord rec({
    required int timeMs,
    required int session,
    required String package,
    String mode = 'balance',
    int current = 100,
    double voltage = 4.0,
    double temperature = 30,
  }) =>
      BatteryHistoryRecord(
        time: '$timeMs',
        session: session,
        temperature: temperature,
        status: kBatteryStatusDischarging,
        mode: mode,
        current: current,
        voltage: voltage,
        package: package,
        screenOn: 1,
        capacity: 50,
      );

  /// 两个会话（session 2 更新、为默认选中）：session 2 单应用 1 小时放电。
  InMemoryBatteryHistoryStore seeded() => InMemoryBatteryHistoryStore(
        seed: <BatteryHistoryRecord>[
          // 旧会话 1
          rec(timeMs: 1000000, session: 1, package: 'com.old.app'),
          rec(
            timeMs: 4600000,
            session: 1,
            package: 'com.old.app',
            current: 300,
            temperature: 35,
          ),
          // 新会话 2（1 小时间隔，电流 100→200 → 估算 150 mAh）
          rec(
            timeMs: 1000000000000,
            session: 2,
            package: 'com.c.app',
            mode: 'performance',
          ),
          rec(
            timeMs: 1000003600000,
            session: 2,
            package: 'com.c.app',
            mode: 'performance',
            current: 200,
            temperature: 40,
          ),
        ],
      );

  testWidgets('空 store → 空状态 + 刷新动作', (tester) async {
    await tester.pumpWidget(harness(InMemoryBatteryHistoryStore()));
    await pump(tester);

    expect(find.byKey(const Key('battery_stats_empty')), findsOneWidget);
    expect(find.text('暂无电池记录'), findsOneWidget);
    expect(
      find.byKey(const Key('battery_stats_empty_refresh')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('按时间：会话卡片渲染时长 / 估算 mAh / 温度', (tester) async {
    await tester.pumpWidget(harness(seeded()));
    await pump(tester);

    // 两个会话卡片（新会话在前）。
    expect(
      find.byKey(const Key('battery_stats_session_card_2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('battery_stats_session_card_1')),
      findsOneWidget,
    );
    expect(find.text('会话 2'), findsOneWidget);
    // 1 小时会话 → 时长 + 估算放电量（100→200 mA 梯形积分 1h = 150 mAh）。
    expect(find.text('1 小时 0 分'), findsWidgets);
    expect(find.text('150 mAh'), findsOneWidget);
    expect(find.text('35.0 °C'), findsOneWidget); // (30+40)/2
    expect(find.text('30.0 ~ 40.0 °C'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按应用：切到应用视角后按 (package, mode) 聚合', (tester) async {
    await tester.pumpWidget(harness(seeded()));
    await pump(tester);

    await tester.tap(find.byKey(const Key('battery_stats_mode_app')));
    await pump(tester);

    // 默认选中最新会话 2 → 仅 com.c.app。
    expect(
      find.byKey(const Key('battery_stats_app_com.c.app')),
      findsOneWidget,
    );
    expect(find.text('com.c.app'), findsWidgets);
    expect(find.text('performance'), findsOneWidget);
    expect(find.text('150.0 mA'), findsOneWidget); // avg(current)
    expect(find.text('600'), findsOneWidget); // avg(current*voltage)
    expect(find.text('35.0 °C'), findsOneWidget);
    expect(find.text('30.0 ~ 40.0 °C'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空动作：危险确认后 store 清空并回到空状态', (tester) async {
    final store = seeded();
    await tester.pumpWidget(harness(store));
    await pump(tester);

    await tester.tap(find.byKey(const Key('battery_stats_clear')));
    await pump(tester);
    expect(find.text('清空电池记录？'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await pump(tester);

    expect(await store.load(), isEmpty);
    expect(find.byKey(const Key('battery_stats_empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/compent/line_chart.dart';

/// 给图表一个有界尺寸（`LineChart` 宽度为 `double.infinity`，需外部约束）。
Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: 220, child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('LineChart 用样本数据渲染（不抛异常）', (tester) async {
    await tester.pumpWidget(
      _host(const LineChart(values: <double>[1, 3, 2, 5, 4, 6, 3])),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(LineChart), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('LineChart 空数据绘制基线（不抛异常）', (tester) async {
    await tester.pumpWidget(
      _host(const LineChart(values: <double>[])),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(LineChart), findsOneWidget);
  });

  testWidgets('LineChart 单点 / 全等 / NaN / Infinity 边界均不抛异常', (tester) async {
    // 单点：应绘制贯穿平线。
    await tester.pumpWidget(_host(const LineChart(values: <double>[42])));
    expect(tester.takeException(), isNull);

    // 全等：应绘制居中平线（无除零）。
    await tester.pumpWidget(
      _host(const LineChart(values: <double>[5, 5, 5, 5])),
    );
    expect(tester.takeException(), isNull);

    // NaN / Infinity：跳过并断开线段。
    await tester.pumpWidget(
      _host(const LineChart(
        values: <double>[1, double.nan, 3, double.infinity, 2, double.nan],
      )),
    );
    expect(tester.takeException(), isNull);

    // 全部为非法值：退回基线。
    await tester.pumpWidget(
      _host(const LineChart(values: <double>[double.nan, double.infinity])),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('LineChart 支持显式 minY/maxY、网格与关闭填充', (tester) async {
    await tester.pumpWidget(
      _host(const LineChart(
        values: <double>[10, 40, 80],
        minY: 0,
        maxY: 100,
        gridLines: 3,
        fill: false,
        showMarker: false,
        strokeWidth: 3,
      )),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('GaugeChart 渲染数值（不抛异常）', (tester) async {
    await tester.pumpWidget(
      _host(const GaugeChart(value: 62.5)),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(GaugeChart), findsOneWidget);
  });

  testWidgets('GaugeChart 越界 / 非法值被钳制（不抛异常）', (tester) async {
    await tester.pumpWidget(_host(const GaugeChart(value: -10)));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_host(const GaugeChart(value: 150)));
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(_host(const GaugeChart(value: double.nan)));
    expect(tester.takeException(), isNull);
  });
}

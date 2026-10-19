import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/scene_thresholds.dart';
import 'package:gstore/page/perf/scene_perf_style.dart';
import 'package:gstore/page/perf/scene_ring_gauge.dart';

/// 宿主：有界宽度 + 主题，供 [SceneRingGauge] 渲染。
Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 220, child: child)),
      ),
    );

/// 从已渲染的 gauge 中取回绘制器（唯一 `SceneRingPainter`）。
SceneRingPainter _painterOf(WidgetTester tester) {
  final CustomPaint paint = tester.widget<CustomPaint>(
    find.byWidgetPredicate(
      (Widget w) => w is CustomPaint && w.painter is SceneRingPainter,
    ),
  );
  return paint.painter! as SceneRingPainter;
}

void main() {
  testWidgets('SceneRingGauge 渲染数值 / 标签 / 副标签（不抛异常）', (tester) async {
    await tester.pumpWidget(
      _host(const SceneRingGauge(
        value: 62.5,
        tierColor: Colors.teal,
        label: '内存',
        sublabel: '3.0 / 8.0 GB',
        valueText: '62%',
      )),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(SceneRingGauge), findsOneWidget);
    expect(find.text('62%'), findsOneWidget);
    expect(find.text('内存'), findsOneWidget);
    expect(find.text('3.0 / 8.0 GB'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('SceneRingGauge 百分比量纲（max:100）归一化正确', (tester) async {
    await tester.pumpWidget(
      _host(const SceneRingGauge(value: 25, tierColor: Colors.teal)),
    );
    expect(tester.takeException(), isNull);
    expect(_painterOf(tester).fraction, closeTo(0.25, 0.0001));
  });

  testWidgets('SceneRingGauge 0..1 量纲（max:1）归一化正确', (tester) async {
    await tester.pumpWidget(
      _host(const SceneRingGauge(
        value: 0.5,
        max: 1,
        tierColor: Colors.teal,
      )),
    );
    expect(tester.takeException(), isNull);
    expect(_painterOf(tester).fraction, closeTo(0.5, 0.0001));
  });

  testWidgets('SceneRingGauge 越界 / NaN / Infinity / max<=0 均钳制（不抛异常）',
      (tester) async {
    for (final (double value, double max) in <(double, double)>[
      (-10, 100),
      (150, 100),
      (double.nan, 100),
      (double.infinity, 100),
      (50, 0),
      (50, -1),
      (50, double.nan),
    ]) {
      await tester.pumpWidget(
        _host(SceneRingGauge(value: value, max: max, tierColor: Colors.teal)),
      );
      expect(tester.takeException(), isNull);
      final double f = _painterOf(tester).fraction;
      expect(f, greaterThanOrEqualTo(0.0));
      expect(f, lessThanOrEqualTo(1.0));
    }
  });

  testWidgets('SceneRingGauge 传递 tierColor 到绘制器', (tester) async {
    await tester.pumpWidget(
      _host(const SceneRingGauge(value: 50, tierColor: Color(0xFF123456))),
    );
    expect(_painterOf(tester).color, const Color(0xFF123456));
  });

  group('ScenePerfStyle 阈值色档映射（无硬编码，仅主题角色 + Scene 强调色）', () {
    final ColorScheme scheme = ColorScheme.fromSeed(seedColor: Colors.blue);

    test('强调色为 Scene colorAccent', () {
      expect(ScenePerfStyle.accent, const Color(0xFFBC8DE4));
    });

    test('CPU 负载档：85 / 65 边界', () {
      expect(ScenePerfStyle.cpuColor(scheme, 90), scheme.error);
      expect(ScenePerfStyle.cpuColor(scheme, 70), scheme.tertiary);
      expect(ScenePerfStyle.cpuColor(scheme, 30), ScenePerfStyle.accent);
      // 边界值：85 不越 veryHigh（严格大于）但 > 65 → high；65 本身不越界。
      expect(ScenePerfStyle.cpuColor(scheme, 85), scheme.tertiary);
      expect(ScenePerfStyle.cpuColor(scheme, 65), ScenePerfStyle.accent);
    });

    test('RAM 使用率档：89 / 80 边界', () {
      expect(ScenePerfStyle.ramColor(scheme, 91), scheme.error);
      expect(ScenePerfStyle.ramColor(scheme, 85), scheme.tertiary);
      expect(ScenePerfStyle.ramColor(scheme, 50), ScenePerfStyle.accent);
    });

    test('温度档：48 / 44 / 41 边界', () {
      expect(ScenePerfStyle.temperatureColor(scheme, 49), scheme.error);
      expect(ScenePerfStyle.temperatureColor(scheme, 46), scheme.error);
      expect(ScenePerfStyle.temperatureColor(scheme, 42), scheme.tertiary);
      expect(ScenePerfStyle.temperatureColor(scheme, 40), ScenePerfStyle.accent);
    });

    test('档位函数与集中阈值语义一致', () {
      expect(sceneCpuLoadTier(86), SceneLoadTier.veryHigh);
      expect(sceneRamLoadTier(81), SceneLoadTier.high);
      expect(sceneTempTier(48), SceneTempTier.veryHigh);
    });
  });
}

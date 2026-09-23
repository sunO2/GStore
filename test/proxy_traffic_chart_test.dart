import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/proxy/proxy_traffic_chart.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

ProxyTrafficChartPainter _painter({
  required List<int> up,
  required List<int> down,
  double axisMaxBps = 100000,
  int version = 1,
  Color downColor = Colors.blue,
  Color upColor = Colors.orange,
  Color gridColor = Colors.grey,
  int capacity = 60,
}) {
  return ProxyTrafficChartPainter(
    up: up,
    down: down,
    axisMaxBps: axisMaxBps,
    version: version,
    downColor: downColor,
    upColor: upColor,
    gridColor: gridColor,
    capacity: capacity,
  );
}

void main() {
  group('niceCeiling', () {
    test('非正值 / 非有限值返回 0', () {
      expect(niceCeiling(0), 0);
      expect(niceCeiling(-5), 0);
      expect(niceCeiling(double.nan), 0);
      expect(niceCeiling(double.infinity), 0);
    });

    test('取整到 1 / 2 / 5 × 10^n', () {
      expect(niceCeiling(1), 1);
      expect(niceCeiling(1.5), 2);
      expect(niceCeiling(2), 2);
      expect(niceCeiling(3), 5);
      expect(niceCeiling(5), 5);
      expect(niceCeiling(6), 10);
      expect(niceCeiling(12), 20);
      expect(niceCeiling(1200), 2000);
      expect(niceCeiling(3000), 5000);
      expect(niceCeiling(60000), 100000);
      // 结果始终 >= 输入值（不低估）。
      for (final v in <double>[1, 7, 42, 999, 65536, 1234567]) {
        expect(niceCeiling(v), greaterThanOrEqualTo(v));
      }
    });
  });

  group('TrafficAxisScale', () {
    test('下限 64 KB/s：小流量不被放大', () {
      final scale = TrafficAxisScale();
      expect(scale.current, TrafficAxisScale.minFloorBps);
      expect(scale.update(100), TrafficAxisScale.minFloorBps);
      expect(scale.update(0), TrafficAxisScale.minFloorBps);
    });

    test('增长立即跟随', () {
      final scale = TrafficAxisScale();
      expect(scale.update(200000), 200000);
      expect(scale.update(5000000), 5000000);
    });

    test('收缩带滞回：仅连续 N 个更低样本后才收缩', () {
      final scale = TrafficAxisScale(shrinkStableSamples: 3);
      expect(scale.update(5000000), 5000000);
      // 目标远低于当前：前 2 次保持不收缩。
      expect(scale.update(1000), 5000000);
      expect(scale.update(1000), 5000000);
      // 第 3 次连续更低 → 收缩到下限（1000 的 nice ceiling < 64KB，取下限）。
      expect(scale.update(1000), TrafficAxisScale.minFloorBps);
    });

    test('收缩过程中目标回升会重置稳定计数', () {
      final scale = TrafficAxisScale(shrinkStableSamples: 2);
      expect(scale.update(5000000), 5000000);
      expect(scale.update(1000), 5000000); // stable=1
      expect(scale.update(5000000), 5000000); // 回升 → stable 重置
      expect(scale.update(1000), 5000000); // stable=1，不收缩
      expect(scale.update(1000), TrafficAxisScale.minFloorBps); // stable=2 → 收缩
    });

    test('reset 回到初始下限', () {
      final scale = TrafficAxisScale();
      scale.update(5000000);
      scale.reset();
      expect(scale.current, TrafficAxisScale.minFloorBps);
      expect(scale.update(200000), 200000);
    });
  });

  group('ProxyTrafficBuffer', () {
    test('追加保持上下行等长与顺序', () {
      final buffer = ProxyTrafficBuffer();
      buffer.add(upBps: 1, downBps: 10);
      buffer.add(upBps: 2, downBps: 20);
      expect(buffer.length, 2);
      expect(buffer.up, <int>[1, 2]);
      expect(buffer.down, <int>[10, 20]);
      expect(buffer.latestUp, 2);
      expect(buffer.latestDown, 20);
      expect(buffer.rawMax, 20);
    });

    test('超过容量后丢弃最旧样本（环形窗口）', () {
      final buffer = ProxyTrafficBuffer(capacity: 3);
      for (var i = 1; i <= 5; i++) {
        buffer.add(upBps: i, downBps: i * 10);
      }
      expect(buffer.length, 3);
      expect(buffer.up, <int>[3, 4, 5]);
      expect(buffer.down, <int>[30, 40, 50]);
      expect(buffer.latestUp, 5);
    });

    test('rawMax 取两路合并最大值', () {
      final buffer = ProxyTrafficBuffer()
        ..add(upBps: 10, downBps: 5)
        ..add(upBps: 7, downBps: 99);
      expect(buffer.rawMax, 99);
    });

    test('空缓冲 rawMax / latest 为 0', () {
      final buffer = ProxyTrafficBuffer();
      expect(buffer.isEmpty, isTrue);
      expect(buffer.rawMax, 0);
      expect(buffer.latestUp, 0);
      expect(buffer.latestDown, 0);
    });

    test('clear 清空并推进 version/resetCount；空 clear 为 no-op', () {
      final buffer = ProxyTrafficBuffer();
      buffer.add(upBps: 1, downBps: 2);
      final v = buffer.version;
      final r = buffer.resetCount;
      buffer.clear();
      expect(buffer.isEmpty, isTrue);
      expect(buffer.version, greaterThan(v));
      expect(buffer.resetCount, r + 1);

      final v2 = buffer.version;
      final r2 = buffer.resetCount;
      buffer.clear();
      expect(buffer.version, v2);
      expect(buffer.resetCount, r2);
    });
  });

  group('ProxyTrafficChartPainter', () {
    test('shouldRepaint 仅在版本 / 轴上限 / 主题色变化时为 true', () {
      final base = _painter(up: const <int>[1, 2], down: const <int>[3, 4]);
      expect(
        base.shouldRepaint(
          _painter(up: const <int>[1, 2], down: const <int>[3, 4]),
        ),
        isFalse,
        reason: '版本与轴上限一致 → 不重绘',
      );
      expect(
        base.shouldRepaint(
          _painter(up: const <int>[1, 2], down: const <int>[3, 4], version: 2),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          _painter(
            up: const <int>[1, 2],
            down: const <int>[3, 4],
            axisMaxBps: 999999,
          ),
        ),
        isTrue,
      );
      expect(
        base.shouldRepaint(
          _painter(
            up: const <int>[1, 2],
            down: const <int>[3, 4],
            downColor: Colors.red,
          ),
        ),
        isTrue,
      );
    });

    test('0 / 1 / 满窗样本均能正常绘制（无异常）', () {
      for (final data in <List<int>>[
        <int>[],
        <int>[1024],
        <int>[for (var i = 0; i < 60; i++) i * 1000],
      ]) {
        final painter = _painter(
          up: data,
          down: data.reversed.toList(),
          axisMaxBps: 65536,
        );
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        painter.paint(canvas, const Size(240, 96));
        recorder.endRecording().dispose();
      }
    });
  });

  group('ProxyTrafficChart widget', () {
    testWidgets('渲染带 key 的图表，颜色取自主题令牌', (tester) async {
      final buffer = ProxyTrafficBuffer()
        ..add(upBps: 1024, downBps: 4096)
        ..add(upBps: 2048, downBps: 8192);
      await tester.pumpWidget(_wrap(ProxyTrafficChart(buffer: buffer)));
      await tester.pump();

      final Finder chart = find.byKey(const Key('proxy-traffic-chart'));
      expect(chart, findsOneWidget);

      final CustomPaint paint = tester.widget<CustomPaint>(
        find.descendant(of: chart, matching: find.byType(CustomPaint)),
      );
      final ProxyTrafficChartPainter painter =
          paint.painter! as ProxyTrafficChartPainter;
      final ColorScheme scheme =
          Theme.of(tester.element(chart)).colorScheme;
      expect(painter.downColor, scheme.primary);
      expect(painter.upColor, scheme.tertiary);
      expect(painter.gridColor, scheme.surfaceContainerHighest);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空缓冲渲染为空闲基线且无异常', (tester) async {
      await tester.pumpWidget(
        _wrap(ProxyTrafficChart(buffer: ProxyTrafficBuffer())),
      );
      await tester.pump();
      expect(find.byKey(const Key('proxy-traffic-chart')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('缓冲更新后重新绘制不抛异常', (tester) async {
      final buffer = ProxyTrafficBuffer();
      await tester.pumpWidget(_wrap(ProxyTrafficChart(buffer: buffer)));
      await tester.pump();

      // 模拟事件驱动的追加：同一 buffer，重建 widget 触发 didUpdateWidget。
      for (var i = 0; i < 5; i++) {
        buffer.add(upBps: i * 1000, downBps: 50000 - i * 1000);
        await tester.pumpWidget(_wrap(ProxyTrafficChart(buffer: buffer)));
        await tester.pump();
      }
      expect(find.byKey(const Key('proxy-traffic-chart')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

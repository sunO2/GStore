import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';

/// 读取 AppLoading 内部 CustomPaint 的 progress。
/// _ElegantRingPainter 为库私有类型，通过 dynamic 读取其公开 progress 字段。
double? loadingProgress(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(find.descendant(
    of: find.byType(AppLoading),
    matching: find.byType(CustomPaint),
  ));
  return (paint.painter as dynamic).progress as double?;
}

Widget harness({AppLoadingSize size = AppLoadingSize.medium}) => MaterialApp(
      home: Scaffold(
        body: Center(child: AppLoading(size: size)),
      ),
    );

void main() {
  testWidgets('AppLoading medium 渲染出 CustomPaint', (tester) async {
    await tester.pumpWidget(harness());
    expect(find.byType(AppLoading), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppLoading),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });

  testWidgets('跨 wrap 边界 progress 严格非降（不回跳）', (tester) async {
    await tester.pumpWidget(harness());
    final p0 = loadingProgress(tester)!;
    expect(p0, 0.0);

    // 100ms 步进 × 40 = 4s > 3s 一圈 → 至少跨过一次 wrap。
    // 旧实现 setState 延迟一帧累加，wrap 帧 progress 会回跳（N+0.999→N+0.x）；
    // 新实现监听器同帧累加，progress 必须严格连续。
    var previous = p0;
    double last = p0;
    for (var i = 1; i <= 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final p = loadingProgress(tester)!;
      expect(
        p,
        greaterThanOrEqualTo(previous),
        reason: 'progress 应严格非降（跨 wrap 不回跳），第 $i 帧: $previous -> $p',
      );
      previous = p;
      last = p;
    }
    // 累计进度 > 1：确认确实跨过了 wrap 而非只走了一圈内
    expect(last, greaterThan(1.0));
  });

  testWidgets('连续 pump 多圈不抛异常（冒烟）', (tester) async {
    await tester.pumpWidget(harness(size: AppLoadingSize.large));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    // 60 × 150ms = 9s = 3 圈
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(AppLoading),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/compent/pressable_scale.dart';

/// 测试辅助：定位 PressableScale 内部唯一的 AnimatedScale
Finder scaleOf(WidgetTester tester) => find.descendant(
      of: find.byType(PressableScale),
      matching: find.byType(AnimatedScale),
    );

double currentScale(WidgetTester tester) =>
    tester.widget<AnimatedScale>(scaleOf(tester)).scale;

Widget harness(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 120, height: 120, child: child),
        ),
      ),
    );

void main() {
  testWidgets('按下时缩至 pressedScale（动画目标值 < 1）', (tester) async {
    await tester.pumpWidget(harness(
      const PressableScale(child: ColoredBox(color: Colors.red)),
    ));

    // 初始：无缩放
    expect(currentScale(tester), 1.0);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PressableScale)),
    );
    await tester.pump();

    // 按下 → 目标 0.97（AnimatedScale 属性即动画目标值）
    expect(currentScale(tester), 0.97);

    await gesture.up();
    await tester.pump();
    await tester.pumpAndSettle();

    // 抬起 → 回弹 1.0
    expect(currentScale(tester), 1.0);
  });

  testWidgets('自定义 pressedScale 生效', (tester) async {
    await tester.pumpWidget(harness(
      const PressableScale(
        pressedScale: 0.9,
        child: ColoredBox(color: Colors.red),
      ),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PressableScale)),
    );
    await tester.pump();
    expect(currentScale(tester), 0.9);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(currentScale(tester), 1.0);
  });

  testWidgets('onTap 转发调用', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(harness(
      PressableScale(
        onTap: () => tapped++,
        child: const ColoredBox(color: Colors.red),
      ),
    ));

    await tester.tap(find.byType(PressableScale));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('onTapCancel（拖离/取消）回弹', (tester) async {
    await tester.pumpWidget(harness(
      const PressableScale(child: ColoredBox(color: Colors.red)),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PressableScale)),
    );
    await tester.pump();
    expect(currentScale(tester), 0.97);

    // 取消手势（等价于 onTapCancel 路径）
    await gesture.cancel();
    await tester.pump();
    expect(currentScale(tester), 1.0);
  });

  testWidgets('enabled=false：按下不缩放且不转发 onTap', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(harness(
      PressableScale(
        enabled: false,
        onTap: () => tapped++,
        child: const ColoredBox(color: Colors.red),
      ),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PressableScale)),
    );
    await tester.pump();
    expect(currentScale(tester), 1.0);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(currentScale(tester), 1.0);
    expect(tapped, 0);
  });

  testWidgets('与 child 内层 GestureDetector 共存：仅反馈 + 内层 onTap 生效',
      (tester) async {
    var innerTapped = 0;
    var outerTapped = 0;
    await tester.pumpWidget(harness(
      PressableScale(
        // 外层 onTap 传 null 仅做反馈（接入点模式）
        onTap: () => outerTapped++,
        child: GestureDetector(
          onTap: () => innerTapped++,
          child: const ColoredBox(color: Colors.red),
        ),
      ),
    ));

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PressableScale)),
    );
    await tester.pump();
    // 按下反馈仍然生效（外层 onTapDown 与内层 tap 不冲突）
    expect(currentScale(tester), 0.97);

    await gesture.up();
    await tester.pump();
    // 内层 GestureDetector 赢得手势竞技场：内层 onTap 执行
    expect(innerTapped, 1);
    // 外层 onTap 不执行（竞技场单一胜者），但反馈已回弹
    expect(outerTapped, 0);
    expect(currentScale(tester), 1.0);
  });
}

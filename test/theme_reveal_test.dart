import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/theme/app_theme_config.dart';
import 'package:gstore/core/theme/theme_reveal.dart';

Future<ui.Image> _makeImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 8, 8),
    Paint()..color = const Color(0xFF808080),
  );
  final picture = recorder.endRecording();
  return picture.toImage(8, 8);
}

Widget _host() {
  return MaterialApp(
    home: ThemeRevealHost(
      child: RepaintBoundary(
        key: ThemeReveal.instance.captureKey,
        child: const ColoredBox(color: Color(0xFFFAFAFA)),
      ),
    ),
  );
}

void main() {
  final reveal = ThemeReveal.instance;

  setUp(() {
    reveal.resetForTest();
    // 测试里没有真实帧耗时回调，跳过重建稳定等待。
    reveal.settleTimeout = Duration.zero;
  });

  tearDown(() {
    reveal.settleTimeout = const Duration(milliseconds: 320);
    reveal.resetForTest();
  });

  testWidgets('run 先显示旧画面遮罩，动画结束后移除并释放', (tester) async {
    final image = await tester.runAsync(_makeImage);
    reveal.captureOverride = (_) async => image;

    var applied = false;
    await tester.pumpWidget(_host());
    final future = reveal.run(
      origin: const Offset(100, 120),
      apply: () {
        applied = true;
      },
    );

    // 第一帧：截图就绪 → 覆盖层出现；随后 apply 已执行。
    await tester.pump();
    expect(applied, isTrue);
    expect(reveal.image, isNotNull, reason: '过渡期间必须用旧画面盖住新主题');

    // 推进两帧（等待新主题首帧）+ 动画时长。
    await tester.pump();
    await tester.pump();
    await tester.pump(ThemeReveal.duration + const Duration(milliseconds: 50));
    await future;

    expect(reveal.image, isNull, reason: '动画结束必须释放截图并移除覆盖层');
  });

  testWidgets('截图失败时降级为直接切换', (tester) async {
    reveal.captureOverride = (_) async => null;
    var applied = false;
    await tester.pumpWidget(_host());

    await reveal.run(
      origin: const Offset(10, 10),
      apply: () {
        applied = true;
      },
    );

    expect(applied, isTrue);
    expect(reveal.image, isNull);
  });

  testWidgets('系统关闭动画时不截图、直接切换', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    var captured = false;
    var applied = false;
    reveal.captureOverride = (_) async {
      captured = true;
      return null;
    };
    await tester.pumpWidget(_host());

    await reveal.run(
      origin: const Offset(10, 10),
      apply: () {
        applied = true;
      },
    );

    expect(captured, isFalse, reason: '关闭动画时不应产生截图开销');
    expect(applied, isTrue);
  });

  testWidgets('亮度不变的切换不播放动画（由调用方直接写入）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      themeMode: ThemeMode.light,
      theme: ThemeData(brightness: Brightness.light),
      home: const SizedBox(),
    ));
    final context = tester.element(find.byType(SizedBox));
    // 当前已是浅色：切到浅色不变，切到深色会变。
    expect(themeModeChangesBrightness(context, AppThemeMode.light), isFalse);
    expect(themeModeChangesBrightness(context, AppThemeMode.dark), isTrue);
  });
}

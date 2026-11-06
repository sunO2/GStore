import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/page/download/widgets/download_hero_card.dart';

/// 用真实主题 + 可选 disableAnimations 包裹英雄卡（限定宽度模拟手机版心）。
Widget _wrap(
  Widget child, {
  bool disableAnimations = false,
}) {
  return MaterialApp(
    home: Builder(
      builder: (context) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations: disableAnimations,
          ),
          child: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(width: 400, child: child),
              ),
            ),
          ),
        );
      },
    ),
  );
}

DownloadHeroCard _hero({
  int speedBps = 0,
  int active = 0,
  int queued = 0,
  int completed = 0,
  int failed = 0,
  int waiting = 0,
  bool canPause = false,
  bool canResume = false,
  double collapse = 0,
  VoidCallback? onPauseAll,
  VoidCallback? onResumeAll,
}) {
  return DownloadHeroCard(
    speedBps: speedBps,
    active: active,
    queued: queued,
    completed: completed,
    failed: failed,
    waiting: waiting,
    canPause: canPause,
    canResume: canResume,
    onPauseAll: onPauseAll ?? () {},
    onResumeAll: onResumeAll ?? () {},
    collapse: collapse,
  );
}

void main() {
  testWidgets('渲染实时吞吐：数字/单位分离 + 活跃/排队/完成/失败统计', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _hero(
          speedBps: (12.4 * 1024 * 1024).round(),
          active: 2,
          queued: 1,
          completed: 3,
          failed: 0,
          waiting: 1,
          canPause: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('实时吞吐'), findsOneWidget);
    expect(find.text('12.4'), findsOneWidget);
    expect(find.text('MB/s'), findsOneWidget);
    // 统计行使用「活跃」而非「下载中」，且不出现「安装 / 已删除」
    expect(find.text('活跃 2 · 排队 1 · 完成 3 · 失败 0'), findsOneWidget);
    expect(find.text('下载中'), findsNothing);
    expect(find.text('安装'), findsNothing);
    expect(find.text('已删除'), findsNothing);

    // 英雄卡不是 AppCard，也不含进度条
    expect(find.byType(AppCard), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空闲时速度显示 0 B/s', (tester) async {
    await tester.pumpWidget(
      _wrap(_hero(completed: 2, failed: 1)),
    );
    await tester.pump();

    expect(find.text('0'), findsOneWidget);
    expect(find.text('B/s'), findsOneWidget);
    expect(find.text('活跃 0 · 排队 0 · 完成 2 · 失败 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按钮按状态调用暂停/恢复回调', (tester) async {
    var paused = 0;
    var resumed = 0;

    await tester.pumpWidget(
      _wrap(
        _hero(
          speedBps: 1024 * 1024,
          active: 1,
          canPause: true,
          onPauseAll: () => paused++,
          onResumeAll: () => resumed++,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('暂停全部'));
    await tester.pump();
    expect(paused, 1);
    expect(resumed, 0);

    // 无下载中任务、仅有等待任务 → 按钮切换为「恢复全部」
    await tester.pumpWidget(
      _wrap(
        _hero(
          waiting: 1,
          canPause: false,
          canResume: true,
          onPauseAll: () => paused++,
          onResumeAll: () => resumed++,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('恢复全部'));
    await tester.pump();
    expect(paused, 1);
    expect(resumed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp 窄屏不溢出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: 320,
              child: _hero(
                speedBps: 1000 * 1024 * 1024,
                active: 9,
                queued: 99,
                completed: 999,
                failed: 99,
                waiting: 9,
                canPause: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('实时吞吐'), findsOneWidget);
    expect(find.byTooltip('暂停全部'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapse=1 简化模式：单行速度+开关，隐藏波形与统计行', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _hero(
          speedBps: (12.4 * 1024 * 1024).round(),
          active: 1,
          completed: 3,
          canPause: true,
          collapse: 1,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('实时吞吐'), findsOneWidget);
    expect(find.text('12.4'), findsOneWidget);
    expect(find.text('MB/s'), findsOneWidget);
    expect(find.byTooltip('暂停全部'), findsOneWidget);
    // 统计行与波形在简化模式下隐藏（统计行不可见即视为已简化）
    expect(find.textContaining('活跃'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disableAnimations 下不启动定时器/呼吸动画且不抛异常', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _hero(
          speedBps: 3 * 1024 * 1024,
          active: 1,
          canPause: true,
        ),
        disableAnimations: true,
      ),
    );
    // 多帧推进：若禁用动画仍启动 timer，会在此暴露 pending timer / 抛异常
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('实时吞吐'), findsOneWidget);
    expect(find.text('3.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

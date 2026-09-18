import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/logic.dart';

/// Agent 页滚动跟随 + 流式 UI 挂起状态机测试
///
/// 需求："手指放屏幕上滑动了抬起了 → 不要自动滑动到底部；除非抬起时滑动
/// 没超过 5 才继续自动滑动"。这里保护判定规则与手势累计逻辑。
///
/// 流式 UI 挂起（三态）：手指按下 → 挂起（chunk 不上屏）；松手按位置——
/// 点按恢复 / 回底部恢复+贴底 / 历史中间保持挂起，滚动回底才恢复。
void main() {
  Future<AgentNotifier> pumpWithList(WidgetTester tester) async {
    final notifier = AgentNotifier();
    addTearDown(() {
      notifier.inputController.dispose();
      notifier.inputFocusNode.dispose();
      notifier.scrollController.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            controller: notifier.scrollController,
            reverse: true,
            itemExtent: 50,
            itemCount: 60,
            itemBuilder: (context, index) => Center(child: Text('m$index')),
          ),
        ),
      ),
    );
    await tester.pump();
    return notifier;
  }

  /// 模拟一次手势：手指移动 + 列表随之滚动到 [toPixels]
  Future<void> drag(
      WidgetTester tester, AgentNotifier n, double toPixels) async {
    final from = n.scrollController.position.pixels;
    n.onPointerDown();
    n.scrollController.jumpTo(toPixels);
    n.onPointerMove(Offset(0, toPixels - from));
    await tester.pump();
    n.onPointerUp();
  }

  group('shouldFollowOutput（是否自动跟随到底部）', () {
    test('用户没主动上翻 → 跟随', () {
      expect(
        shouldFollowOutput(userScrolledAway: false, pixels: 0),
        isTrue,
      );
      expect(
        shouldFollowOutput(userScrolledAway: false, pixels: 500),
        isTrue,
      );
    });

    test('用户已上翻且停在中间 → 不跟随', () {
      expect(
        shouldFollowOutput(userScrolledAway: true, pixels: 300),
        isFalse,
      );
    });

    test('用户已上翻但只挪了几像素 → 只要没超容差仍不跟随', () {
      // 这正是旧实现（按 100px 位置阈值判断）的破绽：滑一点点就被拽回底部
      expect(
        shouldFollowOutput(userScrolledAway: true, pixels: 6),
        isFalse,
      );
      expect(
        shouldFollowOutput(userScrolledAway: true, pixels: 99),
        isFalse,
      );
    });

    test('已上翻但回到最底部 → 恢复跟随', () {
      expect(
        shouldFollowOutput(userScrolledAway: true, pixels: 0),
        isTrue,
      );
      expect(
        shouldFollowOutput(userScrolledAway: true, pixels: kScrollDragSlop),
        isTrue,
      );
    });
  });

  group('手势累计（AgentNotifier，接真实滚动视图）', () {
    testWidgets('上翻（列表真的往上滚了）→ 关闭自动跟随', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();
      expect(n.userScrolledAway, isFalse);

      await drag(tester, n, 300);

      expect(n.userScrolledAway, isTrue);
    });

    testWidgets('往上滑一点点（20px）也照样关闭跟随', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      await drag(tester, n, 20);

      expect(
        n.userScrolledAway,
        isTrue,
        reason: '这是相对旧实现（按 100px 位置阈值）的关键修正：滑一点就不跟随',
      );
    });

    testWidgets('下翻回到底部附近 → 恢复跟随（好操作：不用正好停在 0）', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();
      await drag(tester, n, 300);
      expect(n.userScrolledAway, isTrue);

      // 往下翻，停在距底部 20px（≤ 容差）→ 恢复跟随
      await drag(tester, n, 20);

      expect(n.userScrolledAway, isFalse);
    });

    testWidgets('下翻但停在历史中间 → 保持不跟随（还在读历史）', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();
      await drag(tester, n, 600);
      expect(n.userScrolledAway, isTrue);

      await drag(tester, n, 300); // 下翻但仍离底部很远

      expect(n.userScrolledAway, isTrue);
    });

    testWidgets('手指动了但列表没动（长按/尽头空拖）→ 不改状态', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      // 已经贴底还往下拽：手指位移很大，列表纹丝不动
      n.onPointerDown();
      n.onPointerMove(const Offset(0, 120));
      n.onPointerUp();

      expect(
        n.userScrolledAway,
        isFalse,
        reason: '列表没滚动就不是"上翻阅读"，长按复制时的抖动同理',
      );
    });

    testWidgets('点按 / 长按（位移 0）不置位', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      n.onPointerDown();
      n.onPointerUp();

      expect(n.userScrolledAway, isFalse);
    });

    testWidgets('已上翻后点按一下不解除，也不被误置位', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();
      await drag(tester, n, 300);
      expect(n.userScrolledAway, isTrue);

      // 读历史时点一下（例如长按复制）
      n.onPointerDown();
      n.onPointerUp();

      expect(
        n.userScrolledAway,
        isTrue,
        reason: '小手势只用于判定"不是滑动"，不应把跟随重新打开',
      );
    });

    testWidgets('手指按住滑动期间 pointerActive=true（流式 chunk 到达时不干预滚动的关键）', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();
      expect(n.pointerActive, isFalse);

      // 手指按下开始滑动：此刻 userScrolledAway 还未判定（仍 false），
      // 但 _scrollToBottom(force:false) 必须先看 pointerActive ——
      // 这是"右滑偏移不 jumpTo 0"的时序保障：滑动中绝不干预滚动。
      n.onPointerDown();
      expect(n.pointerActive, isTrue);
      expect(n.userScrolledAway, isFalse,
          reason: '滑动中 userScrolledAway 要等 onPointerUp 才判定，这正是旧实现拽回底部的漏洞');

      // 手指还在屏上（未抬起），滑动已产生偏移
      n.onPointerMove(const Offset(0, 60));
      n.scrollController.jumpTo(120);
      await tester.pump();

      // 仍在滑动中 → 必须保持 pointerActive
      expect(n.pointerActive, isTrue);

      // 抬起后：真实滑动了 → userScrolledAway 置位
      n.onPointerUp();
      expect(n.pointerActive, isFalse);
      expect(n.userScrolledAway, isTrue,
          reason: '抬起判定真实滚动后才关闭跟随，滑动期间从未被拽回底部');
    });

    testWidgets('贴底时手指按住后滑离底部：滑动期间不置位、抬起后置位（覆盖"出发在 0"场景）', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();
      expect(n.userScrolledAway, isFalse);
      expect(n.pointerActive, isFalse);

      // 贴底（pixels=0）时手指按住并上滑——用户从底部出发右滑
      n.onPointerDown();
      expect(n.pointerActive, isTrue);

      // 手指按住期间即使列表已经被推离底部，也不该有任何干预
      // （旧实现：此时 userScrolledAway=false 且 pixels>5 → schedule jumpTo(0)
      //   → 80ms 后把正滑到一半的人拽回底部）
      n.onPointerMove(const Offset(0, 80));
      n.scrollController.jumpTo(150);
      await tester.pump();
      expect(n.pointerActive, isTrue);

      // 只有抬起后 userScrolledAway 才生效（后续 chunk 不再跳转）
      n.onPointerUp();
      expect(n.userScrolledAway, isTrue);
    });
  });

  group('流式 UI 挂起状态机（三态：按下挂起 / 松手按位置恢复）', () {
    testWidgets('手指按下 → 挂起 UI（uiPaused=true）', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();
      expect(n.uiPaused, isFalse);

      n.onPointerDown();

      expect(n.uiPaused, isTrue,
          reason: '手指按下即挂起流式 UI（chunk 不上屏，读历史零打扰）');
    });

    testWidgets('点按（未滑动）松手 → 立即恢复', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      n.onPointerDown();
      expect(n.uiPaused, isTrue);

      n.onPointerUp();

      expect(n.uiPaused, isFalse,
          reason: '点按/长按未真正阅读 → 立即恢复，复制/选中不受影响');
    });

    testWidgets('滑动后回到底部附近松手 → 恢复（积攒内容一次性出现）', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      // 上翻读历史到 300（历史中间）→ 松手保持挂起
      await drag(tester, n, 300);
      expect(n.uiPaused, isTrue, reason: '停在历史中间（300>48）→ 保持挂起');
      expect(n.userScrolledAway, isTrue);

      // 重新按下 → 挂起；下滑回到底部附近 → 松手
      n.onPointerDown();
      expect(n.uiPaused, isTrue);
      n.onPointerMove(const Offset(0, -200));
      n.scrollController.jumpTo(20); // 下翻到 ≤ kReattachTolerance
      await tester.pump();
      n.onPointerUp();

      expect(n.uiPaused, isFalse,
          reason: '下翻回到底部附近松手 → 恢复挂起并主动贴底');
      expect(n.userScrolledAway, isFalse);
    });

    testWidgets('滑动后停在历史中间松手 → 保持挂起', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      n.onPointerDown();
      n.onPointerMove(const Offset(0, 80));
      n.scrollController.jumpTo(200); // 仍在历史中间（> kReattachTolerance）
      await tester.pump();
      n.onPointerUp();

      expect(n.uiPaused, isTrue,
          reason: '停在历史中间松手 → 保持挂起，滚动回底部才恢复');
      expect(n.userScrolledAway, isTrue);
    });

    testWidgets('挂起中滚动回底部 → 自动恢复（resumeUiPauseIfNearBottom）', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      // 上翻读历史 → 挂起保持
      n.onPointerDown();
      n.onPointerMove(const Offset(0, 100));
      n.scrollController.jumpTo(250);
      await tester.pump();
      n.onPointerUp();
      expect(n.uiPaused, isTrue);

      // 滚动回底部附近 → 自动恢复
      n.scrollController.jumpTo(10);
      await tester.pump();
      n.resumeUiPauseIfNearBottom();

      expect(n.uiPaused, isFalse,
          reason: '滚动回底部附近 → 解除挂起恢复跟随');
    });

    testWidgets('手指按住滑动中滚动经过底部 → resume 不打断（防"一滑就跳回 0"）', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      // 手指按下开始上翻（模拟真实手势：从底部出发，pixels 从小变大）
      n.onPointerDown();
      expect(n.pointerActive, isTrue);
      expect(n.uiPaused, isTrue);

      // 刚滑动一点（pixels 仍 ≤ 容差）：滚动监听触发 resume，
      // 但手指按着 → 必须不打断（否则一滑动就被 jumpTo(0) 拽回）
      n.scrollController.jumpTo(20);
      await tester.pump();
      n.resumeUiPauseIfNearBottom();

      expect(n.uiPaused, isTrue,
          reason: '滑动中（pointerActive）滚动经过底部 → resume 应跳过，绝不打断上翻');
      expect(n.userScrolledAway, isFalse,
          reason: '还没松手，userScrolledAway 未判定');

      // 继续滑到历史中间
      n.onPointerMove(const Offset(0, 80));
      n.scrollController.jumpTo(200);
      await tester.pump();
      n.resumeUiPauseIfNearBottom();
      expect(n.uiPaused, isTrue, reason: '滑动中停在历史中间 → 保持挂起');

      // 松手 → 停在历史中间 → 保持挂起
      n.onPointerUp();
      expect(n.uiPaused, isTrue);
      expect(n.userScrolledAway, isTrue);
    });

    testWidgets('手指按住从底部上翻 30px：滑动过程不被拽回，松手保留位置', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      // 从底部出发上翻 30px（模拟想读最新上方一点）
      n.onPointerDown();
      n.onPointerMove(const Offset(0, 30));
      n.scrollController.jumpTo(30);
      await tester.pump();
      // 滚动监听触发 resume，但手指按着 → 不打断
      n.resumeUiPauseIfNearBottom();
      expect(n.uiPaused, isTrue,
          reason: '滑动中经过底部区域不被打断（bug 根因回归）');
      expect(n.scrollController.position.pixels, 30,
          reason: '位置保持在 30，未被拽回 0');

      // 松手：delta > 0（上翻）→ 不强制滚底，保持用户位置，解除挂起
      n.onPointerUp();
      expect(n.scrollController.position.pixels, 30,
          reason: '上翻松手不滚底，位置保留');
      expect(n.uiPaused, isFalse,
          reason: '上翻停在底部附近（30≤48）→ 解除挂起恢复正常更新');
      expect(n.userScrolledAway, isTrue,
          reason: '保留位置：下一个流式 chunk 不会被拽回底部');
    });

    testWidgets('系统中断（onPointerCancel）→ 立即恢复挂起', (tester) async {
      final n = await pumpWithList(tester);
      n.scrollController.jumpTo(0);
      await tester.pump();

      n.onPointerDown();
      expect(n.uiPaused, isTrue);

      n.onPointerCancel();

      expect(n.uiPaused, isFalse,
          reason: '系统中断不应让 UI 永久冻结，立即恢复');
    });
  });
}

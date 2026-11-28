import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/web/browser_tabs_sheet.dart';

void main() {
  testWidgets('标签页面板展示卡片并回传选择/关闭/新建', (tester) async {
    final cards = ValueNotifier<List<BrowserTabCardData>>([
      const BrowserTabCardData(
        index: 0,
        title: 'Example Domain',
        url: 'https://example.com/a',
        active: false,
        suspended: false,
      ),
      const BrowserTabCardData(
        index: 1,
        title: '新标签页',
        url: '',
        active: true,
        suspended: false,
      ),
    ]);
    addTearDown(cards.dispose);

    int? selected;
    int? closed;
    var created = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showBrowserTabsSheet(
                  context,
                  cards: cards,
                  onSelect: (index) => selected = index,
                  onClose: (index) => closed = index,
                  onNewTab: () => created = true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('标签页'), findsOneWidget);
    expect(find.text('Example Domain'), findsOneWidget);
    expect(find.text('新建'), findsOneWidget);

    // 关闭第一张卡片：面板不关闭，回调拿到索引。
    await tester.tap(find.byTooltip('关闭标签页').first);
    await tester.pumpAndSettle();
    expect(closed, 0);
    expect(find.text('标签页'), findsOneWidget);

    // 点卡片：关闭面板并回传索引。
    await tester.tap(find.text('Example Domain'));
    await tester.pumpAndSettle();
    expect(selected, 0);
    expect(find.text('标签页'), findsNothing);
  });

  testWidgets('新建按钮先关面板再回调', (tester) async {
    final cards = ValueNotifier<List<BrowserTabCardData>>([
      const BrowserTabCardData(
        index: 0,
        title: '新标签页',
        url: '',
        active: true,
        suspended: false,
      ),
    ]);
    addTearDown(cards.dispose);

    var created = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showBrowserTabsSheet(
                  context,
                  cards: cards,
                  onSelect: (_) {},
                  onClose: (_) {},
                  onNewTab: () => created = true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建'));
    await tester.pumpAndSettle();

    expect(created, isTrue);
    expect(find.text('标签页'), findsNothing);
  });

  testWidgets('列表变化时面板实时刷新', (tester) async {
    final cards = ValueNotifier<List<BrowserTabCardData>>([
      const BrowserTabCardData(
        index: 0,
        title: 'First',
        url: 'https://a.com',
        active: true,
        suspended: false,
      ),
    ]);
    addTearDown(cards.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showBrowserTabsSheet(
                  context,
                  cards: cards,
                  onSelect: (_) {},
                  onClose: (_) {},
                  onNewTab: () {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);

    cards.value = [
      const BrowserTabCardData(
        index: 0,
        title: 'Second',
        url: 'https://b.com',
        active: true,
        suspended: false,
      ),
    ];
    await tester.pumpAndSettle();
    expect(find.text('First'), findsNothing);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('已释放 · 点按重新加载'), findsNothing);
  });
}

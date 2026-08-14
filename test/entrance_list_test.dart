import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/compent/entrance_list.dart';
import 'package:gstore/core/design/app_animation.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// EntranceList 内每项一个 FadeTransition（排除 MaterialApp 路由过渡自带的）
List<FadeTransition> _fades(WidgetTester tester) => tester
    .widgetList<FadeTransition>(
      find.descendant(
        // EntranceList<int> runtimeType ≠ 原始 EntranceList → 用谓词匹配泛型实例
        of: find.byWidgetPredicate((w) => w is EntranceList),
        matching: find.byType(FadeTransition),
      ),
    )
    .toList();

void main() {
  testWidgets('挂载 n=5：动画进行中后项 opacity < 1（交错未完成）', (tester) async {
    await tester.pumpWidget(_wrap(EntranceList<int>(
      itemCount: 5,
      itemBuilder: (context, i) =>
          SizedBox(height: 60, child: Text('item $i')),
    )));
    await tester.pump();
    // 动画总时长 = medium + 4*stagger = 500ms；进行到 200ms（controller 0.4）
    await tester.pump(const Duration(milliseconds: 200));

    final fades = _fades(tester);
    expect(fades.length, 5);
    // 末项 interval 起点 4/5=0.8 > 0.4 → 尚未开始
    expect(fades.last.opacity.value, lessThan(1.0));
    // 交错生效：首项进度高于末项
    expect(
      fades.first.opacity.value,
      greaterThan(fades.last.opacity.value),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('挂载 n=5：pump 完动画（medium + 4*stagger）后全部 opacity 1', (tester) async {
    await tester.pumpWidget(_wrap(EntranceList<int>(
      itemCount: 5,
      itemBuilder: (context, i) =>
          SizedBox(height: 60, child: Text('item $i')),
    )));
    await tester.pump();

    final total = AppAnimation.medium +
        Duration(
          milliseconds:
              (5 - 1) * AppAnimation.stagger.inMilliseconds,
        );
    await tester.pump(total);
    await tester.pump();

    for (final f in _fades(tester)) {
      expect(f.opacity.value, 1.0);
    }
    for (var i = 0; i < 5; i++) {
      expect(find.text('item $i'), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚动回收重建不重放：重建项 opacity 仍为 1（无闪烁）', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(EntranceList<int>(
      itemCount: 30,
      itemBuilder: (context, i) =>
          SizedBox(height: 60, child: Text('item $i')),
    )));
    await tester.pumpAndSettle();
    // 动画完成后可见项全部 opacity 1
    expect(_fades(tester), isNotEmpty);
    for (final f in _fades(tester)) {
      expect(f.opacity.value, 1.0);
    }

    // 滚动触发 ListView 回收 + 新项重建
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pump();
    await tester.pump();

    // 重建后的项直接以已完成动画状态出现（opacity 1，无重新淡入）
    expect(_fades(tester), isNotEmpty);
    for (final f in _fades(tester)) {
      expect(f.opacity.value, 1.0);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('n=0：空列表不崩溃', (tester) async {
    await tester.pumpWidget(_wrap(EntranceList<int>(
      itemCount: 0,
      itemBuilder: (context, i) => const SizedBox(height: 60),
    )));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(ListView), findsOneWidget);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('separated 模式：separatorBuilder 生效', (tester) async {
    await tester.pumpWidget(_wrap(EntranceList<int>(
      itemCount: 5,
      separated: true,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) =>
          SizedBox(height: 60, child: Text('item $i')),
    )));
    await tester.pumpAndSettle();
    expect(find.byType(Divider), findsNWidgets(4));
    expect(find.text('item 0'), findsOneWidget);
    expect(find.text('item 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('key 变化（同长度）→ State 重建 → 入场动画重放', (tester) async {
    Widget build(String key) => _wrap(EntranceList<int>(
          key: ValueKey(key),
          itemCount: 2,
          itemBuilder: (context, i) =>
              SizedBox(height: 60, child: Text('item $i')),
        ));

    await tester.pumpWidget(build('a'));
    await tester.pumpAndSettle();
    for (final f in _fades(tester)) {
      expect(f.opacity.value, 1.0);
    }

    // 换 key → 新 State → forward 重放
    await tester.pumpWidget(build('b'));
    await tester.pump();
    expect(_fades(tester).first.opacity.value, lessThan(1.0));

    await tester.pumpAndSettle();
    for (final f in _fades(tester)) {
      expect(f.opacity.value, 1.0);
    }
    expect(tester.takeException(), isNull);
  });
}

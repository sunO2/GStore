import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';

/// AppTabBar<T> / AppPillToggle<T> 设计系统原语测试（todoo 3）。
///
/// 覆盖验收：
/// - 6 个不同宽度标签渲染；点按最宽标签后其它标签宽度不变（内容自适应、不强制等宽）
/// - `AppSegment.key` 透传到 `Tab`，`find.byKey` + `getSize` 可用
/// - 仅在用户点按时触发 `onChanged`；程序化 value 变更不触发
/// - 连续快速点按无异常；不用 `DefaultTabController` 也可渲染（自带 controller）
/// - `AppPillToggle` 选中仅通知一次，且不会改变自身/兄弟尺寸
void main() {
  const tabKeys = <Key>[
    Key('tab-0'),
    Key('tab-1'),
    Key('tab-2'),
    Key('tab-3'),
    Key('tab-4'),
    Key('tab-5'),
  ];
  const tabLabels = <String>['A', 'BB', 'CCC', 'WWWWWWWWWWWW', 'DDDD', 'E'];

  Widget tabHarness({
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AppTabBar<String>(
          value: value,
          segments: [
            for (var i = 0; i < tabKeys.length; i++)
              AppSegment<String>(
                value: 'v$i',
                label: tabLabels[i],
                key: tabKeys[i],
              ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  group('AppTabBar<T>', () {
    testWidgets('渲染 6 个标签且 key 透传到 Tab（find.byKey + getSize 可用）',
        (tester) async {
      await tester.pumpWidget(tabHarness(value: 'v0', onChanged: (_) {}));

      // 不使用 DefaultTabController，widget 自带 controller。
      expect(find.byType(DefaultTabController), findsNothing);
      expect(tester.takeException(), isNull);

      for (final key in tabKeys) {
        expect(find.byKey(key), findsOneWidget);
        expect(tester.getSize(find.byKey(key)).width, greaterThan(0));
      }
    });

    testWidgets('点按最宽标签后首个标签宽度不变（内容自适应，不强制等宽）',
        (tester) async {
      await tester.pumpWidget(tabHarness(value: 'v0', onChanged: (_) {}));

      final widthBefore = tester.getSize(find.byKey(tabKeys[0])).width;
      final widestBefore = tester.getSize(find.byKey(tabKeys[3])).width;
      expect(widestBefore, greaterThan(widthBefore));

      await tester.tap(find.byKey(tabKeys[3]));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(tabKeys[0])).width,
        widthBefore,
        reason: '选择最宽标签后，其它标签不得被拉伸/回流',
      );
    });

    testWidgets('用户点按触发 onChanged 一次并传回对应值', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        tabHarness(value: 'v0', onChanged: calls.add),
      );

      await tester.tap(find.byKey(tabKeys[2]));
      await tester.pumpAndSettle();

      expect(calls, ['v2']);
    });

    testWidgets('程序化 value 变更同步选中但绝不触发 onChanged', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        tabHarness(value: 'v0', onChanged: calls.add),
      );

      // 以相同 widget 结构重建，仅 value 变化 → State.didUpdateWidget 路径。
      await tester.pumpWidget(
        tabHarness(value: 'v4', onChanged: calls.add),
      );
      await tester.pumpAndSettle();

      expect(calls, isEmpty, reason: '程序化同步不得回调 onChanged');
      final tabBar = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabBar.controller!.index, 4);
      expect(tester.takeException(), isNull);
    });

    testWidgets('连续快速点按多个标签不抛异常', (tester) async {
      await tester.pumpWidget(tabHarness(value: 'v0', onChanged: (_) {}));

      for (final index in [1, 3, 5, 2, 4]) {
        await tester.tap(find.byKey(tabKeys[index]));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('移除 widget 时释放 controller 不抛异常', (tester) async {
      await tester.pumpWidget(tabHarness(value: 'v0', onChanged: (_) {}));
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('AppPillToggle<T>', () {
    testWidgets('选中通知一次，且不改变自身/兄弟尺寸（内容尺寸，无等宽）',
        (tester) async {
      var value = 'short';
      var calls = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppPillToggle<String>(
                      value: value,
                      segments: const <AppSegment<String>>[
                        AppSegment(
                          value: 'short',
                          label: '短',
                          key: Key('pill-short'),
                        ),
                        AppSegment(
                          value: 'long',
                          label: '非常长的选项',
                          key: Key('pill-long'),
                        ),
                      ],
                      onChanged: (next) {
                        calls++;
                        setState(() => value = next);
                      },
                    ),
                    const SizedBox(
                      key: Key('pill-sibling'),
                      width: 50,
                      height: 20,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      final shortBefore = tester.getSize(find.byKey(const Key('pill-short')));
      final longBefore = tester.getSize(find.byKey(const Key('pill-long')));
      final siblingBefore =
          tester.getSize(find.byKey(const Key('pill-sibling')));

      // 内容尺寸：长标签应更宽（非等宽）。
      expect(longBefore.width, greaterThan(shortBefore.width));

      await tester.tap(find.byKey(const Key('pill-long')));
      await tester.pumpAndSettle();

      expect(calls, 1, reason: '选中应只通知一次');
      expect(value, 'long');

      // 选择不改变任何尺寸。
      expect(tester.getSize(find.byKey(const Key('pill-short'))), shortBefore);
      expect(tester.getSize(find.byKey(const Key('pill-long'))), longBefore);
      expect(
        tester.getSize(find.byKey(const Key('pill-sibling'))),
        siblingBefore,
        reason: '切换不得挤压/推挤兄弟组件',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('选中项使用 primaryContainer/onPrimaryContainer，且无勾选图标',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppPillToggle<String>(
              value: 'b',
              segments: const <AppSegment<String>>[
                AppSegment(value: 'a', label: 'A', key: Key('pill-a')),
                AppSegment(value: 'b', label: 'B', key: Key('pill-b')),
              ],
              onChanged: (_) {},
            ),
          ),
        ),
      );

      final scheme =
          Theme.of(tester.element(find.byKey(const Key('pill-b')))).colorScheme;
      final selectedContainer = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const Key('pill-b')),
          matching: find.byType(Container),
        ),
      );
      expect(
        (selectedContainer.decoration! as BoxDecoration).color,
        scheme.primaryContainer,
      );

      // 无勾选图标（不注入 check icon）。
      expect(find.byIcon(Icons.check), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/page/detail/widgets/more_actions_sheet.dart';

void main() {
  testWidgets('更多底部面板：渲染应用名、当前标签、预置 chips 与动作宫格', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: SizedBox())),
    );

    var actionFired = false;
    final future = showMoreActionsSheet(
      Get.context!,
      appName: '测试应用',
      presetTags: ['工具', '游戏', '社交'],
      currentTags: ['工具'],
      actions: [
        MoreActionItem(
          icon: Icons.manage_search,
          label: '完善应用信息',
          onTap: () => actionFired = true,
        ),
        MoreActionItem(
          icon: Icons.language,
          label: '项目主页',
          onTap: () {},
        ),
      ],
    );
    await tester.pumpAndSettle();

    // 标题与当前标签
    expect(find.text('测试应用'), findsOneWidget);
    expect(find.text('当前标签'), findsOneWidget);
    expect(find.text('工具'), findsWidgets);

    // 预置 chips 全部渲染
    expect(find.widgetWithText(FilterChip, '工具'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '游戏'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, '社交'), findsOneWidget);

    // 初始选中态来自 currentTags
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '工具')).selected,
      isTrue,
    );
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '游戏')).selected,
      isFalse,
    );

    // 动作宫格渲染
    expect(find.text('操作'), findsOneWidget);
    expect(find.byIcon(Icons.manage_search), findsOneWidget);
    expect(find.byIcon(Icons.language), findsOneWidget);
    expect(find.text('完善应用信息'), findsOneWidget);
    expect(find.text('项目主页'), findsOneWidget);

    // 点击动作：面板关闭 + 回调触发（future 返回 null，不保存标签）
    await tester.tap(find.text('完善应用信息'));
    await tester.pumpAndSettle();
    expect(actionFired, isTrue);
    expect(await future, isNull);
  });

  testWidgets('更多底部面板：chip 切换选中、自定义输入追加、确定返回标签', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: SizedBox())),
    );

    final future = showMoreActionsSheet(
      Get.context!,
      appName: '测试应用',
      presetTags: ['工具', '游戏'],
      currentTags: const [],
      actions: const [],
    );
    await tester.pumpAndSettle();

    // 点击 chip 切换选中
    await tester.tap(find.widgetWithText(FilterChip, '游戏'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '游戏')).selected,
      isTrue,
    );

    // 再点一次取消选中
    await tester.tap(find.widgetWithText(FilterChip, '游戏'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '游戏')).selected,
      isFalse,
    );

    // 自定义输入追加
    await tester.enterText(find.byType(TextField), '影音');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '影音'), findsOneWidget);

    // 空白输入被忽略
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsOneWidget);

    // 确定：返回已选标签（预置 + 自定义合并）
    await tester.tap(find.widgetWithText(FilterChip, '工具'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    final tags = await future;
    expect(tags, isNotNull);
    expect(tags, containsAll(['工具', '影音']));
    expect(tags, isNot(contains('游戏')));
  });

  testWidgets('更多底部面板：取消返回 null，清空后确定返回空列表', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: SizedBox())),
    );

    // 取消
    final cancelFuture = showMoreActionsSheet(
      Get.context!,
      appName: '测试应用',
      presetTags: ['工具'],
      currentTags: const ['工具'],
      actions: const [],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(await cancelFuture, isNull);

    // 清空后确认返回空列表
    final clearFuture = showMoreActionsSheet(
      Get.context!,
      appName: '测试应用',
      presetTags: ['工具'],
      currentTags: const ['工具'],
      actions: const [],
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '工具')).selected,
      isTrue,
    );

    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.text('暂无标签'), findsOneWidget);
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '工具')).selected,
      isFalse,
    );

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    expect(await clearFuture, isEmpty);
  });
}

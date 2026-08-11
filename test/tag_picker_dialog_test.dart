import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/page/home/tab/discovery/widgets/tag_picker_dialog.dart';

void main() {
  testWidgets('标签选择对话框：预置分类渲染与选中态切换', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: SizedBox())),
    );

    final future = showTagPickerDialog(
      Get.context!,
      presetTags: ['工具', '游戏', '社交'],
      currentTags: ['工具'],
    );
    await tester.pumpAndSettle();

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

    // 避免对话框残留影响后续用例
    Navigator.of(Get.context!).pop();
    await tester.pumpAndSettle();
    await future;
  });

  testWidgets('标签选择对话框：自定义输入追加可移除标签，确定返回结果', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: SizedBox())),
    );

    final future = showTagPickerDialog(
      Get.context!,
      presetTags: ['工具', '游戏'],
      currentTags: const [],
    );
    await tester.pumpAndSettle();

    // 输入自定义标签并点添加按钮
    await tester.enterText(find.byType(TextField), '影音');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '影音'), findsOneWidget);

    // 回车提交也可追加
    await tester.enterText(find.byType(TextField), '效率');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, '效率'), findsOneWidget);

    // 空白输入被忽略
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.byType(InputChip), findsNWidgets(2));

    // 预置 chip 选中后与自定义标签合并返回
    await tester.tap(find.widgetWithText(FilterChip, '工具'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();

    final tags = await future;
    expect(tags, isNotNull);
    expect(tags, containsAll(['工具', '影音', '效率']));
    expect(tags, isNot(contains('游戏')));
  });

  testWidgets('标签选择对话框：取消返回 null，清空后确认返回空列表', (tester) async {
    await tester.pumpWidget(
      const GetMaterialApp(home: Scaffold(body: SizedBox())),
    );

    // 取消
    final cancelFuture = showTagPickerDialog(
      Get.context!,
      presetTags: ['工具'],
      currentTags: const ['工具'],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(await cancelFuture, isNull);

    // 清空后确认
    final clearFuture = showTagPickerDialog(
      Get.context!,
      presetTags: ['工具'],
      currentTags: const ['工具'],
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '工具')).selected,
      isTrue,
    );

    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<FilterChip>(find.widgetWithText(FilterChip, '工具')).selected,
      isFalse,
    );

    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    expect(await clearFuture, isEmpty);
  });
}

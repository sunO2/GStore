import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';

/// AppEditableField 自适应输入原语测试（plan todo 4）。
///
/// 覆盖验收：
/// - display 行点按 → 打开 `request-editor-field-sheet`
/// - sheet 输入 → `request-editor-field-sheet-confirm` 写回绑定 controller
/// - 重新打开 + `request-editor-field-sheet-cancel` 保留原值
/// - `request-editor-field-fullscreen` 全屏升级：编辑返回后 sheet 与草稿存活，
///   sheet 确认仍写入全屏后的值
/// - `insertAtCursor` 在激活 controller 的当前选区插入（含 sheet 打开时命中草稿）
/// - sheet 内 `receiveAction(done)` 写回、关闭、`onSubmitted` 恰好一次
void main() {
  const Key displayKey = Key('request-editor-field-display');
  const Key sheetKey = Key('request-editor-field-sheet');
  const Key sheetInputKey = Key('request-editor-field-sheet-input');
  const Key sheetConfirmKey = Key('request-editor-field-sheet-confirm');
  const Key sheetCancelKey = Key('request-editor-field-sheet-cancel');
  const Key fullscreenKey = Key('request-editor-field-fullscreen');
  const Key fullscreenInputKey = Key('request-editor-field-fullscreen-input');
  const Key fullscreenDoneKey = Key('request-editor-field-fullscreen-done');

  Widget harness({
    required TextEditingController controller,
    required GlobalKey<AppEditableFieldState> fieldKey,
    ValueChanged<String>? onSubmitted,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: AppEditableField(
            key: fieldKey,
            controller: controller,
            mode: AppEditableFieldMode.sheet,
            onSubmitted: onSubmitted,
            label: '请求地址',
            hintText: '请输入内容',
          ),
        ),
      ),
    );
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(displayKey));
    await tester.pumpAndSettle();
    expect(find.byKey(sheetKey), findsOneWidget);
  }

  testWidgets('点按 display 行打开 sheet，确认后写回绑定 controller', (tester) async {
    final controller = TextEditingController(text: 'original');
    addTearDown(controller.dispose);
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(harness(controller: controller, fieldKey: fieldKey));
    await openSheet(tester);

    await tester.enterText(find.byKey(sheetInputKey), 'changed value');
    await tester.tap(find.byKey(sheetConfirmKey));
    await tester.pumpAndSettle();

    expect(controller.text, 'changed value');
    expect(find.byKey(sheetKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消关闭 sheet 且保留原值', (tester) async {
    final controller = TextEditingController(text: 'original');
    addTearDown(controller.dispose);
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(harness(controller: controller, fieldKey: fieldKey));
    await openSheet(tester);

    await tester.enterText(find.byKey(sheetInputKey), 'discarded edit');
    await tester.tap(find.byKey(sheetCancelKey));
    await tester.pumpAndSettle();

    expect(controller.text, 'original', reason: '取消必须丢弃草稿');
    expect(find.byKey(sheetKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('全屏升级：返回值传播且 sheet 与草稿存活，确认写入全屏值', (tester) async {
    final controller = TextEditingController(text: 'original');
    addTearDown(controller.dispose);
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(harness(controller: controller, fieldKey: fieldKey));
    await openSheet(tester);

    // 先在 sheet 里留存草稿，再升级到全屏。
    await tester.enterText(find.byKey(sheetInputKey), 'sheet draft');
    await tester.tap(find.byKey(fullscreenKey));
    await tester.pumpAndSettle();

    expect(find.byKey(fullscreenInputKey), findsOneWidget);
    await tester.enterText(find.byKey(fullscreenInputKey), 'fullscreen value');
    await tester.tap(find.byKey(fullscreenDoneKey));
    await tester.pumpAndSettle();

    // 全屏返回后：sheet 仍在，且草稿已是全屏编辑后的值。
    expect(find.byKey(sheetKey), findsOneWidget);
    final sheetField =
        tester.widget<TextField>(find.byKey(sheetInputKey));
    expect(sheetField.controller!.text, 'fullscreen value');

    // sheet 确认 → 写回全屏后的值。
    await tester.tap(find.byKey(sheetConfirmKey));
    await tester.pumpAndSettle();

    expect(controller.text, 'fullscreen value');
    expect(find.byKey(sheetKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('insertAtCursor 在 controller 当前选区插入', (tester) async {
    final controller = TextEditingController(text: 'hello world');
    addTearDown(controller.dispose);
    controller.selection = const TextSelection.collapsed(offset: 5);
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(harness(controller: controller, fieldKey: fieldKey));

    fieldKey.currentState!.insertAtCursor(',');
    expect(controller.text, 'hello, world');
    expect(controller.selection.baseOffset, 6);

    // 替换选区（非折叠）同样生效。
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    fieldKey.currentState!.insertAtCursor('HELLO');
    expect(controller.text, 'HELLO, world');
    expect(tester.takeException(), isNull);
  });

  testWidgets('insertAtCursor 在 sheet 打开时命中草稿 controller', (tester) async {
    final controller = TextEditingController(text: 'original');
    addTearDown(controller.dispose);
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(harness(controller: controller, fieldKey: fieldKey));
    await openSheet(tester);

    await tester.enterText(find.byKey(sheetInputKey), 'abc');
    final draft =
        tester.widget<TextField>(find.byKey(sheetInputKey)).controller!;
    draft.selection = const TextSelection.collapsed(offset: 3);

    fieldKey.currentState!.insertAtCursor('X');
    expect(draft.text, 'abcX', reason: 'insert 必须命中 sheet 的本地草稿');
    expect(controller.text, 'original', reason: '未确认前不得改动绑定值');
    expect(tester.takeException(), isNull);
  });

  testWidgets('sheet 内 done 提交：写回、关闭、onSubmitted 恰好一次', (tester) async {
    final controller = TextEditingController(text: 'original');
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(harness(
      controller: controller,
      fieldKey: fieldKey,
      onSubmitted: submitted.add,
    ));
    await openSheet(tester);

    await tester.enterText(find.byKey(sheetInputKey), 'submitted value');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(controller.text, 'submitted value');
    expect(find.byKey(sheetKey), findsNothing);
    expect(submitted, ['submitted value'], reason: 'onSubmitted 必须恰好一次');
    expect(tester.takeException(), isNull);
  });
}

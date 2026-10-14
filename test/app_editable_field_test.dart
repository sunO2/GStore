import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_typography.dart';

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

  // ========== inlineExpandable / commitOnBlur（plan todo 1） ==========

  const Key inlineExpandKey = Key('request-editor-field-expand');
  const Key siblingKey = Key('other-field');

  /// 定位 [fieldKey] 字段内部的行内输入框（与兄弟字段区分）。
  Finder inlineTextField(GlobalKey<AppEditableFieldState> fieldKey) =>
      find.descendant(
        of: find.byKey(fieldKey),
        matching: find.byType(TextField),
      );

  Widget inlineHarness({
    required TextEditingController controller,
    required GlobalKey<AppEditableFieldState> fieldKey,
    ValueChanged<String>? onSubmitted,
    bool dense = false,
    bool borderless = true,
    bool commitOnBlur = false,
    Key? expandKey,
    TextStyle? style,
    bool withSibling = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            AppEditableField(
              key: fieldKey,
              controller: controller,
              mode: AppEditableFieldMode.inlineExpandable,
              dense: dense,
              borderless: borderless,
              commitOnBlur: commitOnBlur,
              expandKey: expandKey,
              style: style,
              onSubmitted: onSubmitted,
              hintText: '值',
            ),
            if (withSibling) const TextField(key: siblingKey),
          ],
        ),
      ),
    );
  }

  testWidgets('inlineExpandable 渲染行内 TextField + 展开按钮，展开确认写回', (tester) async {
    final controller = TextEditingController(text: 'orig');
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(inlineHarness(
      controller: controller,
      fieldKey: fieldKey,
      onSubmitted: submitted.add,
    ));

    expect(inlineTextField(fieldKey), findsOneWidget);
    expect(find.byKey(inlineExpandKey), findsOneWidget);
    expect(find.byIcon(Icons.open_in_full), findsOneWidget);

    await tester.tap(find.byKey(inlineExpandKey));
    await tester.pumpAndSettle();
    expect(find.byKey(sheetInputKey), findsOneWidget);

    await tester.enterText(find.byKey(sheetInputKey), 'expanded');
    await tester.tap(find.byKey(sheetConfirmKey));
    await tester.pumpAndSettle();

    expect(controller.text, 'expanded');
    expect(submitted, ['expanded']);
    expect(find.byKey(sheetKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inlineExpandable 自定义 expandKey 生效且 style 应用到行内输入框', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final fieldKey = GlobalKey<AppEditableFieldState>();
    const Key customExpand = Key('kv-value-expand-7');

    await tester.pumpWidget(inlineHarness(
      controller: controller,
      fieldKey: fieldKey,
      expandKey: customExpand,
      style: AppTypography.code,
    ));

    expect(find.byKey(customExpand), findsOneWidget);
    expect(find.byKey(inlineExpandKey), findsNothing);
    final tf = tester.widget<TextField>(inlineTextField(fieldKey));
    expect(tf.style?.fontFamily, 'monospace', reason: 'style 必须落到行内 TextField');
    expect(tester.takeException(), isNull);
  });

  testWidgets('commitOnBlur: 失焦且文本已变触发一次 onSubmitted', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(inlineHarness(
      controller: controller,
      fieldKey: fieldKey,
      onSubmitted: submitted.add,
      commitOnBlur: true,
      withSibling: true,
    ));

    await tester.enterText(inlineTextField(fieldKey), 'changed');
    await tester.pump();

    // 焦点移到兄弟字段 → 行内失焦。
    await tester.enterText(find.byKey(siblingKey), 'x');
    await tester.pumpAndSettle();

    expect(submitted, ['changed'], reason: '失焦且文本已变，恰好提交一次');
    expect(tester.takeException(), isNull);
  });

  testWidgets('commitOnBlur: 文本未变时失焦不提交', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final submitted = <String>[];
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(inlineHarness(
      controller: controller,
      fieldKey: fieldKey,
      onSubmitted: submitted.add,
      commitOnBlur: true,
      withSibling: true,
    ));

    // 聚焦但文本未变，再失焦。
    await tester.tap(inlineTextField(fieldKey));
    await tester.pump();
    await tester.enterText(find.byKey(siblingKey), 'x');
    await tester.pumpAndSettle();

    expect(submitted, isEmpty, reason: '文本未变不得提交（防重复追加）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('inlineExpandable borderless 开关控制 OutlineInputBorder', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(inlineHarness(
      controller: controller,
      fieldKey: fieldKey,
      borderless: false,
    ));
    final bordered = tester.widget<TextField>(inlineTextField(fieldKey));
    expect(bordered.decoration!.border, isA<OutlineInputBorder>(),
        reason: 'borderless=false（默认）必须仍为 OutlineInputBorder');

    await tester.pumpWidget(inlineHarness(
      controller: controller,
      fieldKey: fieldKey,
      borderless: true,
    ));
    await tester.pump();
    final borderless = tester.widget<TextField>(inlineTextField(fieldKey));
    expect(borderless.decoration!.border, InputBorder.none);
    expect(borderless.decoration!.filled, isFalse);
    expect(tester.takeException(), isNull);
  });

  Widget inlineModeHarness({
    required TextEditingController controller,
    required GlobalKey<AppEditableFieldState> fieldKey,
    bool dense = false,
    bool borderless = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AppEditableField(
          key: fieldKey,
          controller: controller,
          mode: AppEditableFieldMode.inline,
          dense: dense,
          borderless: borderless,
          hintText: '值',
        ),
      ),
    );
  }

  testWidgets('inline 模式 dense+borderless 去方框；默认仍为 OutlineInputBorder', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final fieldKey = GlobalKey<AppEditableFieldState>();

    await tester.pumpWidget(inlineModeHarness(
      controller: controller,
      fieldKey: fieldKey,
      dense: true,
      borderless: true,
    ));
    final borderless = tester.widget<TextField>(inlineTextField(fieldKey));
    expect(borderless.decoration!.border, InputBorder.none,
        reason: 'inline + borderless 必须无方框');
    expect(borderless.decoration!.filled, isFalse);

    await tester.pumpWidget(inlineModeHarness(
      controller: controller,
      fieldKey: fieldKey,
    ));
    await tester.pump();
    final bordered = tester.widget<TextField>(inlineTextField(fieldKey));
    expect(bordered.decoration!.border, isA<OutlineInputBorder>(),
        reason: '默认 inline 必须保持 OutlineInputBorder（回归）');
    expect(bordered.decoration!.filled, isTrue);
    expect(tester.takeException(), isNull);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';

/// `AppEditorToolbar` / `AppSuggestionChips` 设计系统原语测试（plan todo 5）。
///
/// 覆盖验收：
/// - paste 从 mock 剪贴板写入绑定的 controller
/// - clear 清空 controller
/// - insert-at-cursor 在当前选区插入（替换选中内容）
/// - `onFormat` 在提供时被调用（回调级；页面接线属 todo 14/10）
/// - prev/next 回调被调用（回调级；接线属 todo 10）
/// - `AppSuggestionChips(['Content-Type','Authorization'])` 渲染 2 个 chip，
///   点按其中一个把值写入 controller
/// - 空列表渲染 no chip row 且无异常
void main() {
  Widget harness(Widget child) =>
      MaterialApp(home: Scaffold(body: child));

  /// mock `Clipboard.getData` 返回固定文本。
  void mockClipboardText(WidgetTester tester, String text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': text};
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }

  group('AppEditorToolbar', () {
    testWidgets('paste 从剪贴板写入绑定 controller', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      mockClipboardText(tester, 'clipboard value');

      await tester.pumpWidget(
        harness(AppEditorToolbar(controller: controller)),
      );

      await tester.tap(find.byKey(const Key('editor-toolbar-paste')));
      await tester.pumpAndSettle();

      expect(controller.text, 'clipboard value');
      expect(tester.takeException(), isNull);
    });

    testWidgets('clear 清空 controller', (tester) async {
      final controller = TextEditingController(text: 'to be cleared');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        harness(AppEditorToolbar(controller: controller)),
      );

      await tester.tap(find.byKey(const Key('editor-toolbar-clear')));
      await tester.pump();

      expect(controller.text, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('insert-at-cursor 在选区插入 / 替换选中', (tester) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      controller.selection = const TextSelection.collapsed(offset: 5);

      await tester.pumpWidget(
        harness(
          AppEditorToolbar(controller: controller, insertText: '{{host}}'),
        ),
      );

      await tester.tap(find.byKey(const Key('editor-toolbar-insert')));
      await tester.pump();
      expect(controller.text, 'hello{{host}} world');

      // 非折叠选区：替换选中内容。
      controller.selection =
          const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.tap(find.byKey(const Key('editor-toolbar-insert')));
      await tester.pump();
      expect(controller.text, '{{host}}{{host}} world');
      expect(tester.takeException(), isNull);
    });

    testWidgets('未提供 insertText 时不渲染插入按钮', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        harness(AppEditorToolbar(controller: controller)),
      );

      expect(find.byKey(const Key('editor-toolbar-insert')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('onFormat 在提供时被调用', (tester) async {
      final controller = TextEditingController(text: '{"a":1}');
      addTearDown(controller.dispose);
      var formatCalls = 0;

      await tester.pumpWidget(
        harness(
          AppEditorToolbar(
            controller: controller,
            onFormat: () => formatCalls++,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('editor-toolbar-format')));
      await tester.pump();

      expect(formatCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未提供 onFormat 时不渲染格式化按钮', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        harness(AppEditorToolbar(controller: controller)),
      );

      expect(find.byKey(const Key('editor-toolbar-format')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('prev/next 回调被调用', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var previousCalls = 0;
      var nextCalls = 0;

      await tester.pumpWidget(
        harness(
          AppEditorToolbar(
            controller: controller,
            onPrevious: () => previousCalls++,
            onNext: () => nextCalls++,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('editor-toolbar-prev')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('editor-toolbar-next')));
      await tester.pump();

      expect(previousCalls, 1);
      expect(nextCalls, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('AppSuggestionChips', () {
    testWidgets('渲染 2 个 chip，点按一个把值写入 controller', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        harness(
          AppSuggestionChips(
            const ['Content-Type', 'Authorization'],
            controller: controller,
          ),
        ),
      );

      expect(find.byType(ActionChip), findsNWidgets(2));

      await tester.tap(find.text('Content-Type'));
      await tester.pump();
      expect(controller.text, 'Content-Type');

      await tester.tap(find.text('Authorization'));
      await tester.pump();
      expect(controller.text, 'Content-TypeAuthorization');
      expect(tester.takeException(), isNull);
    });

    testWidgets('onSelected 在点按时收到选中值', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final selected = <String>[];

      await tester.pumpWidget(
        harness(
          AppSuggestionChips(
            const ['X-Trace-Id'],
            controller: controller,
            onSelected: selected.add,
          ),
        ),
      );

      await tester.tap(find.text('X-Trace-Id'));
      await tester.pump();

      expect(selected, ['X-Trace-Id']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('空列表不渲染 chip row 且无异常', (tester) async {
      final controller = TextEditingController(text: 'unchanged');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        harness(
          AppSuggestionChips(const [], controller: controller),
        ),
      );

      expect(find.byType(ActionChip), findsNothing);
      expect(controller.text, 'unchanged');
      expect(tester.takeException(), isNull);
    });
  });
}

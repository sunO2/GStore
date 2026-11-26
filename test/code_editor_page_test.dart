import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/design/app_code_view.dart';
import 'package:gstore/core/design/app_markdown_code_block.dart';
import 'package:gstore/core/editor/code_document_source.dart';
import 'package:gstore/page/code_editor/code_editor_page.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AppCodeView 只读渲染并显示行号', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppCodeView(
            text: 'void main() {}',
            filePath: 'main.dart',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.byType(DefaultCodeLineNumber), findsOneWidget);
  });

  testWidgets('AppMarkdownCodeBlock 用 CodeEditor 渲染并显示语言/复制', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppMarkdownCodeBlock(
            code: 'void main() {}',
            language: 'dart',
            showLineNumbers: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.text('dart'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('AppCodeView 双指 pinch 调整字号', (tester) async {
    final notifier = ValueNotifier<double>(14);
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppCodeView(
            text: 'void main() {}',
            filePath: 'main.dart',
            fontSizeNotifier: notifier,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = await tester.startGesture(const Offset(120, 120));
    final second = await tester.startGesture(const Offset(220, 120));
    await tester.pump();

    await first.moveTo(const Offset(70, 120));
    await second.moveTo(const Offset(270, 120));
    await tester.pump();

    expect(notifier.value, greaterThan(14));

    await first.up();
    await second.up();
    await tester.pumpAndSettle();
  });

  testWidgets('CodeEditorPage 默认只读，编辑后保存把文本回传', (tester) async {
    String? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  saved = await Navigator.of(context).push<String>(
                    MaterialPageRoute<String>(
                      builder: (_) => CodeEditorPage(
                        source: CodeDocumentSource.text(
                          'hello',
                          title: 'note.txt',
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.text('note.txt'), findsOneWidget);
    expect(find.byIcon(TablerIcons.edit), findsOneWidget);
    expect(find.byIcon(TablerIcons.zoom_in), findsOneWidget);

    // 字号菜单
    await tester.tap(find.byIcon(TablerIcons.zoom_in));
    await tester.pumpAndSettle();
    expect(find.text('放大字号'), findsOneWidget);
    await tester.tap(find.text('放大字号'));
    await tester.pumpAndSettle();

    // 只读 -> 编辑 -> 保存（内存文本来源直接 pop 回传）
    await tester.tap(find.byIcon(TablerIcons.edit));
    await tester.pumpAndSettle();
    expect(find.byIcon(TablerIcons.device_floppy), findsOneWidget);

    await tester.tap(find.byIcon(TablerIcons.device_floppy));
    await tester.pumpAndSettle();

    expect(saved, 'hello');
  });
}

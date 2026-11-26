import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_workspace_service.dart';
import 'package:gstore/core/editor/code_document_source.dart';

class _FakeWorkspace extends AgentWorkspaceService {
  _FakeWorkspace({
    required this.text,
    this.truncated = false,
    this.binary = false,
  });

  final String text;
  final bool truncated;
  final bool binary;
  String? saved;

  @override
  Future<AgentWorkspaceReadResult> read(String path) async {
    return AgentWorkspaceReadResult(
      path: path,
      bytes: utf8.encode(text).length,
      truncated: truncated,
      binary: binary,
      text: binary ? null : text,
    );
  }

  @override
  Future<AgentWorkspaceWriteResult> writeTextDirect({
    required String path,
    required String content,
  }) async {
    saved = content;
    return AgentWorkspaceWriteResult(
      path: path,
      bytes: utf8.encode(content).length,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CodeDocumentSource.text', () {
    test('内存文本可编辑，保存回调查看全文', () async {
      final source = CodeDocumentSource.text(
        'hello',
        title: 'note.txt',
        filePath: 'note.txt',
      );
      final doc = await source.load();
      expect(doc.title, 'note.txt');
      expect(doc.filePath, 'note.txt');
      expect(doc.text, 'hello');
      expect(doc.editable, isTrue);
      expect(doc.save, isNull);
    });
  });

  group('CodeDocumentSource.file', () {
    test('小文件可编辑，保存写回磁盘', () async {
      final dir = await Directory.systemTemp.createTemp('gstore_code_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.dart');
      await file.writeAsString('void main() {}');

      final doc = await CodeDocumentSource.file(file).load();
      expect(doc.title, 'a.dart');
      expect(doc.text, 'void main() {}');
      expect(doc.editable, isTrue);

      await doc.save!('void main() { print(1); }');
      expect(await file.readAsString(), 'void main() { print(1); }');
    });

    test('超过上限截断并禁用编辑', () async {
      final dir = await Directory.systemTemp.createTemp('gstore_code_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/big.txt');
      await file.writeAsString('abcdefghij');

      final doc = await CodeDocumentSource.file(file).load(maxBytes: 4);
      expect(doc.text, 'abcd');
      expect(doc.truncated, isTrue);
      expect(doc.editable, isFalse);
      expect(doc.save, isNull);
    });

    test('二进制文件报错', () async {
      final dir = await Directory.systemTemp.createTemp('gstore_code_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.bin');
      await file.writeAsBytes([1, 0, 2, 3]);

      await expectLater(
        CodeDocumentSource.file(file).load(),
        throwsA(isA<CodeDocumentException>()),
      );
    });
  });

  group('CodeDocumentSource.workspace', () {
    test('读取工作区文本，保存走 writeTextDirect', () async {
      final workspace = _FakeWorkspace(text: 'hello workspace');
      final doc = await CodeDocumentSource.workspace(
        workspace,
        'notes/hello.txt',
      ).load();

      expect(doc.title, 'notes/hello.txt');
      expect(doc.text, 'hello workspace');
      expect(doc.editable, isTrue);

      await doc.save!('updated');
      expect(workspace.saved, 'updated');
    });

    test('截断时禁用编辑', () async {
      final workspace = _FakeWorkspace(text: 'hello', truncated: true);
      final doc = await CodeDocumentSource.workspace(
        workspace,
        'notes/hello.txt',
      ).load();

      expect(doc.truncated, isTrue);
      expect(doc.editable, isFalse);
      expect(doc.save, isNull);
    });

    test('二进制文件报错', () async {
      final workspace = _FakeWorkspace(text: '', binary: true);
      await expectLater(
        CodeDocumentSource.workspace(workspace, 'a.bin').load(),
        throwsA(isA<CodeDocumentException>()),
      );
    });
  });
}

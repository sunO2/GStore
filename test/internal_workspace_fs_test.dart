import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/workspace/internal_workspace_fs.dart';
import 'package:gstore/core/agent/workspace/workspace_fs.dart';

void main() {
  late Directory tmp;
  late Directory root;
  late InternalWorkspaceFs fs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('gstore_fs_');
    root = Directory('${tmp.path}/root');
    fs = InternalWorkspaceFs(root);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('内部后端：写/读/列/移动/删除/统计', () async {
    await fs.mkdir('notes');
    await fs.writeBytes('notes/a.txt', utf8Bytes('hello'));

    final read = await fs.read('notes/a.txt');
    expect(read.text, 'hello');
    expect((await fs.list('', recursive: true)).map((e) => e.path),
        contains('notes/a.txt'));

    await fs.move('notes/a.txt', 'notes/b.txt');
    expect((await fs.read('notes/b.txt')).text, 'hello');

    await fs.delete('notes/b.txt');
    expect(
      () => fs.read('notes/b.txt'),
      throwsA(isA<AgentWorkspaceException>()),
    );

    final stats = await fs.stats();
    expect(stats.files, 0);
  });

  test('内部后端：拒绝路径穿越与符号链接', () async {
    final outside = Directory('${tmp.path}/outside');
    await outside.create();
    await File('${outside.path}/secret.txt').writeAsString('secret');

    expect(
      () => fs.read('../outside/secret.txt'),
      throwsA(isA<AgentWorkspaceException>()),
    );
    await root.create(recursive: true);
    await Link('${root.path}/link').create(outside.path);
    expect(
      () => fs.read('link/secret.txt'),
      throwsA(isA<AgentWorkspaceException>()),
    );
  });
}

List<int> utf8Bytes(String text) => text.codeUnits;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_workspace_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late Directory root;
  late Directory support;
  late AgentWorkspaceService ws;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('gstore_ws_test_');
    root = Directory('${tmp.path}/workspace');
    support = Directory('${tmp.path}/support');
    ws = AgentWorkspaceService(workspaceRoot: root, supportRoot: support);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<String> approvedWrite(String path, String content,
      {String action = 'write'}) async {
    final approval =
        await ws.createApproval(action: action, path: path, content: content);
    final result =
        await ws.write(approvalId: approval.id, path: path, content: content);
    return result.path;
  }

  test('审批后可写入/读取/列出，并记录审计', () async {
    final path = await approvedWrite('notes/todo.txt', 'hello\nworld');
    expect(path, 'notes/todo.txt');

    final read = await ws.read('notes/todo.txt');
    expect(read.text, 'hello\nworld');
    expect(read.binary, isFalse);

    final entries = await ws.list(dir: 'notes');
    expect(entries.map((e) => e.path), contains('notes/todo.txt'));

    final stats = await ws.stats();
    expect(stats.files, 1);
    expect(stats.bytes, 11);

    final audit = await ws.audit();
    expect(audit, isNotEmpty);
    expect(audit.first.action, 'write');
    expect(audit.first.ok, isTrue);
  });

  test('审计记录按当前工作区隔离', () async {
    await approvedWrite('default.txt', 'd');
    final other = await ws.createWorkspace(name: '第二工作区');
    await ws.selectWorkspace(other.id);
    await approvedWrite('other.txt', 'o');

    final otherAudit = await ws.audit();
    expect(otherAudit.map((e) => e.path), contains('other.txt'));
    expect(otherAudit.map((e) => e.path), isNot(contains('default.txt')));
    expect(otherAudit.every((e) => e.workspaceId == other.id), isTrue);

    final defaultAudit = await ws.audit(
      workspaceId: AgentWorkspaceService.defaultWorkspaceId,
    );
    expect(defaultAudit.map((e) => e.path), contains('default.txt'));
    expect(defaultAudit.map((e) => e.path), isNot(contains('other.txt')));
  });

  test('移除工作区：默认不可移除；移除当前后切回默认', () async {
    final other = await ws.createWorkspace(name: '第二工作区');
    await ws.selectWorkspace(other.id);
    expect(ws.workspaceId, other.id);

    await expectLater(
      ws.removeWorkspace(AgentWorkspaceService.defaultWorkspaceId),
      throwsA(isA<AgentWorkspaceException>()),
    );

    await ws.removeWorkspace(other.id);
    expect(
      (await ws.workspaces()).any((item) => item.id == other.id),
      isFalse,
    );
    expect(ws.workspaceId, AgentWorkspaceService.defaultWorkspaceId);
    expect(
      (await ws.currentWorkspace()).id,
      AgentWorkspaceService.defaultWorkspaceId,
    );
  });

  test('移除应用内工作区会删除其私有目录', () async {
    final svc = AgentWorkspaceService(supportRoot: support);
    final info = await svc.createWorkspace(name: '删除我');
    final dir = Directory('${support.path}/agent_workspaces/${info.id}');
    expect(await dir.exists(), isTrue);

    await svc.removeWorkspace(info.id);
    expect(await dir.exists(), isFalse);
    expect(
      (await svc.workspaces()).any((item) => item.id == info.id),
      isFalse,
    );
  });

  test('未审批、内容不一致、token 复用都会被拒绝', () async {
    expect(
      () => ws.write(approvalId: 'fake', path: 'a.txt', content: 'x'),
      throwsA(isA<AgentWorkspaceException>()),
    );

    final approval = await ws.createApproval(
      action: 'write',
      path: 'a.txt',
      content: 'approved',
    );
    expect(
      () => ws.write(
        approvalId: approval.id,
        path: 'a.txt',
        content: 'tampered',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );
    // 内容不一致不消费 token，正确内容仍可写入
    await ws.write(
      approvalId: approval.id,
      path: 'a.txt',
      content: 'approved',
    );
    // 单次使用
    expect(
      () => ws.write(
        approvalId: approval.id,
        path: 'a.txt',
        content: 'approved',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );
  });

  test('create 不允许覆盖，write 可以覆盖', () async {
    await approvedWrite('a.txt', 'one');
    expect(
      () => ws.createApproval(
        action: 'create',
        path: 'a.txt',
        content: 'two',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );
    await approvedWrite('a.txt', 'two', action: 'write');
    expect((await ws.read('a.txt')).text, 'two');
  });

  test('拒绝路径穿越、绝对路径和符号链接', () async {
    final outside = Directory('${tmp.path}/outside');
    await outside.create();
    await File('${outside.path}/secret.txt').writeAsString('secret');

    expect(
      () => ws.createApproval(
        action: 'write',
        path: '../evil.txt',
        content: 'x',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );
    expect(
      () => ws.read('/etc/passwd'),
      throwsA(isA<AgentWorkspaceException>()),
    );

    await root.create(recursive: true);
    await Link('${root.path}/link').create(outside.path);
    expect(
      () => ws.read('link/secret.txt'),
      throwsA(isA<AgentWorkspaceException>()),
    );
    expect(
      () => ws.createApproval(
        action: 'write',
        path: 'link/new.txt',
        content: 'x',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );
  });

  test('二进制文件不返回正文', () async {
    await root.create(recursive: true);
    await File('${root.path}/blob.bin')
        .writeAsBytes(<int>[0, 1, 2, 3, 0, 255]);
    final read = await ws.read('blob.bin');
    expect(read.binary, isTrue);
    expect(read.text, isNull);
  });

  test('超过单文件大小限制会被拒绝', () async {
    final content = 'x' * (AgentWorkspaceService.maxWriteBytes + 1);
    expect(
      () => ws.createApproval(
        action: 'write',
        path: 'big.txt',
        content: content,
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );
  });

  test('清空工作区', () async {
    await approvedWrite('a.txt', 'a');
    await approvedWrite('b.txt', 'b');
    expect((await ws.stats()).files, 2);
    await ws.clear();
    expect((await ws.stats()).files, 0);
  });

  test('目录、移动、删除与导入导出', () async {
    await ws.mkdir('docs');
    expect((await ws.stats()).files, 0);

    final source = File('${tmp.path}/source.txt');
    await source.writeAsString('imported');
    final imported = await ws.importFile(source.path, asPath: 'docs/a.txt');
    expect(imported.path, 'docs/a.txt');
    expect(await ws.exportBytes('docs/a.txt'), utf8.encode('imported'));

    final moveApproval = await ws.createApproval(
      action: 'move',
      path: 'docs/a.txt',
      target: 'docs/b.txt',
    );
    await ws.moveWithApproval(
      approvalId: moveApproval.id,
      path: 'docs/a.txt',
      target: 'docs/b.txt',
    );
    expect((await ws.read('docs/b.txt')).text, 'imported');

    final deleteApproval = await ws.createApproval(
      action: 'delete',
      path: 'docs/b.txt',
    );
    await ws.deleteWithApproval(
      approvalId: deleteApproval.id,
      path: 'docs/b.txt',
    );
    expect(
      () => ws.read('docs/b.txt'),
      throwsA(isA<AgentWorkspaceException>()),
    );
  });

  test('删除/移动未审批会被拒绝', () async {
    await approvedWrite('a.txt', 'a');
    expect(
      () => ws.deleteWithApproval(approvalId: 'fake', path: 'a.txt'),
      throwsA(isA<AgentWorkspaceException>()),
    );
    expect(
      () => ws.moveWithApproval(
        approvalId: 'fake',
        path: 'a.txt',
        target: 'b.txt',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );

    // 不能用 delete 审批去写文件
    final deleteApproval = await ws.createApproval(
      action: 'delete',
      path: 'a.txt',
    );
    expect(
      () => ws.write(
        approvalId: deleteApproval.id,
        path: 'a.txt',
        content: '',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );
  });

  test('精确编辑：唯一匹配、找不到、多处匹配与 replaceAll', () async {
    await approvedWrite('a.txt', 'hello world\nhello again');

    // 多处匹配默认拒绝
    expect(
      () => ws.createApproval(
        action: 'edit',
        path: 'a.txt',
        oldText: 'hello',
        newText: 'hi',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );
    // 找不到拒绝
    expect(
      () => ws.createApproval(
        action: 'edit',
        path: 'a.txt',
        oldText: 'missing',
        newText: 'x',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );

    // 唯一匹配成功
    final unique = await ws.createApproval(
      action: 'edit',
      path: 'a.txt',
      oldText: 'world',
      newText: 'there',
    );
    await ws.editWithApproval(
      approvalId: unique.id,
      path: 'a.txt',
      oldText: 'world',
      newText: 'there',
    );
    expect((await ws.read('a.txt')).text, 'hello there\nhello again');

    // replaceAll 替换全部
    final all = await ws.createApproval(
      action: 'edit',
      path: 'a.txt',
      oldText: 'hello',
      newText: 'hi',
      replaceAll: true,
    );
    await ws.editWithApproval(
      approvalId: all.id,
      path: 'a.txt',
      oldText: 'hello',
      newText: 'hi',
      replaceAll: true,
    );
    expect((await ws.read('a.txt')).text, 'hi there\nhi again');
  });
}

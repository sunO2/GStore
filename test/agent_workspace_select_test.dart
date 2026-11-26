import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gstore/core/core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory support;
  late AgentWorkspaceService workspace;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('gstore_ws_select_');
    support = Directory('${tmp.path}/support');
    workspace = AgentWorkspaceService(supportRoot: support);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> writeFile(String path, String content) async {
    final approval = await workspace.createApproval(
      action: 'write',
      path: path,
      content: content,
    );
    await workspace.write(
      approvalId: approval.id,
      path: path,
      content: content,
    );
  }

  test('默认工作区 + 新建/切换工作区互相隔离', () async {
    final list = await workspace.workspaces();
    expect(list, hasLength(1));
    expect(list.first.id, AgentWorkspaceService.defaultWorkspaceId);
    await workspace.selectWorkspace(AgentWorkspaceService.defaultWorkspaceId);
    await writeFile('default.txt', 'default');

    final created = await workspace.createWorkspace(name: '项目 A');
    expect(created.name, '项目 A');
    expect((await workspace.workspaces()).length, 2);

    await workspace.selectWorkspace(created.id);
    // 切换后默认工作区文件不可见
    expect(await workspace.listAll(), isEmpty);
    await writeFile('project.txt', 'project');

    await workspace
        .selectWorkspace(AgentWorkspaceService.defaultWorkspaceId);
    final paths = (await workspace.listAll()).map((e) => e.path).toList();
    expect(paths, contains('default.txt'));
    expect(paths, isNot(contains('project.txt')));
  });

  test('旧全局工作区自动迁移到 default', () async {
    final legacy = Directory('${support.path}/agent_workspace');
    await legacy.create(recursive: true);
    await File('${legacy.path}/legacy.txt').writeAsString('legacy');

    await workspace
        .selectWorkspace(AgentWorkspaceService.defaultWorkspaceId);
    final read = await workspace.read('legacy.txt');
    expect(read.text, 'legacy');
  });

  test('切换工作区会清空审批 token，不能跨工作区复用', () async {
    await workspace
        .selectWorkspace(AgentWorkspaceService.defaultWorkspaceId);
    final approval = await workspace.createApproval(
      action: 'write',
      path: 'cross.txt',
      content: 'x',
    );
    final created = await workspace.createWorkspace();
    await workspace.selectWorkspace(created.id);
    expect(
      () => workspace.write(
        approvalId: approval.id,
        path: 'cross.txt',
        content: 'x',
      ),
      throwsA(isA<AgentWorkspaceException>()),
    );
  });

  test('移除当前会话工作区后会回绑 default', () async {
    final agent = AgentService(workspaceService: workspace);
    addTearDown(agent.dispose);
    await agent.initialize();

    final created = await workspace.createWorkspace(name: '临时项目');
    expect(await agent.setWorkspaceForCurrentSession(created.id), isTrue);
    final session = agent.sessionStore!.current!;
    expect(
      await agent.sessionStore!.readMeta('session_workspace:${session.id}'),
      created.id,
    );

    expect(await agent.removeWorkspaceForCurrentSession(created.id), isTrue);
    expect(
      agent.workspaceService.workspaceId,
      AgentWorkspaceService.defaultWorkspaceId,
    );
    expect(
      agent.currentWorkspace.value?.id,
      AgentWorkspaceService.defaultWorkspaceId,
    );
    expect(
      await agent.sessionStore!.readMeta('session_workspace:${session.id}'),
      AgentWorkspaceService.defaultWorkspaceId,
    );

    final second = await agent.newSession();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(second.id, isNotEmpty);
    expect(
      agent.workspaceService.workspaceId,
      AgentWorkspaceService.defaultWorkspaceId,
    );
  });

  test('会话可以绑定不同工作区并继承到新会话', () async {
    final agent = AgentService(workspaceService: workspace);
    addTearDown(agent.dispose);
    await agent.initialize();
    await agent.setFileAccessEnabled(true);

    final firstSession = agent.sessionStore!.current!.id;
    expect(
      agent.currentWorkspace.value?.id,
      AgentWorkspaceService.defaultWorkspaceId,
    );

    final created = await workspace.createWorkspace(name: '共享项目');
    expect(await agent.setWorkspaceForCurrentSession(created.id), isTrue);
    expect(agent.workspaceService.workspaceId, created.id);

    final second = await agent.newSession();
    // 新会话继承当前工作区
    expect(agent.workspaceService.workspaceId, created.id);

    await agent.switchSession(firstSession);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(agent.workspaceService.workspaceId, created.id);

    await agent.switchSession(second.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(agent.workspaceService.workspaceId, created.id);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/agent/agent_tool_selector.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AgentWorkspaceService workspace;
  late AgentService agent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);

    tmp = await Directory.systemTemp.createTemp('gstore_file_tools_');
    workspace = AgentWorkspaceService(
      workspaceRoot: Directory('${tmp.path}/workspace'),
      supportRoot: Directory('${tmp.path}/support'),
    );
    agent = AgentService(workspaceService: workspace);
    await agent.initialize();
  });

  tearDown(() async {
    agent.dispose();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('默认关闭：文件工具不下发，执行被拒绝', () async {
    expect(agent.fileAccessEnabled.value, isFalse);
    final names = agent.debugSelectableToolNames;
    expect(names, isNot(contains('fileList')));
    expect(names, isNot(contains('fileRead')));
    expect(names, isNot(contains('fileApprove')));
    expect(names, isNot(contains('fileWrite')));

    final result = await agent.runTool('fileList', {});
    expect(result, contains('文件访问未启用'));
  });

  test('开启后：工具下发、读取/列出可用、未审批写入被拒绝', () async {
    await agent.setFileAccessEnabled(true);
    final names = agent.debugSelectableToolNames;
    expect(names, containsAll([
      'fileList',
      'fileRead',
      'fileApprove',
      'fileWrite',
      'fileEdit',
      'fileMkdir',
      'fileDelete',
      'fileMove',
    ]));

    final approval = await workspace.createApproval(
      action: 'write',
      path: 'notes/todo.txt',
      content: 'hello',
    );
    await workspace.write(
      approvalId: approval.id,
      path: 'notes/todo.txt',
      content: 'hello',
    );

    expect(
      await agent.runTool('fileList', {'dir': 'notes'}),
      contains('notes/todo.txt'),
    );
    expect(
      await agent.runTool('fileRead', {'path': 'notes/todo.txt'}),
      contains('hello'),
    );

    final denied = await agent.runTool('fileWrite', {
      'approvalId': 'fake',
      'path': 'a.txt',
      'content': 'x',
    });
    expect(denied, contains('写入文件失败'));
  });

  test('fileEdit 走审批并可精确替换', () async {
    await agent.setFileAccessEnabled(true);
    final writeApproval = await workspace.createApproval(
      action: 'write',
      path: 'edit.txt',
      content: 'hello world',
    );
    await workspace.write(
      approvalId: writeApproval.id,
      path: 'edit.txt',
      content: 'hello world',
    );

    final editApproval = await workspace.createApproval(
      action: 'edit',
      path: 'edit.txt',
      oldText: 'world',
      newText: 'there',
    );
    expect(
      await agent.runTool('fileEdit', {
        'approvalId': editApproval.id,
        'path': 'edit.txt',
        'oldText': 'world',
        'newText': 'there',
      }),
      contains('已修改'),
    );
    expect((await workspace.read('edit.txt')).text, 'hello there');

    expect(
      await agent.runTool('fileEdit', {
        'approvalId': 'fake',
        'path': 'edit.txt',
        'oldText': 'there',
        'newText': 'x',
      }),
      contains('修改文件失败'),
    );
  });

  test('目录/删除/移动工具走审批与路径沙箱', () async {
    await agent.setFileAccessEnabled(true);
    expect(await agent.runTool('fileMkdir', {'path': 'docs'}), contains('已创建目录'));

    await workspace.createApproval(
      action: 'write',
      path: 'docs/a.txt',
      content: 'a',
    ).then((approval) => workspace.write(
          approvalId: approval.id,
          path: 'docs/a.txt',
          content: 'a',
        ));

    final moveApproval = await workspace.createApproval(
      action: 'move',
      path: 'docs/a.txt',
      target: 'docs/b.txt',
    );
    expect(
      await agent.runTool('fileMove', {
        'approvalId': moveApproval.id,
        'path': 'docs/a.txt',
        'target': 'docs/b.txt',
      }),
      contains('已移动'),
    );

    final deleteApproval = await workspace.createApproval(
      action: 'delete',
      path: 'docs/b.txt',
    );
    expect(
      await agent.runTool('fileDelete', {
        'approvalId': deleteApproval.id,
        'path': 'docs/b.txt',
      }),
      contains('已删除'),
    );

    expect(
      await agent.runTool('fileDelete', {
        'approvalId': 'fake',
        'path': 'docs',
      }),
      contains('删除失败'),
    );
  });

  test('文件任务会强制保留文件工具', () {
    final selection = AgentToolSelector.select(
      userText: '帮我读取 notes/todo.txt 文件',
      all: AgentToolCatalog.enabled,
    );
    expect(selection.names, containsAll([
      'fileList',
      'fileRead',
      'fileApprove',
      'fileWrite',
      'fileEdit',
      'fileMkdir',
      'fileDelete',
      'fileMove',
    ]));
  });

  test('文件访问开关持久化', () async {
    await agent.setFileAccessEnabled(true);
    expect(await AgentFileSettings.loadEnabled(), isTrue);
    await agent.setFileAccessEnabled(false);
    expect(await AgentFileSettings.loadEnabled(), isFalse);
  });
}

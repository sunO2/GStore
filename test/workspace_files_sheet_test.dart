import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/page/agent/workspace_files_sheet.dart';

class _FakeWorkspace extends AgentWorkspaceService {
  _FakeWorkspace(this.info) : super();

  final AgentWorkspaceInfo info;

  static final entry = AgentWorkspaceEntry(
    path: 'notes/hello.txt',
    isDirectory: false,
    bytes: 15,
    modifiedAt: DateTime(2026, 1, 2, 3, 4),
  );

  @override
  Future<AgentWorkspaceInfo> currentWorkspace() async => info;

  @override
  Future<AgentWorkspaceStats> stats() async => const AgentWorkspaceStats(
        files: 1,
        bytes: 15,
        maxFiles: 200,
        maxBytes: 5 * 1024 * 1024,
      );

  @override
  Future<List<AgentWorkspaceEntry>> listAll({int limit = 500}) async => [entry];

  @override
  Future<AgentWorkspaceReadResult> read(String path) async =>
      const AgentWorkspaceReadResult(
        path: 'notes/hello.txt',
        bytes: 15,
        truncated: false,
        binary: false,
        text: 'hello workspace',
      );

  @override
  Future<List<int>> readBytes(String path) async => [1, 2, 3];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('工作区 pill 弹层显示当前文件、可预览、标题右侧可切换', (tester) async {
    final workspace = _FakeWorkspace(const AgentWorkspaceInfo(
      id: AgentWorkspaceService.defaultWorkspaceId,
      name: '默认工作区',
      createdAt: 0,
      updatedAt: 0,
    ));
    final service = AgentService(workspaceService: workspace);
    addTearDown(service.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showAgentWorkspaceFilesSheet(context, service),
            child: const Text('打开'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('默认工作区'), findsOneWidget);
    expect(find.text('notes/hello.txt'), findsOneWidget);
    expect(find.text('切换'), findsOneWidget);

    await tester.tap(find.text('notes/hello.txt'));
    await tester.pumpAndSettle();

    expect(find.text('hello workspace'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
  });
}

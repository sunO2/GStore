import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/page/agent/agent_tool_overview.dart';

void main() {
  testWidgets('工具概览列出当前模型工具、分组与说明', (tester) async {
    final tools = AgentToolCatalog.enabled;
    expect(tools, isNotEmpty);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentToolOverview(),
          ),
        ),
      ),
    );

    expect(find.byKey(AgentToolOverview.sectionKey), findsOneWidget);
    expect(find.text('当前模型工具'), findsOneWidget);
    expect(find.text('${tools.length} 个'), findsOneWidget);

    final searchApp = tools.where((t) => t.name == 'searchApp');
    expect(searchApp, isNotEmpty);
    expect(find.text('searchApp'), findsOneWidget);
    expect(find.text(searchApp.first.brief), findsOneWidget);
    expect(find.text(AgentToolGroup.discover), findsWidgets);
  });

  testWidgets('工具概览会显示运行时注册的 MCP 工具', (tester) async {
    const name = 'mcpDemoTool';
    AgentToolCatalog.register(const AgentToolSpec(
      name: name,
      group: AgentToolGroup.mcp,
      label: '演示工具',
      brief: '演示 MCP 工具的说明',
      protocol: '演示协议',
      mcp: true,
      mcpServerId: 'demo',
      mcpToolName: 'demo',
    ));
    addTearDown(() => AgentToolCatalog.unregister(name));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentToolOverview(),
          ),
        ),
      ),
    );

    expect(find.text(name), findsOneWidget);
    expect(find.text('演示 MCP 工具的说明'), findsOneWidget);
    expect(find.text('MCP'), findsWidgets);
    expect(find.text(AgentToolGroup.mcp), findsWidgets);
  });
}

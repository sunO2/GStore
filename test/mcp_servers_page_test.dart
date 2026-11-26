import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/mcp/mcp_server_store.dart';
import 'package:gstore/page/agent/mcp_servers_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('空态显示添加入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: McpServersPage()));
    await tester.pumpAndSettle();

    expect(find.text('还没有 MCP 服务器'), findsOneWidget);
    expect(find.text('添加服务器'), findsOneWidget);
    expect(find.text('MCP 服务器'), findsOneWidget);
  });

  testWidgets('条目有展开按钮，点击条目弹出详情与测试连接', (tester) async {
    SharedPreferences.setMockInitialValues({
      McpServerStore.storageKey: jsonEncode([
        {
          'id': 'mcp-1',
          'name': '测试 MCP',
          'url': 'https://mcp.example.com/mcp',
          'headers': <String, String>{},
          'enabled': true,
          'timeoutSeconds': 15,
        }
      ]),
    });
    await tester.pumpWidget(const MaterialApp(home: McpServersPage()));
    await tester.pumpAndSettle();

    expect(find.text('测试 MCP'), findsOneWidget);
    expect(find.byTooltip('展开工具'), findsOneWidget);

    await tester.tap(find.text('测试 MCP'));
    await tester.pumpAndSettle();

    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('远程 Streamable HTTP 端点'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

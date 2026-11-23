import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}

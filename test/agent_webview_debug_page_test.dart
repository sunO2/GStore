import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/agent/agent_webview_debug_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('WebView 调试页初始状态渲染地址栏与提示', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AgentWebViewDebugPage()),
    );

    expect(find.text('打开'), findsOneWidget);
    expect(find.textContaining('输入网址开始调试'), findsOneWidget);
    expect(find.textContaining('共用 Cookie'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}

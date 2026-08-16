import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/page/webdav_config/logic.dart';

/// WebDavConfigLogic 降级测试（todo 12a）
///
/// 验证：WebDavService 未绑定（webdav 模块下线）时，
/// testConnection 短路降级提示"模块未启用"，不抛异常、不置位 testing。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
  });

  testWidgets('testConnection：服务未绑定 → 降级提示不抛', (tester) async {
    await tester.pumpWidget(MaterialApp(
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const Scaffold(body: SizedBox()),
    ));

    final logic = WebDavConfigLogic();
    await logic.testConnection();
    await tester.pump();

    expect(find.text('WebDAV 模块未启用，无法测试连接'), findsOneWidget);
    expect(logic.state.isTesting.value, isFalse);
  });
}

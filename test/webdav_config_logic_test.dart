import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:gstore/page/webdav_config/providers.dart';

/// WebDAV 配置 Notifier 降级测试（Riverpod 版，替代原 GetxController 测试）
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

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(webDavConfigProvider.notifier);

    await notifier.testConnection(WebDavConfig(
      url: 'example.com/dav',
      username: 'user',
      password: 'pass',
    ));
    await tester.pump();

    expect(find.text('WebDAV 模块未启用，无法测试连接'), findsOneWidget);
    expect(container.read(webDavConfigProvider).isTesting, isFalse);
  });
}

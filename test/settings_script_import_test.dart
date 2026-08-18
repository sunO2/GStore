import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/settings/settings_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// mock path_provider：getApplicationDocumentsPath 返回临时目录
/// （MethodChannel mock 无效：path_provider_linux 注册了自己的平台实例）
class _FakePathProvider extends PathProviderPlatform {
  final String path;
  _FakePathProvider(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

/// 合法脚本：实现 getAllApps，应用名含 'A'
const String _script = '''
const CHANNEL_META = { name: 'A 渠道', description: 'A 描述' };

const apps = [
  { appId: 'com.a.one', name: 'App A One', icon: 'icon://a1', des: 'A 第一个' }
];

async function main(method, params) {
  switch (method) {
    case 'getAllApps':
      return { ok: true, data: apps };
    default:
      return null;
  }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    Get.reset();
    tempDir = await Directory.systemTemp.createTemp('settings_script_import');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    for (final channel in ChannelManager.instance.dynamicChannels) {
      if (channel is JsChannel) {
        ChannelManager.instance.unregisterChannelByKey(channel.channelKey);
      }
    }
    await tempDir.delete(recursive: true);
    Get.reset();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(GetMaterialApp(
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: const SettingsPage(),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('设置页「脚本渠道」入口 → 粘贴脚本导入 → 渠道注册成功 + 文件落盘', (tester) async {
    await pumpSettings(tester);

    // 入口存在（数据与同步分组）
    expect(find.text('脚本渠道'), findsOneWidget);

    // 打开导入对话框
    await tester.tap(find.text('脚本渠道'));
    await tester.pumpAndSettle();
    expect(find.text('导入脚本渠道'), findsOneWidget);

    // 填写渠道标识 + 脚本内容
    await tester.enterText(
        find.byKey(const Key('script_channel_key_input')), 'vivo');
    await tester.enterText(
        find.byKey(const Key('script_channel_script_input')), _script);

    // 确认导入
    await tester.tap(find.text('导入'));
    await tester.pump();
    // importScript 走真实异步（文件 IO + QuickJS FFI），pumpAndSettle 不等待
    // 非帧驱动 Future → 用 runAsync 让真实事件循环推进（多轮确保完成）
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    // 渠道已注册（key = js_vivo，自动加 js_ 前缀）
    final channel = ChannelManager.instance.getChannelByKey('js_vivo');
    expect(channel, isNotNull);
    expect(channel, isA<JsChannel>());
    expect((channel as JsChannel).isInitialized, isTrue);

    // 成功提示
    expect(find.textContaining('脚本渠道已导入'), findsOneWidget);

    // 文件已写入渠道目录（key 去 js_ 前缀 + .zip 渠道包）
    expect(File('${tempDir.path}/channels/vivo.zip').existsSync(), isTrue);
  });

  testWidgets('非法渠道标识 → 提示错误，不导入', (tester) async {
    await pumpSettings(tester);

    await tester.tap(find.text('脚本渠道'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('script_channel_key_input')), 'my-channel');
    await tester.enterText(
        find.byKey(const Key('script_channel_script_input')), _script);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(ChannelManager.instance.getChannelByKey('js_my-channel'), isNull);
    expect(find.textContaining('仅限字母'), findsOneWidget);
  });
}
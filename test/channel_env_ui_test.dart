import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/page/settings/settings_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// mock path_provider：getApplicationDocumentsPath 返回临时目录
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
    // env 持久化走内存存储（敏感键自动路由，js_channel_env_test 同款）
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance
        .initialize(storages: [MemoryConfigStorage(), MemoryConfigStorage()]);
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    Get.reset();
    tempDir = await Directory.systemTemp.createTemp('channel_env_ui');
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

  Future<void> pumpSettings(WidgetTester tester,
      {Future<String?> Function()? filePicker}) async {
    await tester.pumpWidget(GetMaterialApp(
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: SettingsPage(filePicker: filePicker),
    ));
    await tester.pumpAndSettle();
  }

  /// 等待真实异步（QuickJS FFI + 文件 IO 非帧驱动）完成
  Future<void> settleAsync(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// 打开导入对话框（expandEnv: 展开环境变量区）
  Future<void> openImportDialog(WidgetTester tester,
      {bool expandEnv = false}) async {
    await tester.tap(find.text('脚本渠道'));
    await tester.pumpAndSettle();
    if (expandEnv) {
      await tester.ensureVisible(
          find.byKey(const Key('script_channel_env_section')));
      await tester.tap(find.byKey(const Key('script_channel_env_section')));
      await tester.pumpAndSettle();
    }
  }

  /// 通过导入对话框导入渠道（可选 env），返回 channelKey（js_ 前缀）
  Future<String> importChannel(
    WidgetTester tester, {
    String key = 'vivo',
    Map<String, String>? env,
  }) async {
    await openImportDialog(tester, expandEnv: env != null);
    await tester.enterText(
        find.byKey(const Key('script_channel_key_input')), key);
    await tester.enterText(
        find.byKey(const Key('script_channel_script_input')), _script);
    if (env != null) {
      var row = 0;
      for (final entry in env.entries) {
        await tester
            .ensureVisible(find.byKey(const Key('script_channel_env_add')));
        await tester.tap(find.byKey(const Key('script_channel_env_add')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(Key('script_channel_env_key_$row')), entry.key);
        await tester.enterText(
            find.byKey(Key('script_channel_env_value_$row')), entry.value);
        row++;
      }
    }
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleAsync(tester);
    return 'js_$key';
  }

  testWidgets('① 导入对话框显示「从文件选择」按钮，注入 filePicker 读取 .js 内容并导入',
      (tester) async {
    var picked = false;
    await pumpSettings(tester, filePicker: () async {
      picked = true;
      return _script;
    });

    await openImportDialog(tester);

    // 按钮存在
    expect(find.byKey(const Key('script_channel_file_button')), findsOneWidget);
    expect(find.textContaining('从文件选择'), findsOneWidget);

    // 点击 → 注入实现被调用 → 脚本内容填入文本框
    await tester
        .ensureVisible(find.byKey(const Key('script_channel_file_button')));
    await tester.tap(find.byKey(const Key('script_channel_file_button')));
    await tester.pumpAndSettle();
    expect(picked, isTrue);
    final scriptField = tester.widget<TextField>(
        find.byKey(const Key('script_channel_script_input')));
    expect(scriptField.controller!.text, contains('getAllApps'));

    // 填 key 后导入
    await tester.enterText(
        find.byKey(const Key('script_channel_key_input')), 'file1');
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleAsync(tester);

    expect(ChannelManager.instance.getChannelByKey('js_file1'), isNotNull);
    expect(File('${tempDir.path}/channels/file1.js').existsSync(), isTrue);
    expect(find.textContaining('脚本渠道已导入'), findsOneWidget);
  });

  testWidgets('② 导入对话框添加环境变量 → 导入后 channel.getAllEnv 含该项（存储落盘）',
      (tester) async {
    await pumpSettings(tester);
    await importChannel(tester, key: 'envch', env: {'PINGAN_USER': 'alice'});

    final channel = ChannelManager.instance.getChannelByKey('js_envch');
    expect(channel, isNotNull);
    // widget 侧断言：渠道 env 含导入时配置的项
    expect(await (channel as JsChannel).getAllEnv(),
        {'PINGAN_USER': 'alice'});
    // store 侧断言：channel_env_<key> 落盘
    final raw = await ConfigStore.instance.readString('channel_env_js_envch');
    expect(raw, contains('PINGAN_USER'));
    // 提示包含 host.env.get 说明
    expect(find.textContaining('host.env.get'), findsOneWidget);
  });

  testWidgets('③ 删除环境变量行 → 导入后仅保留剩余项', (tester) async {
    await pumpSettings(tester);
    await openImportDialog(tester, expandEnv: true);

    // 添加两行并填写
    Future<void> addRow(int i, String k, String v) async {
      await tester
          .ensureVisible(find.byKey(const Key('script_channel_env_add')));
      await tester.tap(find.byKey(const Key('script_channel_env_add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(Key('script_channel_env_key_$i')), k);
      await tester.enterText(find.byKey(Key('script_channel_env_value_$i')), v);
    }

    await addRow(0, 'KEEP', '1');
    await addRow(1, 'DROP', '2');

    // 删除第二行（DROP）
    await tester.ensureVisible(
        find.byKey(const Key('script_channel_env_remove_1')));
    await tester.tap(find.byKey(const Key('script_channel_env_remove_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('script_channel_env_remove_1')), findsNothing);

    await tester.enterText(
        find.byKey(const Key('script_channel_key_input')), 'envdel');
    await tester.enterText(
        find.byKey(const Key('script_channel_script_input')), _script);
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleAsync(tester);

    final channel =
        ChannelManager.instance.getChannelByKey('js_envdel') as JsChannel;
    expect(await channel.getAllEnv(), {'KEEP': '1'});
  });

  testWidgets('④ 已导入渠道列表显示渠道（管理入口）', (tester) async {
    await pumpSettings(tester);
    await importChannel(tester, key: 'vivo');

    // 管理入口 subtitle 显示数量
    expect(find.text('1 个脚本渠道'), findsOneWidget);

    await tester.tap(find.text('已导入渠道'));
    await tester.pumpAndSettle();

    expect(find.text('脚本渠道管理'), findsOneWidget);
    expect(
        find.byKey(const Key('script_channel_manage_js_vivo')), findsOneWidget);
    expect(find.text('js_vivo'), findsOneWidget);
    expect(find.text('A 渠道'), findsOneWidget);
  });

  testWidgets('⑤ 管理入口编辑环境变量 → setEnv 生效（持久化更新）', (tester) async {
    await pumpSettings(tester);
    await importChannel(tester, key: 'envedit', env: {'PINGAN_USER': 'alice'});

    // 打开管理 → 环境变量编辑
    await tester.tap(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('script_channel_env_edit_js_envedit')));
    await tester.pumpAndSettle();

    // 既有键值已加载
    expect(find.text('PINGAN_USER'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);

    // 修改值 + 新增一行
    await tester.enterText(
        find.byKey(const Key('script_channel_env_value_0')), 'alice2');
    await tester
        .ensureVisible(find.byKey(const Key('script_channel_env_add')));
    await tester.tap(find.byKey(const Key('script_channel_env_add')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('script_channel_env_key_1')), 'TOKEN');
    await tester.enterText(
        find.byKey(const Key('script_channel_env_value_1')), 't1');

    await tester.tap(find.text('保存'));
    await tester.pump();
    await settleAsync(tester);

    final channel =
        ChannelManager.instance.getChannelByKey('js_envedit') as JsChannel;
    expect(await channel.getAllEnv(),
        {'PINGAN_USER': 'alice2', 'TOKEN': 't1'});
    expect(find.textContaining('环境变量已保存'), findsOneWidget);
  });

  testWidgets('⑥ 删除渠道 → 注销 + 文件删除 + env 清空', (tester) async {
    await pumpSettings(tester);
    await importChannel(tester, key: 'del', env: {'SECRET': 'x'});

    // 前置：注册 + 文件 + env 均存在
    expect(ChannelManager.instance.getChannelByKey('js_del'), isNotNull);
    expect(File('${tempDir.path}/channels/del.js').existsSync(), isTrue);
    expect(await ConfigJsChannelEnvStore('js_del').load(), {'SECRET': 'x'});

    // 管理 → 删除 → 危险确认
    await tester.tap(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('script_channel_delete_js_del')));
    await tester.pumpAndSettle();
    expect(find.text('删除脚本渠道'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pump();
    await settleAsync(tester);

    // 注销 + 文件删除 + env 清空
    expect(ChannelManager.instance.getChannelByKey('js_del'), isNull);
    expect(File('${tempDir.path}/channels/del.js').existsSync(), isFalse);
    expect(await ConfigJsChannelEnvStore('js_del').load(), isEmpty);
    expect(find.textContaining('脚本渠道已删除'), findsOneWidget);

    // 管理列表已刷新（渠道行消失）
    expect(
        find.byKey(const Key('script_channel_manage_js_del')), findsNothing);
  });
}

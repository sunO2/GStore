import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
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

/// 构造内存 zip 渠道包：entry.js 可选（null → 缺 entry.js 的无效包）；
/// meta.json / extra 文件可选。
Uint8List makeZip({
  String? entry,
  String? metaJson,
  Map<String, String> extra = const {},
}) {
  final archive = Archive();
  if (entry != null) {
    archive.addFile(ArchiveFile.string('entry.js', entry));
  }
  if (metaJson != null) {
    archive.addFile(ArchiveFile.string('meta.json', metaJson));
  }
  for (final file in extra.entries) {
    archive.addFile(ArchiveFile.string(file.key, file.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // env 持久化走内存存储（敏感键自动路由，channel_env_ui_test 同款）
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance
        .initialize(storages: [MemoryConfigStorage(), MemoryConfigStorage()]);
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
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
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    Future<({String name, Uint8List bytes})?> Function()? filePicker,
  }) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: SettingsPage(filePicker: filePicker),
      ),
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

  /// 打开导入对话框并点击「从文件选择渠道包 (.zip)」（不点导入）
  Future<void> selectZip(
    WidgetTester tester, {
    required Future<({String name, Uint8List bytes})?> Function() pick,
  }) async {
    await tester.tap(find.text('脚本渠道'));
    await tester.pumpAndSettle();
    expect(find.text('导入渠道包'), findsOneWidget);
    await tester.ensureVisible(
        find.byKey(const Key('script_channel_file_button')));
    await tester.tap(find.byKey(const Key('script_channel_file_button')));
    await tester.pumpAndSettle();
  }

  testWidgets('① 从文件选择 .zip → 校验通过 → importZip 注册成功 + 文件落盘',
      (tester) async {
    var picked = false;
    final zipBytes = makeZip(entry: _script);
    await pumpSettings(tester, filePicker: () async {
      picked = true;
      return (name: 'vivo.zip', bytes: zipBytes);
    });

    // 入口存在（数据与同步分组），文案为渠道包语义
    expect(find.text('脚本渠道'), findsOneWidget);

    await selectZip(tester, pick: () async => (name: 'vivo.zip', bytes: zipBytes));
    expect(picked, isTrue);

    // 预览显示渠道标识（文件名去 .zip + js_ 前缀）与 entry.js 大小
    expect(find.textContaining('js_vivo'), findsOneWidget);
    expect(find.textContaining('entry.js 大小'), findsOneWidget);

    // 确认导入
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleAsync(tester);

    // 渠道已注册（key = js_vivo）
    final channel = ChannelManager.instance.getChannelByKey('js_vivo');
    expect(channel, isNotNull);
    expect(channel, isA<JsChannel>());
    expect((channel as JsChannel).isInitialized, isTrue);

    // 成功提示
    expect(find.textContaining('渠道包已导入'), findsOneWidget);

    // 文件已写入渠道目录（key 去 js_ 前缀 + .zip 渠道包）
    expect(File('${tempDir.path}/channels/vivo.zip').existsSync(), isTrue);
  });

  testWidgets('② 无效 zip（缺 entry.js）→ 提示错误，不导入', (tester) async {
    final badZip =
        makeZip(entry: null, extra: {'other.js': 'const x = 1;'});
    await pumpSettings(tester,
        filePicker: () async => (name: 'bad.zip', bytes: badZip));

    await selectZip(tester, pick: () async => (name: 'bad.zip', bytes: badZip));

    // 校验失败提示（AppDialogs.showError）
    expect(find.textContaining('无效的渠道包'), findsOneWidget);
    expect(ChannelManager.instance.getChannelByKey('js_bad'), isNull);

    // 未选中包时点导入 → 提示先选择文件，仍不导入
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请先选择'), findsOneWidget);
    expect(ChannelManager.instance.getChannelByKey('js_bad'), isNull);
  });

  testWidgets('③ 合法 zip + meta → 导入确认前预览显示包名称/描述', (tester) async {
    final zipBytes = makeZip(
      entry: _script,
      metaJson: '{"name": "示例渠道", "description": "示例描述"}',
    );
    await pumpSettings(tester,
        filePicker: () async => (name: 'demo.zip', bytes: zipBytes));

    await selectZip(tester, pick: () async => (name: 'demo.zip', bytes: zipBytes));

    // 预览显示 meta 名称/描述 + 渠道标识（文件名去 .zip）
    expect(find.textContaining('示例渠道'), findsOneWidget);
    expect(find.textContaining('示例描述'), findsOneWidget);
    expect(find.textContaining('js_demo'), findsOneWidget);

    // 预览后确认导入成功
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleAsync(tester);
    expect(ChannelManager.instance.getChannelByKey('js_demo'), isNotNull);
  });

  testWidgets('④ 取消选择 → 不导入', (tester) async {
    await pumpSettings(tester, filePicker: () async => null);

    await selectZip(tester, pick: () async => null);

    // 未选中任何包 → 导入按钮提示先选择文件，渠道未注册
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请先选择'), findsOneWidget);
    expect(ChannelManager.instance.dynamicChannels.whereType<JsChannel>(),
        isEmpty);
  });

  testWidgets('⑤ 环境变量区保留：导入时配置 env → 导入后 setEnv 持久化',
      (tester) async {
    // meta.json 声明 requiredEnvVars → 选包后环境变量编辑器自动渲染
    final zipBytes = makeZip(entry: _script,
        metaJson: '{"requiredEnvVars": ["PINGAN_USER"]}');
    await pumpSettings(tester,
        filePicker: () async => (name: 'envch.zip', bytes: zipBytes));

    await selectZip(tester,
        pick: () async => (name: 'envch.zip', bytes: zipBytes));

    // requiredEnvVars 预填行：键只读，仅填值（channel_env_ui_test ② 同款模式）
    await tester.enterText(
        find.byKey(const Key('script_channel_env_value_0')), 'alice');

    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleAsync(tester);

    final channel =
        ChannelManager.instance.getChannelByKey('js_envch') as JsChannel;
    expect(await channel.getAllEnv(), {'PINGAN_USER': 'alice'});
    // 提示包含 host.env.get 说明
    expect(find.textContaining('host.env.get'), findsOneWidget);
  });

  testWidgets('⑥ 已导入渠道列表/删除（zip 渠道）', (tester) async {
    final zipBytes = makeZip(entry: _script);
    await pumpSettings(tester,
        filePicker: () async => (name: 'vivo.zip', bytes: zipBytes));
    await selectZip(tester,
        pick: () async => (name: 'vivo.zip', bytes: zipBytes));
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleAsync(tester);

    // 管理入口 subtitle 显示数量
    expect(find.text('1 个渠道包'), findsOneWidget);

    // 已导入渠道列表显示渠道（名称来自脚本 CHANNEL_META）
    await tester.tap(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    expect(find.text('渠道包管理'), findsOneWidget);
    expect(
        find.byKey(const Key('script_channel_manage_js_vivo')), findsOneWidget);
    expect(find.text('js_vivo'), findsOneWidget);
    expect(find.text('A 渠道'), findsOneWidget);

    // 删除 → 危险确认 → 注销 + 文件删除
    await tester.tap(find.byKey(const Key('script_channel_delete_js_vivo')));
    await tester.pumpAndSettle();
    expect(find.text('删除渠道包'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pump();
    await settleAsync(tester);

    expect(ChannelManager.instance.getChannelByKey('js_vivo'), isNull);
    expect(File('${tempDir.path}/channels/vivo.zip').existsSync(), isFalse);
    expect(find.textContaining('渠道包已删除'), findsOneWidget);
  });
}

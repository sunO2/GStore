import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:gstore/page/settings/settings_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settle.dart';

/// In-memory `ScriptApiBackend` (FRB seam): the env UI reaches the Rust script
/// lane (ScriptApi.getEnv/setEnv), never a Dart `JsChannel` (deleted).
class _FakeScriptBackend implements ScriptApiBackend {
  final Map<String, rust_pack.ScriptPackInfo> packs = {};
  final List<String> removed = [];
  final List<String> envSets = [];
  final Map<String, Map<String, String>> lastEnv = {};

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {}

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async {
    final key = expectedKey ?? 'js_unknown';
    final info = rust_pack.ScriptPackInfo(
      key: key,
      name: 'A 渠道',
      description: 'A 描述',
      icon: '',
      hasDetail: false,
    );
    packs[key] = info;
    return info;
  }

  @override
  Future<void> remove({required String key}) async {
    removed.add(key);
    packs.remove(key);
    lastEnv.remove(key);
  }

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async =>
      packs[key] ??
      rust_pack.ScriptPackInfo(
        key: key,
        name: '',
        description: '',
        icon: '',
        hasDetail: false,
      );

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async {
    envSets.add(key);
    lastEnv[key] = Map.of(env);
  }

  @override
  Future<Map<String, String>> getEnv({required String key}) async =>
      Map.of(lastEnv[key] ?? const {});

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async {}

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async => packs.values.toList();

  @override
  Future<String> storedApps({required String key}) async => '[]';

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {}

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async {}
}

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
  }
}

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

/// 构造内存 zip 渠道包（entry.js 必填；meta.json / extra 可选）
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

/// 注入「选择 zip 渠道包」：文件名 + 字节
Future<({String name, Uint8List bytes})?> pickZip(String fileName) async =>
    (name: fileName, bytes: makeZip(entry: _script));

/// 注入「选择 zip 渠道包」：meta.json 声明 requiredEnvVars，
/// 触发导入 BottomSheet 的必需环境变量引导（键预填只读，仅填值）
Future<({String name, Uint8List bytes})?> pickZipWithRequired(
        String fileName, List<String> requiredVars) async =>
    (
      name: fileName,
      bytes: makeZip(
        entry: _script,
        metaJson: jsonEncode({'requiredEnvVars': requiredVars}),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;
  late _FakeScriptBackend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance
        .initialize(storages: [MemoryConfigStorage(), MemoryConfigStorage()]);
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    tempDir = await Directory.systemTemp.createTemp('channel_env_ui');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);

    CoreFlags.installBackend(
        _FakeFlagsBackend(const CoreFlagsSnapshot(jsChannel: true)));
    await CoreFlags.refresh();
    backend = _FakeScriptBackend();
    ScriptApi.installBackend(backend);
    ScriptChannelService.installForTest(ScriptChannelService(
      coreDirs: () async => (
        '${tempDir.path}/core/data',
        '${tempDir.path}/core/files',
        '${tempDir.path}/core/cache',
      ),
      ensureRust: () async {},
    ));
    RustScriptChannelLane.resetForTest();
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    CoreFlags.resetBackend();
    ScriptApi.resetBackend();
    ScriptChannelService.resetForTest();
    RustScriptChannelLane.resetForTest();
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

  Future<void> openImportDialog(WidgetTester tester) async {
    await tester.ensureVisible(find.text('脚本渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('脚本渠道'));
    await tester.pumpAndSettle();
  }

  /// 通过导入 BottomSheet 导入 zip 渠道包，返回 channelKey（js_ 前缀）
  Future<String> importChannel(
    WidgetTester tester, {
    String fileName = 'vivo.zip',
    Map<String, String>? env,
  }) async {
    await openImportDialog(tester);
    await tester
        .ensureVisible(find.byKey(const Key('script_channel_file_button')));
    await tester.tap(find.byKey(const Key('script_channel_file_button')));
    await tester.pumpAndSettle();
    if (env != null) {
      var row = 0;
      for (final entry in env.entries) {
        await tester.enterText(
            find.byKey(Key('script_channel_env_value_$row')), entry.value);
        row++;
      }
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.text('导入'));
    await tester.tap(find.text('导入'));
    await tester.pump();
    final base = fileName.toLowerCase().endsWith('.zip')
        ? fileName.substring(0, fileName.length - 4)
        : fileName;
    final key = 'js_$base';
    await settleUntil(
        tester, () => RustScriptChannelLane.instance.packFor(key) != null);
    return key;
  }

  testWidgets('① 导入对话框显示「从文件选择」按钮，注入 filePicker 选择 .zip 并导入',
      (tester) async {
    var picked = false;
    await pumpSettings(tester, filePicker: () async {
      picked = true;
      return pickZip('file1.zip');
    });

    await openImportDialog(tester);

    expect(find.byKey(const Key('script_channel_file_button')), findsOneWidget);
    expect(find.textContaining('从文件选择'), findsOneWidget);

    await tester
        .ensureVisible(find.byKey(const Key('script_channel_file_button')));
    await tester.tap(find.byKey(const Key('script_channel_file_button')));
    await tester.pumpAndSettle();
    expect(picked, isTrue);
    expect(find.byKey(const Key('script_channel_preview')), findsOneWidget);
    expect(find.textContaining('js_file1'), findsOneWidget);

    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleUntil(
      tester,
      () =>
          backend.packs.containsKey('js_file1') &&
          find.textContaining('渠道包已导入').evaluate().isNotEmpty,
      reason: '导入后必须把 js_file1 装进 Rust 脚本通道并显示成功提示',
    );

    expect(backend.packs.containsKey('js_file1'), isTrue);
    expect(find.textContaining('渠道包已导入'), findsOneWidget);
  });

  testWidgets('② 导入对话框填写必需环境变量 → 导入后 ScriptApi env 含该项',
      (tester) async {
    await pumpSettings(
        tester,
        filePicker: () =>
            pickZipWithRequired('envch.zip', ['PINGAN_USER']));
    await importChannel(tester,
        fileName: 'envch.zip', env: {'PINGAN_USER': 'alice'});

    expect(backend.envSets, contains('js_envch'));
    expect(backend.lastEnv['js_envch'], {'PINGAN_USER': 'alice'});
    // 提示包含 host.env.get 说明
    expect(find.textContaining('host.env.get'), findsOneWidget);
  });

  testWidgets('③ 删除新增环境变量行 → 导入后仅保留剩余项', (tester) async {
    await pumpSettings(
        tester,
        filePicker: () => pickZipWithRequired('envdel.zip', ['KEEP']));
    await openImportDialog(tester);

    await tester
        .ensureVisible(find.byKey(const Key('script_channel_file_button')));
    await tester.tap(find.byKey(const Key('script_channel_file_button')));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('script_channel_env_value_0')), '1');
    await tester
        .ensureVisible(find.byKey(const Key('script_channel_env_add')));
    await tester.tap(find.byKey(const Key('script_channel_env_add')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('script_channel_env_key_1')), 'DROP');
    await tester.enterText(
        find.byKey(const Key('script_channel_env_value_1')), '2');

    await tester.ensureVisible(
        find.byKey(const Key('script_channel_env_remove_1')));
    await tester.tap(find.byKey(const Key('script_channel_env_remove_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('script_channel_env_remove_1')), findsNothing);

    await tester.ensureVisible(find.text('导入'));
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleUntil(
      tester,
      () =>
          backend.lastEnv['js_envdel']?.length == 1 &&
          backend.lastEnv['js_envdel']?['KEEP'] == '1',
      reason: '导入后必须能取到 js_envdel 且环境变量仅保留 KEEP',
    );

    expect(backend.lastEnv['js_envdel'], {'KEEP': '1'});
  });

  testWidgets('④ 已导入渠道列表显示渠道（管理入口）', (tester) async {
    await pumpSettings(tester, filePicker: () => pickZip('vivo.zip'));
    await importChannel(tester, fileName: 'vivo.zip');

    expect(find.text('1 个渠道包'), findsOneWidget);

    await tester.ensureVisible(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已导入渠道'));
    await tester.pumpAndSettle();

    expect(find.text('渠道包管理'), findsOneWidget);
    expect(
        find.byKey(const Key('script_channel_manage_js_vivo')), findsOneWidget);
    expect(find.text('js_vivo'), findsOneWidget);
  });

  testWidgets('⑤ 管理入口编辑环境变量 → setEnv 生效', (tester) async {
    await pumpSettings(
        tester,
        filePicker: () =>
            pickZipWithRequired('envedit.zip', ['PINGAN_USER']));
    await importChannel(tester,
        fileName: 'envedit.zip', env: {'PINGAN_USER': 'alice'});

    await tester.ensureVisible(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('script_channel_env_edit_js_envedit')));
    await tester.pumpAndSettle();

    // 既有键值已加载（ScriptApi.getEnv）
    expect(find.text('PINGAN_USER'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);

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
    await settleUntil(
      tester,
      () =>
          backend.lastEnv['js_envedit']?['PINGAN_USER'] == 'alice2' &&
          backend.lastEnv['js_envedit']?['TOKEN'] == 't1' &&
          find.textContaining('环境变量已保存').evaluate().isNotEmpty,
      reason: '保存后必须经 ScriptApi.setEnv 持久化两项并显示成功提示',
    );

    expect(backend.lastEnv['js_envedit'],
        {'PINGAN_USER': 'alice2', 'TOKEN': 't1'});
    expect(find.textContaining('环境变量已保存'), findsOneWidget);
  });

  testWidgets('⑥ 删除渠道 → ScriptApi.remove + 从 lane 移除', (tester) async {
    await pumpSettings(
        tester,
        filePicker: () => pickZipWithRequired('del.zip', ['SECRET']));
    await importChannel(tester, fileName: 'del.zip', env: {'SECRET': 'x'});

    expect(backend.packs.containsKey('js_del'), isTrue);

    await tester.ensureVisible(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('script_channel_delete_js_del')));
    await tester.pumpAndSettle();
    expect(find.text('删除渠道包'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pump();
    await settleUntil(
      tester,
      () =>
          backend.removed.contains('js_del') &&
          find.textContaining('渠道包已删除').evaluate().isNotEmpty,
      reason: '删除后必须调 ScriptApi.remove 并显示提示',
    );

    expect(backend.removed, contains('js_del'));
    expect(find.textContaining('渠道包已删除'), findsOneWidget);
    expect(
        find.byKey(const Key('script_channel_manage_js_del')), findsNothing);
  });
}

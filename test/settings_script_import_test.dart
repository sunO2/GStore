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

/// In-memory `ScriptApiBackend` (FRB seam): the settings import/env/delete flows
/// reach the Rust script lane, never a Dart `JsChannel` (deleted).
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
      name: '示例渠道',
      description: '示例描述',
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
  late _FakeScriptBackend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance
        .initialize(storages: [MemoryConfigStorage(), MemoryConfigStorage()]);
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    tempDir = await Directory.systemTemp.createTemp('settings_script_import');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);

    // Rust script lane is the shipping path (CoreFlags.jsChannel ON).
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

  /// 打开导入对话框并点击「从文件选择渠道包 (.zip)」（不点导入）
  Future<void> selectZip(
    WidgetTester tester, {
    required Future<({String name, Uint8List bytes})?> Function() pick,
  }) async {
    await tester.ensureVisible(find.text('脚本渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('脚本渠道'));
    await tester.pumpAndSettle();
    expect(find.text('导入渠道包'), findsOneWidget);
    await tester.ensureVisible(
        find.byKey(const Key('script_channel_file_button')));
    await tester.tap(find.byKey(const Key('script_channel_file_button')));
    await tester.pumpAndSettle();
  }

  testWidgets('① 从文件选择 .zip → 校验通过 → 导入 Rust 脚本通道 + 成功提示',
      (tester) async {
    var picked = false;
    final zipBytes = makeZip(entry: _script);
    await pumpSettings(tester, filePicker: () async {
      picked = true;
      return (name: 'vivo.zip', bytes: zipBytes);
    });

    expect(find.text('脚本渠道'), findsOneWidget);

    await selectZip(tester, pick: () async => (name: 'vivo.zip', bytes: zipBytes));
    expect(picked, isTrue);

    // 预览显示渠道标识（文件名去 .zip + js_ 前缀）与 entry.js 大小
    expect(find.textContaining('js_vivo'), findsOneWidget);
    expect(find.textContaining('entry.js 大小'), findsOneWidget);

    // 确认导入
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleUntil(
      tester,
      () => RustScriptChannelLane.instance.packFor('js_vivo') != null,
      reason: '导入后必须把 js_vivo 装进 Rust 脚本通道并刷新 lane 缓存',
    );

    // 装进 Rust 通道（不再有 Dart JsChannel / 旧渠道目录落盘）
    expect(backend.packs.containsKey('js_vivo'), isTrue);
    expect(RustScriptChannelLane.instance.codes, contains('js_vivo'));
    expect(find.textContaining('渠道包已导入'), findsOneWidget);
  });

  testWidgets('② 无效 zip（缺 entry.js）→ 提示错误，不导入', (tester) async {
    final badZip =
        makeZip(entry: null, extra: {'other.js': 'const x = 1;'});
    await pumpSettings(tester,
        filePicker: () async => (name: 'bad.zip', bytes: badZip));

    await selectZip(tester, pick: () async => (name: 'bad.zip', bytes: badZip));

    // 校验失败提示（AppDialogs.showError）
    expect(find.textContaining('无效的渠道包'), findsOneWidget);
    expect(backend.packs.containsKey('js_bad'), isFalse);

    // 未选中包时点导入 → 提示先选择文件，仍不导入
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请先选择'), findsOneWidget);
    expect(backend.packs.containsKey('js_bad'), isFalse);
  });

  testWidgets('③ 合法 zip + meta → 导入确认前预览显示包名称/描述', (tester) async {
    final zipBytes = makeZip(
      entry: _script,
      metaJson: '{"name": "示例渠道", "description": "示例描述"}',
    );
    await pumpSettings(tester,
        filePicker: () async => (name: 'demo.zip', bytes: zipBytes));

    await selectZip(tester, pick: () async => (name: 'demo.zip', bytes: zipBytes));

    expect(find.textContaining('示例渠道'), findsOneWidget);
    expect(find.textContaining('示例描述'), findsOneWidget);
    expect(find.textContaining('js_demo'), findsOneWidget);

    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleUntil(
      tester,
      () => RustScriptChannelLane.instance.packFor('js_demo') != null,
      reason: '导入后必须把 js_demo 装进 Rust 脚本通道',
    );
    expect(backend.packs.containsKey('js_demo'), isTrue);
  });

  testWidgets('④ 取消选择 → 不导入', (tester) async {
    await pumpSettings(tester, filePicker: () async => null);

    await selectZip(tester, pick: () async => null);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请先选择'), findsOneWidget);
    expect(RustScriptChannelLane.instance.packs, isEmpty);
  });

  testWidgets('⑤ 环境变量区保留：导入时配置 env → 导入后 setEnv 持久化',
      (tester) async {
    final zipBytes = makeZip(entry: _script,
        metaJson: '{"requiredEnvVars": ["PINGAN_USER"]}');
    await pumpSettings(tester,
        filePicker: () async => (name: 'envch.zip', bytes: zipBytes));

    await selectZip(tester,
        pick: () async => (name: 'envch.zip', bytes: zipBytes));

    // requiredEnvVars 预填行：键只读，仅填值
    await tester.enterText(
        find.byKey(const Key('script_channel_env_value_0')), 'alice');

    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleUntil(
      tester,
      () =>
          backend.lastEnv['js_envch']?['PINGAN_USER'] == 'alice' &&
          find.textContaining('host.env.get').evaluate().isNotEmpty,
      reason: '导入后必须经 ScriptApi.setEnv 持久化 PINGAN_USER=alice 并显示提示',
    );

    expect(backend.envSets, contains('js_envch'));
    expect(backend.lastEnv['js_envch'], {'PINGAN_USER': 'alice'});
    expect(find.textContaining('host.env.get'), findsOneWidget);
  });

  testWidgets('⑥ 已导入渠道列表/删除（Rust 脚本通道）', (tester) async {
    final zipBytes = makeZip(entry: _script);
    await pumpSettings(tester,
        filePicker: () async => (name: 'vivo.zip', bytes: zipBytes));
    await selectZip(tester,
        pick: () async => (name: 'vivo.zip', bytes: zipBytes));
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleUntil(
      tester,
      () => RustScriptChannelLane.instance.packFor('js_vivo') != null,
      reason: '导入后必须把 js_vivo 装进 Rust 脚本通道',
    );

    // 管理入口 subtitle 显示数量
    expect(find.text('1 个渠道包'), findsOneWidget);

    await tester.ensureVisible(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    expect(find.text('渠道包管理'), findsOneWidget);
    expect(
        find.byKey(const Key('script_channel_manage_js_vivo')), findsOneWidget);
    expect(find.text('js_vivo'), findsOneWidget);

    // 删除 → 危险确认 → ScriptApi.remove
    await tester.tap(find.byKey(const Key('script_channel_delete_js_vivo')));
    await tester.pumpAndSettle();
    expect(find.text('删除渠道包'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pump();
    await settleUntil(
      tester,
      () =>
          backend.removed.contains('js_vivo') &&
          find.textContaining('渠道包已删除').evaluate().isNotEmpty,
      reason: '删除后必须调 ScriptApi.remove 并显示提示',
    );

    expect(backend.removed, contains('js_vivo'));
    expect(find.textContaining('渠道包已删除'), findsOneWidget);
  });
}

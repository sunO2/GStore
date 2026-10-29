/// Rust-lane channel env echo (回显) — the read counterpart of `set_env`.
///
/// `test/channel_env_ui_test.dart` case ⑤ covers the **Dart** lane (env editor
/// prefilled from `JsChannel.getAllEnv`). With `CoreFlags.jsChannel` ON (the Rust
/// default) the settings page used to read `ConfigStore('channel_env_<key>')`
/// for a Rust channel while the write went to the Rust store, so the editor was
/// always empty. This mirrors case ⑤ on the Rust lane and asserts the editor is
/// prefilled from `ScriptApi.getEnv` (the Rust store read) instead.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:gstore/page/settings/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/settle.dart';

/// In-memory `ScriptApiBackend` (the FRB seam) that persists env the way the
/// real Rust store does: `setEnv` writes a per-key snapshot and `getEnv`
/// re-reads it, so the assertions prove the UI reached the Rust read, never a
/// hand-shaped shortcut.
class _RustEnvBackend implements ScriptApiBackend {
  final Map<String, rust_pack.ScriptPackInfo> packs = {};
  final Map<String, Map<String, String>> env = {};
  final List<String> envReads = [];

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
    packs.remove(key);
    env.remove(key);
  }

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async =>
      packs[key]!;

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async {
    this.env[key] = Map.of(env);
  }

  @override
  Future<Map<String, String>> getEnv({required String key}) async {
    envReads.add(key);
    return Map.of(env[key] ?? const {});
  }

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async {}

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async {
    final values = packs.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return values;
  }

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

const String _script = '''
const CHANNEL_META = { name: 'A 渠道', description: 'A 描述' };

async function main(method, params) {
  return null;
}
''';

Uint8List _makeZip({List<String> requiredEnvVars = const []}) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('entry.js', _script))
    ..addFile(ArchiveFile.string(
        'meta.json', jsonEncode({'requiredEnvVars': requiredEnvVars})));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RustEnvBackend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance
        .initialize(storages: [MemoryConfigStorage(), MemoryConfigStorage()]);
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);

    CoreFlags.installBackend(
      _FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: true)),
    );
    await CoreFlags.refresh();
    expect(CoreFlags.jsChannel, isTrue);

    backend = _RustEnvBackend();
    ScriptApi.installBackend(backend);
    ScriptChannelService.installForTest(ScriptChannelService(
      coreDirs: () async => (
        '/tmp/gstore_env_rust/data',
        '/tmp/gstore_env_rust/files',
        '/tmp/gstore_env_rust/cache',
      ),
      ensureRust: () async {},
    ));
    RustScriptChannelLane.resetForTest();
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    ScriptApi.resetBackend();
    ScriptChannelService.resetForTest();
    RustScriptChannelLane.resetForTest();
    await ChannelManager.instance.disposeAll();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
        home: SettingsPage(
          filePicker: () async =>
              (name: 'envedit.zip', bytes: _makeZip(requiredEnvVars: ['PINGAN_USER'])),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('⑤ rust lane: 管理入口编辑环境变量 → 从 ScriptApi 回显既有值',
      (tester) async {
    await pumpSettings(tester);

    // 导入（Rust 轨）：必需环境变量 PINGAN_USER = alice → ScriptApi.setEnv。
    await tester.ensureVisible(find.text('脚本渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('脚本渠道'));
    await tester.pumpAndSettle();
    await tester
        .ensureVisible(find.byKey(const Key('script_channel_file_button')));
    await tester.tap(find.byKey(const Key('script_channel_file_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('script_channel_env_value_0')), 'alice');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('导入'));
    await tester.tap(find.text('导入'));
    await tester.pump();
    await settleUntil(
      tester,
      () => backend.env['js_envedit'] != null,
      reason: '导入后 Rust 存储必须写入 js_envedit 的 env（ScriptApi.setEnv）',
    );

    // 写入确实落在 Rust 存储；ConfigStore 未镜像（敏感项不回写 Flutter 存储）。
    expect(backend.env['js_envedit'], {'PINGAN_USER': 'alice'});
    expect(await ConfigStore.instance.readString('channel_env_js_envedit'), isNull);

    // 管理入口 → 环境变量编辑。
    await tester.ensureVisible(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已导入渠道'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('script_channel_env_edit_js_envedit')));
    await tester.pumpAndSettle();

    // 回显：编辑器从 ScriptApi.getEnv 预填（修复前读 ConfigStore → 空）。
    await settleUntil(
      tester,
      () => find.text('alice').evaluate().isNotEmpty,
      reason: '编辑器必须从 ScriptApi.getEnv 回显既有值',
    );
    expect(backend.envReads, contains('js_envedit'));
    expect(find.text('PINGAN_USER'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
  });
}

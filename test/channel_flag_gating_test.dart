import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';

/// Records the ScriptApi lane traffic; optionally fails the import so the typed
/// error path can be asserted.
class _RecordingScriptApiBackend implements ScriptApiBackend {
  _RecordingScriptApiBackend({this.failImport = false});

  final bool failImport;
  final List<String> importedKeys = <String>[];
  int initCalls = 0;

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    initCalls++;
  }

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async {
    if (failImport) throw StateError('invalid_argument: pack rejected');
    importedKeys.add(expectedKey ?? '');
    return rust_pack.ScriptPackInfo(
      key: expectedKey ?? 'js_unknown',
      name: 'imported',
      description: '',
      icon: '',
      hasDetail: false,
    );
  }

  @override
  Future<void> remove({required String key}) async {}

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async =>
      rust_pack.ScriptPackInfo(
        key: key,
        name: 'imported',
        description: '',
        icon: '',
        hasDetail: false,
      );

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async {}

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async {}

  @override
  Future<String> run({
    required String key,
    required String method,
    required String paramsJson,
  }) async =>
      '{"ok":true,"data":null}';

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async =>
      const <rust_pack.ScriptPackInfo>[];

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

/// Installs a no-FFI service: fake ScriptApi backend + fixed core dirs.
void _installScriptService(_RecordingScriptApiBackend backend) {
  ScriptApi.installBackend(backend);
  ScriptChannelService.installForTest(ScriptChannelService(
    coreDirs: () async => ('/tmp/gstore_data', '/tmp/gstore_files', '/tmp/gstore_cache'),
    ensureRust: () async {},
  ));
}

/// 可注入的 flags 后端（Rust 侧默认全 false；这里只切 `jsChannel`）。
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
const CHANNEL_META = { name: 'gate 渠道' };
function main(method, params) { return { ok: true, data: [] }; }
''';

Uint8List _zip() {
  final archive = Archive()..addFile(ArchiveFile.string('entry.js', _script));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Future<Directory> _channelDir() async {
  final dir = await Directory.systemTemp.createTemp('gstore_flag_gating');
  await File('${dir.path}/gate.zip').writeAsBytes(_zip());
  return dir;
}

Future<void> _setFlag({required bool jsChannel}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: jsChannel)),
  );
  await CoreFlags.refresh();
  // 断言仅在 fake 生效后继续（防止误读真实 Rust 后端）。
  expect(CoreFlags.jsChannel, jsChannel);
}

/// 只切 `channels`（Rust 渠道 facade 接管读路径）；`jsChannel` 保持 false。
Future<void> _setChannelsFlag({required bool channels}) async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(CoreFlagsSnapshot(channels: channels)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.channels, channels);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await ChannelManager.instance.disposeAll();
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    ScriptApi.resetBackend();
    ScriptChannelService.resetForTest();
    await ChannelManager.instance.disposeAll();
  });

  test('flag=false：loader 扫描并注册 Dart JsChannel（旧路径不变）', () async {
    await _setFlag(jsChannel: false);
    final manager = ChannelManager.instance;
    expect(manager.dartScriptChannelsEnabled, isTrue);

    final dir = await _channelDir();
    addTearDown(() => dir.delete(recursive: true));

    final loaded = await ChannelLoader(directory: dir).loadAndRegister();

    expect(loaded.map((channel) => channel.channelKey), <String>['js_gate']);
    expect(manager.getChannelByKey('js_gate'), isA<JsChannel>());
    expect(manager.dynamicChannels, isNotEmpty);
    expect(manager.getChannel(ChannelType.custom), isA<JsChannel>());
  });

  test('flag=true：loader 不注册 Dart JsChannel，但把渠道包导入 Rust 通道',
      () async {
    await _setFlag(jsChannel: true);
    final backend = _RecordingScriptApiBackend();
    _installScriptService(backend);
    final manager = ChannelManager.instance;
    expect(manager.dartScriptChannelsEnabled, isFalse);

    final dir = await _channelDir();
    addTearDown(() => dir.delete(recursive: true));

    final loaded = await ChannelLoader(directory: dir).loadAndRegister();
    expect(loaded, isEmpty, reason: 'Rust ScriptApi 接管时不构建 Dart JsChannel');
    expect(backend.importedKeys, <String>['js_gate'],
        reason: '启动加载必须把渠道目录里的 zip 真正导入 Rust 脚本通道');
    expect(manager.getChannelByKey('js_gate'), isNull);
    expect(manager.dynamicChannels, isEmpty);

    // 结构性门禁：即使有人绕过 loader 直接注册，也不会进入动态索引。
    final js = JsChannel(channelKey: 'js_rejected', script: _script);
    manager.registerChannel(js);
    expect(manager.getChannelByKey('js_rejected'), isNull);
    expect(manager.getChannel(ChannelType.custom), isNull);
    expect(manager.dynamicChannels, isEmpty);
  });

  test('flag 默认值 false（CoreFlags 快照默认）→ Dart 渠道启用', () {
    CoreFlags.resetBackend();
    expect(CoreFlags.jsChannel, isFalse);
    expect(ChannelManager.instance.dartScriptChannelsEnabled, isTrue);
  });

  test('channel_import_zip_routes_to_the_script_lane_when_flipped', () async {
    // jsChannel=true：旧 Dart 写入路径停用，但必须把 zip 真正导入 Rust 脚本
    // 通道（不再以 CORE_E_CHANNEL_LEGACY_DISABLED 拒绝整个导入动作）。
    await _setFlag(jsChannel: true);
    final backend = _RecordingScriptApiBackend();
    _installScriptService(backend);

    final dir = await Directory.systemTemp.createTemp('gstore_flag_import');
    addTearDown(() => dir.delete(recursive: true));

    final result = await ChannelLoader(directory: dir).importZip(
      channelKey: 'js_flipped',
      zipBytes: _zip(),
    );

    expect(result, isA<ScriptLaneChannelImport>(),
        reason: 'flag on 的导入必须走 Rust ScriptApi 通道');
    expect((result as ScriptLaneChannelImport).pack.key, 'js_flipped');
    expect(backend.importedKeys, <String>['js_flipped'],
        reason: '真实 ScriptApi.import 必须被调用一次');
    expect(
      File('${dir.path}/flipped.zip').existsSync(),
      isFalse,
      reason: 'flag on 时不得写入任何旧 zip 渠道包',
    );
    expect(ChannelManager.instance.getChannelByKey('js_flipped'), isNull);
  });

  test('channel_import_zip_script_lane_failure_is_typed_and_writes_nothing',
      () async {
    await _setFlag(jsChannel: true);
    _installScriptService(_RecordingScriptApiBackend(failImport: true));

    final dir = await Directory.systemTemp.createTemp('gstore_flag_import_fail');
    addTearDown(() => dir.delete(recursive: true));

    Object? thrown;
    try {
      await ChannelLoader(directory: dir).importZip(
        channelKey: 'js_broken',
        zipBytes: _zip(),
      );
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isA<ScriptChannelImportException>(),
        reason: 'Rust 导入失败必须是类型化错误');
    expect(
      (thrown as ScriptChannelImportException).errorCode,
      ScriptChannelImportException.code,
    );
    expect(
      File('${dir.path}/broken.zip').existsSync(),
      isFalse,
      reason: '导入失败不得回落到旧 zip 写入位置',
    );
    expect(ChannelManager.instance.getChannelByKey('js_broken'), isNull);
  });

  test('legacy_channel_import_stays_typed_when_channels_flag_on', () async {
    // channels=true 但 jsChannel=false：旧 Dart 写入仍在 Rust channel 域之下，
    // 保留既有的类型化拒绝（这是 flag-off 的旧路径语义）。
    await _setChannelsFlag(channels: true);

    final dir = await Directory.systemTemp.createTemp('gstore_flag_import');
    addTearDown(() => dir.delete(recursive: true));

    Object? thrown;
    try {
      await ChannelLoader(directory: dir).importZip(
        channelKey: 'js_flipped',
        zipBytes: _zip(),
      );
    } catch (error) {
      thrown = error;
    }

    expect(
      thrown,
      isNotNull,
      reason: 'flag on 必须返回类型化错误，不能静默写入后再由 registerChannel 拒绝',
    );
    expect(
      thrown.toString(),
      contains('CORE_E_CHANNEL_LEGACY_DISABLED'),
      reason: '错误必须是稳定的 CORE_E_CHANNEL_LEGACY_DISABLED 代码',
    );
    expect(
      File('${dir.path}/flipped.zip').existsSync(),
      isFalse,
      reason: 'flag on 时不得写入任何 zip 渠道包',
    );
    expect(ChannelManager.instance.getChannelByKey('js_flipped'), isNull);
  });
}

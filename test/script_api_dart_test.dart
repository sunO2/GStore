import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';

/// 可注入的 flags 后端（不触碰 FFI）。
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

/// 记录调用并按固定数据返回的假 ScriptApi 后端。
class _RecordingScriptBackend implements ScriptApiBackend {
  final List<String> calls = <String>[];
  String runResult = '{"version":2026.1,"proxy":"http://127.0.0.1:7890"}';

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    calls.add('init');
  }

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async {
    calls.add('import:${packZipBytes.length}:$expectedKey');
    return _pack();
  }

  @override
  Future<void> remove({required String key}) async => calls.add('remove:$key');

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async {
    calls.add('refresh:$key');
    return _pack();
  }

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async =>
      calls.add('setEnv:$key:$env');

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async =>
      calls.add('setConfig:$key:$config');

  @override
  Future<String> run({
    required String key,
    required String method,
    required String paramsJson,
  }) async {
    calls.add('run:$key:$method:$paramsJson');
    return runResult;
  }

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async {
    calls.add('list');
    return <rust_pack.ScriptPackInfo>[_pack()];
  }

  @override
  Future<String> storedApps({required String key}) async {
    calls.add('storedApps:$key');
    return '[]';
  }

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async =>
      calls.add('releaseDetail:$key:$appId');

  static rust_pack.ScriptPackInfo _pack() => const rust_pack.ScriptPackInfo(
        key: 'js_demo',
        name: 'Demo',
        description: '',
        icon: '',
        hasDetail: false,
      );
}

const _jsChannelOff = CoreFlagsSnapshot(jsChannel: false);
const _jsChannelOn = CoreFlagsSnapshot(jsChannel: true);

Future<void> _setFlag(bool jsChannel) async {
  CoreFlags.installBackend(_FakeFlagsBackend(
    jsChannel ? _jsChannelOn : _jsChannelOff,
  ));
  await CoreFlags.refresh();
  expect(CoreFlags.jsChannel, jsChannel);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(CoreFlags.resetBackend);

  test(
      'flag=false：facade 全部入口抛出 typed CORE_E_SCRIPT_JS_CHANNEL_DISABLED 且不触达后端',
      () async {
    await _setFlag(false);
    final backend = _RecordingScriptBackend();
    final api = ScriptApi(backend: backend);

    final calls = <Future<Object?> Function()>[
      () => api.init(dataDir: 'd', filesDir: 'f', cacheDir: 'c'),
      () => api.import_(packZipBytes: const <int>[1], expectedKey: 'js_demo'),
      () => api.remove(key: 'js_demo'),
      () => api.refresh(key: 'js_demo'),
      () => api.setEnv(key: 'js_demo', env: const <String, String>{}),
      () => api.setConfig(key: 'js_demo', config: const <String, String>{}),
      () => api.run(key: 'js_demo', method: 'getAllApps', paramsJson: '{}'),
      () => api.list(),
      () => api.storedApps(key: 'js_demo'),
      () => api.releaseDetail(key: 'js_demo', appId: 'com.example.app'),
      () => api.getConfig(key: 'js_demo'),
    ];

    for (final call in calls) {
      await expectLater(
        call(),
        throwsA(isA<ScriptApiDisabledException>().having(
          (error) => error.errorCode,
          'code',
          ScriptApiDisabledException.code,
        )),
      );
    }
    expect(backend.calls, isEmpty, reason: 'flag=false 时不得触达 ScriptApi 后端');
  });

  test(
      'flag=true：十个入口委托 rust.ScriptApi，getConfig 与 Dart lane 的 ChannelConfig 形状一致',
      () async {
    await _setFlag(true);
    final backend = _RecordingScriptBackend();
    final api = ScriptApi(backend: backend);

    await api.init(dataDir: 'd', filesDir: 'f', cacheDir: 'c');
    await api.import_(packZipBytes: const <int>[1, 2], expectedKey: 'js_demo');
    await api.remove(key: 'js_demo');
    await api.refresh(key: 'js_demo');
    await api.setEnv(key: 'js_demo', env: const <String, String>{'A': '1'});
    await api
        .setConfig(key: 'js_demo', config: const <String, String>{'k': '"v"'});
    final raw =
        await api.run(key: 'js_demo', method: 'getAllApps', paramsJson: '{}');
    await api.list();
    await api.storedApps(key: 'js_demo');
    await api.releaseDetail(key: 'js_demo', appId: 'com.example.app');

    expect(raw, backend.runResult);
    expect(backend.calls, <String>[
      'init',
      'import:2:js_demo',
      'remove:js_demo',
      'refresh:js_demo',
      'setEnv:js_demo:{A: 1}',
      'setConfig:js_demo:{k: "v"}',
      'run:js_demo:getAllApps:{}',
      'list',
      'storedApps:js_demo',
      'releaseDetail:js_demo:com.example.app',
    ]);

    final config = await api.getConfig(key: 'js_demo');
    expect(backend.calls.last, 'run:js_demo:getConfig:{}');
    // JsChannel.getConfig maps the raw payload to {version, proxy} with
    // version defaulting to '' and proxy nullable/stringified.
    expect(config, <String, Object?>{
      'version': '2026.1',
      'proxy': 'http://127.0.0.1:7890',
    });
  });

  test('getConfig 的 proxy 缺失 → null，version 缺失 → 空串（与 Dart lane 一致）', () async {
    await _setFlag(true);
    final backend = _RecordingScriptBackend()..runResult = '{"version":"3"}';
    final api = ScriptApi(backend: backend);

    expect(await api.getConfig(key: 'js_demo'),
        <String, Object?>{'version': '3', 'proxy': null});
  });
}

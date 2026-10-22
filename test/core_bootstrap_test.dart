import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/core_bootstrap.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Fake FRB backend: records the exact call order and never touches the
/// native library.
class _RecordingBackend implements CoreBootstrapBackend {
  _RecordingBackend({this.initError});

  final Object? initError;

  final List<String> calls = <String>[];
  rust.PlatformFactsDto? facts;
  rust.InventorySnapshotDto? snapshot;

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    calls.add('init');
    final error = initError;
    if (error != null) throw error;
  }

  @override
  Future<void> pushPlatformFacts(rust.PlatformFactsDto value) async {
    calls.add('pushPlatformFacts');
    facts = value;
  }

  @override
  Future<rust.InventoryPushResultDto> pushInventory(
    rust.InventorySnapshotDto value,
  ) async {
    calls.add('pushInventory');
    snapshot = value;
    return const rust.InventoryPushResultDto(accepted: true);
  }
}

/// Fake platform probe: fixed device info + inventory payloads.
class _FakeProbe implements CorePlatformProbe {
  _FakeProbe({this.deviceInfoError});

  final Object? deviceInfoError;

  int deviceInfoCalls = 0;
  int listInstalledCalls = 0;

  @override
  Future<Map<String, Object?>> deviceInfo() async {
    deviceInfoCalls++;
    final error = deviceInfoError;
    if (error != null) throw error;
    return <String, Object?>{
      'manufacturer': 'Google',
      'model': 'Pixel 8',
      'device': 'shiba',
      'android_version': '14',
      'sdk_int': 34,
      'abis': <String>['arm64-v8a', 'armeabi-v7a'],
    };
  }

  @override
  Future<List<Map<String, Object?>>> listInstalled() async {
    listInstalledCalls++;
    return <Map<String, Object?>>[
      <String, Object?>{
        'package_name': 'com.example.app',
        'app_name': '示例',
        'version_name': '1.2.3',
        'version_code': 123,
        'icon': null,
        'is_system': false,
        'signature_sha256': 'ab:cd:ef',
        'source_dir': '/data/app/base.apk',
        'installer': null,
        'target_sdk': 34,
        'min_sdk': 24,
        'abis': <String>['arm64-v8a'],
      },
      <String, Object?>{
        'package_name': 'com.example.system',
      },
    ];
  }
}

void main() {
  const int capturedMs = 1700000000123;

  setUp(() {
    CoreBootstrap.reset();
  });

  tearDown(() {
    CoreBootstrap.reset();
  });

  test('start() pushes init -> facts -> inventory in order with ms clock',
      () async {
    final backend = _RecordingBackend();
    final probe = _FakeProbe();
    CoreBootstrap.debugConfigure(
      backend: backend,
      probe: probe,
      nowMillis: () => capturedMs,
      os: 'android',
      dirs: const (
        '/tmp/gstore/data',
        '/tmp/gstore/files',
        '/tmp/gstore/cache',
      ),
    );

    await CoreBootstrap.start();

    expect(CoreBootstrap.ready, isTrue);
    expect(
      backend.calls,
      <String>['init', 'pushPlatformFacts', 'pushInventory'],
      reason: 'facts must land before the inventory snapshot',
    );

    final facts = backend.facts!;
    expect(facts.sourceId, 'android_frontend');
    expect(facts.os, 'android');
    expect(facts.arch, 'arm64-v8a');
    expect(facts.abis, <String>['arm64-v8a', 'armeabi-v7a']);
    expect(facts.sdk, 34);
    expect(facts.device.model, 'Pixel 8');
    expect(facts.device.manufacturer, 'Google');
    expect(facts.paths.data, endsWith('/data'));
    expect(facts.paths.files, endsWith('/files'));
    expect(facts.paths.cache, endsWith('/cache'));
    expect(facts.cryptoKey, isNull);
    expect(
      facts.capturedAt,
      capturedMs,
      reason: 'the crate clock is milliseconds, not seconds',
    );

    final snapshot = backend.snapshot!;
    expect(snapshot.sourceId, 'android_frontend');
    expect(snapshot.capturedAt, capturedMs);
    expect(snapshot.seq, greaterThanOrEqualTo(capturedMs));
    expect(snapshot.apps, hasLength(2));

    final first = snapshot.apps.first;
    expect(first.packageName, 'com.example.app');
    expect(first.appName, '示例');
    expect(first.versionName, '1.2.3');
    expect(first.versionCode, 123);
    expect(first.isSystem, isFalse);
    expect(first.signatureSha256, 'ab:cd:ef');
    expect(first.sourceDir, '/data/app/base.apk');
    expect(first.installer, isNull);
    expect(first.targetSdk, 34);
    expect(first.minSdk, 24);
    expect(first.abis, <String>['arm64-v8a']);

    final second = snapshot.apps.last;
    expect(second.packageName, 'com.example.system');
    expect(second.appName, isNull);
    expect(second.versionName, '');
    expect(second.versionCode, 0);
    expect(second.isSystem, isFalse);
    expect(second.targetSdk, 0);
    expect(second.minSdk, 0);
    expect(second.abis, isEmpty);
  });

  test('start() is idempotent: a second call re-pushes nothing', () async {
    final backend = _RecordingBackend();
    final probe = _FakeProbe();
    CoreBootstrap.debugConfigure(
      backend: backend,
      probe: probe,
      nowMillis: () => capturedMs,
      os: 'android',
      dirs: const (
        '/tmp/gstore/data',
        '/tmp/gstore/files',
        '/tmp/gstore/cache',
      ),
    );

    await CoreBootstrap.start();
    await CoreBootstrap.start();

    expect(backend.calls, <String>[
      'init',
      'pushPlatformFacts',
      'pushInventory',
    ]);
    expect(probe.deviceInfoCalls, 1);
    expect(probe.listInstalledCalls, 1);
  });

  test('concurrent start() calls share one single-flight run', () async {
    final backend = _RecordingBackend();
    final probe = _FakeProbe();
    CoreBootstrap.debugConfigure(
      backend: backend,
      probe: probe,
      nowMillis: () => capturedMs,
      os: 'android',
      dirs: const (
        '/tmp/gstore/data',
        '/tmp/gstore/files',
        '/tmp/gstore/cache',
      ),
    );

    await Future.wait(<Future<void>>[
      CoreBootstrap.start(),
      CoreBootstrap.start(),
      CoreBootstrap.start(),
    ]);

    expect(backend.calls.where((call) => call == 'init'), hasLength(1));
    expect(backend.calls.where((call) => call == 'pushInventory'),
        hasLength(1));
  });

  test('a thrown error is non-fatal and leaves ready == false', () async {
    final backend = _RecordingBackend(initError: StateError('no native lib'));
    CoreBootstrap.debugConfigure(
      backend: backend,
      probe: _FakeProbe(),
      nowMillis: () => capturedMs,
      os: 'android',
      dirs: const (
        '/tmp/gstore/data',
        '/tmp/gstore/files',
        '/tmp/gstore/cache',
      ),
    );

    await expectLater(CoreBootstrap.start(), completes);

    expect(CoreBootstrap.ready, isFalse);
    expect(backend.calls, <String>['init']);
  });

  test('a failing platform probe leaves ready == false without pushing facts',
      () async {
    final backend = _RecordingBackend();
    CoreBootstrap.debugConfigure(
      backend: backend,
      probe: _FakeProbe(deviceInfoError: StateError('channel missing')),
      nowMillis: () => capturedMs,
      os: 'android',
      dirs: const (
        '/tmp/gstore/data',
        '/tmp/gstore/files',
        '/tmp/gstore/cache',
      ),
    );

    await expectLater(CoreBootstrap.start(), completes);

    expect(CoreBootstrap.ready, isFalse);
    expect(backend.calls, <String>['init']);
  });

  test('reset() clears ready so tests start from a clean gate', () async {
    CoreBootstrap.debugConfigure(
      backend: _RecordingBackend(),
      probe: _FakeProbe(),
      nowMillis: () => capturedMs,
      os: 'android',
      dirs: const (
        '/tmp/gstore/data',
        '/tmp/gstore/files',
        '/tmp/gstore/cache',
      ),
    );
    await CoreBootstrap.start();
    expect(CoreBootstrap.ready, isTrue);

    CoreBootstrap.reset();

    expect(CoreBootstrap.ready, isFalse);
  });
}

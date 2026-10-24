import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/core_bootstrap.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/core_cutover.dart';
import 'dart:io';

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

/// Fake flags backend: appends its read into the shared bootstrap call log so
/// the refresh position is observable.
class _RecordingFlagsBackend implements CoreFlagsBackend {
  _RecordingFlagsBackend(this.calls, {this.readError});

  final List<String> calls;
  final Object? readError;

  @override
  Future<CoreFlagsSnapshot> read() async {
    calls.add('flagsRefresh');
    final error = readError;
    if (error != null) throw error;
    return const CoreFlagsSnapshot(download: true);
  }

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    calls.add('flagsWrite');
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

/// Fake cutover backend: appends its work into the shared bootstrap call log
/// so the durable cutover's position (after the inventory push) is observable.
class _RecordingCutover implements CoreCutoverBackend {
  _RecordingCutover(this.calls);

  final List<String> calls;

  @override
  Future<int> exportSnapshot({required String path}) async {
    calls.add('cutover:snapshot');
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(const <int>[0x53, 0x51, 0x4c, 0x69, 0x74, 0x65]);
    return 1;
  }

  @override
  Future<CutoverStepResult> resyncChannels() async {
    calls.add('cutover:channels');
    return const CutoverStepResult(rows: 1, parityOk: true);
  }

  @override
  Future<CutoverStepResult> resyncJsChannel() async {
    calls.add('cutover:jsChannel');
    return const CutoverStepResult(rows: 1, parityOk: true);
  }

  @override
  Future<CutoverStepResult> resyncCatalog() async {
    calls.add('cutover:catalog');
    return const CutoverStepResult(rows: 1, parityOk: true);
  }

  @override
  Future<CutoverStepResult> resyncUpdate() async {
    calls.add('cutover:update');
    return const CutoverStepResult(rows: 1, parityOk: true);
  }
}

/// Fake cutover backend whose resync fails mid-way: no marker may be written.
class _FailingCutover implements CoreCutoverBackend {
  @override
  Future<int> exportSnapshot({required String path}) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(const <int>[0x53, 0x51, 0x4c, 0x69, 0x74, 0x65]);
    return 1;
  }

  @override
  Future<CutoverStepResult> resyncChannels() async =>
      throw StateError('forced channels failure');

  @override
  Future<CutoverStepResult> resyncJsChannel() async =>
      const CutoverStepResult(rows: 0, parityOk: true);

  @override
  Future<CutoverStepResult> resyncCatalog() async =>
      const CutoverStepResult(rows: 0, parityOk: true);

  @override
  Future<CutoverStepResult> resyncUpdate() async =>
      const CutoverStepResult(rows: 0, parityOk: true);
}

void main() {
  const int capturedMs = 1700000000123;

  setUp(() {
    CoreBootstrap.reset();
    CoreFlags.resetBackend();
  });

  tearDown(() {
    CoreBootstrap.reset();
    CoreFlags.resetBackend();
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

  test('start() refreshes flags after init and before pushPlatformFacts',
      () async {
    final backend = _RecordingBackend();
    final flags = _RecordingFlagsBackend(backend.calls);
    CoreFlags.installBackend(flags);
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

    await CoreBootstrap.start();

    expect(CoreBootstrap.ready, isTrue);
    expect(
      backend.calls,
      <String>[
        'init',
        'flagsRefresh',
        'pushPlatformFacts',
        'pushInventory',
      ],
      reason: 'flags must be readable before facts/inventory are pushed',
    );
    expect(CoreFlags.download, isTrue,
        reason: 'bootstrap refresh populates the mirror');
  });

  test('a failing flags refresh does not fail bootstrap', () async {
    final backend = _RecordingBackend();
    CoreFlags.installBackend(
      _RecordingFlagsBackend(
        backend.calls,
        readError: StateError('flags unavailable'),
      ),
    );
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

    expect(CoreBootstrap.ready, isTrue);
    expect(
      backend.calls,
      <String>[
        'init',
        'flagsRefresh',
        'pushPlatformFacts',
        'pushInventory',
      ],
    );
  });
  test('the durable cutover runs once, after facts + inventory', () async {
    final backend = _RecordingBackend();
    CoreFlags.installBackend(_RecordingFlagsBackend(backend.calls));
    final filesDir = Directory.systemTemp.createTempSync('gstore_boot_cutover_');
    addTearDown(() {
      if (filesDir.existsSync()) filesDir.deleteSync(recursive: true);
    });
    CoreBootstrap.debugConfigure(
      backend: backend,
      probe: _FakeProbe(),
      cutover: _RecordingCutover(backend.calls),
      nowMillis: () => capturedMs,
      os: 'android',
      dirs: (
        '/tmp/gstore/data',
        filesDir.path,
        '/tmp/gstore/cache',
      ),
    );

    await CoreBootstrap.start();

    expect(CoreBootstrap.ready, isTrue);
    expect(
      backend.calls,
      <String>[
        'init',
        'flagsRefresh',
        'pushPlatformFacts',
        'pushInventory',
        'cutover:snapshot',
        'cutover:channels',
        'cutover:jsChannel',
        'cutover:catalog',
        'cutover:update',
      ],
      reason: 'the cutover must run after the bootstrap inventory push',
    );
    expect(File('${filesDir.path}/migration/cutover_v6.done').existsSync(),
        isTrue);

    // Second start is single-flight: no second cutover run.
    await CoreBootstrap.start();
    expect(backend.calls.where((c) => c == 'cutover:snapshot'), hasLength(1));
  });

  test('a failed cutover leaves the marker absent but keeps bootstrap ready',
      () async {
    final backend = _RecordingBackend();
    final filesDir = Directory.systemTemp.createTempSync('gstore_boot_fail_');
    addTearDown(() {
      if (filesDir.existsSync()) filesDir.deleteSync(recursive: true);
    });
    CoreBootstrap.debugConfigure(
      backend: backend,
      probe: _FakeProbe(),
      cutover: _FailingCutover(),
      nowMillis: () => capturedMs,
      os: 'android',
      dirs: (
        '/tmp/gstore/data',
        filesDir.path,
        '/tmp/gstore/cache',
      ),
    );

    await CoreBootstrap.start();

    expect(CoreBootstrap.ready, isTrue,
        reason: 'a cutover failure retries next launch, it does not brick boot');
    expect(File('${filesDir.path}/migration/cutover_v6.done').existsSync(),
        isFalse);
  });
}

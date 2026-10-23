import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:gstore/core/service/install_manager.dart';

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

class _NoopDownloadBackend implements DownloadBackend {
  @override
  Future<int> start(rust.DownloadStartRequest request) async => 0;

  @override
  Future<List<rust.DownloadTaskDto>> list() async =>
      const <rust.DownloadTaskDto>[];

  @override
  Future<rust.DownloadTaskDto?> get(String moduleTaskId) async => null;

  @override
  Future<void> pause(String moduleTaskId) async {}

  @override
  Future<void> resume(String moduleTaskId) async {}

  @override
  Future<void> cancel(String moduleTaskId) async {}

  @override
  Future<void> retry(String moduleTaskId) async {}

  @override
  Future<void> restart(String moduleTaskId) async {}

  @override
  Future<void> remove(String moduleTaskId) async {}

  @override
  Stream<rust.DownloadTaskDto> watchAll() => const Stream.empty();
}

/// Fake install transport: records every call and replays queued events.
class _FakeInstallBackend implements InstallBackend {
  _FakeInstallBackend({required this.start});

  InstallStart start;
  List<String> events = const <String>[];

  final List<String> calls = <String>[];
  final List<InstallReport> reports = <InstallReport>[];
  Object? reportError;

  @override
  Future<InstallStart> install(String moduleTaskId) async {
    calls.add('install:$moduleTaskId');
    return start;
  }

  @override
  Future<List<InstallStart>> pendingRequests() async {
    calls.add('pendingRequests');
    return const <InstallStart>[];
  }

  @override
  Future<InstallResultAck> reportResult(InstallReport report) async {
    calls.add('reportResult:${report.status}');
    final error = reportError;
    if (error != null) throw error;
    reports.add(report);
    return InstallResultAck(
      sessionId: report.sessionId,
      status: report.status,
      changed: true,
    );
  }

  @override
  Future<List<String>> takeEvents() async {
    calls.add('takeEvents');
    final drained = events;
    events = const <String>[];
    return drained;
  }

  @override
  Future<InstallRecord?> get(String moduleTaskId) async {
    calls.add('get:$moduleTaskId');
    return start.record;
  }

  @override
  Future<void> uninstall(String packageName) async =>
      calls.add('uninstall:$packageName');

  @override
  Future<void> launch(String packageName) async =>
      calls.add('launch:$packageName');
}

/// Minimal `rust.InstallApi` stand-in so the FRB error normalisation can be
/// exercised without a native library. The FRB codec throws the raw error
/// string for `Result<_, String>`.
class _FakeInstallApi implements rust.InstallApi {
  _FakeInstallApi({this.error, this.changed = true});

  final String? error;
  final bool changed;
  int reportCalls = 0;

  @override
  bool get isDisposed => false;

  @override
  void dispose() {}

  @override
  Future<rust.InstallRecordDto?> get_({required String moduleTaskId}) async =>
      null;

  @override
  Future<rust.InstallStartDto> install({required String moduleTaskId}) async {
    throw StateError('not used');
  }

  @override
  Future<List<rust.InstallStartDto>> pendingRequests() async =>
      const <rust.InstallStartDto>[];

  @override
  Future<rust.InstallResultAckDto> reportResult({
    required rust.InstallReportDto report,
  }) async {
    reportCalls++;
    final message = error;
    if (message != null) throw message;
    return rust.InstallResultAckDto(
      sessionId: report.sessionId,
      status: report.status,
      changed: changed,
    );
  }

  @override
  Future<List<String>> takeEvents() async => const <String>[];
}

InstallRecord _record({
  String status = 'pending',
  String? sessionId = 'session-1',
}) =>
    InstallRecord(
      moduleTaskId: 'task-1',
      appId: 'com.example.app',
      status: status,
      method: 'shizuku',
      sessionId: sessionId,
    );

InstallRequest _request({String apkPath = ''}) => InstallRequest(
      moduleTaskId: 'task-1',
      sessionId: 'session-1',
      packageName: 'com.example.app',
      versionName: '1.2.3',
      apkPath: apkPath,
      method: 'shizuku',
      variant: const InstallVariant(
        abi: 'arm64-v8a',
        url: 'https://example.test/app.apk',
        fallbackChain: <String>[],
      ),
    );

String _requestedEvent(InstallRequest request) => jsonEncode(
      <String, Object?>{
        'event': 'install.requested',
        'payload': <String, Object?>{'request': request.toJson()},
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late File apk;
  late _FakeInstallBackend backend;

  setUp(() async {
    InstallManager.resetForTest();
    InstallFacade.resetForTest();
    DownloadFacade.backendOverride = _NoopDownloadBackend();
    CoreFlags.installBackend(
      _FakeFlagsBackend(const CoreFlagsSnapshot(install: true)),
    );
    await CoreFlags.refresh();
    temp = Directory.systemTemp.createTempSync('gstore_install_flow_');
    apk = File('${temp.path}/app.apk')..writeAsBytesSync(<int>[0x50, 0x4B]);
    backend = _FakeInstallBackend(start: InstallStart(record: _record()));
    InstallManager.installFacadeForTest = InstallFacade(backend: backend);
    InstallManager.clock = () => DateTime.fromMillisecondsSinceEpoch(
          1700000000123,
        );
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
    InstallManager.resetForTest();
    InstallFacade.resetForTest();
    DownloadFacade.backendOverride = null;
    CoreFlags.resetBackend();
  });

  test('request == null reports the settled record and never re-installs',
      () async {
    backend.start = InstallStart(record: _record(status: 'installed'));
    var commands = 0;
    InstallManager.commandRunnerForTest = (_) async {
      commands++;
      return 'Success';
    };
    final manager = InstallManager.instance
      ..setShizukuStateForTest(binder: true, permission: true)
      ..setIsAndroidForTest(true);

    final result = await manager.installTask('task-1', apk.path);

    expect(result, (true, InstallMethod.shizuku));
    expect(commands, 0, reason: 'a settled record must not run pm install');
    expect(
      backend.calls.where((call) => call.startsWith('reportResult')),
      isEmpty,
      reason: 'nothing to report when the core already settled the row',
    );
    expect(backend.calls, <String>['pendingRequests', 'install:task-1']);
  });

  test('request != null runs the staged pm install then reports installed',
      () async {
    backend.start = InstallStart(
      record: _record(),
      request: _request(apkPath: apk.path),
    );
    final commands = <String>[];
    InstallManager.commandRunnerForTest = (command) async {
      commands.add(command);
      return 'Success';
    };
    final manager = InstallManager.instance
      ..setShizukuStateForTest(binder: true, permission: true)
      ..setIsAndroidForTest(true);

    final result = await manager.installTask('task-1', apk.path);

    expect(result, (true, InstallMethod.shizuku));
    expect(commands, hasLength(1));
    expect(commands.single, contains('pm install -r'));
    expect(commands.single, contains("/data/local/tmp/gstore_install_"));
    expect(commands.single, contains(apk.path));

    expect(backend.reports, hasLength(1));
    final report = backend.reports.single;
    expect(report.sessionId, 'session-1');
    expect(report.status, 'installed');
    expect(report.method, 'shizuku');
    expect(report.installedVersion, '1.2.3');
    expect(report.reportedAt, 1700000000123, reason: 'ms clock');
  });

  test('a rejected pm install reports denied and skips the system fallback',
      () async {
    backend.start = InstallStart(
      record: _record(),
      request: _request(apkPath: apk.path),
    );
    final commands = <String>[];
    InstallManager.commandRunnerForTest = (command) async {
      commands.add(command);
      return 'Failure [INSTALL_FAILED_USER_RESTRICTED: rejected permissions]';
    };
    var systemInstalls = 0;
    InstallManager.appInstallerForTest = (path) async => systemInstalls++;
    final manager = InstallManager.instance
      ..setShizukuStateForTest(binder: true, permission: true)
      ..setIsAndroidForTest(true);

    final result = await manager.installTask('task-1', apk.path);

    expect(result.$1, isFalse);
    expect(commands, hasLength(1));
    expect(systemInstalls, 0, reason: 'user denial stops the fallback');
    expect(backend.reports.single.status, 'denied');
  });

  test('a failed pm install falls back to the system installer', () async {
    backend.start = InstallStart(
      record: _record(),
      request: _request(apkPath: apk.path),
    );
    InstallManager.commandRunnerForTest = (_) async => 'Failure [BOOM]';
    final installedPaths = <String>[];
    InstallManager.appInstallerForTest = (path) async =>
        installedPaths.add(path);
    final manager = InstallManager.instance
      ..setShizukuStateForTest(binder: true, permission: true)
      ..setIsAndroidForTest(true);

    final result = await manager.installTask('task-1', apk.path);

    expect(result, (true, InstallMethod.shizuku));
    expect(installedPaths, <String>[apk.path]);
    expect(backend.reports.single.status, 'installed');
  });

  test('an unknown session surfaces the typed CORE_E_INSTALL_SESSION error',
      () async {
    final facade = InstallFacade(
      backend: FrbInstallBackend(
        dataDir: '${temp.path}/data',
        filesDir: '${temp.path}/files',
        cacheDir: '${temp.path}/cache',
        apiFactory: (String dataDir, String filesDir, String cacheDir) async =>
            _FakeInstallApi(
          error: 'CORE_E_INSTALL_SESSION: no pending row for session-9',
        ),
      ),
    );

    await expectLater(
      () => facade.reportResult(
        const InstallReport(
          sessionId: 'session-9',
          status: 'installed',
          method: 'shizuku',
          reportedAt: 1700000000123,
        ),
      ),
      throwsA(
        isA<InstallCoreException>()
            .having((e) => e.code, 'code', 'CORE_E_INSTALL_SESSION')
            .having((e) => e.message, 'message', contains('session-9')),
      ),
    );
  });

  test('a duplicate terminal report passes changed:false through', () async {
    final api = _FakeInstallApi(changed: false);
    final facade = InstallFacade(
      backend: FrbInstallBackend(
        dataDir: '${temp.path}/data',
        filesDir: '${temp.path}/files',
        cacheDir: '${temp.path}/cache',
        apiFactory: (String dataDir, String filesDir, String cacheDir) async =>
            api,
      ),
    );

    final ack = await facade.reportResult(
      const InstallReport(
        sessionId: 'session-1',
        status: 'installed',
        method: 'shizuku',
        reportedAt: 1700000000123,
      ),
    );

    expect(ack.sessionId, 'session-1');
    expect(ack.status, 'installed');
    expect(ack.changed, isFalse);
    expect(api.reportCalls, 1);
  });

  test('install.requested event triggers the auto-install path', () async {
    final request = _request(apkPath: apk.path);
    backend.events = <String>[_requestedEvent(request)];
    final commands = <String>[];
    InstallManager.commandRunnerForTest = (command) async {
      commands.add(command);
      return 'Success';
    };
    final manager = InstallManager.instance
      ..setShizukuStateForTest(binder: true, permission: true)
      ..setIsAndroidForTest(true);

    final handled = await manager.consumeInstallRequests();

    expect(handled, 1);
    expect(commands, hasLength(1));
    expect(commands.single, contains('pm install -r'));
    expect(backend.reports.single.sessionId, 'session-1');
    expect(backend.reports.single.status, 'installed');
  });

  test('malformed / unknown events are ignored without crashing', () async {
    backend.events = <String>[
      'not-json',
      '{"event":"inventory.changed","payload":{}}',
      '{"event":"install.requested","payload":{"request":{"session_id":""}}}',
      '{"event":"install.requested"}',
    ];
    var commands = 0;
    InstallManager.commandRunnerForTest = (_) async {
      commands++;
      return 'Success';
    };
    final manager = InstallManager.instance
      ..setShizukuStateForTest(binder: true, permission: true)
      ..setIsAndroidForTest(true);

    final handled = await manager.consumeInstallRequests();

    expect(handled, 0);
    expect(commands, 0);
    expect(backend.reports, isEmpty);
  });

  test('an unknown package for an event reports failed, never throws', () async {
    final request = _request(apkPath: '${temp.path}/missing.apk');
    backend.events = <String>[_requestedEvent(request)];
    InstallManager.commandRunnerForTest = (_) async => 'Success';
    final manager = InstallManager.instance
      ..setShizukuStateForTest(binder: true, permission: true)
      ..setIsAndroidForTest(true);

    final handled = await manager.consumeInstallRequests();

    expect(handled, 1);
    expect(backend.reports.single.status, 'failed');
    expect(backend.reports.single.error, contains('CORE_E_INSTALL_APK_MISSING'));
  });

  group('apk import path materialisation', () {
    const channel = MethodChannel('gstore/apk_source');
    late List<MethodCall> calls;
    late List<String> imported;

    void installHandler(Future<Object?> Function(MethodCall call)? handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    setUp(() {
      calls = <MethodCall>[];
      imported = <String>[];
      ApkSourceService.instance
        ..debugSetMaterializeUriResolver(null)
        ..debugSetCoreImporter((String pathOrFd) async {
          imported.add(pathOrFd);
          return BigInt.from(7);
        });
    });

    tearDown(() {
      installHandler(null);
      ApkSourceService.instance
        ..debugSetMaterializeUriResolver(null)
        ..debugSetCoreImporter(null);
    });

    test('content:// is materialised by gstore/apk_source and imported verbatim',
        () async {
      const cachePath =
          '/data/user/0/com.suno2.gstore/cache/imports/ab12cd34.apk';
      installHandler((call) async {
        calls.add(call);
        expect(call.method, 'materializeUri');
        expect(call.arguments, 'content://media/external/file/42');
        return cachePath;
      });

      final handle = await ApkSourceService.instance
          .importApk('content://media/external/file/42');

      expect(handle, BigInt.from(7));
      expect(calls, hasLength(1), reason: 'one channel call, no N+1');
      expect(
        imported,
        <String>[cachePath],
        reason: 'the materialised path is what importFile(pathOrFd:) receives',
      );
    });

    test('a failure envelope becomes a typed exception with the exact code',
        () async {
      installHandler((call) async {
        calls.add(call);
        return jsonEncode(<String, Object?>{
          'ok': false,
          'code': 'CORE_E_APK_URI_UNREADABLE',
          'message': 'content provider permission denied',
        });
      });

      await expectLater(
        () => ApkSourceService.instance
            .importApk('content://media/external/file/42'),
        throwsA(
          isA<ApkSourceException>()
              .having((e) => e.code, 'code', 'CORE_E_APK_URI_UNREADABLE')
              .having((e) => e.message, 'message', contains('permission')),
        ),
      );
      expect(calls, hasLength(1));
      expect(imported, isEmpty, reason: 'no importFile on a failed materialise');
    });

    test('a COPY_FAILED envelope keeps its exact code too', () async {
      installHandler((call) async => jsonEncode(<String, Object?>{
            'ok': false,
            'code': 'CORE_E_APK_URI_COPY_FAILED',
            'message': 'cannot create cache dir',
          }));

      await expectLater(
        () => ApkSourceService.instance
            .importApk('content://media/external/file/43'),
        throwsA(
          isA<ApkSourceException>()
              .having((e) => e.code, 'code', ApkSourceService.uriCopyFailedCode),
        ),
      );
      expect(imported, isEmpty);
    });

    test('an absolute path is still sent once and passes through unchanged',
        () async {
      installHandler((call) async {
        calls.add(call);
        return call.arguments as String;
      });

      final handle = await ApkSourceService.instance.importApk(apk.path);

      expect(handle, BigInt.from(7));
      expect(calls, hasLength(1), reason: 'one call per import');
      expect(calls.single.method, 'materializeUri');
      expect(calls.single.arguments, apk.path);
      expect(imported, <String>[apk.path]);
    });

    test('empty / file:// / relative are typed errors with no importFile call',
        () async {
      installHandler((call) async {
        calls.add(call);
        return null;
      });

      await expectLater(
        () => ApkSourceService.instance.importApk('   '),
        throwsA(
          isA<ApkSourceException>()
              .having((e) => e.code, 'code', ApkSourceService.uriMalformedCode),
        ),
      );
      await expectLater(
        () => ApkSourceService.instance.importApk('file://${apk.path}'),
        throwsA(
          isA<ApkSourceException>().having(
            (e) => e.code,
            'code',
            ApkSourceService.uriUnsupportedCode,
          ),
        ),
      );
      await expectLater(
        () => ApkSourceService.instance.importApk('relative/app.apk'),
        throwsA(
          isA<ApkSourceException>().having(
            (e) => e.code,
            'code',
            ApkSourceService.uriUnsupportedCode,
          ),
        ),
      );

      expect(calls, isEmpty, reason: 'rejected inputs never reach the channel');
      expect(imported, isEmpty);
    });

    test('a malformed envelope is a typed MALFORMED error, never a silent path',
        () async {
      installHandler((call) async => '{not-json');

      await expectLater(
        () => ApkSourceService.instance
            .importApk('content://media/external/file/44'),
        throwsA(
          isA<ApkSourceException>()
              .having((e) => e.code, 'code', ApkSourceService.uriMalformedCode),
        ),
      );
      expect(imported, isEmpty);
    });
  });
}

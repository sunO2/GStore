import 'dart:async';
import 'dart:convert';
import 'dart:io';

// fake_async 是 flutter_test 的传递依赖（未直接列入 pubspec，故忽略该 lint）。
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
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

InstallRequest _request({
  String apkPath = '',
  String method = 'shizuku',
  String versionName = '1.2.3',
}) =>
    InstallRequest(
      moduleTaskId: 'task-1',
      sessionId: 'session-1',
      packageName: 'com.example.app',
      versionName: versionName,
      apkPath: apkPath,
      method: method,
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

/// 捕获 `debugPrint`（生产禁止 `log()`），用于断言「快照未变化」日志已被节流。
///
/// 不转发给原始实现：既避免测试期间把被节流前的刷屏日志打到控制台，也让
/// 计数只反映源码里真正调用 `debugPrint` 的次数（与 `debugPrintThrottled`
/// 自身的节流无关）。
List<String> _captureDebugPrint() {
  final logs = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    logs.add(message ?? '');
  };
  addTearDown(() => debugPrint = original);
  return logs;
}

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

    expect(result, (InstallOutcome.alreadyInstalled, InstallMethod.shizuku));
    expect(commands, 0, reason: 'a settled record must not run pm install');
    expect(
      backend.calls.where((call) => call.startsWith('reportResult')),
      isEmpty,
      reason: 'nothing to report when the core already settled the row',
    );
    expect(backend.calls, <String>['pendingRequests', 'install:task-1']);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 覆盖安装（用户需求）：核心行已是 `installed` 时，显式点击「安装」必须真正
  // 重装（Shizuku/系统安装器），而不是只回报 alreadyInstalled 后什么都不做。
  // 默认 force=false 保持自动安装路径的幂等语义不变。
  // ───────────────────────────────────────────────────────────────────────────
  group('force overwrite install', () {
    test('force: true on an installed row runs the direct overwrite install',
        () async {
      backend.start = InstallStart(record: _record(status: 'installed'));
      final commands = <String>[];
      InstallManager.commandRunnerForTest = (command) async {
        commands.add(command);
        return 'Success';
      };
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final result = await manager.installTask('task-1', apk.path, force: true);

      expect(result, (InstallOutcome.installed, InstallMethod.shizuku),
          reason: 'a forced tap must overwrite-install the APK, not no-op');
      expect(result.$1, isNot(InstallOutcome.alreadyInstalled));
      expect(commands, hasLength(1),
          reason: 'the overwrite install must run the installer');
      expect(commands.single, contains('pm install -r'));
      expect(commands.single, contains(apk.path));
    });

    test('force: false on the same installed row still no-ops', () async {
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

      expect(result, (InstallOutcome.alreadyInstalled, InstallMethod.shizuku));
      expect(commands, 0,
          reason: 'the non-forced default must keep the idempotent no-op');
      expect(backend.calls, <String>['pendingRequests', 'install:task-1']);
    });

    test('force: true with a missing APK yields a typed failure', () async {
      backend.start = InstallStart(record: _record(status: 'installed'));
      var commands = 0;
      InstallManager.commandRunnerForTest = (_) async {
        commands++;
        return 'Success';
      };
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final result = await manager.installTask(
        'task-1',
        '${temp.path}/missing.apk',
        force: true,
      );

      expect(result.$1, InstallOutcome.failed,
          reason: 'a missing APK must be a typed failure, never a silent no-op');
      expect(commands, 0, reason: 'no installer runs for a missing APK');
    });
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

    expect(result, (InstallOutcome.installed, InstallMethod.shizuku));
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

    expect(result.$1, InstallOutcome.failed);
    expect(commands, hasLength(1));
    expect(systemInstalls, 0, reason: 'user denial stops the fallback');
    expect(backend.reports.single.status, 'denied');
  });

  test(
      'a failed pm install launches the system installer but reports NO terminal '
      'status (the row stays pending for the event bridge)', () async {
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

    // The launch is honest: not `installed`, only `launched`.
    expect(result, (InstallOutcome.launched, InstallMethod.shizuku));
    expect(installedPaths, <String>[apk.path],
        reason: 'the system installer intent must still be launched');
    expect(
      backend.reports.where((r) => r.status == 'installed'),
      isEmpty,
      reason: 'launching the installer intent must never report installed',
    );
    expect(
      backend.calls.where((call) => call.startsWith('reportResult')),
      isEmpty,
      reason: 'no terminal report at launch; the terminal result is async',
    );
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

  // ───────────────────────────────────────────────────────────────────────────
  // 点击安装无响应回归（failing-first）：启动系统安装器 Intent 不是"安装完成"。
  // 平台分支只允许 `launched`；核心行保持 pending，由 install_events 或
  // deadline 送达终端结果。绝不在 Intent 启动时谎报 installed。
  // ───────────────────────────────────────────────────────────────────────────
  group('platform launch is honest about the install result', () {
    test('platform intent launch reports NO terminal status', () async {
      backend.start = InstallStart(
        record: _record(),
        request: _request(method: 'platform', apkPath: apk.path),
      );
      final launches = <String>[];
      InstallManager.appInstallerForTest = (path) async => launches.add(path);
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final result = await manager.installTask('task-1', apk.path);

      expect(result.$1, InstallOutcome.launched);
      expect(launches, <String>[apk.path]);
      expect(
        backend.reports,
        isEmpty,
        reason: 'launching the installer intent must report no terminal status',
      );
    });

    test('a terminal install event after a launch produces the matching report',
        () async {
      final controller = StreamController<Object?>();
      addTearDown(controller.close);
      InstallManager.installEventsStreamForTest = controller.stream;
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);
      manager.startEventBridge();
      addTearDown(manager.stopEventBridge);

      backend.start = InstallStart(
        record: _record(),
        request: _request(method: 'platform', apkPath: apk.path),
      );
      InstallManager.appInstallerForTest = (_) async {};

      final launched = await manager.installTask('task-1', apk.path);
      expect(launched.$1, InstallOutcome.launched);
      expect(backend.reports, isEmpty, reason: 'no terminal report at launch');

      controller.add(<String, Object?>{
        'sessionId': 'session-1',
        'packageName': 'com.example.app',
        'status': 'installed',
        'method': 'platform',
        'installedVersion': '1.2.3',
        'error': null,
      });
      await pumpEventQueue();

      expect(backend.reports, hasLength(1));
      expect(backend.reports.single.status, 'installed');
      expect(backend.reports.single.sessionId, 'session-1');
    });

    for (final terminal in <String>['denied', 'failed', 'timeout']) {
      test('a terminal install event ($terminal) is reported verbatim',
          () async {
        final controller = StreamController<Object?>();
        addTearDown(controller.close);
        InstallManager.installEventsStreamForTest = controller.stream;
        final manager = InstallManager.instance
          ..setShizukuStateForTest(binder: true, permission: true)
          ..setIsAndroidForTest(true);
        manager.startEventBridge();
        addTearDown(manager.stopEventBridge);

        controller.add(<String, Object?>{
          'sessionId': 'session-1',
          'packageName': 'com.example.app',
          'status': terminal,
          'method': 'platform',
          'installedVersion': null,
          'error': 'CORE_E_INSTALL_$terminal',
        });
        await pumpEventQueue();

        expect(backend.reports.single.status, terminal);
        expect(backend.reports.single.error, 'CORE_E_INSTALL_$terminal');
      });
    }

    test('no install event within the deadline reports timeout', () {
      backend.start = InstallStart(
        record: _record(),
        request: _request(method: 'platform', apkPath: apk.path),
      );
      InstallManager.appInstallerForTest = (_) async {};
      InstallManager.installPollInterval = const Duration(milliseconds: 10);
      InstallManager.installPendingDeadline = const Duration(milliseconds: 50);
      InstallManager.installPollTimeout = const Duration(seconds: 5);
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
      });

      expect(
        backend.reports.where((r) => r.status == 'timeout'),
        hasLength(1),
        reason: 'a pending row with no event must time out at the deadline',
      );
      expect(
        backend.reports.where((r) => r.status == 'installed'),
        isEmpty,
        reason: 'a timeout must never be reported as installed',
      );
    });

    test('a second tap on a still-pending row re-executes the install', () async {
      backend.start = InstallStart(
        record: _record(),
        request: _request(method: 'platform', apkPath: apk.path),
      );
      final launches = <String>[];
      InstallManager.appInstallerForTest = (path) async => launches.add(path);
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final first = await manager.installTask('task-1', apk.path);
      final second = await manager.installTask('task-1', apk.path);

      expect(first.$1, InstallOutcome.launched);
      expect(second.$1, InstallOutcome.launched);
      expect(
        launches,
        <String>[apk.path, apk.path],
        reason: 'a still-pending row must re-execute, not silently no-op',
      );
      expect(backend.reports, isEmpty,
          reason: 'neither tap may claim a terminal status at launch');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 后台完成确认（on-device 缺陷）：系统安装器在前台运行时，Android 拦截发往后台
  // 应用的隐式 PACKAGE_ADDED / PACKAGE_REPLACED 广播（BroadcastQueue: Background
  // execution not allowed），`install_events` 永远收不到终端结果。平台校验兜底在
  // pending 期间查询目标包是否已按预期版本安装，命中即上报 installed；回到前台
  // 时再校验一次。timeout 仍是最后手段。
  // ───────────────────────────────────────────────────────────────────────────
  group('backgrounded install completion is confirmed by the platform check', () {
    InstallManager managerWithDeadline({
      Duration interval = const Duration(milliseconds: 10),
      Duration deadline = const Duration(milliseconds: 100),
    }) {
      InstallManager.installPollInterval = interval;
      InstallManager.installPendingDeadline = deadline;
      InstallManager.installPollTimeout = const Duration(seconds: 5);
      return InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);
    }

    test(
        'a pending row whose package becomes installed is reported installed '
        '(no install_events event ever arrives)', () {
      // 目标包在安装器确认后变为已安装；广播被系统拦截 → 只有平台校验能确认。
      backend.start = InstallStart(
        record: _record(),
        request: _request(method: 'platform', apkPath: apk.path),
      );
      InstallManager.appInstallerForTest = (_) async {};
      InstallManager.installedVersionCheckForTest = (packageName) async =>
          packageName == 'com.example.app' ? '1.2.3' : null;
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 40));
        async.flushMicrotasks();
      });

      expect(
        backend.reports.where((r) => r.status == 'installed'),
        hasLength(1),
        reason: 'the platform check must confirm a backgrounded install',
      );
      expect(
        backend.reports.where((r) => r.status == 'timeout'),
        isEmpty,
        reason: 'a confirmed install must never be reported as timeout',
      );
    });

    test('a pending row whose package never installs still ends in timeout', () {
      backend.start = InstallStart(
        record: _record(),
        request: _request(method: 'platform', apkPath: apk.path),
      );
      InstallManager.appInstallerForTest = (_) async {};
      // 包始终未安装：校验返回 null，超时兜底必须生效。
      InstallManager.installedVersionCheckForTest = (_) async => null;
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
      });

      expect(
        backend.reports.where((r) => r.status == 'timeout'),
        hasLength(1),
        reason: 'an unconfirmed pending row must still time out',
      );
      expect(
        backend.reports.where((r) => r.status == 'installed'),
        isEmpty,
      );
    });

    test(
        'the blocked-broadcast scenario does not leave the row stuck: the '
        'resume re-check confirms the install', () async {
      backend.start = InstallStart(
        record: _record(),
        request: _request(method: 'platform', apkPath: apk.path),
      );
      InstallManager.appInstallerForTest = (_) async {};
      // 长 deadline / 长间隔：本测试不推进时间，证明「回到前台」本身就能确认，
      // 不依赖前台恰好在安装完成的那一刻。
      InstallManager.installPollInterval = const Duration(seconds: 30);
      InstallManager.installPendingDeadline = const Duration(seconds: 60);
      InstallManager.installPollTimeout = const Duration(seconds: 120);
      var installed = false;
      InstallManager.installedVersionCheckForTest = (_) async =>
          installed ? '1.2.3' : null;
      final manager = InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);

      final launched = await manager.installTask('task-1', apk.path);

      // 启动安装器 Intent 不是完成：绝不谎报 installed。
      expect(launched.$1, InstallOutcome.launched);
      expect(backend.reports, isEmpty,
          reason: 'launching the installer must not report a terminal status');

      // 用户在后台完成安装；广播被系统拦截（无 install_events 事件）。
      installed = true;
      // 应用回到前台 → 校验桥调用 recheckPendingInstalls。
      await manager.recheckPendingInstalls();

      expect(
        backend.reports.where((r) => r.status == 'installed'),
        hasLength(1),
        reason: 'the resume re-check must confirm the backgrounded install',
      );
      expect(
        backend.reports.where((r) => r.status == 'timeout'),
        isEmpty,
      );
    });

    test('a package installed at a DIFFERENT version is not falsely confirmed',
        () async {
      backend.start = InstallStart(
        record: _record(),
        request: _request(method: 'platform', apkPath: apk.path),
      );
      InstallManager.appInstallerForTest = (_) async {};
      // 目标包存在但版本与期望不符（例如旧版本仍在）→ 不得误判为本次安装成功。
      InstallManager.installedVersionCheckForTest = (_) async => '9.9.9';
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
      });

      expect(backend.reports.where((r) => r.status == 'installed'), isEmpty);
      expect(backend.reports.where((r) => r.status == 'timeout'), hasLength(1));
    });

    test('a core-settled failed row is never overridden by the platform check',
        () {
      // 核心已由 install_events 落定 failed（前台收到终端广播），但设备上恰有
      // 期望版本的包：不得以平台校验把 failed 覆盖成 installed。
      backend.start = InstallStart(
        record: _record(),
        request: _request(method: 'platform', apkPath: apk.path),
      );
      InstallManager.appInstallerForTest = (_) async {};
      InstallManager.installedVersionCheckForTest = (_) async => '1.2.3';
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        // 轮询期间核心落定 failed。
        backend.start = InstallStart(record: _record(status: 'failed'));
        async.elapse(const Duration(milliseconds: 40));
        async.flushMicrotasks();
      });

      expect(
        backend.reports.where((r) => r.status == 'installed'),
        isEmpty,
        reason: 'a core-settled terminal row must not be overridden',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // pre/post 快照确认（on-device 假阴性修复）：核心 `version` 对 GitHub release
  // 来源的下载是 **release tag**（`Release v3.5.0-20261024.1`），安装包的
  // `version_name` 是 APK 自身版本名（`3.4.0`）。二者字符串本就不同，旧实现用
  // 相等比较永远匹配不上 → 一次成功安装被误报为 timeout。改为安装前后快照差分：
  // 包由「不存在」变「存在」，或已存在但 version_name / version_code 变化 → 确认。
  // ───────────────────────────────────────────────────────────────────────────
  group('install confirmation by pre/post snapshot diff', () {
    InstallManager managerWithDeadline({
      Duration interval = const Duration(milliseconds: 10),
      Duration deadline = const Duration(milliseconds: 100),
    }) {
      InstallManager.installPollInterval = interval;
      InstallManager.installPendingDeadline = deadline;
      InstallManager.installPollTimeout = const Duration(seconds: 5);
      return InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);
    }

    InstallStart platformStart({String versionName = '1.2.3'}) => InstallStart(
          record: _record(),
          request: _request(
            method: 'platform',
            apkPath: apk.path,
            versionName: versionName,
          ),
        );

    test(
        '(a) target package ABSENT before and PRESENT after is confirmed '
        '(the version string does NOT match)', () {
      backend.start = platformStart();
      InstallManager.appInstallerForTest = (_) async {};
      // 安装前包不存在；安装器确认后包出现，版本名与核心 version 不同。
      InstalledSnapshot? current;
      InstallManager.installedSnapshotCheckForTest = (_) async => current;
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        current = const InstalledSnapshot(versionName: '2.0.0', versionCode: 20);
        async.elapse(const Duration(milliseconds: 40));
        async.flushMicrotasks();
      });

      expect(
        backend.reports.where((r) => r.status == 'installed'),
        hasLength(1),
        reason: 'absent→present must confirm, not time out',
      );
      expect(backend.reports.where((r) => r.status == 'timeout'), isEmpty);
    });

    test('(b) package PRESENT at v1 and now v2 is confirmed', () {
      backend.start = platformStart();
      InstallManager.appInstallerForTest = (_) async {};
      var current =
          const InstalledSnapshot(versionName: '1.0.0', versionCode: 10);
      InstallManager.installedSnapshotCheckForTest = (_) async => current;
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        current = const InstalledSnapshot(versionName: '2.0.0', versionCode: 20);
        async.elapse(const Duration(milliseconds: 40));
        async.flushMicrotasks();
      });

      expect(backend.reports.where((r) => r.status == 'installed'), hasLength(1));
      expect(backend.reports.where((r) => r.status == 'timeout'), isEmpty);
    });

    test(
        '(b2) a version_code-only change (same version_name) is confirmed',
        () {
      backend.start = platformStart();
      InstallManager.appInstallerForTest = (_) async {};
      var current =
          const InstalledSnapshot(versionName: '1.0.0', versionCode: 10);
      InstallManager.installedSnapshotCheckForTest = (_) async => current;
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        // 版本名不变，仅版本号前进 → 仍视为已安装落地。
        current = const InstalledSnapshot(versionName: '1.0.0', versionCode: 11);
        async.elapse(const Duration(milliseconds: 40));
        async.flushMicrotasks();
      });

      expect(backend.reports.where((r) => r.status == 'installed'), hasLength(1));
      expect(backend.reports.where((r) => r.status == 'timeout'), isEmpty);
    });

    test('(c) an unchanged snapshot is NOT confirmed and still times out', () {
      backend.start = platformStart();
      InstallManager.appInstallerForTest = (_) async {};
      InstallManager.installedSnapshotCheckForTest =
          (_) async => const InstalledSnapshot(versionName: '1.0.0', versionCode: 10);
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
      });

      expect(backend.reports.where((r) => r.status == 'installed'), isEmpty);
      expect(
        backend.reports.where((r) => r.status == 'timeout'),
        hasLength(1),
        reason: 'an unchanged package must not be falsely confirmed',
      );
    });

    test(
        '(d) the on-device shape: core version is a release tag while the '
        'installed version_name is a plain version → confirmed by the diff', () {
      // 真实设备日志：expected=Release v3.5.0-20261024.1 actual=3.4.0 → 旧实现
      // 报 timeout；安装后 version_name 变为 3.5.0，差分必须确认。
      backend.start =
          platformStart(versionName: 'Release v3.5.0-20261024.1');
      InstallManager.appInstallerForTest = (_) async {};
      var current =
          const InstalledSnapshot(versionName: '3.4.0', versionCode: 34);
      InstallManager.installedSnapshotCheckForTest = (_) async => current;
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        current = const InstalledSnapshot(versionName: '3.5.0', versionCode: 35);
        async.elapse(const Duration(milliseconds: 40));
        async.flushMicrotasks();
      });

      expect(
        backend.reports.where((r) => r.status == 'installed'),
        hasLength(1),
        reason: 'the exact on-device tag-vs-versionName case must confirm',
      );
      expect(backend.reports.where((r) => r.status == 'timeout'), isEmpty);
      expect(backend.reports.single.installedVersion, '3.5.0');
    });

    test(
        'a failed pre-snapshot falls back conservatively: presence with a '
        'different version is unconfirmed → timeout', () {
      backend.start =
          platformStart(versionName: 'Release v3.5.0-20261024.1');
      InstallManager.appInstallerForTest = (_) async {};
      // 安装前快照读取失败（平台错误）；确认阶段包已存在但版本名不同。
      var throwOnRead = true;
      InstallManager.installedSnapshotCheckForTest = (_) async {
        if (throwOnRead) {
          throw StateError('platform channel unavailable');
        }
        return const InstalledSnapshot(versionName: '3.5.0', versionCode: 35);
      };
      final manager = managerWithDeadline();

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        throwOnRead = false;
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
      });

      expect(
        backend.reports.where((r) => r.status == 'installed'),
        isEmpty,
        reason: 'without a pre-snapshot the conservative rule must not confirm',
      );
      expect(backend.reports.where((r) => r.status == 'timeout'), hasLength(1));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // 校验日志节流 + pending 轮询终止（on-device 日志刷屏修复）：平台校验在每个
  // 轮询 tick 都跑（生产间隔 ~500ms、deadline 90s），快照未变化时旧实现每 tick
  // 都 `debugPrint`，一次陈旧的 pending 安装会刷屏整个窗口。改为按
  // (moduleTaskId, reason) 只记一次；deadline 仍必须终止轮询并上报 timeout，
  // 且不因回前台 / 重启而重新武装。
  // ───────────────────────────────────────────────────────────────────────────
  group('verify-log throttle and pending-poller termination', () {
    InstallManager managerWithDeadline({
      Duration interval = const Duration(milliseconds: 10),
      Duration deadline = const Duration(milliseconds: 100),
    }) {
      InstallManager.installPollInterval = interval;
      InstallManager.installPendingDeadline = deadline;
      InstallManager.installPollTimeout = const Duration(seconds: 5);
      return InstallManager.instance
        ..setShizukuStateForTest(binder: true, permission: true)
        ..setIsAndroidForTest(true);
    }

    InstallStart platformStart({String versionName = '1.2.3'}) => InstallStart(
          record: _record(),
          request: _request(
            method: 'platform',
            apkPath: apk.path,
            versionName: versionName,
          ),
        );

    // 目标包始终停在安装前的快照：既非精确版本名命中，也无 pre/post 差分。
    const unchangedSnapshot =
        InstalledSnapshot(versionName: '1.0.0', versionCode: 10);

    test(
        '(a) N poll ticks with an unchanged snapshot produce exactly ONE log '
        'line, not N', () {
      final logs = _captureDebugPrint();
      backend.start = platformStart();
      InstallManager.appInstallerForTest = (_) async {};
      InstallManager.installedSnapshotCheckForTest =
          (_) async => unchangedSnapshot;
      final manager = managerWithDeadline(
        interval: const Duration(milliseconds: 10),
        deadline: const Duration(milliseconds: 100),
      );

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        // 覆盖整个 deadline 窗口（10ms × 10 ticks）并越过 deadline。
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
      });

      final unchangedLogs =
          logs.where((line) => line.contains('包已安装但快照未变化')).toList();
      expect(
        unchangedLogs,
        hasLength(1),
        reason: 'a stale pending row must log the unchanged snapshot once, '
            'not once per poll tick (production: ~2/s for the whole 90s window)',
      );
      expect(unchangedLogs.single, contains('expected=1.2.3'));
      expect(unchangedLogs.single, contains('installed=1.0.0'));
      expect(unchangedLogs.single, contains('code=10'));
    });

    test('(b) the poller stops at the deadline and reports timeout exactly once',
        () {
      backend.start = platformStart();
      InstallManager.appInstallerForTest = (_) async {};
      InstallManager.installedSnapshotCheckForTest =
          (_) async => unchangedSnapshot;
      final manager = managerWithDeadline(
        interval: const Duration(milliseconds: 10),
        deadline: const Duration(milliseconds: 100),
      );

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();

        final getsAtDeadline =
            backend.calls.where((call) => call.startsWith('get:')).length;
        // 继续推进远超 deadline 的时间：定时器必须已取消，不得再轮询。
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(
          backend.calls.where((call) => call.startsWith('get:')).length,
          getsAtDeadline,
          reason: 'the deadline must cancel the poller for good',
        );
      });

      expect(
        backend.reports.where((r) => r.status == 'timeout'),
        hasLength(1),
        reason: 'a pending row with no change must report timeout exactly once',
      );
      expect(
        backend.reports.where((r) => r.status == 'installed'),
        isEmpty,
        reason: 'a timeout must never be reported as installed',
      );
    });

    test('(c) a timed-out stale row never re-arms on resume or app restart',
        () async {
      backend.start = platformStart();
      InstallManager.appInstallerForTest = (_) async {};
      InstallManager.installedSnapshotCheckForTest =
          (_) async => unchangedSnapshot;
      final manager = managerWithDeadline(
        interval: const Duration(milliseconds: 10),
        deadline: const Duration(milliseconds: 100),
      );

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 300));
        async.flushMicrotasks();
      });

      expect(backend.reports.where((r) => r.status == 'timeout'), hasLength(1));
      final callsAfterDeadline = backend.calls.length;

      // 同一实例上的多次「回前台」：行已不再被跟踪 → 纯 no-op。
      await manager.recheckPendingInstalls();
      await manager.recheckPendingInstalls();
      expect(
        backend.reports.where((r) => r.status == 'timeout'),
        hasLength(1),
        reason: 'a resume after the deadline must not re-report or re-arm',
      );
      expect(
        backend.calls.length,
        callsAfterDeadline,
        reason: 'the row is no longer tracked, so a resume is a pure no-op',
      );

      // 模拟一次全新的 App 启动：新实例，校验桥在任何安装点击之前触发。
      InstallManager.resetForTest();
      InstallManager.installFacadeForTest = InstallFacade(backend: backend);
      InstallManager.installedSnapshotCheckForTest =
          (_) async => unchangedSnapshot;
      final fresh = InstallManager.instance..setIsAndroidForTest(true);
      final callsBeforeRestart = backend.calls.length;
      for (var i = 0; i < 3; i++) {
        await fresh.recheckPendingInstalls();
      }
      expect(
        backend.reports.where((r) => r.status == 'timeout'),
        hasLength(1),
        reason:
            'a stale pending row must not re-arm a poller across app starts',
      );
      expect(
        backend.calls.length,
        callsBeforeRestart,
        reason: 'a fresh instance tracks nothing, so resumes are pure no-ops',
      );
    });

    test(
        '(d) a genuine snapshot change still confirms immediately '
        '(no regression of acacccea)', () {
      final logs = _captureDebugPrint();
      backend.start = platformStart();
      InstallManager.appInstallerForTest = (_) async {};
      var current = unchangedSnapshot;
      InstallManager.installedSnapshotCheckForTest = (_) async => current;
      final manager = managerWithDeadline(
        interval: const Duration(milliseconds: 10),
        deadline: const Duration(milliseconds: 500),
      );

      fakeAsync((async) {
        manager.installTask('task-1', apk.path);
        async.flushMicrotasks();
        // 安装落地：版本前进 → 差分必须确认，且不得再轮询到 deadline。
        current = const InstalledSnapshot(versionName: '2.0.0', versionCode: 20);
        async.elapse(const Duration(milliseconds: 30));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 700));
        async.flushMicrotasks();
      });

      expect(
        backend.reports.where((r) => r.status == 'installed'),
        hasLength(1),
        reason: 'a real pre/post change must still confirm immediately',
      );
      expect(backend.reports.where((r) => r.status == 'timeout'), isEmpty);
      expect(
        logs.where((line) => line.contains('包已安装但快照未变化')),
        isEmpty,
        reason: 'a genuine change must not log the unchanged message',
      );
    });
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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/module/app_modules.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module.dart';
import 'package:gstore/core/platform/platform_channel.dart';
import 'package:gstore/core/service/install_manager.dart';
import 'package:gstore/core/service/install_resume_bridge.dart';

/// `gstore/install_events` 的 Dart 侧契约测试。
///
/// Kotlin 侧终端状态只有四种（Decision 12：installed / failed / denied / timeout），
/// `ok` 由枚举出的 `status` 派生：只有 `installed` 为真。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = EventChannel(installEventsChannelName);

  MockStreamHandlerEventSink? sink;
  var cancelled = false;
  var listenCount = 0;

  void installStreamHandler(MockStreamHandler? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(channel, handler);
  }

  void useSink({bool trackCancel = false}) {
    sink = null;
    cancelled = false;
    listenCount = 0;
    installStreamHandler(
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink eventsSink) {
          listenCount++;
          sink = eventsSink;
        },
        onCancel: (Object? arguments) {
          if (trackCancel) cancelled = true;
          sink = null;
        },
      ),
    );
  }

  tearDown(() => installStreamHandler(null));

  Map<String, Object?> payload({
    String sessionId = 'task:1:1:1',
    String? packageName = 'com.example.app',
    String status = 'installed',
    String method = 'shizuku',
    String? installedVersion = '1.2.3',
    String? error,
  }) =>
      <String, Object?>{
        'sessionId': sessionId,
        'packageName': packageName,
        'ok': status == 'installed',
        'status': status,
        'method': method,
        'installedVersion': installedVersion,
        'error': error,
      };

  /// 订阅 `gstore/install_events`，推送 [events]，收齐后取消订阅。
  Future<List<InstallEvent>> collect(List<Map<String, Object?>> events) async {
    final received = <InstallEvent>[];
    final done = Completer<void>();
    final sub = channel.receiveBroadcastStream().listen((Object? event) {
      received.add(InstallEvent.fromMap(event! as Map<Object?, Object?>));
      if (received.length == events.length && !done.isCompleted) {
        done.complete();
      }
    });
    // 让 onListen 先到达（mock handler 在事件循环的下一轮被调用）。
    await Future<void>.delayed(Duration.zero);
    expect(sink, isNotNull, reason: 'onListen 必须已经触发');
    for (final event in events) {
      sink!.success(event);
    }
    await done.future.timeout(const Duration(seconds: 5));
    unawaited(sub.cancel());
    await Future<void>.delayed(Duration.zero);
    return received;
  }

  test('installed → ok=true 且字段完整', () async {
    useSink();

    final received = await collect(<Map<String, Object?>>[
      payload(status: 'installed', installedVersion: '1.2.3'),
    ]);

    expect(received, hasLength(1));
    final event = received.single;
    expect(event.status, 'installed');
    expect(event.ok, isTrue);
    expect(event.sessionId, 'task:1:1:1');
    expect(event.packageName, 'com.example.app');
    expect(event.method, 'shizuku');
    expect(event.installedVersion, '1.2.3');
    expect(event.error, isNull);
  });

  for (final status in <String>['denied', 'failed', 'timeout']) {
    test('$status → ok=false（枚举状态而非布尔）', () async {
      useSink();

      final received = await collect(<Map<String, Object?>>[
        payload(status: status, installedVersion: null, error: 'CORE_E_INSTALL'),
      ]);

      expect(received.single.status, status);
      expect(received.single.ok, isFalse);
      expect(received.single.error, 'CORE_E_INSTALL');
    });
  }

  test('重复/迟到终端事件不抛异常', () async {
    useSink(trackCancel: true);

    final received = await collect(<Map<String, Object?>>[
      payload(status: 'installed'),
      payload(status: 'installed'),
    ]);

    expect(received, hasLength(2));
    expect(received.every((e) => e.ok), isTrue);
    // 取消订阅后 Kotlin 侧 StreamHandler.onCancel 必须被触发（sink 清空）。
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
  });

  test('未知状态不因缺少枚举分支而崩溃', () async {
    useSink();

    final received = await collect(<Map<String, Object?>>[
      payload(status: 'pending'),
    ]);

    expect(received.single.status, 'pending');
    expect(received.single.ok, isFalse);
  });

  group('fromMap 契约', () {
    test('wire 上的 ok 与 status 冲突时以 status 为准', () {
      final event = InstallEvent.fromMap(<Object?, Object?>{
        'sessionId': 's',
        'packageName': null,
        'ok': true,
        'status': 'denied',
        'method': 'package_installer',
        'installedVersion': null,
        'error': null,
      });

      expect(event.ok, isFalse);
    });

    test('缺失键不抛异常，sessionId 缺省为空串', () {
      final event = InstallEvent.fromMap(<Object?, Object?>{});

      expect(event.sessionId, '');
      expect(event.status, '');
      expect(event.ok, isFalse);
      expect(event.packageName, isNull);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // 生产订阅（Plan-Todo 4 / 6A-A4）：InstallManager.startEventBridge()
  // 全仓唯一的 `gstore/install_events` 订阅者。
  // ───────────────────────────────────────────────────────────────────────
  group('InstallManager 生产订阅', () {
    late _FakeInstallBackend backend;

    setUp(() {
      InstallManager.resetForTest();
      InstallFacade.resetForTest();
      backend = _FakeInstallBackend();
      InstallFacade.installBackendForTest(backend);
      // 通道只在 Android 注册；Linux 测试用注入让它按生产路径订阅。
      InstallManager.instance.setIsAndroidForTest(true);
    });

    tearDown(() async {
      await InstallManager.instance.stopEventBridge();
      InstallManager.resetForTest();
      InstallFacade.resetForTest();
    });

    Future<void> startBridge() async {
      InstallManager.instance.startEventBridge();
      await pumpEventQueue();
      expect(sink, isNotNull, reason: 'startEventBridge 必须真正监听通道');
    }

    Future<void> emit(Object? event) async {
      sink!.success(event);
      await pumpEventQueue();
    }

    test('install_events_ignores_empty_session', () async {
      useSink();
      await startBridge();

      await emit(payload(sessionId: ''));
      await emit(payload(sessionId: '', status: 'failed', error: 'x'));

      expect(backend.reports, isEmpty,
          reason: '空 sessionId 事件必须被忽略，不得上报核心');
      expect(backend.acks, isEmpty);
    });

    test('install_events_maps_all_four_statuses', () async {
      useSink();
      await startBridge();

      const statuses = <String>['installed', 'failed', 'denied', 'timeout'];
      for (var i = 0; i < statuses.length; i++) {
        await emit(payload(
          sessionId: 'session:$i',
          status: statuses[i],
          installedVersion: statuses[i] == 'installed' ? '1.2.3' : null,
          error: statuses[i] == 'installed' ? null : 'CORE_E_$i',
        ));
      }

      expect(backend.reports.map((r) => r.status).toList(), statuses);
      final installed = backend.reports.first;
      expect(installed.sessionId, 'session:0');
      expect(installed.method, 'shizuku');
      expect(installed.installedVersion, '1.2.3');
      expect(installed.error, isNull);
      expect(backend.reports[1].error, 'CORE_E_1');
      expect(backend.reports.every((r) => r.reportedAt > 0), isTrue);
    });

    test('install_events_duplicate_is_noop', () async {
      useSink();
      await startBridge();

      final event = payload(sessionId: 'dup-session');
      await emit(event);
      await emit(event);

      // 生产侧不做客户端去重（不加 LRU/缓存）：两条都转发给核心，
      // 由核心对已终态 session 返回 changed:false 完成幂等。
      expect(backend.reports, hasLength(2),
          reason: '不得在客户端缓存/丢弃重复事件');
      expect(backend.reports.map((r) => r.sessionId),
          <String>['dup-session', 'dup-session']);
      expect(backend.acks, <bool>[true, false],
          reason: '去重只依赖核心的 changed:false');
    });

    test('install_events_start_is_idempotent', () async {
      useSink(trackCancel: true);
      await startBridge();

      final first = InstallManager.instance.installEventsSubscriptionForTest;
      expect(first, isNotNull);

      InstallManager.instance.startEventBridge();
      InstallManager.instance.startEventBridge();
      await pumpEventQueue();

      expect(listenCount, 1, reason: 'start × 3 只能产生一个订阅');
      expect(
        identical(
          InstallManager.instance.installEventsSubscriptionForTest,
          first,
        ),
        isTrue,
        reason: '重复 start 必须保持同一订阅对象',
      );

      await InstallManager.instance.stopEventBridge();
      await pumpEventQueue();
      expect(cancelled, isTrue);
      expect(
        InstallManager.instance.installEventsSubscriptionForTest,
        isNull,
      );
    });

    test('install_events_stop_mid_stream_then_restart_resubscribes_once',
        () async {
      useSink(trackCancel: true);
      await startBridge();

      await emit(payload(sessionId: 'before-stop'));
      expect(backend.reports, hasLength(1));
      final staleSink = sink!;

      await InstallManager.instance.stopEventBridge();
      await pumpEventQueue();
      expect(cancelled, isTrue);

      // 取消后旧 sink 再推事件也不能产生上报。
      try {
        staleSink.success(payload(sessionId: 'after-stop'));
      } catch (_) {
        // 取消后 sink 失效属预期；重点是不得产生上报。
      }
      await pumpEventQueue();
      expect(backend.reports, hasLength(1),
          reason: 'stopEventBridge 之后不得再投递任何报告');

      // 重启只重新订阅一次，并恢复正常投递。
      await startBridge();
      expect(listenCount, 2, reason: 'restart 只新增一个订阅');
      await emit(payload(sessionId: 'after-restart'));
      expect(backend.reports.map((r) => r.sessionId).toList(),
          <String>['before-stop', 'after-restart']);
    });

    test('install_events_probe_streamcontroller_pause_resume', () async {
      // 长跑/可恢复流程探针：StreamController 显式驱动，无真实通道参与。
      final firstController = StreamController<Object?>();
      addTearDown(firstController.close);
      InstallManager.installEventsStreamForTest = firstController.stream;

      InstallManager.instance.startEventBridge();
      await pumpEventQueue();
      expect(InstallManager.instance.installEventsSubscriptionForTest, isNotNull);

      firstController.add(payload(sessionId: 'sc-1'));
      await pumpEventQueue();
      expect(backend.reports.single.sessionId, 'sc-1');

      // 中断：取消订阅后旧控制器再推事件不得上报。
      await InstallManager.instance.stopEventBridge();
      await pumpEventQueue();
      firstController.add(payload(sessionId: 'sc-stale'));
      await pumpEventQueue();
      expect(backend.reports, hasLength(1),
          reason: '中断后旧流不得继续投递');

      // 恢复：换一条流重新订阅，只新增一个订阅并恢复投递。
      final secondController = StreamController<Object?>();
      addTearDown(secondController.close);
      InstallManager.installEventsStreamForTest = secondController.stream;
      InstallManager.instance.startEventBridge();
      InstallManager.instance.startEventBridge();
      await pumpEventQueue();
      secondController.add(payload(sessionId: 'sc-2'));
      await pumpEventQueue();
      expect(backend.reports.map((r) => r.sessionId).toList(),
          <String>['sc-1', 'sc-2']);
    });

    test('install_events_swallows_malformed_unknown_and_core_errors', () async {
      final logs = _captureDebugPrint();
      useSink();
      await startBridge();

      // 非 Map 载荷。
      await emit('not-a-map');
      // 未知状态。
      await emit(payload(sessionId: 'unknown', status: 'pending'));
      // 核心错误（例如 session 不存在）。
      backend.error = Exception('CORE_E_INSTALL_SESSION: missing');
      await emit(payload(sessionId: 'core-error'));
      expect(backend.reports, isEmpty);

      // 流必须仍然活着：清掉错误后继续正常上报。
      backend.error = null;
      await emit(payload(sessionId: 'still-alive'));
      expect(backend.reports.single.sessionId, 'still-alive');

      expect(logs.any((line) => line.contains('CORE_E_INSTALL_SESSION')), isTrue,
          reason: '核心错误必须记录');
      expect(logs.any((line) => line.contains('pending')), isTrue,
          reason: '未知状态必须记录');
    });

    test('InstallModule.onRegister 启动、onUnregister 取消', () async {
      useSink(trackCancel: true);
      final module = InstallModule();
      await module.onRegister(ModuleContext());
      await pumpEventQueue();

      expect(listenCount, 1, reason: 'onRegister 必须立即启动订阅');
      await emit(payload(sessionId: 'on-register'));
      expect(backend.reports.single.sessionId, 'on-register');

      await module.onUnregister(ModuleContext());
      await pumpEventQueue();
      expect(cancelled, isTrue, reason: 'onUnregister 必须取消订阅');
      expect(
        InstallManager.instance.installEventsSubscriptionForTest,
        isNull,
      );
    });

    // Post-cutover (Plan-Todo 4): `download` + `install` default to the core,
    // so a completed installAfterDownload task must go straight to
    // `installTask` — there is no `installApk` fallback — while the
    // `gstore/install_events` subscriber stays a single, cancellable
    // subscription.
    test('cutover completion uses installTask and keeps one subscriber',
        () async {
      useSink(trackCancel: true);
      final module = InstallModule();
      await module.onRegister(ModuleContext());
      await pumpEventQueue();
      expect(listenCount, 1,
          reason: 'onRegister establishes exactly one install_events subscriber');

      final manager = _RecordingInstallManager();
      ModuleManager.instance.bind<InstallManager>(manager);
      addTearDown(() => ModuleManager.instance.unbind<InstallManager>());

      final download = _FakeDownloadService();
      final watcher = DownloadTaskWatcher.debug()..start(download);
      addTearDown(watcher.dispose);

      download.controller.add(_completedInstallTask(11));
      await pumpEventQueue();

      expect(manager.installTaskCalls, 1);
      expect(manager.lastModuleTaskId, '11');
      expect(manager.consumeCalls, 1);
      expect(manager.installApkCalls, 0,
          reason: 'the cutover default must never route through installApk');
      expect(listenCount, 1,
          reason: 'a download completion must not re-subscribe install_events');

      await module.onUnregister(ModuleContext());
      await pumpEventQueue();
      expect(cancelled, isTrue, reason: 'onUnregister must cancel install_events');
      expect(
        InstallManager.instance.installEventsSubscriptionForTest,
        isNull,
      );
    });
  });

  // 回前台校验桥：安装器前台期间隐式广播被 Android 拦截，用户从安装器返回
  // （resumed）时是确认后台完成安装的关键时机。
  group('InstallResumeBridge', () {
    test('resumed triggers the handler once; dispose stops it', () async {
      var calls = 0;
      final bridge = InstallResumeBridge(onResumed: () async => calls++);
      addTearDown(bridge.dispose);
      bridge.start();
      bridge.start(); // 幂等：重复 start 不重复注册

      bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(calls, 1);

      bridge.didChangeAppLifecycleState(AppLifecycleState.paused);
      bridge.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await pumpEventQueue();
      expect(calls, 1, reason: 'only resumed triggers the check');

      bridge.dispose();
      bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(calls, 1, reason: 'a disposed bridge must not fire');
    });

    test('a throwing handler is swallowed', () async {
      final bridge = InstallResumeBridge(
        onResumed: () async => throw StateError('boom'),
      );
      addTearDown(bridge.dispose);
      bridge.start();

      bridge.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      // 未抛出即通过：桥必须吞掉异常，绝不从生命周期回调冒泡。
    });
  });
}

DownloadTask _completedInstallTask(int id) => DownloadTask(
      id: id,
      appId: 'com.example.app',
      appName: 'Example',
      version: '1.2.3',
      fileName: 'example.apk',
      url: 'https://example.test/example.apk',
      filePath: '/tmp/example.apk',
      total: 100,
      received: 100,
      status: DownloadStatusEnum.completed,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      installAfterDownload: true,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1),
    );

/// Core-cutover install seam for the watcher: records which install entry
/// point it used. `installApk` must stay at zero after the flip.
class _RecordingInstallManager implements InstallManager {
  int installTaskCalls = 0;
  int installApkCalls = 0;
  int consumeCalls = 0;
  String? lastModuleTaskId;

  @override
  Future<(InstallOutcome, InstallMethod)> installTask(
    String moduleTaskId,
    String filePath,
  ) async {
    installTaskCalls++;
    lastModuleTaskId = moduleTaskId;
    return (InstallOutcome.installed, InstallMethod.shizuku);
  }

  @override
  Future<(InstallOutcome, InstallMethod)> installApk(
    String filePath, {
    bool moduleInstall = false,
  }) async {
    installApkCalls++;
    return (InstallOutcome.launched, InstallMethod.system);
  }

  @override
  Future<int> consumeInstallRequests() async {
    consumeCalls++;
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

class _FakeDownloadService implements IDownloadService {
  final StreamController<DownloadTask> controller =
      StreamController<DownloadTask>.broadcast();

  @override
  Stream<DownloadTask> watchAll() => controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 记录上报与核心幂等应答的假件；`changed` 模拟核心的第一次 true、之后 false。
class _FakeInstallBackend implements InstallBackend {
  final List<InstallReport> reports = <InstallReport>[];
  final List<bool> acks = <bool>[];
  Object? error;

  @override
  Future<InstallResultAck> reportResult(InstallReport report) async {
    final failure = error;
    if (failure != null) throw failure;
    final changed = reports.isEmpty;
    reports.add(report);
    acks.add(changed);
    return InstallResultAck(
      sessionId: report.sessionId,
      status: report.status,
      changed: changed,
    );
  }

  @override
  Future<InstallStart> install(String moduleTaskId) =>
      throw UnimplementedError();

  @override
  Future<List<InstallStart>> pendingRequests() =>
      throw UnimplementedError();

  @override
  Future<List<String>> takeEvents() => throw UnimplementedError();

  @override
  Future<InstallRecord?> get(String moduleTaskId) =>
      throw UnimplementedError();

  @override
  Future<void> uninstall(String packageName) => throw UnimplementedError();

  @override
  Future<void> launch(String packageName) => throw UnimplementedError();
}

/// 捕获 `debugPrint`（生产禁止 `log()`），用于断言错误已被记录且未抛出。
List<String> _captureDebugPrint() {
  final logs = <String>[];
  final original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    logs.add(message ?? '');
    original(message, wrapWidth: wrapWidth);
  };
  addTearDown(() => debugPrint = original);
  return logs;
}

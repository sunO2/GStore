import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/service/install_manager.dart';

/// 更新页安装（`installTask`）与下载管理安装（`installApk`）的前置条件对齐回归。
///
/// BUG：下载模块推送 `download.done` 后，核心 `download_task.status` 可能仍是
/// `running`（唯一写入者是 `DownloadFacade.list()` 触发的 reconcile）。下载管理
/// 的 `installApk` 会先 `list()` 对账，更新页的 `installTask` 却直接进核心安装，
/// 于是同一个 APK 从更新页安装会报 `CORE_E_INSTALL_NOT_DOWNLOADED`
/// （用户看到「下载完成，但安装失败」）。
///
/// 这里用两个假件共享一条 `events` 时间线，断言「先对账、后安装」以及有界重试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> events;

  setUp(() {
    InstallManager.resetForTest();
    InstallFacade.resetForTest();
    DownloadFacade.backendOverride = null;
    events = <String>[];
  });

  tearDown(() {
    InstallManager.resetForTest();
    InstallFacade.resetForTest();
    DownloadFacade.backendOverride = null;
  });

  /// 安装一个假下载后端：只把 `list()` 记入共享时间线（reconcile 的唯一入口）。
  ///
  /// [listError] 非空时 `list()` 抛出，用于验证对账失败不阻塞安装。
  void useDownloadBackend({Object? listError}) {
    DownloadFacade.backendOverride =
        _FakeDownloadBackend(events, listError: listError);
  }

  InstallManager useInstallBackend(InstallBackend backend) {
    InstallFacade.installBackendForTest(backend);
    return InstallManager.instance
      ..setShizukuStateForTest(binder: true, permission: true)
      ..setIsAndroidForTest(true);
  }

  /// 制造一个真实存在的 APK 文件：`_executeInstallRequest` 会检查扩展名与存在性。
  File makeApk() {
    final dir = Directory.systemTemp.createTempSync('gstore_reconcile_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    return File('${dir.path}/app.apk')..writeAsBytesSync(<int>[0x50, 0x4B]);
  }

  InstallRequest shizukuRequest(String moduleTaskId, String apkPath) =>
      InstallRequest(
        moduleTaskId: moduleTaskId,
        sessionId: 'session:$moduleTaskId',
        packageName: 'com.example.app',
        versionName: '1.2.3',
        apkPath: apkPath,
        method: 'shizuku',
        variant: const InstallVariant(abi: 'arm64-v8a', url: ''),
      );

  test('installTask 在核心 install 之前先做一次下载对账（list）', () async {
    useDownloadBackend();
    final install = _SequencedInstallBackend(events)..start = _settledInstalled;
    final manager = useInstallBackend(install);
    final apk = makeApk();

    final result = await manager.installTask('task-1', apk.path);

    expect(result, (InstallOutcome.alreadyInstalled, InstallMethod.shizuku));
    expect(events, containsAllInOrder(<String>['list', 'install:task-1']),
        reason: '对账（list）必须发生在核心 install 之前');
    expect(events.where((e) => e == 'install:task-1'), hasLength(1));
    expect(events.where((e) => e == 'list'), hasLength(1),
        reason: '首次安装只需一次对账');
  });

  test('首次 CORE_E_INSTALL_NOT_DOWNLOADED → 再对账并重试一次，共 2 次 install', () async {
    useDownloadBackend();
    final apk = makeApk();
    final install = _SequencedInstallBackend(events)
      ..starts = <Object>[
        const InstallCoreException(
          'CORE_E_INSTALL_NOT_DOWNLOADED',
          'CORE_E_INSTALL_NOT_DOWNLOADED: task-1 is running',
        ),
        InstallStart(
          record: const InstallRecord(
            moduleTaskId: 'task-1',
            appId: 'com.example.app',
            status: 'pending',
            method: 'shizuku',
          ),
          request: shizukuRequest('task-1', apk.path),
        ),
      ];
    InstallManager.commandRunnerForTest = (_) async => 'Success';
    final manager = useInstallBackend(install);

    final result = await manager.installTask('task-1', apk.path);

    expect(result, (InstallOutcome.installed, InstallMethod.shizuku));
    expect(events.where((e) => e == 'install:task-1'), hasLength(2),
        reason: '恰好 2 次 install 尝试（首次失败 + 重试成功）');
    expect(events.where((e) => e == 'list'), hasLength(2),
        reason: '首次安装前 + 重试前各对账一次');
    expect(
      events,
      containsAllInOrder(<String>[
        'list',
        'install:task-1',
        'list',
        'install:task-1',
      ]),
    );
  });

  test('非 NOT_DOWNLOADED 的 InstallCoreException 不重试，直接上抛', () async {
    useDownloadBackend();
    final apk = makeApk();
    final install = _SequencedInstallBackend(events)
      ..starts = <Object>[
        const InstallCoreException(
          'CORE_E_INSTALL_APK_MISSING',
          'CORE_E_INSTALL_APK_MISSING: /tmp/gone.apk',
        ),
        // 若发生重试，会命中这一条并改成「成功」——断言重试没有发生。
        _settledInstalled,
      ];
    final manager = useInstallBackend(install);

    await expectLater(
      manager.installTask('task-1', apk.path),
      throwsA(isA<InstallCoreException>()
          .having((e) => e.code, 'code', 'CORE_E_INSTALL_APK_MISSING')),
    );
    expect(events.where((e) => e == 'install:task-1'), hasLength(1),
        reason: '只有 1 次 install 尝试，其它错误码保持既有 rethrow');
    expect(events.where((e) => e == 'list'), hasLength(1),
        reason: '重试前的第二次对账不得发生');
  });

  test('对账（list）失败不阻塞安装尝试', () async {
    useDownloadBackend(listError: Exception('reconcile boom'));
    final install = _SequencedInstallBackend(events)..start = _settledInstalled;
    final manager = useInstallBackend(install);
    final apk = makeApk();

    final result = await manager.installTask('task-1', apk.path);

    expect(result, (InstallOutcome.alreadyInstalled, InstallMethod.shizuku));
    expect(events.where((e) => e == 'list'), hasLength(1),
        reason: '对账被尝试过（尽管失败）');
    expect(events.where((e) => e == 'install:task-1'), hasLength(1),
        reason: '对账失败后核心 install 仍然执行');
  });
}

const InstallStart _settledInstalled = InstallStart(
  record: InstallRecord(
    moduleTaskId: 'task-1',
    appId: 'com.example.app',
    status: 'installed',
    method: 'shizuku',
  ),
);

/// 假下载后端：只关心 `list()`（reconcile 入口），其余能力不使用。
class _FakeDownloadBackend implements DownloadBackend {
  _FakeDownloadBackend(this.events, {this.listError});

  final List<String> events;
  final Object? listError;

  @override
  Future<List<rust.DownloadTaskDto>> list() async {
    events.add('list');
    final failure = listError;
    if (failure != null) throw failure;
    return const <rust.DownloadTaskDto>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 假安装后端：每次 `install()` 依次消费 [starts] 中的结果（异常即抛出）。
class _SequencedInstallBackend implements InstallBackend {
  _SequencedInstallBackend(this.events);

  final List<String> events;

  /// 单条结果（[starts] 为空时使用）。
  Object start = _settledInstalled;

  /// 依次消费的结果队列，元素为 [InstallStart] 或要抛出的异常。
  List<Object> starts = <Object>[];

  @override
  Future<InstallStart> install(String moduleTaskId) async {
    events.add('install:$moduleTaskId');
    final next = starts.isNotEmpty ? starts.removeAt(0) : start;
    if (next is InstallStart) return next;
    throw next;
  }

  @override
  Future<List<InstallStart>> pendingRequests() async => const <InstallStart>[];

  @override
  Future<InstallResultAck> reportResult(InstallReport report) async =>
      InstallResultAck(
        sessionId: report.sessionId,
        status: report.status,
        changed: true,
      );

  @override
  Future<List<String>> takeEvents() async => const <String>[];

  @override
  Future<InstallRecord?> get(String moduleTaskId) async => null;

  @override
  Future<void> uninstall(String packageName) async {}

  @override
  Future<void> launch(String packageName) async {}
}

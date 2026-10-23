import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/install/install_facade.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/service/install_manager.dart';
import 'package:gstore/core/service/legacy_write_guard.dart';
import 'package:shizuku_api/shizuku_api.dart';

/// 可配置结果的 ShizukuApi 假实现（shizuku_api 1.2.2 的 ShizukuApi 为非 final class，
/// runCommand/pingBinder/checkPermission 均可 override）
class _FakeShizukuApi extends ShizukuApi {
  /// 下次 runCommand 返回的结果
  String? runResult;

  /// 已执行的命令记录
  final List<String> commands = [];

  @override
  Future<String?> runCommand(String command) async {
    commands.add(command);
    return runResult;
  }

  @override
  Future<bool?> pingBinder() async => true;

  @override
  Future<bool?> checkPermission() async => true;

  @override
  Future<bool?> requestPermission() async => true;
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

Future<void> _setInstallFlags() async {
  CoreFlags.installBackend(
    _FakeFlagsBackend(const CoreFlagsSnapshot(download: true, install: true)),
  );
  await CoreFlags.refresh();
}

class _EmptyDownloadBackend implements DownloadBackend {
  final List<String> calls = <String>[];

  @override
  Future<int> start(rust.DownloadStartRequest request) async => 0;

  @override
  Future<List<rust.DownloadTaskDto>> list() async {
    calls.add('list');
    return const <rust.DownloadTaskDto>[];
  }

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

class _FakeInstallBackend implements InstallBackend {
  _FakeInstallBackend({this.installError});

  final Object? installError;
  final List<String> calls = <String>[];
  int getCalls = 0;

  @override
  Future<InstallStart> install(String moduleTaskId) async {
    calls.add('install:$moduleTaskId');
    final error = installError;
    if (error != null) throw error;
    return const InstallStart(
      record: InstallRecord(
        moduleTaskId: 'task-1',
        appId: 'com.example.app',
        status: 'installed',
        method: 'shizuku',
      ),
    );
  }

  @override
  Future<List<InstallStart>> pendingRequests() async {
    calls.add('pendingRequests');
    return const <InstallStart>[];
  }

  @override
  Future<InstallResultAck> reportResult(InstallReport report) async {
    calls.add('reportResult:${report.status}');
    return InstallResultAck(
      sessionId: report.sessionId,
      status: report.status,
      changed: true,
    );
  }

  @override
  Future<List<String>> takeEvents() async {
    calls.add('takeEvents');
    return const <String>[];
  }

  @override
  Future<InstallRecord?> get(String moduleTaskId) async {
    getCalls++;
    calls.add('get:$moduleTaskId');
    return null;
  }

  @override
  Future<void> uninstall(String packageName) async =>
      calls.add('uninstall:$packageName');

  @override
  Future<void> launch(String packageName) async =>
      calls.add('launch:$packageName');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isPmSuccess', () {
    test("'Success' → true", () {
      expect(isPmSuccess('Success'), isTrue);
    });

    test("'Success\\n' → true", () {
      expect(isPmSuccess('Success\n'), isTrue);
    });

    test("' Success '（含首尾空白）→ true", () {
      expect(isPmSuccess('  Success  '), isTrue);
    });

    test("'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]' → false", () {
      expect(
        isPmSuccess('Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]'),
        isFalse,
      );
    });

    test("''（空输出）→ false", () {
      expect(isPmSuccess(''), isFalse);
    });

    test('null（命令未执行）→ false', () {
      expect(isPmSuccess(null), isFalse);
    });
  });

  group('InstallManager', () {
    late _FakeShizukuApi fakeApi;
    late File tempApk;

    setUp(() {
      InstallManager.resetForTest();
      InstallFacade.resetForTest();
      DownloadFacade.backendOverride = _EmptyDownloadBackend();
      LegacyWriteGuard.resetForTest();
      fakeApi = _FakeShizukuApi();
      final manager = InstallManager.instance;
      manager.shizukuApiForTest = fakeApi;
      // 命令执行已迁移到 Rust 门面：测试注入假 runner（复用假件的 runCommand），
      // 使 runResult / commands 断言继续成立且不触达 Rust / 真机。
      InstallManager.commandRunnerForTest = fakeApi.runCommand;
      manager.setShizukuStateForTest(binder: true, permission: true);
      manager.setIsAndroidForTest(true);
      tempApk = File(
        '${Directory.systemTemp.path}/gstore_test_'
        '${DateTime.now().microsecondsSinceEpoch}.apk',
      );
      tempApk.writeAsBytesSync([0x50, 0x4B, 0x03, 0x04]);
    });

    tearDown(() {
      if (tempApk.existsSync()) tempApk.deleteSync();
      InstallManager.resetForTest();
      InstallFacade.resetForTest();
      DownloadFacade.backendOverride = null;
      LegacyWriteGuard.resetForTest();
      CoreFlags.resetBackend();
    });

    group('installApk', () {
      test('runCommand 返回 Failure [...] → 不误判成功，落入回退系统安装', () async {
        fakeApi.runResult = 'Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]';
        final result = await InstallManager.instance.installApk(tempApk.path);

        // 回归点：此前 result != null 判定会把 Failure 误判为 (true, shizuku)
        expect(result, isNot((true, InstallMethod.shizuku)));
        // 已落入回退系统安装路径（测试宿主非 Android，AppInstaller no-op 返回成功）
        expect(result.$2, InstallMethod.system);
      });

      test('runCommand 返回 Success → (true, shizuku)', () async {
        fakeApi.runResult = 'Success';
        final result = await InstallManager.instance.installApk(tempApk.path);

        expect(result, (true, InstallMethod.shizuku));
      });

      test('runCommand 返回 null → 落入回退系统安装，不误判成功', () async {
        fakeApi.runResult = null;
        final result = await InstallManager.instance.installApk(tempApk.path);

        expect(result, isNot((true, InstallMethod.shizuku)));
        expect(result.$2, InstallMethod.system);
      });

      test('非 Android 平台 → 提前返回 (false, preferredMethod)', () async {
        InstallManager.instance.setIsAndroidForTest(false);
        final result = await InstallManager.instance.installApk(tempApk.path);

        expect(result, (false, InstallMethod.system));
        expect(fakeApi.commands, isEmpty);
      });

      test('install_core_task_missing_row_is_typed', () async {
        await _setInstallFlags();
        final install = _FakeInstallBackend(
          installError: const InstallCoreException(
            'CORE_E_INSTALL_NOT_FOUND',
            'no mirrored row',
          ),
        );
        InstallManager.installFacadeForTest = InstallFacade(backend: install);
        final manager = InstallManager.instance
          ..setShizukuStateForTest(binder: true, permission: true)
          ..setIsAndroidForTest(true);

        await expectLater(
          manager.installTask('task-404', tempApk.path),
          throwsA(
            isA<InstallCoreException>().having(
              (InstallCoreException e) => e.code,
              'code',
              'CORE_E_INSTALL_NOT_FOUND',
            ),
          ),
        );
        expect(install.calls, <String>['pendingRequests', 'install:task-404']);
        expect(install.getCalls, 0,
            reason: 'a typed NOT_FOUND must not start an install poller');
        expect(fakeApi.commands, isEmpty);
      });

      test('install_direct_apk_creates_no_core_state', () async {
        await _setInstallFlags();
        final install = _FakeInstallBackend();
        InstallManager.installFacadeForTest = InstallFacade(backend: install);
        fakeApi.runResult = 'Success';
        final manager = InstallManager.instance
          ..setShizukuStateForTest(binder: true, permission: true)
          ..setIsAndroidForTest(true);

        final result = await manager.installApk(tempApk.path);

        expect(result, (true, InstallMethod.shizuku));
        expect(install.calls, isEmpty,
            reason: 'a direct APK install must create no core state');
        expect(fakeApi.commands, hasLength(1));
      });

      test('manual install still works while the install marker is armed',
          () async {
        await _setInstallFlags();
        final install = _FakeInstallBackend();
        InstallManager.installFacadeForTest = InstallFacade(backend: install);
        LegacyWriteGuard.probeOverride = (domain) async => domain == 'install';
        fakeApi.runResult = 'Success';
        final manager = InstallManager.instance
          ..setShizukuStateForTest(binder: true, permission: true)
          ..setIsAndroidForTest(true);

        final result = await manager.installApk(tempApk.path);

        expect(result, (true, InstallMethod.shizuku));
        expect(install.calls, isEmpty);
        expect(fakeApi.commands, hasLength(1));
      });
    });

    group('_runShizukuCommand 链路', () {
      test('managePackage(uninstall) always uses the core facade', () async {
        final install = _FakeInstallBackend();
        InstallManager.installFacadeForTest = InstallFacade(backend: install);
        final ok = await InstallManager.instance.managePackage(
          'com.example.app',
          'uninstall',
        );

        expect(ok, isTrue);
        expect(install.calls, <String>['uninstall:com.example.app']);
        expect(fakeApi.commands, isEmpty);
      });

      test('clearAppData 返回 Success → true', () async {
        fakeApi.runResult = 'Success';
        final ok =
            await InstallManager.instance.clearAppData('com.example.app');

        expect(ok, isTrue);
        expect(fakeApi.commands.single, 'pm clear "com.example.app"');
      });

      test('forceStopApp（am 成功无输出）→ true', () async {
        fakeApi.runResult = '';
        final ok =
            await InstallManager.instance.forceStopApp('com.example.app');

        expect(ok, isTrue);
        expect(fakeApi.commands.single, 'am force-stop "com.example.app"');
      });

      test('silentInstall 返回 Success → true（默认 checkPmSuccess）', () async {
        fakeApi.runResult = 'Success';
        final ok =
            await InstallManager.instance.silentInstall(tempApk.path);

        expect(ok, isTrue);
      });

      test('silentInstall 返回 Failure → false（默认 checkPmSuccess）', () async {
        fakeApi.runResult = 'Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]';
        final ok =
            await InstallManager.instance.silentInstall(tempApk.path);

        expect(ok, isFalse);
      });
    });
  });
}

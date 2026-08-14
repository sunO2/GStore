import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/install_manager.dart';
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
      fakeApi = _FakeShizukuApi();
      final manager = InstallManager.instance;
      manager.shizukuApiForTest = fakeApi;
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
    });

    group('_runShizukuCommand 链路', () {
      test('managePackage(uninstall) 返回 Failure [DELETE_FAILED] → false',
          () async {
        fakeApi.runResult = 'Failure [DELETE_FAILED_DEVICE_OWNER]';
        final ok = await InstallManager.instance.managePackage(
          'com.example.app',
          'uninstall',
        );

        expect(ok, isFalse);
        expect(fakeApi.commands.single,
            'pm uninstall --user 0 "com.example.app"');
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

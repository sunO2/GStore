import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/proxy_ca_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(MethodChannelProxyCaService.channelName);
  late List<MethodCall> calls;
  late MethodChannelProxyCaService service;

  void installHandler(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    calls = <MethodCall>[];
    service = MethodChannelProxyCaService();
  });

  tearDown(() {
    installHandler(null);
  });

  group('chooseCaInstallAction 纯决策全组合', () {
    test('非 root / 未安装 / sdk=29 → KeyChain', () {
      expect(
        chooseCaInstallAction(29, false, false),
        CaInstallAction.installUserKeychain,
      );
    });

    test('非 root / 未安装 / sdk=30（边界内）→ KeyChain', () {
      expect(
        chooseCaInstallAction(30, false, false),
        CaInstallAction.installUserKeychain,
      );
    });

    test('非 root / 未安装 / sdk=31（边界外）→ 引导', () {
      expect(
        chooseCaInstallAction(31, false, false),
        CaInstallAction.installUserGuide,
      );
    });

    test('非 root / 未安装 / sdk=34 → 引导', () {
      expect(
        chooseCaInstallAction(34, false, false),
        CaInstallAction.installUserGuide,
      );
    });

    test('已 root / 未安装 / sdk=29 → 系统写入', () {
      expect(
        chooseCaInstallAction(29, true, false),
        CaInstallAction.installSystem,
      );
    });

    test('已 root / 未安装 / sdk=31 → 系统写入（root 优先于 API 分支）', () {
      expect(
        chooseCaInstallAction(31, true, false),
        CaInstallAction.installSystem,
      );
    });

    test('已安装 / 非 root / sdk=29 → 无需安装', () {
      expect(
        chooseCaInstallAction(29, false, true),
        CaInstallAction.alreadyInstalled,
      );
    });

    test('已安装 / 非 root / sdk=31 → 无需安装', () {
      expect(
        chooseCaInstallAction(31, false, true),
        CaInstallAction.alreadyInstalled,
      );
    });

    test('已安装 / 已 root / sdk=34 → 无需安装（安装态优先级最高）', () {
      expect(
        chooseCaInstallAction(34, true, true),
        CaInstallAction.alreadyInstalled,
      );
    });
  });

  group('chooseSystemCaMethod 纯决策边界', () {
    test('sdk=33 → legacyFs', () {
      expect(chooseSystemCaMethod(33), SystemCaMethod.legacyFs);
    });

    test('sdk=34 → apexNsenter', () {
      expect(chooseSystemCaMethod(34), SystemCaMethod.apexNsenter);
    });
  });

  group('installUserCa', () {
    test('KeyChain 分支：精确方法名 + 参数 + 结构化结果（未安装/待用户动作）', () async {
      installHandler((call) async {
        calls.add(call);
        return <String, Object?>{
          'ok': true,
          'code': 'USER_KEYCHAIN_LAUNCHED',
          'action': 'keychain',
          'userActionRequired': true,
          'installed': false,
          'message': '已拉起系统证书安装器',
        };
      });
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);

      final result = await service.installUserCa(bytes);

      expect(calls.single.method, 'installUserCa');
      final args = calls.single.arguments as Map;
      expect(args['bytes'], equals(bytes));
      expect(result.ok, isTrue);
      expect(result.code, 'USER_KEYCHAIN_LAUNCHED');
      expect(result.action, 'keychain');
      expect(result.userActionRequired, isTrue);
      expect(result.installed, isFalse);
      expect(result.cancelled, isFalse);
    });

    test('引导分支（API≥31）：保存路径与安全设置打开状态可解析', () async {
      installHandler((call) async {
        calls.add(call);
        return <String, Object?>{
          'ok': true,
          'code': 'USER_GUIDE_DOWNLOADED',
          'action': 'guide',
          'reason': 'api_ge_31',
          'userActionRequired': true,
          'installed': false,
          'savedPath': 'Download/gstore-capture-ca.crt',
          'settingsOpened': true,
        };
      });

      final result = await service.installUserCa(Uint8List(0));

      expect(result.ok, isTrue);
      expect(result.code, 'USER_GUIDE_DOWNLOADED');
      expect(result.action, 'guide');
      expect(result.reason, 'api_ge_31');
      expect(result.savedPath, 'Download/gstore-capture-ca.crt');
      expect(result.settingsOpened, isTrue);
      expect(result.installed, isFalse);
    });

    test('取消分支：通道抛 USER_CANCELLED → 结构化失败且不崩溃', () async {
      installHandler((call) async {
        calls.add(call);
        throw PlatformException(code: 'USER_CANCELLED', message: '用户取消安装');
      });

      final result = await service.installUserCa(Uint8List(0));

      expect(calls.single.method, 'installUserCa');
      expect(result.ok, isFalse);
      expect(result.code, 'USER_CANCELLED');
      expect(result.cancelled, isTrue);
      expect(result.installed, isFalse);
      expect(result.message, '用户取消安装');
    });

    test('通道异常（非取消）→ 结构化失败，含平台 code', () async {
      installHandler((call) async {
        throw PlatformException(code: 'CA_INSTALL_USER', message: 'boom');
      });

      final result = await service.installUserCa(Uint8List(0));

      expect(result.ok, isFalse);
      expect(result.code, 'CA_INSTALL_USER');
      expect(result.cancelled, isFalse);
    });

    test('通道缺失（无 handler）→ CHANNEL_UNAVAILABLE，不崩溃', () async {
      installHandler(null);

      final result = await service.installUserCa(Uint8List(0));

      expect(result.ok, isFalse);
      expect(result.code, CaInstallResult.channelUnavailableCode);
    });
  });

  group('installSystemCa', () {
    test('root 成功分支：精确方法名 + pem 参数 + installed=true', () async {
      installHandler((call) async {
        calls.add(call);
        return <String, Object?>{
          'ok': true,
          'code': 'SYSTEM_CA_INSTALLED',
          'action': 'legacy_fs',
          'fileName': 'abcd1234.0',
          'installed': true,
          'userActionRequired': false,
        };
      });

      final result = await service.installSystemCa('PEM-BYTES');

      expect(calls.single.method, 'installSystemCa');
      expect(calls.single.arguments, <String, Object?>{'pem': 'PEM-BYTES'});
      expect(result.ok, isTrue);
      expect(result.code, 'SYSTEM_CA_INSTALLED');
      expect(result.action, 'legacy_fs');
      expect(result.installed, isTrue);
      expect(result.fileName, 'abcd1234.0');
    });

    test('非 root 失败分支：ok=false / code=NOT_ROOT', () async {
      installHandler((call) async {
        calls.add(call);
        return <String, Object?>{
          'ok': false,
          'code': 'NOT_ROOT',
          'installed': false,
          'userActionRequired': false,
          'message': '未检测到 root',
        };
      });

      final result = await service.installSystemCa('PEM-BYTES');

      expect(result.ok, isFalse);
      expect(result.code, 'NOT_ROOT');
      expect(result.installed, isFalse);
    });

    test('通道异常 → 结构化失败', () async {
      installHandler((call) async {
        throw PlatformException(code: 'CA_INSTALL_SYSTEM', message: 'boom');
      });

      final result = await service.installSystemCa('PEM-BYTES');

      expect(result.ok, isFalse);
      expect(result.code, 'CA_INSTALL_SYSTEM');
    });
  });

  group('detectRoot', () {
    test('返回 true → 精确方法名', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await service.detectRoot(), isTrue);
      expect(calls.single.method, 'detectRoot');
    });

    test('返回 false', () async {
      installHandler((call) async => false);

      expect(await service.detectRoot(), isFalse);
    });

    test('通道异常 → 抛结构化 ProxyCaException', () async {
      installHandler((call) async {
        throw PlatformException(code: 'CA_DETECT_ROOT', message: 'x');
      });

      await expectLater(
        service.detectRoot(),
        throwsA(
          isA<ProxyCaException>().having((e) => e.code, 'code', 'CA_DETECT_ROOT'),
        ),
      );
    });

    test('通道缺失 → ProxyCaException(CHANNEL_UNAVAILABLE)', () async {
      installHandler(null);

      await expectLater(
        service.detectRoot(),
        throwsA(
          isA<ProxyCaException>().having(
            (e) => e.code,
            'code',
            CaInstallResult.channelUnavailableCode,
          ),
        ),
      );
    });
  });

  group('systemCaInstalled', () {
    test('带 pem：精确方法名 + pem 参数 + true', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await service.systemCaInstalled(pem: 'PEM-BYTES'), isTrue);
      expect(calls.single.method, 'systemCaInstalled');
      expect(calls.single.arguments, <String, Object?>{'pem': 'PEM-BYTES'});
    });

    test('不带 pem：参数为空映射（用最近一次写入的文件名）', () async {
      installHandler((call) async {
        calls.add(call);
        return false;
      });

      expect(await service.systemCaInstalled(), isFalse);
      expect(calls.single.method, 'systemCaInstalled');
      expect(calls.single.arguments, <String, Object?>{});
    });

    test('通道异常 → 抛结构化 ProxyCaException', () async {
      installHandler((call) async {
        throw PlatformException(code: 'CA_SYSTEM_STATUS', message: 'x');
      });

      await expectLater(
        service.systemCaInstalled(),
        throwsA(
          isA<ProxyCaException>()
              .having((e) => e.code, 'code', 'CA_SYSTEM_STATUS'),
        ),
      );
    });
  });

  group('CaInstallResult.fromChannel 防御性解析', () {
    test('非映射 → BAD_RESPONSE 失败，不抛', () {
      final result = CaInstallResult.fromChannel('not-a-map');
      expect(result.ok, isFalse);
      expect(result.code, 'BAD_RESPONSE');
    });

    test('缺少 code 且 ok=true → 回落 OK', () {
      final result = CaInstallResult.fromChannel(<String, Object?>{'ok': true});
      expect(result.ok, isTrue);
      expect(result.code, 'OK');
    });
  });
}

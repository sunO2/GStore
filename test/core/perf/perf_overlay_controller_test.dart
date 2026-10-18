import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/perf/perf_overlay_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PerfOverlayController.channelName);
  late List<MethodCall> calls;
  late PerfOverlayController controller;

  void installHandler(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  List<String> methods() => calls.map((c) => c.method).toList();

  setUp(() {
    calls = <MethodCall>[];
    controller = const PerfOverlayController();
  });

  tearDown(() => installHandler(null));

  group('start 权限校验', () {
    test('未授权 → 返回 false 且绝不调用原生 start', () async {
      installHandler((call) async {
        calls.add(call);
        if (call.method == 'isPermissionGranted') return false;
        return true;
      });

      expect(await controller.start(), isFalse);
      expect(methods(), contains('isPermissionGranted'));
      expect(methods(), isNot(contains('start')));
    });

    test('已授权 → 先校验权限再调用原生 start', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.start(), isTrue);
      expect(methods(), <String>['isPermissionGranted', 'start']);
    });

    test('已授权但原生 start 返回 false → false', () async {
      installHandler((call) async {
        calls.add(call);
        return call.method == 'isPermissionGranted';
      });

      expect(await controller.start(), isFalse);
      expect(methods(), <String>['isPermissionGranted', 'start']);
    });
  });

  group('graceful 失败', () {
    test('通道缺失（无 handler）→ 各方法均返回 false 不抛', () async {
      installHandler(null);

      expect(await controller.isPermissionGranted(), isFalse);
      expect(await controller.requestPermission(), isFalse);
      expect(await controller.start(), isFalse);
      expect(await controller.stop(), isFalse);
      expect(await controller.isRunning(), isFalse);
    });

    test('PlatformException → 返回 false 不抛', () async {
      installHandler((call) async {
        throw PlatformException(code: 'X', message: 'boom');
      });

      expect(await controller.isRunning(), isFalse);
      expect(await controller.stop(), isFalse);
    });
  });

  test('isRunning / stop / requestPermission 使用精确方法名', () async {
    installHandler((call) async {
      calls.add(call);
      return true;
    });

    expect(await controller.isRunning(), isTrue);
    expect(await controller.stop(), isTrue);
    expect(await controller.requestPermission(), isTrue);
    expect(methods(),
        <String>['isRunning', 'stop', 'requestPermission']);
  });

  group('setMode / getMode', () {
    test('setMode 合法值 → 调用原生并返回 true', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(
        await controller.setMode(PerfOverlayController.modeExpanded),
        isTrue,
      );
      expect(methods(), <String>['setMode']);
      expect(calls.single.arguments, <String, Object?>{'mode': 'expanded'});
    });

    test('setMode 非法值 → 返回 false 且不调用原生', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.setMode('bogus'), isFalse);
      expect(methods(), isEmpty);
    });

    test('setMode target 合法值 → 调用原生并返回 true', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(
        await controller.setMode(PerfOverlayController.modeTarget),
        isTrue,
      );
      expect(methods(), <String>['setMode']);
      expect(calls.single.arguments, <String, Object?>{'mode': 'target'});
    });

    test('modes 包含四种合法模式（Kotlin/Dart 常量对齐）', () {
      expect(
        PerfOverlayController.modes,
        <String>{'compact', 'expanded', 'target', 'live'},
      );
      expect(PerfOverlayController.modeLive, 'live');
    });

    test('setMode live 合法值 → 调用原生并返回 true', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.setMode(PerfOverlayController.modeLive), isTrue);
      expect(methods(), <String>['setMode']);
      expect(calls.single.arguments, <String, Object?>{'mode': 'live'});
    });

    test('getMode → target 原样返回，未知回退 compact', () async {
      installHandler((call) async {
        calls.add(call);
        return 'target';
      });
      expect(await controller.getMode(), PerfOverlayController.modeTarget);

      installHandler((call) async {
        calls.add(call);
        return 'weird';
      });
      expect(await controller.getMode(), PerfOverlayController.modeCompact);
    });

    test('getMode → 非 expanded 一律回退 compact', () async {
      installHandler((call) async {
        calls.add(call);
        return 'expanded';
      });
      expect(await controller.getMode(), PerfOverlayController.modeExpanded);

      installHandler((call) async {
        calls.add(call);
        return 'weird';
      });
      expect(await controller.getMode(), PerfOverlayController.modeCompact);
    });

    test('通道缺失 → setMode false / getMode compact，不抛', () async {
      installHandler(null);

      expect(
        await controller.setMode(PerfOverlayController.modeExpanded),
        isFalse,
      );
      expect(await controller.getMode(), PerfOverlayController.modeCompact);
    });

    test('PlatformException → setMode false / getMode compact', () async {
      installHandler((call) async {
        throw PlatformException(code: 'X', message: 'boom');
      });

      expect(
        await controller.setMode(PerfOverlayController.modeExpanded),
        isFalse,
      );
      expect(await controller.getMode(), PerfOverlayController.modeCompact);
    });
  });

  group('setTarget / clearTarget / getTarget', () {
    test('setTarget 非空 → 调用原生并传 package，返回 true', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.setTarget('com.example.app'), isTrue);
      expect(methods(), <String>['setTarget']);
      expect(
        calls.single.arguments,
        <String, Object?>{'package': 'com.example.app'},
      );
    });

    test('setTarget 空 / 空白 → false 且不调用原生', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.setTarget('   '), isFalse);
      expect(methods(), isEmpty);
    });

    test('clearTarget → 调用原生 clearTarget', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.clearTarget(), isTrue);
      expect(methods(), <String>['clearTarget']);
    });

    test('getTarget → 返回字符串；空 / null 回退 null', () async {
      installHandler((call) async {
        calls.add(call);
        return 'com.example.app';
      });
      expect(await controller.getTarget(), 'com.example.app');

      installHandler((call) async {
        calls.add(call);
        return '';
      });
      expect(await controller.getTarget(), isNull);

      installHandler((call) async {
        calls.add(call);
        return null;
      });
      expect(await controller.getTarget(), isNull);
    });

    test('通道缺失 → setTarget false / clearTarget false / getTarget null', () async {
      installHandler(null);

      expect(await controller.setTarget('com.example.app'), isFalse);
      expect(await controller.clearTarget(), isFalse);
      expect(await controller.getTarget(), isNull);
    });

    test('PlatformException → 三者 graceful 不抛', () async {
      installHandler((call) async {
        throw PlatformException(code: 'X', message: 'boom');
      });

      expect(await controller.setTarget('com.example.app'), isFalse);
      expect(await controller.clearTarget(), isFalse);
      expect(await controller.getTarget(), isNull);
    });
  });

  group('setProfile / getProfile', () {
    test('setProfile 非空 → 调用原生并传 name，返回 true', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.setProfile('balanced'), isTrue);
      expect(methods(), <String>['setProfile']);
      expect(
        calls.single.arguments,
        <String, Object?>{'name': 'balanced'},
      );
    });

    test('setProfile 归一化 bool 返回值（非 bool 强转不抛）', () async {
      installHandler((call) async {
        calls.add(call);
        return 1; // 原生意外返回非 bool：归一化后为 false，但不触发 _CastError
      });

      expect(await controller.setProfile('balanced'), isFalse);
      expect(methods(), <String>['setProfile']);
    });

    test('setProfile 空串 → 仍调用原生（清除），不本地拒绝', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.setProfile('   '), isTrue);
      expect(calls.single.arguments, <String, Object?>{'name': ''});
    });

    test('getProfile → 返回字符串；空 / null 回退 null', () async {
      installHandler((call) async {
        calls.add(call);
        return 'performance';
      });
      expect(await controller.getProfile(), 'performance');

      installHandler((call) async {
        calls.add(call);
        return '';
      });
      expect(await controller.getProfile(), isNull);

      installHandler((call) async {
        calls.add(call);
        return null;
      });
      expect(await controller.getProfile(), isNull);
    });

    test('getProfile 原生返回 bool → toString 归一化，不抛 _CastError', () async {
      installHandler((call) async {
        calls.add(call);
        return false;
      });
      expect(await controller.getProfile(), 'false');
    });

    test('通道缺失 → setProfile false / getProfile null', () async {
      installHandler(null);

      expect(await controller.setProfile('balanced'), isFalse);
      expect(await controller.getProfile(), isNull);
    });

    test('PlatformException → 二者 graceful 不抛', () async {
      installHandler((call) async {
        throw PlatformException(code: 'X', message: 'boom');
      });

      expect(await controller.setProfile('balanced'), isFalse);
      expect(await controller.getProfile(), isNull);
    });
  });

  group('start 携带 targetPackage', () {
    test('已授权 + targetPackage → start 参数含 targetPackage', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(
        await controller.start(targetPackage: 'com.example.app'),
        isTrue,
      );
      expect(methods(), <String>['isPermissionGranted', 'start']);
      final startCall = calls.firstWhere((c) => c.method == 'start');
      expect(
        startCall.arguments,
        <String, Object?>{'targetPackage': 'com.example.app'},
      );
    });

    test('无 targetPackage → start 参数为 null', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.start(), isTrue);
      expect(calls.last.method, 'start');
      expect(calls.last.arguments, isNull);
    });

    test('空白 targetPackage → start 参数为 null', () async {
      installHandler((call) async {
        calls.add(call);
        return true;
      });

      expect(await controller.start(targetPackage: '  '), isTrue);
      expect(calls.last.arguments, isNull);
    });
  });
}

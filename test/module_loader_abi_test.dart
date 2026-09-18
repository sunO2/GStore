import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('gstore/apk_source');
  final loader = RustModuleLoader.instance;

  void installHandler(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  setUp(() {
    loader.resetDeviceAbiCache();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    loader.resetDeviceAbiCache();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('deviceAbi 真实解析', () {
    test('通道返回 armeabi-v7a → deviceAbi() 返回该 ABI', () async {
      final calls = <MethodCall>[];
      installHandler((call) async {
        calls.add(call);
        return call.method == 'currentAbi' ? 'armeabi-v7a' : null;
      });

      expect(await loader.deviceAbi(), 'armeabi-v7a');
      expect(calls.single.method, 'currentAbi');
    });

    test('通道抛 PlatformException → 回退 arm64-v8a 且不抛', () async {
      installHandler((call) async {
        throw PlatformException(code: 'UNAVAILABLE', message: 'no channel');
      });

      expect(await loader.deviceAbi(), 'arm64-v8a');
    });

    test('通道返回 null → 回退 arm64-v8a', () async {
      installHandler((call) async => null);
      expect(await loader.deviceAbi(), 'arm64-v8a');
    });

    test('通道返回空串 → 回退 arm64-v8a', () async {
      installHandler((call) async => '');
      expect(await loader.deviceAbi(), 'arm64-v8a');
    });

    test('通道返回不支持的 ABI → 回退 arm64-v8a', () async {
      installHandler((call) async => 'riscv64');
      expect(await loader.deviceAbi(), 'arm64-v8a');
    });

    test('缓存：两次调用仅触发一次通道', () async {
      var invocations = 0;
      installHandler((call) async {
        invocations++;
        return 'x86_64';
      });

      expect(await loader.deviceAbi(), 'x86_64');
      expect(await loader.deviceAbi(), 'x86_64');
      expect(invocations, 1);
    });

    test('非 Android → 桌面值 x86_64，且不触发通道', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      var invoked = false;
      installHandler((call) async {
        invoked = true;
        return 'armeabi-v7a';
      });

      expect(await loader.deviceAbi(), 'x86_64');
      expect(invoked, isFalse);
    });
  });

  group('通道参数使用解析后的 ABI', () {
    test('hasModule 载荷 module/abi 使用真实 ABI', () async {
      final calls = <MethodCall>[];
      installHandler((call) async {
        calls.add(call);
        return switch (call.method) {
          'currentAbi' => 'armeabi-v7a',
          'hasModule' => true,
          _ => null,
        };
      });

      expect(await loader.isAvailable('qr'), isTrue);
      final hasCall = calls.firstWhere((c) => c.method == 'hasModule');
      final args = hasCall.arguments as Map;
      expect(args['module'], 'qr');
      expect(args['abi'], 'armeabi-v7a');
    });

    test('extractModule 载荷 module/abi 使用真实 ABI', () async {
      final calls = <MethodCall>[];
      installHandler((call) async {
        calls.add(call);
        return switch (call.method) {
          'currentAbi' => 'armeabi-v7a',
          'extractModule' => null,
          _ => null,
        };
      });

      await loader.debugBuiltinSoPath('qr');
      final extractCall = calls.firstWhere((c) => c.method == 'extractModule');
      final args = extractCall.arguments as Map;
      expect(args['module'], 'qr');
      expect(args['abi'], 'armeabi-v7a');
    });
  });
}

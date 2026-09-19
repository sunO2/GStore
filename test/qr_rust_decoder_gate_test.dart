import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleInstance;
import 'package:gstore/core/rust/QrRustDecoder.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;

/// 伪造的宿主模块句柄：仅经 `loadOverride` 原样返回，绝不触碰 FFI。
class _FakeHandle implements ModuleHandle {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 伪造的模块实例：`callModule('decode_luma')` 返回预置的 JSON 字节。
class _FakeInstance implements RustModuleInstance {
  _FakeInstance(this.responseBytes);

  final Uint8List responseBytes;

  @override
  Future<Uint8List> callModule(String method, [Uint8List? payload]) async =>
      responseBytes;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 模块 `decode_luma` 成功响应的 JSON（契约层字段）。
Uint8List _okDecodeResponse(String text) => Uint8List.fromList(utf8.encode(
      jsonEncode(<String, dynamic>{
        'text': text,
        'format': 'QR_CODE',
        'points': <double>[1, 2, 3, 4, 5, 6, 7, 8],
        'raw_bytes': <int>[],
        'is_mirrored': false,
        'is_inverted': false,
        'is_valid': true,
        'error': '',
        'orientation': 0,
      }),
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bootstrap = ModuleBootstrap.instance;

  setUp(() {
    bootstrap.debugReset();
    QrRustDecoder.debugReset();
  });

  tearDown(() {
    bootstrap.debugReset();
    QrRustDecoder.debugReset();
  });

  test('gate ready：N 帧均解码成功且 ensure 全程仅一次', () async {
    var ensureCalls = 0;
    final handle = _FakeHandle();
    final instance = _FakeInstance(_okDecodeResponse('hello'));

    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) async {
        ensureCalls++;
        return true;
      },
      loadOverride: (String module) async => handle,
      factoryOverride: (ModuleHandle h) async => instance,
    );

    // 预热门：安装 + 建实例，门缓存 ready。
    await bootstrap.acquire('qr');
    expect(ensureCalls, 1, reason: '预热恰好一次 ensure');
    // 复位解码器阶段缓存，使首帧经订阅重新同步门状态（门缓存不受影响）。
    QrRustDecoder.debugReset();

    final luma = Uint8List.fromList(<int>[7]);
    for (var i = 0; i < 5; i++) {
      final result = await QrRustDecoder.decodeLuma(luma, 1, 1);
      expect(result, isNotNull, reason: '第 ${i + 1} 帧应返回解码结果');
      expect(result!.text, 'hello');
      expect(result.isValid, isTrue);
    }
    expect(ensureCalls, 1, reason: 'N 帧复用门缓存实例：ensure 不得新增');
  });

  test('ensure 失败：全帧返回 null、不抛异常、后续帧重试且不粘滞', () async {
    var ensureCalls = 0;
    final handle = _FakeHandle();
    final instance = _FakeInstance(_okDecodeResponse('never'));
    final delays = <Duration>[];

    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) async {
        ensureCalls++;
        return false; // 模拟安装/确保失败
      },
      loadOverride: (String module) async => handle,
      factoryOverride: (ModuleHandle h) async => instance,
      delayOverride: (Duration d) async {
        delays.add(d); // 退避零延迟，避免测试等待
      },
    );

    final luma = Uint8List.fromList(<int>[9]);

    // 首帧：即发即忘触发安装，立即返回 null，绝不抛出。
    final first = await QrRustDecoder.decodeLuma(luma, 1, 1);
    expect(first, isNull, reason: '安装中/失败帧返回 null，不阻塞相机');
    await pumpEventQueue();
    final afterFirst = ensureCalls;
    expect(afterFirst, greaterThan(0), reason: '首帧应触发 ensure');
    expect(delays, isNotEmpty, reason: '失败走有界退避');

    // 后续帧：门状态 failed（不粘滞）→ 再次触发 ensure 重试；仍全部 null。
    var sawRetry = false;
    for (var i = 0; i < 3; i++) {
      final r = await QrRustDecoder.decodeLuma(luma, 1, 1);
      expect(r, isNull, reason: '失败期间所有帧返回 null');
      await pumpEventQueue();
      if (ensureCalls > afterFirst) sawRetry = true;
    }
    expect(sawRetry, isTrue, reason: '失败不粘滞：后续帧应再次触发 ensure 重试');
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/rust/generated/contract/envelope.pb.dart'
    show EnvelopeResponse, StatusCode;

/// 伪造的宿主模块句柄。
///
/// 测试只经 [RustModuleManager.debugConfigure] 注入接缝，句柄仅用于
/// `callEnvelope` 的受控返回；其余成员经 [noSuchMethod] 透传，**不触碰 FFI**。
class _FakeModuleHandle implements ModuleHandle {
  _FakeModuleHandle(this.responseBytes);

  final Uint8List responseBytes;

  @override
  Future<Uint8List> callEnvelope({required List<int> requestBytes}) async =>
      responseBytes;

  @override
  Future<Uint8List> callEnvelopeTimed(
          {required List<int> requestBytes, required BigInt timeoutMs}) async =>
      responseBytes;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 构造一个 200 信封（payload = 原始字节）。
Uint8List _okEnvelopeBytes(List<int> payload) {
  final response = EnvelopeResponse(
    protocolVersion: 1,
    status: StatusCode.STATUS_OK,
    payload: payload,
  );
  return Uint8List.fromList(response.writeToBuffer());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = RustModuleManager.instance;

  /// 统计自愈成功日志条数（`appLog.clear()` 后的增量）。
  int healLogCount() => appLog.logs
      .where((l) => l.message.contains('after MODULE_NOT_FOUND'))
      .length;

  setUp(() {
    manager.debugReset();
    appLog.clear();
  });

  tearDown(() {
    manager.debugReset();
  });

  test('happy: MODULE_NOT_FOUND 自愈一次，第二次调用命中缓存', () async {
    const module = 'analyzer';
    final payload = Uint8List.fromList(<int>[7, 8, 9]);
    final handle = _FakeModuleHandle(_okEnvelopeBytes(payload));

    var loadCalls = 0;
    var ensureCalls = 0;
    var seedCalls = 0;

    manager.debugConfigure(
      // 绕过 FFI 初始化（测试环境无 gstore_host 原生库）。
      readyOverride: () async {},
      loadModuleOverride: (String name) async {
        loadCalls++;
        throw '[404] MODULE_NOT_FOUND: module not found: $name';
      },
      ensureOverride: (
        String name, {
        bool? allowDownload,
        ModuleProgressCallback? onProgress,
      }) async {
        ensureCalls++;
        // 模拟 ensure 挂载把句柄写入真实缓存。
        manager.debugSeedHandle(name, handle);
        return true;
      },
      seedHandle: (String name, ModuleHandle h) => seedCalls++,
    );

    final first = await manager.callModule(module, null, 'ping', Uint8List(0));
    expect(first, payload, reason: '自愈成功后应返回解包 payload');
    expect(ensureCalls, 1, reason: '自愈仅触发一次 ensure');
    expect(loadCalls, 1, reason: 'seed 命中缓存后不应二次加载');
    expect(seedCalls, 1, reason: 'seedHandle 被调用一次');
    expect(healLogCount(), 1, reason: '成功自愈恰好记录一条日志');

    final second = await manager.callModule(module, null, 'ping', Uint8List(0));
    expect(second, payload);
    expect(ensureCalls, 1, reason: '第二次调用命中缓存，零 ensure');
    expect(loadCalls, 1, reason: '第二次调用命中缓存，零加载');
    expect(seedCalls, 1);
    expect(healLogCount(), 1, reason: '缓存命中不重复记录自愈日志');
  });

  test('guard: 确认策略(llm) 加载失败直接重抛，零 ensure、零日志', () async {
    const module = 'llm';
    var ensureCalls = 0;

    manager.debugConfigure(
      readyOverride: () async {},
      loadModuleOverride: (String name) async =>
          throw '[404] MODULE_NOT_FOUND: module not found: $name',
      ensureOverride: (
        String name, {
        bool? allowDownload,
        ModuleProgressCallback? onProgress,
      }) async {
        ensureCalls++;
        return true;
      },
    );

    await expectLater(
      manager.callModule(module, null, 'run', Uint8List(0)),
      throwsA(contains('module not found: llm')),
    );
    expect(ensureCalls, 0, reason: '确认策略绝不因调用失败而自动安装');
    expect(healLogCount(), 0, reason: '未自愈不得记录成功日志');
  });

  test('guard: ensure 返回 false 时仅一次尝试并重抛原始错误、零日志', () async {
    const module = 'qr';
    var ensureCalls = 0;
    var loadCalls = 0;

    manager.debugConfigure(
      readyOverride: () async {},
      loadModuleOverride: (String name) async {
        loadCalls++;
        throw '[404] MODULE_NOT_FOUND: module not found: $name';
      },
      ensureOverride: (
        String name, {
        bool? allowDownload,
        ModuleProgressCallback? onProgress,
      }) async {
        ensureCalls++;
        return false;
      },
    );

    await expectLater(
      manager.callModule(module, null, 'decode', Uint8List(0)),
      throwsA(contains('MODULE_NOT_FOUND')),
    );
    expect(ensureCalls, 1, reason: '补装失败只尝试一次，无循环重试');
    expect(loadCalls, 1, reason: '补装失败不得二次加载');
    expect(healLogCount(), 0, reason: '自愈失败不得记录成功日志');
  });

  test('auto 策略：非 MODULE_NOT_FOUND 失败先记录原始错误再自愈', () async {
    const module = 'download';
    final payload = Uint8List.fromList(<int>[1, 2, 3]);
    final handle = _FakeModuleHandle(_okEnvelopeBytes(payload));

    var ensureCalls = 0;

    manager.debugConfigure(
      readyOverride: () async {},
      // ABI 不匹配等非 MODULE_NOT_FOUND 失败（裸 String，按宿主契约）。
      loadModuleOverride: (String name) async =>
          throw 'native ABI mismatch: expected 2, got 1',
      ensureOverride: (
        String name, {
        bool? allowDownload,
        ModuleProgressCallback? onProgress,
      }) async {
        ensureCalls++;
        manager.debugSeedHandle(name, handle);
        return true;
      },
    );

    final result = await manager.callModule(module, null, 'ping', Uint8List(0));
    expect(result, payload, reason: 'auto 策略仍按既有行为补装后完成调用');
    expect(ensureCalls, 1, reason: 'auto 策略自愈行为不变');
    expect(
      appLog.logs.any((l) => l.message.contains('native ABI mismatch')),
      isTrue,
      reason: '自愈前必须记录原始错误，避免根因被成功日志掩盖',
    );
    expect(healLogCount(), 1, reason: '成功自愈仍恰好一条日志');
  });
}

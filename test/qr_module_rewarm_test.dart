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
  int callCalls = 0;

  @override
  Future<Uint8List> callModule(String method, [Uint8List? payload]) async {
    callCalls++;
    return responseBytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// `decode_luma` 成功响应的 JSON（契约层字段）。
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

/// `QrRustDecoder.prewarm()` 重入回归（状态机 bug）。
///
/// 根因：`ModuleBootstrap._ensureOnlyInternal` 在调用 loader 前发布
/// `downloading`；当模块**已安装**时 `RustModuleLoader.ensureModule` 因
/// `_isLoaded` 短路立即返回 `true`，该 ensure **成功却没有终态**。随后
/// `acquire` 命中实例缓存直接返回、不再发布 `initializing → ready`。
/// 净效果：`_lastStates['qr']` 被永久冻结在 `downloading`，扫码页显示
/// 「下载中」且 `decodeLuma` 永远走 downloading 分支返回 null。
///
/// 本文件锁定修复后的契约：
/// * (a) 首次 `prewarm()` 正常收敛到 `ready`，ensure/工厂各一次；
/// * (b) **第二次 `prewarm()` 不得把已 ready 的模块翻回 downloading**，
///       且 `decodeLuma` 仍能解码成功；
/// * (c) 已安装模块上 `prewarm()` 完全不发布 `downloading`。
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

  /// 注入全部测试接缝并返回计数闭包（无 FFI、无网络）。
  ({int Function() ensureCalls, int Function() factoryCalls}) configure({
    required _FakeHandle handle,
    required _FakeInstance instance,
  }) {
    var ensures = 0;
    var factories = 0;
    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) async {
        ensures++;
        return true;
      },
      loadOverride: (String module) async => handle,
      factoryOverride: (ModuleHandle h) async {
        factories++;
        return instance;
      },
    );
    return (
      ensureCalls: () => ensures,
      factoryCalls: () => factories,
    );
  }

  test('(a) 首次 prewarm 收敛到 ready：ensure/工厂各一次', () async {
    final counters = configure(
      handle: _FakeHandle(),
      instance: _FakeInstance(_okDecodeResponse('hello')),
    );

    final phases = <ModuleBootstrapPhase>[];
    final sub = bootstrap.watch('qr').listen((s) => phases.add(s.phase));
    await pumpEventQueue();

    QrRustDecoder.prewarm();
    await pumpEventQueue();
    await sub.cancel();

    expect(phases.last, ModuleBootstrapPhase.ready,
        reason: '首次预热后 watch(qr) 终态必须为 ready');
    expect(counters.ensureCalls(), 1, reason: '预热恰好一次 ensure');
    expect(counters.factoryCalls(), 1, reason: '预热恰好建一次实例');
  });

  test('(b) 二次 prewarm 不回退：watch(qr) 终态仍 ready 且 decodeLuma 成功', () async {
    final instance = _FakeInstance(_okDecodeResponse('hello'));
    final counters = configure(handle: _FakeHandle(), instance: instance);

    final phases = <ModuleBootstrapPhase>[];
    final sub = bootstrap.watch('qr').listen((s) => phases.add(s.phase));
    await pumpEventQueue();

    // 第一次预热：真实安装 → downloading → initializing → ready。
    QrRustDecoder.prewarm();
    await pumpEventQueue();
    expect(phases.last, ModuleBootstrapPhase.ready,
        reason: '第一次预热必须收敛到 ready');

    // 第二次预热（模拟「切回识别模式 / 再次进入扫码页」）：模块已安装。
    // 修复前：ensureStarted 会再发一次 downloading，而 loader 短路使其无终态、
    // acquire 又命中缓存不补终态 → 阶段永久停在 downloading。
    QrRustDecoder.prewarm();
    await pumpEventQueue();

    expect(phases.last, ModuleBootstrapPhase.ready,
        reason: '二次预热后终态必须仍为 ready，绝不能被翻回 downloading');
    expect(phases.last, isNot(ModuleBootstrapPhase.downloading));

    // 阶段仍 ready → decodeLuma 必须真正解码（而非走 downloading 分支返回 null）。
    final result =
        await QrRustDecoder.decodeLuma(Uint8List.fromList(<int>[7]), 1, 1);
    expect(result, isNotNull, reason: '阶段未回退，decodeLuma 必须解码成功');
    expect(result!.text, 'hello');

    expect(counters.ensureCalls(), 1, reason: '二次预热不得新增 ensure');
    expect(counters.factoryCalls(), 1, reason: '二次预热不得新增实例');
    await sub.cancel();
  });

  test('(c) 已安装模块上 prewarm 完全不发出 downloading', () async {
    final counters = configure(
      handle: _FakeHandle(),
      instance: _FakeInstance(_okDecodeResponse('hello')),
    );

    // 先让模块完成安装并缓存实例（等价于「已安装」）。
    await bootstrap.acquire('qr');
    expect(counters.ensureCalls(), 1);

    final phases = <ModuleBootstrapPhase>[];
    final sub = bootstrap.watch('qr').listen((s) => phases.add(s.phase));
    await pumpEventQueue();

    QrRustDecoder.prewarm();
    await pumpEventQueue();
    await sub.cancel();

    expect(phases, isNot(contains(ModuleBootstrapPhase.downloading)),
        reason: '已安装模块上预热绝不能再发布 downloading');
    expect(phases.last, ModuleBootstrapPhase.ready);
    expect(counters.ensureCalls(), 1, reason: '已安装模块上预热不得触发 ensure');
    expect(counters.factoryCalls(), 1, reason: '已安装模块上预热不得新建实例');
  });
}

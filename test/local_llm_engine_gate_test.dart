import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/llm/local_llm_engine.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart'
    show InstanceHandle, ModuleHandle;
import 'package:gstore/core/rust/generated/contract/envelope.pb.dart'
    show EnvelopeResponse, StatusCode;

/// 伪造的实例句柄：只服务于 `instanceId()`，不触碰 FFI。
class _FakeInstanceHandle implements InstanceHandle {
  @override
  Future<String> instanceId() async => 'llm-inst-1';

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 伪造的宿主模块句柄。
///
/// 经 [ModuleBootstrap.debugConfigure] / [RustModuleManager.debugConfigure]
/// 接缝注入：`createInstance` 返回假实例句柄，`callEnvelope` 返回受控信封，
/// 其余成员经 [noSuchMethod] 透传，**全程无 FFI、无网络**。
class _FakeModuleHandle implements ModuleHandle {
  _FakeModuleHandle(this.responseBytes);

  final Uint8List responseBytes;
  int createCalls = 0;

  @override
  Future<InstanceHandle> createInstance({required List<int> config}) async {
    createCalls++;
    return _FakeInstanceHandle();
  }

  @override
  Future<Uint8List> callEnvelope({required List<int> requestBytes}) async =>
      responseBytes;

  @override
  Future<Uint8List> callEnvelopeTimed(
          {required List<int> requestBytes, required BigInt timeoutMs}) async =>
      responseBytes;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// 构造 200 信封，payload 为 JSON 文本字节。
Uint8List _okJsonEnvelope(Map<String, dynamic> body) {
  final response = EnvelopeResponse(
    protocolVersion: 1,
    status: StatusCode.STATUS_OK,
    payload: utf8.encode(jsonEncode(body)),
  );
  return Uint8List.fromList(response.writeToBuffer());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final engine = LocalLlmEngine.instance;
  final bootstrap = ModuleBootstrap.instance;
  final manager = RustModuleManager.instance;

  setUp(() async {
    bootstrap.debugReset();
    manager.debugReset();
    await manager.releaseModule('llm');
    engine.debugReset();
    appLog.clear();
  });

  tearDown(() async {
    bootstrap.debugReset();
    manager.debugReset();
    await manager.releaseModule('llm');
    engine.debugReset();
  });

  /// 配置门接缝：确认处理器、ensure 计数、句柄加载计数（无 FFI）。
  void configureBootstrap({
    required _FakeModuleHandle handle,
    required Future<bool> Function(String module) confirm,
    void Function()? onEnsure,
    void Function()? onLoad,
  }) {
    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) async {
        onEnsure?.call();
        return true;
      },
      loadOverride: (String module) async {
        onLoad?.call();
        return handle;
      },
      confirmHandler: confirm,
      // 零退避，避免测试等待。
      delayOverride: (Duration duration) async {},
    );
  }

  /// 配置 manager 接缝：信封调用经同一个假句柄返回受控响应。
  void configureManager(_FakeModuleHandle handle) {
    manager.debugConfigure(
      readyOverride: () async {},
      loadModuleOverride: (String name) async => handle,
    );
  }

  group('todo 16 - LocalLlmEngine 经确认策略门自举', () {
    test('确认接受：ensureReady=true、_call 成功、二次 _call 命中缓存不再确认', () async {
      final handle = _FakeModuleHandle(_okJsonEnvelope(<String, dynamic>{'ok': true}));
      var confirmCalls = 0;
      var ensureCalls = 0;

      configureManager(handle);
      configureBootstrap(
        handle: handle,
        confirm: (String module) async {
          confirmCalls++;
          return true;
        },
        onEnsure: () => ensureCalls++,
      );

      expect(await engine.ensureReady(), isTrue, reason: '确认接受后应就绪');
      expect(confirmCalls, 1, reason: '首次使用恰好确认一次');
      expect(ensureCalls, 1, reason: '确认通过后恰好一次 ensure');
      expect(handle.createCalls, 1, reason: '经 create(llm) 创建实例一次');

      final caps = await engine.capabilities();
      expect(caps['ok'], isTrue, reason: '首帧 _call 应解出 JSON Map');
      expect(confirmCalls, 1, reason: '已就绪，_call 不得再次确认');

      final caps2 = await engine.capabilities();
      expect(caps2['ok'], isTrue, reason: '二次 _call 仍应成功');
      expect(confirmCalls, 1, reason: '二次 _call 命中缓存实例，不再确认');
      expect(handle.createCalls, 1, reason: '实例仅创建一次');
      expect(ensureCalls, 1, reason: '缓存命中不新增 ensure');
    });

    test('确认拒绝：ensureReady=false、_call 抛既有 StateError、后续接受仍会安装', () async {
      final handle = _FakeModuleHandle(_okJsonEnvelope(<String, dynamic>{'ok': true}));
      configureManager(handle);

      var confirmCalls = 0;
      var accepted = false;
      var ensureCalls = 0;

      configureBootstrap(
        handle: handle,
        confirm: (String module) async {
          confirmCalls++;
          return accepted;
        },
        onEnsure: () => ensureCalls++,
      );

      expect(await engine.ensureReady(), isFalse, reason: '拒绝不得抛错，返回 false');
      expect(confirmCalls, 1, reason: '拒绝路径恰好确认一次');
      expect(ensureCalls, 0, reason: '拒绝发生在 ensure 之前');

      await expectLater(
        engine.capabilities(),
        throwsA(isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          '本地推理模块不可用（gstore_mod_llm 未安装或加载失败）',
        )),
        reason: '_call 在不可用时沿用既有 StateError 文案',
      );
      expect(confirmCalls, 2, reason: '后续 _call 会重新询问（无 _tried 粘滞锁）');
      expect(ensureCalls, 0, reason: '再次拒绝仍不触发 ensure');

      // 之后用户接受：同一引擎仍可安装（未被永久禁用）。
      accepted = true;
      expect(await engine.ensureReady(), isTrue, reason: '后续接受仍可安装');
      expect(confirmCalls, 3, reason: '接受路径重新询问');
      expect(ensureCalls, 1, reason: '接受后完成一次 ensure');
      expect(handle.createCalls, 1, reason: '接受后才创建实例');

      final caps = await engine.capabilities();
      expect(caps['ok'], isTrue, reason: '安装后 _call 成功');
      expect(confirmCalls, 3, reason: '安装成功后不再确认');
    });
  });
}

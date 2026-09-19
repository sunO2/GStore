import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/rust/generated/contract/envelope.pb.dart'
    show EnvelopeResponse, StatusCode;

/// 伪造的宿主模块句柄。
///
/// 仅通过 `debugConfigure` 接缝注入，句柄只用于 `callEnvelope` 的受控返回；
/// 其余成员经 [noSuchMethod] 透传，**不触碰 FFI**。
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

/// 伪造的模块实例：仅用于身份断言，不调用任何实例方法。
class _FakeInstance implements RustModuleInstance {
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
  final bootstrap = ModuleBootstrap.instance;

  /// 统计自愈成功日志条数（`appLog.clear()` 后的增量）。
  int healLogCount() => appLog.logs
      .where((l) => l.message.contains('after MODULE_NOT_FOUND'))
      .length;

  setUp(() {
    manager.debugReset();
    bootstrap.debugReset();
    appLog.clear();
  });

  tearDown(() {
    manager.debugReset();
    bootstrap.debugReset();
  });

  group('todo 9 - 句柄复用 + 无重复加载日志', () {
    test('seed 命中缓存：自愈仅一次加载、恰好一条成功日志', () async {
      const module = 'analyzer';
      final payload = Uint8List.fromList(<int>[7, 8, 9]);
      final handle = _FakeModuleHandle(_okEnvelopeBytes(payload));

      var loadCalls = 0;
      var ensureCalls = 0;

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
          // 模拟 ensure 挂载把句柄写入真实缓存。
          manager.debugSeedHandle(name, handle);
          return true;
        },
      );

      final result = await manager.callModule(module, null, 'ping', Uint8List(0));
      expect(result, payload, reason: '自愈成功后返回解包 payload');
      expect(loadCalls, 1, reason: 'seed 命中缓存：不得二次加载');
      expect(ensureCalls, 1, reason: '仅触发一次 ensure');
      expect(healLogCount(), 1, reason: '成功自愈恰好记录一条日志');

      final again = await manager.callModule(module, null, 'ping', Uint8List(0));
      expect(again, payload);
      expect(loadCalls, 1, reason: '第二次调用命中缓存：零宿主加载');
      expect(ensureCalls, 1, reason: '第二次调用命中缓存：零 ensure');
      expect(healLogCount(), 1, reason: '缓存命中不重复记录自愈日志');
    });

    test('ensure 未 seed：至多一次重载，成功日志仍恰好一条', () async {
      const module = 'download';
      final payload = Uint8List.fromList(<int>[4, 5, 6]);
      final handle = _FakeModuleHandle(_okEnvelopeBytes(payload));

      var loadCalls = 0;
      var ensureCalls = 0;

      manager.debugConfigure(
        readyOverride: () async {},
        loadModuleOverride: (String name) async {
          loadCalls++;
          if (loadCalls == 1) {
            throw '[404] MODULE_NOT_FOUND: module not found: $name';
          }
          return handle;
        },
        ensureOverride: (
          String name, {
          bool? allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          ensureCalls++;
          // 本用例 ensure 不写缓存，迫使调用方重载一次（且仅一次）。
          return true;
        },
      );

      final result = await manager.callModule(module, null, 'ping', Uint8List(0));
      expect(result, payload);
      expect(loadCalls, 2, reason: '未 seed 时最多再加载一次（无循环）');
      expect(ensureCalls, 1);
      expect(healLogCount(), 1, reason: '成功自愈恰好记录一条日志');

      final again = await manager.callModule(module, null, 'ping', Uint8List(0));
      expect(again, payload);
      expect(loadCalls, 2, reason: '第二次调用命中缓存：零宿主加载');
      expect(ensureCalls, 1);
      expect(healLogCount(), 1);
    });

    test('ensure 返回 false：仅一次尝试、重抛原始错误、零成功日志', () async {
      const module = 'repo';
      var loadCalls = 0;
      var ensureCalls = 0;

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
        manager.callModule(module, null, 'ping', Uint8List(0)),
        throwsA(contains('MODULE_NOT_FOUND')),
      );
      expect(ensureCalls, 1, reason: '补装失败只尝试一次，无循环重试');
      expect(loadCalls, 1, reason: '补装失败不得二次加载');
      expect(healLogCount(), 0, reason: '自愈失败不得记录成功日志');
    });
  });

  group('todo 10 - 未挂载 auto 模块经 callModule 安装后成功', () {
    test('qr happy：一次 ensureOnly、至多一次重载、返回 payload 并缓存', () async {
      const module = 'qr';
      final payload = Uint8List.fromList(<int>[11, 22, 33]);
      final handle = _FakeModuleHandle(_okEnvelopeBytes(payload));

      var ensureCalls = 0;
      var loadCalls = 0;

      // 生产路径不在 manager 侧覆盖 ensure，从而真正走
      // ModuleBootstrap.instance.ensureOnly（门接缝）。
      manager.debugConfigure(
        readyOverride: () async {},
        loadModuleOverride: (String name) async {
          loadCalls++;
          throw '[404] MODULE_NOT_FOUND: module not found: $name';
        },
      );
      bootstrap.debugConfigure(
        ensureOverride: (
          String name, {
          required bool allowDownload,
          ModuleProgressCallback? onProgress,
        }) async {
          ensureCalls++;
          // 模拟 ensure 挂载写入真实句柄缓存。
          manager.debugSeedHandle(name, handle);
          return true;
        },
      );

      final result =
          await manager.callModule(module, null, 'decode', Uint8List(0));
      expect(result, payload, reason: '自愈后应完成原调用并返回解码 payload');
      expect(ensureCalls, 1, reason: '一次 ensureOnly(qr)');
      expect(loadCalls, 1, reason: 'happy 路径宿主只被请求加载一次');

      final second =
          await manager.callModule(module, null, 'decode', Uint8List(0));
      expect(second, payload);
      expect(ensureCalls, 1, reason: '模块已缓存：不得二次 ensure');
      expect(loadCalls, 1, reason: '宿主不得被要求二次加载');
    });

    test('qr failure：ensure 失败重抛原始错误，仅一次 ensure 尝试', () async {
      const module = 'repo';
      var ensureCalls = 0;
      var loadCalls = 0;

      manager.debugConfigure(
        readyOverride: () async {},
        loadModuleOverride: (String name) async {
          loadCalls++;
          throw '[404] MODULE_NOT_FOUND: module not found: $name';
        },
      );
      bootstrap.debugConfigure(
        ensureOverride: (
          String name, {
          required bool allowDownload,
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
      expect(ensureCalls, 1, reason: '补装失败仅一次 ensure 尝试，无循环');
      expect(loadCalls, 1, reason: '补装失败重抛，不吞错、不二次加载');
      expect(healLogCount(), 0, reason: '失败不得记录成功自愈日志');
    });
  });
}

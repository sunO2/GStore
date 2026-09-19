import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleLoader.dart' show ModuleProgressCallback;
import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleInstance;
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:mockito/mockito.dart';

/// 安装确保回调（与 [ModuleBootstrap.debugConfigure] 的 `ensureOverride` 同型）。
typedef _EnsureFn = Future<bool> Function(
  String module, {
  required bool allowDownload,
  ModuleProgressCallback? onProgress,
});

/// 伪造的宿主模块句柄（本测不触碰 FFI，仅作 `loadOverride` 返回值）。
class _FakeModuleHandle extends Mock implements ModuleHandle {}

/// 伪造的模块实例（仅用于身份，不调用任何实例方法）。
class _FakeRustModuleInstance extends Mock implements RustModuleInstance {}

/// HIGH-1 / HIGH-2 回归：ensure 抛异常或永久挂起时，
/// 自举门必须 (a) 发布终态 `failed`（横幅据此隐藏），(b) 释放单飞条目，
/// 使后续调用重新尝试而非复用被污染的 future。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ModuleBootstrap bootstrap;
  late int ensureCalls;

  setUp(() {
    bootstrap = ModuleBootstrap.instance;
    bootstrap.debugReset();
    ensureCalls = 0;
  });

  tearDown(() {
    bootstrap.debugReset();
  });

  /// 注入全部测试接缝（无 FFI、无网络）：ensure 计数、假句柄/工厂、
  /// 零延迟退避、可选短步骤超时。
  void configure({
    required _EnsureFn ensure,
    Duration? stepTimeout,
  }) {
    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) {
        ensureCalls++;
        return ensure(
          module,
          allowDownload: allowDownload,
          onProgress: onProgress,
        );
      },
      loadOverride: (String module) async => _FakeModuleHandle(),
      factoryOverride: (ModuleHandle handle) async => _FakeRustModuleInstance(),
      delayOverride: (Duration duration) async {},
      stepTimeout: stepTimeout,
    );
  }

  test(
    'throwing ensure emits terminal failed and later calls can retry',
    () async {
      final boom = StateError('boom: ensure exploded');
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => throw boom,
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      ModuleInstallFailedException? firstFailure;
      try {
        await bootstrap.acquire('x', maxAttempts: 1);
        fail('ensure 抛异常时 acquire 必须失败');
      } on ModuleInstallFailedException catch (error) {
        firstFailure = error;
      }
      await pumpEventQueue();

      // 终态：failed，且携带**原始**异常（cause 不丢失）。
      expect(firstFailure, isNotNull);
      expect(firstFailure!.cause, same(boom));
      expect(states.last.phase, ModuleBootstrapPhase.failed,
          reason: '抛异常路径也必须发布终态 failed（横幅不再 downloading）');
      expect(states.last.error, same(boom), reason: 'failed 状态必须保留原始错误对象');

      // 单飞条目必须被释放（异常路径不得留下永久在途）。
      expect(bootstrap.debugEnsureInFlightCount, 0, reason: 'ensure 单飞条目应被清理');
      expect(bootstrap.debugInstanceInFlightCount, 0,
          reason: 'instance 单飞条目应被清理');
      expect(ensureCalls, 1);

      // 后续 acquire 重新发起 ensure，而不是复用被污染的失败 future。
      ModuleInstallFailedException? secondFailure;
      try {
        await bootstrap.acquire('x', maxAttempts: 1);
        fail('再次 acquire 仍应失败（ensure 仍抛异常）');
      } on ModuleInstallFailedException catch (error) {
        secondFailure = error;
      }
      await pumpEventQueue();

      expect(secondFailure, isNotNull);
      expect(ensureCalls, 2, reason: '单飞已释放：新的 acquire 重新发起 ensure');

      await sub.cancel();
    },
  );

  test(
    'hung ensure times out into failed and frees the single-flight',
    () async {
      // 永不完成的 ensure：模拟网络/FFI 永久挂起。
      final never = Completer<bool>();
      configure(
        ensure: (m, {required bool allowDownload, onProgress}) => never.future,
        stepTimeout: const Duration(milliseconds: 30),
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      final stopwatch = Stopwatch()..start();
      ModuleInstallFailedException? failure;
      try {
        await bootstrap.acquire('x', maxAttempts: 1);
        fail('ensure 挂起时 acquire 必须因超时而失败');
      } on ModuleInstallFailedException catch (error) {
        failure = error;
      }
      stopwatch.stop();
      await pumpEventQueue();

      expect(failure, isNotNull);
      expect(failure!.cause, isA<TimeoutException>(),
          reason: '超时后的 cause 应为 TimeoutException');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: '必须在短超时内终止，而非永久挂起');

      // 终态 failed（横幅据此隐藏，绝不停留在 downloading）。
      expect(
        states.any((s) => s.phase == ModuleBootstrapPhase.failed),
        isTrue,
        reason: '超时路径必须发布终态 failed',
      );
      expect(states.last.phase, ModuleBootstrapPhase.failed);

      // 单飞条目必须被释放，否则后续调用会被永久污染。
      expect(bootstrap.debugEnsureInFlightCount, 0,
          reason: '超时后 ensure 单飞条目应被释放');
      expect(bootstrap.debugInstanceInFlightCount, 0,
          reason: '超时后 instance 单飞条目应被释放');
      expect(ensureCalls, 1);

      // 下一次调用重新发起 ensure（短超时后返回 false），而不是永久挂起。
      final retried = await bootstrap.ensureOnly('x');
      expect(retried, isFalse, reason: 'ensure 仍挂起，但重新发起后应在超时内返回 false');
      expect(ensureCalls, 2, reason: '超时释放单飞后应允许重试');

      await sub.cancel();
    },
  );
}

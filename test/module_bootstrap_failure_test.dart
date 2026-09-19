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

      // 下一次调用复用仍在途的孤儿底层 ensure（`timeout` 不取消底层），
      // 在已耗尽的整体期限内立即返回 false——不再新起第二个并发安装。
      final retried = await bootstrap.ensureOnly('x');
      expect(retried, isFalse, reason: 'ensure 仍挂起，但重试应在期限内返回 false');
      expect(ensureCalls, 1, reason: '重试复用孤儿底层 ensure，不得再次调用 ensureModule');

      await sub.cancel();
    },
  );

  test(
    'late progress after a timed-out ensure does not revive the downloading state',
    () async {
      // 捕获底层 ensure 的进度回调；ensure 本身永不完成（模拟超时后仍在跑的孤儿）。
      ModuleProgressCallback? capturedProgress;
      final never = Completer<bool>();
      configure(
        ensure: (m, {required allowDownload, onProgress}) {
          capturedProgress = onProgress;
          return never.future;
        },
        stepTimeout: const Duration(milliseconds: 30),
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      await expectLater(
        bootstrap.acquire('x', maxAttempts: 1),
        throwsA(isA<ModuleInstallFailedException>()),
      );
      await pumpEventQueue();

      expect(states.last.phase, ModuleBootstrapPhase.failed,
          reason: '超时必须先发布终态 failed');
      expect(capturedProgress, isNotNull, reason: 'ensure 应收到进度回调以模拟晚到进度');

      // 模拟底层 ensure 在超时后仍继续推进：晚到进度绝不能复活 downloading。
      capturedProgress!(0.4);
      capturedProgress!(0.8);
      await pumpEventQueue();

      expect(states.last.phase, isNot(ModuleBootstrapPhase.downloading),
          reason: '同一尝试终结后的晚到进度必须被丢弃');
      expect(states.last.phase, ModuleBootstrapPhase.failed,
          reason: '状态应停留在终态 failed');
      expect(
        states.where((s) =>
            s.phase == ModuleBootstrapPhase.downloading && s.progress != null),
        isEmpty,
        reason: '超时终态之后不得再发布任何带进度的 downloading 状态',
      );

      await sub.cancel();
    },
  );

  test(
    'concurrent ensureOnly calls share one in-deadline attempt and do not duplicate installs',
    () async {
      // 期限内：即使底层 ensure 尚未完成，两个并发调用也必须共享同一个单飞 future，
      // 只调用一次 ensureModule（不得并发重复安装）。
      final never = Completer<bool>();
      configure(
        ensure: (m, {required allowDownload, onProgress}) => never.future,
        stepTimeout: const Duration(seconds: 5),
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      final first = bootstrap.ensureOnly('x');
      await pumpEventQueue();
      final second = bootstrap.ensureOnly('x');
      await pumpEventQueue();

      expect(ensureCalls, 1, reason: '期限内并发调用共享同一次底层安装，不得重复');
      expect(bootstrap.debugEnsureInFlightCount, 1, reason: '期限内单飞条目应保持在途');

      never.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      await pumpEventQueue();
      expect(bootstrap.debugEnsureInFlightCount, 0);
      expect(bootstrap.debugPendingEnsureCount, 0, reason: '完成的底层尝试应从在途表中移除');

      await sub.cancel();
    },
  );

  test(
    'abandoned orphan that succeeds without an intervening retry reconciles to ready',
    () async {
      // 永不完成的 ensure：孤儿在超时后仍挂在 _pendingEnsure 中。
      final never = Completer<bool>();
      configure(
        ensure: (m, {required allowDownload, onProgress}) => never.future,
        stepTimeout: const Duration(milliseconds: 30),
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      await expectLater(
        bootstrap.acquire('x', maxAttempts: 1),
        throwsA(isA<ModuleInstallFailedException>()),
      );
      await pumpEventQueue();
      expect(ensureCalls, 1, reason: '首次尝试恰好调用一次底层 ensure');
      expect(bootstrap.debugPendingEnsureCount, 1,
          reason: '超时后孤儿底层 ensure 应仍被保留');
      expect(bootstrap.debugEnsureInFlightCount, 0);

      // 中间**没有**任何重试：孤儿稍后真正成功 → 显式对账为 ready。
      never.complete(true);
      await pumpEventQueue();
      expect(states.last.phase, ModuleBootstrapPhase.ready,
          reason: '无人 await 的孤儿稍后成功时必须对账为 ready');
      expect(bootstrap.debugPendingEnsureCount, 0, reason: '完成的底层尝试应从在途表中移除');

      await sub.cancel();
    },
  );

  test(
    'expired hung ensure is evicted and a later call starts a fresh attempt',
    () async {
      // 捕获每次底层尝试的进度回调；每次尝试各自一个永不完成的 future。
      final callbacks = <ModuleProgressCallback?>[];
      configure(
        ensure: (m, {required allowDownload, onProgress}) {
          callbacks.add(onProgress);
          return Completer<bool>().future;
        },
        stepTimeout: const Duration(milliseconds: 30),
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      // 第一次：永不完成 → 整体期限超时 → 孤儿留在 _pendingEnsure 中。
      await expectLater(
        bootstrap.acquire('x', maxAttempts: 1),
        throwsA(isA<ModuleInstallFailedException>()),
      );
      await pumpEventQueue();
      expect(ensureCalls, 1, reason: '首次尝试调用一次底层 ensure');
      expect(bootstrap.debugPendingEnsureCount, 1);
      expect(callbacks.length, 1);

      // 等到整体期限确实过期。
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // 再次调用：必须驱逐过期孤儿并重新发起底层安装（而非即时失败）。
      final retried = bootstrap.ensureOnly('x');
      await pumpEventQueue();
      expect(ensureCalls, 2, reason: '过期的挂起孤儿必须被驱逐并重新调用 ensureModule');
      expect(bootstrap.debugPendingEnsureCount, 1, reason: '新的底层尝试取代被驱逐的过期孤儿');
      expect(callbacks.length, 2, reason: '新尝试应重新注册进度回调');

      // 过期孤儿（第 0 次尝试）的晚到进度必须被丢弃；新尝试的进度正常发布。
      final before = states.length;
      callbacks[0]!(0.9);
      await pumpEventQueue();
      expect(
        states.skip(before).where((s) => s.progress == 0.9),
        isEmpty,
        reason: '被驱逐孤儿的晚到进度不得覆盖新尝试状态',
      );

      callbacks[1]!(0.2);
      await pumpEventQueue();
      expect(
        states.skip(before).any((s) =>
            s.phase == ModuleBootstrapPhase.downloading && s.progress == 0.2),
        isTrue,
        reason: '新尝试的进度应正常发布',
      );

      // 新尝试同样在期限内超时并返回 false（关键：不是即时失败）。
      expect(await retried, isFalse);

      await sub.cancel();
    },
  );

  test(
    'hung confirm handler times out and frees the single-flight',
    () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        stepTimeout: const Duration(milliseconds: 30),
      );
      // 注入一个永不返回的确认处理器。
      final neverConfirm = Completer<bool>();
      bootstrap.setConfirmHandler((m) => neverConfirm.future);

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      final stopwatch = Stopwatch()..start();
      final accepted = await bootstrap.ensureOnly(
        'x',
        policy: ModuleInstallPolicy.confirm,
      );
      stopwatch.stop();

      expect(accepted, isFalse, reason: '确认处理器挂起应按未接受处理（失败）');
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
          reason: '确认等待必须有界，不得永久挂起');
      expect(states.last.phase, ModuleBootstrapPhase.failed,
          reason: '确认超时必须发布终态 failed');
      expect(ensureCalls, 0, reason: '确认未通过不得触发 ensureModule');
      expect(bootstrap.debugEnsureInFlightCount, 0,
          reason: '确认超时必须释放单飞条目（不得永久污染）');
      expect(bootstrap.debugInstanceInFlightCount, 0);

      // 后续调用不被污染：换成接受的处理器即可正常安装。
      bootstrap.setConfirmHandler((m) async => true);
      expect(
        await bootstrap.ensureOnly('x', policy: ModuleInstallPolicy.confirm),
        isTrue,
        reason: '释放后的单飞应允许后续调用重新确认并安装',
      );
      expect(ensureCalls, 1);

      await sub.cancel();
    },
  );

  test(
    'late progress after a successful install does not revive downloading',
    () async {
      ModuleProgressCallback? capturedProgress;
      final completer = Completer<bool>();
      configure(
        ensure: (m, {required allowDownload, onProgress}) {
          capturedProgress = onProgress;
          return completer.future;
        },
        stepTimeout: const Duration(seconds: 5),
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      final ensured = bootstrap.ensureOnly('x');
      await pumpEventQueue();
      expect(capturedProgress, isNotNull);

      capturedProgress!(0.5);
      await pumpEventQueue();
      expect(states.last.phase, ModuleBootstrapPhase.downloading);
      expect(states.last.progress, 0.5);

      completer.complete(true);
      expect(await ensured, isTrue);
      await pumpEventQueue();

      // 安装成功后的晚到进度绝不能复活 downloading / 推进进度。
      capturedProgress!(0.9);
      await pumpEventQueue();
      expect(
        states.any((s) => s.progress == 0.9),
        isFalse,
        reason: '成功终态后的晚到进度必须被丢弃',
      );
      expect(states.last.progress, 0.5, reason: '最后发布的进度应停留在成功前的那次');

      await sub.cancel();
    },
  );
}

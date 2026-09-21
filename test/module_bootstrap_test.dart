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

/// 伪造的宿主模块句柄。
///
/// 本测试全程经 [ModuleBootstrap.debugConfigure] 注入接缝，句柄只被
/// `loadOverride` 原样返回、从不调用其任何宿主方法；因此 `Mock` 的无实现
/// 透传即可，**不触碰 FFI**。
class _FakeModuleHandle extends Mock implements ModuleHandle {}

/// 伪造的模块实例：仅用于身份/计数断言，不调用任何实例方法。
class _FakeRustModuleInstance extends Mock implements RustModuleInstance {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ModuleBootstrap bootstrap;
  late int ensureCalls;
  late int factoryCalls;
  late List<String> ensureModules;
  late List<Duration> delays;

  setUp(() {
    bootstrap = ModuleBootstrap.instance;
    bootstrap.debugReset();
    ensureCalls = 0;
    factoryCalls = 0;
    ensureModules = <String>[];
    delays = <Duration>[];
  });

  tearDown(() {
    bootstrap.debugReset();
  });

  /// 注入全部测试接缝（无 FFI、无网络）：ensure/factory 计数、假句柄、
  /// 退避记录、确认处理器。
  void configure({
    required _EnsureFn ensure,
    Future<bool> Function(String module)? confirm,
    Future<void> Function(Duration duration)? delay,
  }) {
    bootstrap.debugConfigure(
      ensureOverride: (
        String module, {
        required bool allowDownload,
        ModuleProgressCallback? onProgress,
      }) {
        ensureCalls++;
        ensureModules.add(module);
        return ensure(
          module,
          allowDownload: allowDownload,
          onProgress: onProgress,
        );
      },
      loadOverride: (String module) async => _FakeModuleHandle(),
      factoryOverride: (ModuleHandle handle) async {
        factoryCalls++;
        return _FakeRustModuleInstance();
      },
      delayOverride: delay ??
          (Duration duration) async {
            delays.add(duration);
          },
      confirmHandler: confirm,
    );
  }

  group('two-level-single-flight', () {
    test('(a) 并发 acquire 同 key：1 次 ensure + 1 次 factory，同一实例', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final first = bootstrap.acquire('x');
      final second = bootstrap.acquire('x');
      final a = await first;
      final b = await second;

      expect(ensureCalls, 1, reason: '两个调用应共享同一次模块确保');
      expect(factoryCalls, 1, reason: '两个调用应共享同一次实例创建');
      expect(identical(a, b), isTrue, reason: '应返回同一实例');
    });

    test('(b) 并发 acquire 不同 instanceKey：1 次 ensure + 2 次 factory，实例不同', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final first = bootstrap.acquire('x', instanceKey: 'k1');
      final second = bootstrap.acquire('x', instanceKey: 'k2');
      final a = await first;
      final b = await second;

      expect(ensureCalls, 1, reason: 'ensure 只按模块去重（与 instanceKey 无关）');
      expect(factoryCalls, 2, reason: '不同 instanceKey 各创建一次实例');
      expect(identical(a, b), isFalse, reason: '不同 key 应为不同实例');
    });

    test('(c) 并发 acquire 不同模块：2 次 ensure', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final results = await Future.wait(<Future<RustModuleInstance>>[
        bootstrap.acquire('x'),
        bootstrap.acquire('y'),
      ]);

      expect(results.length, 2);
      expect(ensureCalls, 2, reason: '不同模块各自 ensure 一次');
      expect(ensureModules.toSet(), <String>{'x', 'y'});
      expect(factoryCalls, 2);
    });

    test('(d) 完成后再 acquire：零新增 ensure/factory（命中缓存）', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final first = await bootstrap.acquire('x');
      expect(ensureCalls, 1);
      expect(factoryCalls, 1);

      final second = await bootstrap.acquire('x');
      expect(ensureCalls, 1, reason: '已缓存实例不应再次 ensure');
      expect(factoryCalls, 1, reason: '已缓存实例不应再次创建');
      expect(identical(first, second), isTrue);
    });

    test('(e) release 显式淘汰非默认键缓存，且不影响其他多源实例', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final a = await bootstrap.acquire('x', instanceKey: 'k1');
      final b = await bootstrap.acquire('x', instanceKey: 'k2');
      expect(bootstrap.debugInstanceCacheCount, 2);
      expect(identical(await bootstrap.acquire('x', instanceKey: 'k1'), a), isTrue,
          reason: '同键命中缓存');

      expect(bootstrap.release('x', instanceKey: 'k1'), isTrue,
          reason: '释放已缓存键应返回 true');
      expect(bootstrap.debugInstanceCacheCount, 1, reason: '仅移除 k1');
      expect(bootstrap.release('x', instanceKey: 'k1'), isFalse,
          reason: '重复释放无缓存应返回 false');

      // 释放后重新 acquire 会创建新实例；k2 不受影响且仍命中缓存。
      final a2 = await bootstrap.acquire('x', instanceKey: 'k1');
      expect(identical(a2, a), isFalse, reason: '释放后重新创建实例');
      expect(identical(await bootstrap.acquire('x', instanceKey: 'k2'), b), isTrue,
          reason: '释放 k1 不得影响 k2 的多源实例');
      expect(ensureCalls, 3,
          reason: '每次顺序 acquire 各自 ensure 一次（仅并发时按模块去重）');
      expect(factoryCalls, 3, reason: 'k1/k2 各一次 + 释放后 k1 重建一次');
    });
  });

  group('retry', () {
    test('(a) ensure 失败两次后成功：3 次 ensure，退避 [base, 2*base]，返回实例', () async {
      const base = Duration(milliseconds: 10);
      configure(
        ensure: (m, {required allowDownload, onProgress}) async =>
            ensureCalls >= 3,
      );

      final instance = await bootstrap.acquire('x', baseDelay: base);

      expect(instance, isNotNull, reason: '第 3 次尝试成功后应返回实例');
      expect(ensureCalls, 3, reason: '两次失败 + 一次成功 = 3 次 ensure');
      expect(
        delays,
        <Duration>[base, base * 2],
        reason: '退避 = baseDelay * 2^(attempt-1)',
      );
      expect(factoryCalls, 1);
    });

    test('(b) 全部尝试失败：3 次 ensure + ModuleInstallFailedException', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => false,
      );

      await expectLater(
        bootstrap.acquire('x', baseDelay: const Duration(milliseconds: 5)),
        throwsA(isA<ModuleInstallFailedException>()),
      );

      expect(ensureCalls, 3);
      expect(delays.length, 2, reason: '3 次尝试之间只有 2 次退避');
      expect(factoryCalls, 0, reason: 'ensure 从未成功，不应创建实例');
    });

    test('(c) 失败 settle 后新 acquire：重新 3 次尝试（不粘滞）', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => false,
      );

      await expectLater(
        bootstrap.acquire('x'),
        throwsA(isA<ModuleInstallFailedException>()),
      );
      expect(ensureCalls, 3, reason: '首次耗尽 3 次尝试后失败');

      await expectLater(
        bootstrap.acquire('x'),
        throwsA(isA<ModuleInstallFailedException>()),
      );
      expect(ensureCalls, 6, reason: '失败不缓存：新的 acquire 重新尝试 3 次');
    });

    test('(d) 失败在途期间加入的 acquire 共享同一失败，不新增尝试', () async {
      final gate = Completer<bool>();
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => gate.future,
      );

      final first = bootstrap.acquire('x');
      final second = bootstrap.acquire('x');
      expect(identical(first, second), isTrue, reason: '同 key 复用同一在途 future');
      expect(ensureCalls, 1, reason: '第二次 acquire 不触发新的 ensure');

      final joined1 = first.then<Object?>((v) => v, onError: (Object e) => e);
      final joined2 = second.then<Object?>((v) => v, onError: (Object e) => e);
      gate.complete(false);

      expect(await joined1, isA<ModuleInstallFailedException>());
      expect(await joined2, isA<ModuleInstallFailedException>());
      expect(ensureCalls, 3, reason: '总尝试次数仍为 3，join 者不新增尝试');
    });

    test('(e) 确认拒绝：不触发 ensure、不做任何退避', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async => false,
      );

      await expectLater(
        bootstrap.acquire('x', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<ModuleInstallDeclinedException>()),
      );

      expect(ensureCalls, 0, reason: '拒绝发生在 ensure 之前');
      expect(delays, isEmpty, reason: 'ModuleInstallDeclinedException 不进入退避');
    });
  });

  group('state-stream', () {
    test('(a) 进度注入 [0.05,0.7,1.0]：downloading 非递减 → initializing → ready', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async {
          onProgress?.call(0.05);
          onProgress?.call(0.7);
          onProgress?.call(1.0);
          return true;
        },
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      final instance = await bootstrap.acquire('x');
      await pumpEventQueue();
      await sub.cancel();

      expect(instance, isNotNull);

      final progress = states
          .where((s) => s.phase == ModuleBootstrapPhase.downloading)
          .where((s) => s.progress != null)
          .map((s) => s.progress!)
          .toList();
      expect(progress, <double>[0.05, 0.7, 1.0],
          reason: '每个 fraction 各发布一次 downloading 状态');
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i] >= progress[i - 1], isTrue,
            reason: '进度必须单调不减');
      }

      expect(
        states.map((s) => s.phase),
        containsAllInOrder(<ModuleBootstrapPhase>[
          ModuleBootstrapPhase.downloading,
          ModuleBootstrapPhase.initializing,
          ModuleBootstrapPhase.ready,
        ]),
      );
    });

    test('(a2) 乱序 fraction 被忽略：[0.05,0.7,0.3,1.0] → [0.05,0.7,1.0]', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async {
          onProgress?.call(0.05);
          onProgress?.call(0.7);
          onProgress?.call(0.3); // 回退：应被忽略
          onProgress?.call(1.0);
          return true;
        },
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      await bootstrap.acquire('x');
      await pumpEventQueue();
      await sub.cancel();

      final progress = states
          .where((s) => s.phase == ModuleBootstrapPhase.downloading)
          .where((s) => s.progress != null)
          .map((s) => s.progress!)
          .toList();
      expect(progress, <double>[0.05, 0.7, 1.0],
          reason: '小于上次已发布值的 fraction 必须被丢弃');
    });

    test('(b) ensure 失败：最后状态为 failed(error != null)，从未 ready', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => false,
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      await expectLater(
        bootstrap.acquire('x', baseDelay: const Duration(milliseconds: 5)),
        throwsA(isA<ModuleInstallFailedException>()),
      );
      await pumpEventQueue();
      await sub.cancel();

      expect(states.any((s) => s.phase == ModuleBootstrapPhase.ready), isFalse,
          reason: '失败过程绝不能发布 ready');
      expect(states.last.phase, ModuleBootstrapPhase.failed);
      expect(states.last.error, isNotNull,
          reason: 'failed 状态必须携带非空错误');

      final snapshot = await bootstrap.states.first;
      final entry = snapshot.firstWhere((s) => s.module == 'x');
      expect(entry.phase, ModuleBootstrapPhase.failed);
      expect(entry.error, isNotNull);
    });

    test('(c) watch 已 ready 缓存模块：立即收到 ready', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );
      await bootstrap.acquire('x');

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();
      await sub.cancel();

      expect(states, isNotEmpty, reason: 'watch 应先发布缓存状态');
      expect(states.first.phase, ModuleBootstrapPhase.ready);
    });

    test('(d) states 每模块仅聚合一条最新状态', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );
      await Future.wait(<Future<RustModuleInstance>>[
        bootstrap.acquire('x'),
        bootstrap.acquire('y'),
      ]);

      final snapshot = await bootstrap.states.first;
      expect(snapshot.map((s) => s.module).toList(), <String>['x', 'y']);
      expect(snapshot.where((s) => s.module == 'x').length, 1);
      expect(snapshot.where((s) => s.module == 'y').length, 1);
      expect(
        snapshot.every((s) => s.phase == ModuleBootstrapPhase.ready),
        isTrue,
      );
    });

    test('(e) 不同模块互不串流', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final xStates = <ModuleBootstrapState>[];
      final yStates = <ModuleBootstrapState>[];
      final xSub = bootstrap.watch('x').listen(xStates.add);
      final ySub = bootstrap.watch('y').listen(yStates.add);
      await pumpEventQueue();

      await Future.wait(<Future<RustModuleInstance>>[
        bootstrap.acquire('x'),
        bootstrap.acquire('y'),
      ]);
      await pumpEventQueue();
      await xSub.cancel();
      await ySub.cancel();

      expect(xStates, isNotEmpty);
      expect(yStates, isNotEmpty);
      expect(xStates.every((s) => s.module == 'x'), isTrue,
          reason: 'watch(x) 只会发出 x 的状态');
      expect(yStates.every((s) => s.module == 'y'), isTrue,
          reason: 'watch(y) 只会发出 y 的状态');
    });

    test('(f) 订阅后立即发布的状态不被丢弃（缓存交付即触发发布）', () async {
      // 先制造一个缓存状态：让 x 安装失败（failed 写入 _lastStates）。
      configure(
        ensure: (m, {required bool allowDownload, onProgress}) async => false,
      );
      await expectLater(
        bootstrap.acquire('x',
            maxAttempts: 1, baseDelay: const Duration(milliseconds: 1)),
        throwsA(isA<ModuleInstallFailedException>()),
      );
      await pumpEventQueue();

      final received = <ModuleBootstrapState>[];
      var triggered = false;
      final sub = bootstrap.watch('x').listen((state) {
        received.add(state);
        if (!triggered && state.phase == ModuleBootstrapPhase.failed) {
          // 在**缓存状态刚交付**的同一刻发布一次新状态（downloading）。
          // 旧的 `async*` 实现在交付缓存后、订阅广播流前会让出事件循环，
          // 此刻发布的状态会被永久丢弃。
          triggered = true;
          bootstrap.ensureStarted('x');
        }
      });
      await pumpEventQueue();
      await sub.cancel();

      expect(
        received.any((s) => s.phase == ModuleBootstrapPhase.downloading),
        isTrue,
        reason: 'watch 订阅后立即发布的状态绝不能被丢弃',
      );
    });

    test('(g) states 订阅后立即发布的快照不丢失（快照交付即触发发布）', () async {
      configure(
        ensure: (m, {required bool allowDownload, onProgress}) async => false,
      );
      await expectLater(
        bootstrap.acquire('x',
            maxAttempts: 1, baseDelay: const Duration(milliseconds: 1)),
        throwsA(isA<ModuleInstallFailedException>()),
      );
      await pumpEventQueue();

      final snapshots = <List<ModuleBootstrapState>>[];
      var triggered = false;
      final sub = bootstrap.states.listen((list) {
        snapshots.add(list);
        final hasFailed = list.any(
            (s) => s.module == 'x' && s.phase == ModuleBootstrapPhase.failed);
        if (!triggered && hasFailed) {
          // 在首个快照刚交付的同一刻发布一次新状态（downloading）。
          triggered = true;
          bootstrap.ensureStarted('x');
        }
      });
      await pumpEventQueue();
      await sub.cancel();

      expect(
        snapshots.any((list) => list.any((s) =>
            s.module == 'x' && s.phase == ModuleBootstrapPhase.downloading)),
        isTrue,
        reason: 'states 订阅后立即发布的快照必须可见，不得被竞态丢弃',
      );
    });

    test('(h) 已缓存实例后 ensureStarted：保持 ready 且零新增 ensure/实例', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );
      await bootstrap.acquire('x');
      expect(ensureCalls, 1);
      expect(factoryCalls, 1);

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('x').listen(states.add);
      await pumpEventQueue();

      bootstrap.ensureStarted('x');
      await pumpEventQueue();
      await sub.cancel();

      expect(states.last.phase, ModuleBootstrapPhase.ready,
          reason: '已缓存实例的 ensureStarted 必须保持 ready，不得停在 downloading');
      expect(
        states.any((s) => s.phase == ModuleBootstrapPhase.downloading),
        isFalse,
        reason: '已缓存实例不得再发布 downloading',
      );
      expect(ensureCalls, 1, reason: '已缓存实例不得再次 ensure');
      expect(factoryCalls, 1, reason: '已缓存实例不得再次创建实例');
    });

    test('(i) 有缓存实例时 ensureOnly 成功绝不残留 downloading（不变量）', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );
      await bootstrap.acquire('x');
      expect(ensureCalls, 1);

      final ok = await bootstrap.ensureOnly('x');
      await pumpEventQueue();

      expect(ok, isTrue);
      final snapshot = await bootstrap.states.first;
      final entry = snapshot.firstWhere((s) => s.module == 'x');
      expect(entry.phase, ModuleBootstrapPhase.ready,
          reason: '有缓存实例时 ensureOnly 成功必须收敛到 ready，绝不残留 downloading');
      expect(ensureCalls, 1, reason: '有缓存实例时 ensureOnly 不得新增 ensure');
      expect(factoryCalls, 1, reason: 'ensureOnly 不创建实例');
    });
  });

  group('helpers', () {
    test('(a) 并发 run：factory 一次，任务体各执行一次且共享同一实例', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final seen = <RustModuleInstance>[];
      Future<int> task(RustModuleInstance instance) async {
        seen.add(instance);
        return seen.length;
      }

      final results = await Future.wait(<Future<int>>[
        bootstrap.run<int>('x', task),
        bootstrap.run<int>('x', task),
      ]);

      expect(results.length, 2);
      expect(factoryCalls, 1, reason: '并发 run 共享同一次实例创建');
      expect(seen.length, 2, reason: '每个 run 各执行一次任务体');
      expect(identical(seen[0], seen[1]), isTrue, reason: '任务体共享同一实例');
    });

    test('(b) 获取失败：任务体 0 次且 ModuleInstallFailedException 传播', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => false,
      );

      var taskCalls = 0;
      await expectLater(
        bootstrap.run<int>('x', (instance) async {
          taskCalls++;
          return 1;
        }),
        throwsA(isA<ModuleInstallFailedException>()),
      );
      expect(taskCalls, 0, reason: '获取失败时任务体绝不执行');
    });

    test('(c) ensureStarted 立即返回且仅触发一次 ensure', () async {
      final gate = Completer<bool>();
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => gate.future,
      );

      final stopwatch = Stopwatch()..start();
      bootstrap.ensureStarted('x');
      bootstrap.ensureStarted('x');
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(100), reason: '立即返回');
      expect(ensureCalls, 1, reason: '重复触发被单飞去重');

      gate.complete(true);
      await pumpEventQueue();
    });

    test('(d) ensureOnly 返回 bool 且不创建实例', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      final ok = await bootstrap.ensureOnly('x');

      expect(ok, isTrue);
      expect(ensureCalls, 1);
      expect(factoryCalls, 0, reason: 'ensureOnly 不创建实例');
    });

    test('(e) prepareExisting 传 allowDownload=false 且不下载', () async {
      final allowFlags = <bool>[];
      configure(
        ensure: (m, {required allowDownload, onProgress}) async {
          allowFlags.add(allowDownload);
          return false; // 无本地/内置产物
        },
      );

      final ok = await bootstrap.prepareExisting('repo');

      expect(ok, isFalse);
      expect(allowFlags, <bool>[false],
          reason: 'prepareExisting 必须以 allowDownload=false 调用 ensure');
      expect(factoryCalls, 0);
    });
  });

  group('confirm-policy', () {
    test('(a) 拒绝：ensure 0 次 + ModuleInstallDeclinedException', () async {
      var handlerCalls = 0;
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          handlerCalls++;
          return false;
        },
      );

      await expectLater(
        bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<ModuleInstallDeclinedException>()),
      );
      expect(handlerCalls, 1);
      expect(ensureCalls, 0, reason: '拒绝发生在 ensure 之前');
    });

    test('(b) 接受：先 ensure 再 ready', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async => true,
      );

      final states = <ModuleBootstrapState>[];
      final sub = bootstrap.watch('llm').listen(states.add);
      await pumpEventQueue();

      final instance =
          await bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm);
      await pumpEventQueue();
      await sub.cancel();

      expect(instance, isNotNull);
      expect(ensureCalls, 1);
      expect(
        states.map((s) => s.phase),
        containsAllInOrder(<ModuleBootstrapPhase>[
          ModuleBootstrapPhase.downloading,
          ModuleBootstrapPhase.initializing,
          ModuleBootstrapPhase.ready,
        ]),
      );
    });

    test('(c) 接受后再次 acquire：不再调用确认处理器', () async {
      var handlerCalls = 0;
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          handlerCalls++;
          return true;
        },
      );

      await bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm);
      expect(handlerCalls, 1);

      await bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm);
      expect(handlerCalls, 1, reason: '已缓存实例不再确认');
      expect(ensureCalls, 1);
    });

    test('(d) 未注册处理器：StateError 且不 ensure', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
      );

      await expectLater(
        bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<StateError>()),
      );
      expect(ensureCalls, 0, reason: '无处理器时绝不静默自动安装');
    });

    test('(e) 处理器抛错：视为拒绝（不 ensure、不崩溃）', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          throw StateError('boom');
        },
      );

      await expectLater(
        bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<ModuleInstallDeclinedException>()),
      );
      expect(ensureCalls, 0);
    });

    test('(e2) 处理器抛错：原始错误作为拒绝 cause 保留（不与用户拒绝混淆）', () async {
      final boom = StateError('boom: confirm handler exploded');
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async => throw boom,
      );

      ModuleInstallDeclinedException? failure;
      try {
        await bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm);
        fail('确认处理器抛错时应抛出 ModuleInstallDeclinedException');
      } on ModuleInstallDeclinedException catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(failure!.cause, same(boom),
          reason: '处理器异常的原始错误必须作为拒绝 cause 保留，便于诊断');
      expect(ensureCalls, 0, reason: '处理器异常按拒绝处理，不触发 ensure');
      expect(delays, isEmpty, reason: '处理器异常按拒绝处理，零退避');
    });

    test('(e3) 用户主动拒绝：cause 为空（与处理器异常可区分）', () async {
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async => false,
      );

      ModuleInstallDeclinedException? failure;
      try {
        await bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm);
        fail('用户拒绝时应抛出 ModuleInstallDeclinedException');
      } on ModuleInstallDeclinedException catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(failure!.cause, isNull, reason: '纯用户拒绝不应携带 cause');
      expect(ensureCalls, 0);
      expect(delays, isEmpty);
    });

    test('(f) policyFor：llm=confirm，其余=auto', () {
      expect(bootstrap.policyFor('llm'), ModuleInstallPolicy.confirm);
      for (final module in <String>[
        'qr',
        'analyzer',
        'repo',
        'download',
        'unknown',
      ]) {
        expect(
          bootstrap.policyFor(module),
          ModuleInstallPolicy.auto,
          reason: module,
        );
      }
    });

    test('(g) 拒绝不缓存：再次 acquire 会重新询问', () async {
      var handlerCalls = 0;
      configure(
        ensure: (m, {required allowDownload, onProgress}) async => true,
        confirm: (m) async {
          handlerCalls++;
          return false;
        },
      );

      await expectLater(
        bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<ModuleInstallDeclinedException>()),
      );
      await expectLater(
        bootstrap.acquire('llm', policy: ModuleInstallPolicy.confirm),
        throwsA(isA<ModuleInstallDeclinedException>()),
      );
      expect(handlerCalls, 2, reason: '拒绝结果不缓存');
      expect(ensureCalls, 0);
    });
  });
}

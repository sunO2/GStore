import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;

/// 模块自举阶段（安装/挂载状态机的公开快照）。
///
/// 该枚举只描述**用户可感知的宏观阶段**，不暴露底层下载/校验步骤：
/// * [absent] —— 尚无任何状态（空闲；`states` 不聚合该阶段）。
/// * [downloading] —— 正在确保产物就绪（必要时经远程下载）。
/// * [initializing] —— 产物已就绪，正在挂载/创建模块实例。
/// * [ready] —— 实例可用。
/// * [failed] —— 本次确保/实例化失败（失败**不粘滞**，后续调用可重试）。
enum ModuleBootstrapPhase { absent, downloading, initializing, ready, failed }

/// 单个模块的自举状态快照（不可变）。
///
/// 由 [ModuleBootstrap.states] / [ModuleBootstrap.watch] 对外发布，
/// 供顶部进度条与诊断使用。
class ModuleBootstrapState {
  /// 模块名（`qr` / `analyzer` / `repo` / `download` / `llm`）。
  final String module;

  /// 当前阶段。
  final ModuleBootstrapPhase phase;

  /// 下载/安装完成比例 `[0,1]`；无进度信息时为 `null`。
  final double? progress;

  /// 失败时的最后错误对象；非失败阶段为 `null`。
  final Object? error;

  /// 触发本次状态的尝试序号（从 1 开始；无重试语义时为 0）。
  final int attempt;

  /// 构造一个状态快照。
  const ModuleBootstrapState({
    required this.module,
    required this.phase,
    this.progress,
    this.error,
    this.attempt = 0,
  });
}

/// 模块安装策略。
///
/// * [auto] —— 首次使用时静默安装（qr/analyzer/repo/download）。
/// * [confirm] —— 安装前必须经确认处理器同意（llm 的大体积 arm64 下载）。
enum ModuleInstallPolicy { auto, confirm }

/// 用户在确认弹层中**拒绝**安装时抛出。
///
/// 不触发退避重试；后续调用可重新询问（拒绝结果不缓存）。
class ModuleInstallDeclinedException implements Exception {
  /// 被拒绝的模块名。
  final String module;

  /// 关联的底层错误（无则为 `null`）。
  final Object? cause;

  /// 构造拒绝异常。
  const ModuleInstallDeclinedException(this.module, [this.cause]);

  @override
  String toString() => cause == null
      ? 'ModuleInstallDeclinedException($module)'
      : 'ModuleInstallDeclinedException($module): $cause';
}

/// 确保/实例化在耗尽全部尝试后仍失败时抛出。
///
/// 失败结果**不缓存**：一次新的 [ModuleBootstrap.acquire] 会重新尝试。
class ModuleInstallFailedException implements Exception {
  /// 安装失败的模块名。
  final String module;

  /// 最后一次失败的原因（无则为 `null`）。
  final Object? cause;

  /// 构造失败异常。
  const ModuleInstallFailedException(this.module, [this.cause]);

  @override
  String toString() => cause == null
      ? 'ModuleInstallFailedException($module)'
      : 'ModuleInstallFailedException($module): $cause';
}

/// 由宿主 [ModuleHandle] 创建模块实例的工厂。
///
/// 默认实现为 `(h) => RustModuleInstance.createWithContext(module, h)`；
/// 调用方（如 repo 多源）可传入自定义工厂以复用同一安装产物。
typedef ModuleInstanceFactory = Future<RustModuleInstance> Function(
  ModuleHandle handle,
);

/// 一次 ensure 单飞的结果快照。
///
/// 用于区分「软失败（ensure 返回 `false`）」与「硬失败（ensure 抛异常/超时）」，
/// 并把**原始**错误对象逐层传递到 [ModuleBootstrap.acquire]：耗尽重试后
/// [ModuleInstallFailedException] 的 `cause`、以及 [ModuleBootstrapState.error]
/// 都不会丢失原始错误文本。
class _EnsureOutcome {
  /// ensure 是否成功。
  final bool ok;

  /// 失败时的原始错误（成功为 `null`）。
  final Object? error;

  /// 原始错误的栈（可空；软失败时为 `null`）。
  final StackTrace? stackTrace;

  const _EnsureOutcome.success()
      : ok = true,
        error = null,
        stackTrace = null;

  const _EnsureOutcome.failure(this.error, [this.stackTrace]) : ok = false;
}

/// 统一模块自举门（on-use install gate）。
///
/// 五个模块消费方（qr / analyzer / repo / download / llm）共用此单一入口：
/// * 两级单飞：安装保证按**模块**去重（`_ensureInFlight`），实例创建按
///   `module#instanceKey` 去重（`_instanceInFlight`），并缓存已创建实例。
/// * 有界退避：失败的确保/实例化按 `baseDelay * 2^(attempt-1)` 重试，
///   耗尽后抛 [ModuleInstallFailedException]（不粘滞）。
/// * 状态流：[states] / [watch] 发布 [ModuleBootstrapState]，供进度条展示。
/// * 安装策略：`llm` 走 [ModuleInstallPolicy.confirm]，其余默认 `auto`。
///
/// 生产默认实现直接委托 [RustModuleLoader] / [RustModuleManager]；
/// 所有接缝均可经 [debugConfigure] 注入，使测试**无需 FFI、无需网络**。
class ModuleBootstrap {
  ModuleBootstrap._();

  static ModuleBootstrap? _instance;

  /// 单例入口。
  static ModuleBootstrap get instance => _instance ??= ModuleBootstrap._();

  // ---- 两级单飞 + 实例缓存 ----

  /// 按模块去重的安装确保在途表。
  final Map<String, Future<_EnsureOutcome>> _ensureInFlight =
      <String, Future<_EnsureOutcome>>{};

  /// 按 `module#instanceKey` 去重的实例在途表。
  final Map<String, Future<RustModuleInstance>> _instanceInFlight =
      <String, Future<RustModuleInstance>>{};

  /// 已创建实例缓存（键为 `module#instanceKey`）。
  final Map<String, RustModuleInstance> _instances =
      <String, RustModuleInstance>{};

  // ---- 挂起保护 ----

  /// 单飞步骤（安装确保 / 实例化）的最长等待时长。
  ///
  /// 超过该时长仍未完成即视为挂起：发布 [ModuleBootstrapPhase.failed]、释放在途
  /// 条目，使下一次调用可重试，**绝不**让单飞条目永久残留。默认值对慢速网络下
  /// 的大模块（如 llm）下载足够宽松；测试可经 [debugConfigure] 注入更短值。
  static const Duration defaultStepTimeout = Duration(minutes: 10);

  /// 当前生效的步骤超时（生产为 [defaultStepTimeout]）。
  Duration _stepTimeout = defaultStepTimeout;

  // ---- 状态流 ----

  /// 每个模块最近一次非空闲状态（[ModuleBootstrapPhase.absent] 不入表）。
  final Map<String, ModuleBootstrapState> _lastStates =
      <String, ModuleBootstrapState>{};

  /// 单模块状态广播流。
  final StreamController<ModuleBootstrapState> _stateController =
      StreamController<ModuleBootstrapState>.broadcast();

  /// 聚合状态广播流。
  final StreamController<List<ModuleBootstrapState>> _statesController =
      StreamController<List<ModuleBootstrapState>>.broadcast();

  // ---- 测试接缝（生产未配置覆盖时行为不变） ----

  /// 安装确保覆盖（生产：`RustModuleLoader.ensureModule`）。
  Future<bool> Function(
    String module, {
    required bool allowDownload,
    ModuleProgressCallback? onProgress,
  })? _ensureOverride;

  /// 模块句柄加载覆盖（生产：`RustModuleManager.loadModule`）。
  Future<ModuleHandle> Function(String module)? _loadOverride;

  /// 实例工厂覆盖（低于 [acquire] 的显式 `factory` 参数优先级）。
  ModuleInstanceFactory? _factoryOverride;

  /// 退避等待覆盖（测试用零延迟；生产：`Future.delayed`）。
  Future<void> Function(Duration duration)? _delayOverride;

  /// 确认处理器（[ModuleInstallPolicy.confirm] 时调用）。
  Future<bool> Function(String module)? _confirmHandler;

  /// 全部模块最近一次非空闲状态（按模块名升序）。
  Stream<List<ModuleBootstrapState>> get states async* {
    yield _snapshot();
    yield* _statesController.stream;
  }

  /// 订阅某模块的状态流（广播；仅该模块的状态）。
  ///
  /// 订阅时**先发布该模块的当前缓存状态**（若存在），因此监听一个已 `ready`
  /// 的模块会立即收到 `ready`；随后再转发后续的广播状态事件。
  Stream<ModuleBootstrapState> watch(String module) async* {
    final cached = _lastStates[module];
    if (cached != null) yield cached;
    yield* _stateController.stream.where((state) => state.module == module);
  }

  /// 获取（必要时安装并创建）模块实例。
  ///
  /// 顺序：实例缓存 → 加入在途实例 → 新建按 `module#instanceKey` 去重的在途
  /// future，其内先 [ensureOnly]（按模块单飞去重）再经 [factory] 创建实例。
  ///
  /// [maxAttempts] / [baseDelay] 控制失败退避；耗尽抛
  /// [ModuleInstallFailedException] 且**不写缓存**。
  Future<RustModuleInstance> acquire(
    String module, {
    String instanceKey = '',
    ModuleInstanceFactory? factory,
    ModuleInstallPolicy? policy,
    int maxAttempts = 3,
    Duration baseDelay = const Duration(seconds: 1),
  }) {
    final key = '$module#$instanceKey';
    final cached = _instances[key];
    if (cached != null) return Future<RustModuleInstance>.value(cached);

    final inFlight = _instanceInFlight[key];
    if (inFlight != null) return inFlight;

    final future = _acquireWithRetry(
      module: module,
      key: key,
      factory: factory,
      policy: policy,
      maxAttempts: maxAttempts,
      baseDelay: baseDelay,
    );
    _instanceInFlight[key] = future;
    return future;
  }

  /// 仅确保模块可安装/可挂载（不创建实例）。
  ///
  /// 按模块单飞去重；[policy] 为空时取 [policyFor]。
  /// 确认门异常（拒绝/未注册处理器）按既有语义原样抛出；ensure 自身的失败
  /// （返回 `false`、抛异常或超时）不抛给调用方，而是返回 `false`，同时已发布
  /// 终态 [ModuleBootstrapPhase.failed]。
  Future<bool> ensureOnly(String module, {ModuleInstallPolicy? policy}) async {
    final outcome = await _ensureSingleFlight(module, policy);
    return outcome.ok;
  }

  /// 触发一次「即发即忘」的安装确保（不等待、不抛错）。
  ///
  /// 供热路径（如二维码逐帧解码）使用：安装由门在后台完成，
  /// 调用方不阻塞相机循环。
  void ensureStarted(String module, {ModuleInstallPolicy? policy}) {
    ensureOnly(module, policy: policy).ignore();
  }

  /// 仅当**本地/内置产物存在**时挂载（绝不触发远程下载）。
  ///
  /// 启动路径使用：保持「启动零网络」契约（如 F-Droid repo 的 `onInit`）。
  Future<bool> prepareExisting(String module) =>
      _invokeEnsure(module, allowDownload: false);

  /// 获取实例后运行 [task]。
  ///
  /// 获取失败时 [task] 不会被执行，原异常原样传播；
  /// 并发调用共享同一次获取（由 [acquire] 单飞保证）。
  Future<T> run<T>(
    String module,
    Future<T> Function(RustModuleInstance instance) task, {
    String instanceKey = '',
    ModuleInstallPolicy? policy,
  }) async {
    final instance = await acquire(
      module,
      instanceKey: instanceKey,
      policy: policy,
    );
    return task(instance);
  }

  /// 注册确认处理器；传 `null` 清除。
  ///
  /// 仅 [ModuleInstallPolicy.confirm] 模块会调用；未注册时确认路径抛
  /// [StateError]（绝不静默自动安装）。
  void setConfirmHandler(Future<bool> Function(String module)? handler) {
    _confirmHandler = handler;
  }

  /// 返回模块的安装策略（`llm` → `confirm`，其余 → `auto`）。
  ModuleInstallPolicy policyFor(String module) =>
      module == 'llm' ? ModuleInstallPolicy.confirm : ModuleInstallPolicy.auto;

  /// 注入测试接缝：安装确保/句柄加载/工厂/退避等待/确认处理器/步骤超时。
  ///
  /// 未配置的项保持生产行为；配置后全部门路径在**无 FFI、无网络**下可测。
  @visibleForTesting
  void debugConfigure({
    Future<bool> Function(
      String module, {
      required bool allowDownload,
      ModuleProgressCallback? onProgress,
    })? ensureOverride,
    Future<ModuleHandle> Function(String module)? loadOverride,
    ModuleInstanceFactory? factoryOverride,
    Future<void> Function(Duration duration)? delayOverride,
    Future<bool> Function(String module)? confirmHandler,
    Duration? stepTimeout,
  }) {
    _ensureOverride = ensureOverride;
    _loadOverride = loadOverride;
    _factoryOverride = factoryOverride;
    _delayOverride = delayOverride;
    _confirmHandler = confirmHandler;
    _stepTimeout = stepTimeout ?? defaultStepTimeout;
  }

  /// 还原生产默认并清空全部在途/缓存/状态。
  @visibleForTesting
  void debugReset() {
    _ensureOverride = null;
    _loadOverride = null;
    _factoryOverride = null;
    _delayOverride = null;
    _confirmHandler = null;
    _stepTimeout = defaultStepTimeout;
    _ensureInFlight.clear();
    _instanceInFlight.clear();
    _instances.clear();
    _lastStates.clear();
  }

  /// 当前在途的 ensure 单飞条目数（测试专用，用于断言不被永久污染）。
  @visibleForTesting
  int get debugEnsureInFlightCount => _ensureInFlight.length;

  /// 当前在途的实例单飞条目数（测试专用）。
  @visibleForTesting
  int get debugInstanceInFlightCount => _instanceInFlight.length;

  /// 当前生效的步骤超时（测试专用）。
  @visibleForTesting
  Duration get debugStepTimeout => _stepTimeout;

  // ---- 内部实现 ----

  /// 按模块去重的 ensure 单飞。
  ///
  /// 在途条目**先于**执行登记到 [_ensureInFlight]，因此即使 [_ensureOnlyInternal]
  /// 在首个 `await` 之前同步抛错（如确认门），条目也会在执行完成后被清理，
  /// 绝不会留下永久残留的失败 future（poisoned single-flight）。
  Future<_EnsureOutcome> _ensureSingleFlight(
    String module,
    ModuleInstallPolicy? policy,
  ) {
    final existing = _ensureInFlight[module];
    if (existing != null) return existing;

    final completer = Completer<_EnsureOutcome>();
    _ensureInFlight[module] = completer.future;
    unawaited(_ensureOnlyInternal(module, policy).then(
      (outcome) {
        _ensureInFlight.remove(module);
        if (!completer.isCompleted) completer.complete(outcome);
      },
      onError: (Object error, StackTrace stackTrace) {
        _ensureInFlight.remove(module);
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      },
    ));
    return completer.future;
  }

  /// 按 `.so`/内置产物确保模块就绪（带确认门、超时与终态保证）。
  ///
  /// **永不「无终态」退出**：无论 ensure 返回 `false`、抛异常还是超时，都会在
  /// 完成之前发布一次 [ModuleBootstrapPhase.failed]（携带原始错误）。确认门异常
  /// （拒绝/未注册处理器）按既有语义向调用方抛出，不发布 failed、不进入退避。
  Future<_EnsureOutcome> _ensureOnlyInternal(
    String module,
    ModuleInstallPolicy? policy,
  ) async {
    final effectivePolicy = policy ?? policyFor(module);
    if (effectivePolicy == ModuleInstallPolicy.confirm) {
      final handler = _confirmHandler;
      if (handler == null) {
        throw StateError(
          'ModuleBootstrap: 模块 "$module" 为确认策略但未注册确认处理器',
        );
      }
      var accepted = false;
      try {
        accepted = await handler(module);
      } catch (_) {
        // 处理器异常一律视为拒绝（不安装、不崩溃）。
        accepted = false;
      }
      if (!accepted) {
        throw ModuleInstallDeclinedException(module);
      }
    }

    _emit(ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.downloading,
    ));
    // 下载进度单调不减：忽略任何小于上一次已发布值的 fraction。
    double? lastProgress;
    void reportProgress(double fraction) {
      final previous = lastProgress;
      if (previous != null && fraction < previous) return;
      lastProgress = fraction;
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.downloading,
        progress: fraction,
      ));
    }

    final bool ok;
    try {
      ok = await _invokeEnsure(
        module,
        allowDownload: true,
        onProgress: reportProgress,
      ).timeout(_stepTimeout);
    } on TimeoutException catch (error, stackTrace) {
      debugPrint(
        'ModuleBootstrap: 模块 "$module" 安装确保超时'
        '（>${_stepTimeout.inMilliseconds}ms），已释放单飞以便重试',
      );
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.failed,
        error: error,
      ));
      return _EnsureOutcome.failure(error, stackTrace);
    } catch (error, stackTrace) {
      // 网络/FFI/ABI 等任意异常：先发布终态 failed（保留原始错误），再让上层
      // 释放单飞；绝不从单飞路径逃逸而不留终态。
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.failed,
        error: error,
      ));
      return _EnsureOutcome.failure(error, stackTrace);
    }

    if (!ok) {
      final error = StateError('模块 $module 安装/确保失败');
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.failed,
        error: error,
      ));
      return _EnsureOutcome.failure(error);
    }
    return const _EnsureOutcome.success();
  }

  /// 在按 `module#instanceKey` 去重的在途 future 内执行：确保 → 创建实例，
  /// 失败按有界指数退避重试；拒绝确认不进入退避。
  ///
  /// ensure 的「软失败（false）」与「硬失败（异常/超时）」都进入有界退避，
  /// 耗尽后发布终态 failed 并以**原始** cause 抛出
  /// [ModuleInstallFailedException]；实例化步骤同样受 [_stepTimeout] 保护。
  Future<RustModuleInstance> _acquireWithRetry({
    required String module,
    required String key,
    ModuleInstanceFactory? factory,
    ModuleInstallPolicy? policy,
    required int maxAttempts,
    required Duration baseDelay,
  }) async {
    try {
      var attempt = 0;
      while (true) {
        attempt++;
        final outcome = await _ensureSingleFlight(module, policy);
        if (outcome.ok) {
          _emit(ModuleBootstrapState(
            module: module,
            phase: ModuleBootstrapPhase.initializing,
            attempt: attempt,
          ));
          try {
            final handle = await _loadHandle(module).timeout(_stepTimeout);
            final effectiveFactory = factory ??
                _factoryOverride ??
                (ModuleHandle h) =>
                    RustModuleInstance.createWithContext(module, h);
            final instance =
                await effectiveFactory(handle).timeout(_stepTimeout);
            _instances[key] = instance;
            _emit(ModuleBootstrapState(
              module: module,
              phase: ModuleBootstrapPhase.ready,
              progress: 1.0,
              attempt: attempt,
            ));
            return instance;
          } catch (error) {
            if (attempt >= maxAttempts) {
              _emit(ModuleBootstrapState(
                module: module,
                phase: ModuleBootstrapPhase.failed,
                error: error,
                attempt: attempt,
              ));
              throw ModuleInstallFailedException(module, error);
            }
            await _backoff(attempt, baseDelay);
          }
        } else {
          final error = outcome.error ?? StateError('模块 $module 安装/确保失败');
          if (attempt >= maxAttempts) {
            _emit(ModuleBootstrapState(
              module: module,
              phase: ModuleBootstrapPhase.failed,
              error: error,
              attempt: attempt,
            ));
            throw ModuleInstallFailedException(module, error);
          }
          await _backoff(attempt, baseDelay);
        }
      }
    } finally {
      _instanceInFlight.remove(key);
    }
  }

  /// 指数退避等待（`baseDelay * 2^(attempt-1)`）。
  Future<void> _backoff(int attempt, Duration baseDelay) async {
    final duration = baseDelay * (1 << (attempt - 1));
    final override = _delayOverride;
    if (override != null) {
      await override(duration);
      return;
    }
    await Future<void>.delayed(duration);
  }

  /// 调用安装确保（尊重 [_ensureOverride] 接缝；生产委托 [RustModuleLoader]）。
  Future<bool> _invokeEnsure(
    String module, {
    required bool allowDownload,
    ModuleProgressCallback? onProgress,
  }) {
    final override = _ensureOverride;
    if (override != null) {
      return override(
        module,
        allowDownload: allowDownload,
        onProgress: onProgress,
      );
    }
    return RustModuleLoader.instance.ensureModule(
      module,
      allowDownload: allowDownload,
      onProgress: onProgress,
    );
  }

  /// 加载模块句柄（尊重 [_loadOverride] 接缝；生产委托 [RustModuleManager]）。
  Future<ModuleHandle> _loadHandle(String module) {
    final override = _loadOverride;
    if (override != null) return override(module);
    return RustModuleManager.instance.loadModule(module);
  }

  /// 发布一次状态变更并更新聚合快照。
  void _emit(ModuleBootstrapState state) {
    if (state.phase == ModuleBootstrapPhase.absent) {
      _lastStates.remove(state.module);
    } else {
      _lastStates[state.module] = state;
    }
    if (!_stateController.isClosed) _stateController.add(state);
    if (!_statesController.isClosed) _statesController.add(_snapshot());
  }

  /// 当前全部模块的非空闲状态（模块名升序）。
  List<ModuleBootstrapState> _snapshot() {
    final list = _lastStates.values.toList();
    list.sort((a, b) => a.module.compareTo(b.module));
    return list;
  }
}

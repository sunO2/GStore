import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

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
  final Map<String, Future<bool>> _ensureInFlight = <String, Future<bool>>{};

  /// 按 `module#instanceKey` 去重的实例在途表。
  final Map<String, Future<RustModuleInstance>> _instanceInFlight =
      <String, Future<RustModuleInstance>>{};

  /// 已创建实例缓存（键为 `module#instanceKey`）。
  final Map<String, RustModuleInstance> _instances =
      <String, RustModuleInstance>{};

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
  Stream<ModuleBootstrapState> watch(String module) =>
      _stateController.stream.where((state) => state.module == module);

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
  Future<bool> ensureOnly(String module, {ModuleInstallPolicy? policy}) {
    final inFlight = _ensureInFlight[module];
    if (inFlight != null) return inFlight;

    final future = _ensureOnlyInternal(module, policy);
    _ensureInFlight[module] = future;
    return future;
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

  /// 注入测试接缝：安装确保/句柄加载/工厂/退避等待/确认处理器。
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
  }) {
    _ensureOverride = ensureOverride;
    _loadOverride = loadOverride;
    _factoryOverride = factoryOverride;
    _delayOverride = delayOverride;
    _confirmHandler = confirmHandler;
  }

  /// 还原生产默认并清空全部在途/缓存/状态。
  @visibleForTesting
  void debugReset() {
    _ensureOverride = null;
    _loadOverride = null;
    _factoryOverride = null;
    _delayOverride = null;
    _confirmHandler = null;
    _ensureInFlight.clear();
    _instanceInFlight.clear();
    _instances.clear();
    _lastStates.clear();
  }

  // ---- 内部实现 ----

  /// 按 `.so`/内置产物确保模块就绪（带确认门与单飞 finally 清理）。
  Future<bool> _ensureOnlyInternal(
    String module,
    ModuleInstallPolicy? policy,
  ) async {
    try {
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
      final ok = await _invokeEnsure(module, allowDownload: true);
      if (!ok) {
        _emit(ModuleBootstrapState(
          module: module,
          phase: ModuleBootstrapPhase.failed,
        ));
      }
      return ok;
    } finally {
      _ensureInFlight.remove(module);
    }
  }

  /// 在按 `module#instanceKey` 去重的在途 future 内执行：确保 → 创建实例，
  /// 失败按有界指数退避重试；拒绝确认不进入退避。
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
        final ok = await ensureOnly(module, policy: policy);
        if (ok) {
          _emit(ModuleBootstrapState(
            module: module,
            phase: ModuleBootstrapPhase.initializing,
            attempt: attempt,
          ));
          try {
            final handle = await _loadHandle(module);
            final effectiveFactory = factory ??
                _factoryOverride ??
                (ModuleHandle h) =>
                    RustModuleInstance.createWithContext(module, h);
            final instance = await effectiveFactory(handle);
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
          if (attempt >= maxAttempts) {
            _emit(ModuleBootstrapState(
              module: module,
              phase: ModuleBootstrapPhase.failed,
              attempt: attempt,
            ));
            throw ModuleInstallFailedException(module, null);
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
    return RustModuleLoader.instance
        .ensureModule(module, allowDownload: allowDownload);
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

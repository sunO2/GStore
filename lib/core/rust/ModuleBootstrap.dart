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

  /// 清单声明的权威资产字节数（未知时为 `null`）。
  ///
  /// 由下载器链路透传，供顶部横幅显示「约 X MB · 仅需一次」。
  final int? sizeBytes;

  /// 构造一个状态快照。
  const ModuleBootstrapState({
    required this.module,
    required this.phase,
    this.progress,
    this.error,
    this.attempt = 0,
    this.sizeBytes,
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

/// 内部哨兵：实例创建期间模块被 [ModuleBootstrap.invalidate] 作废。
///
/// 必须与真正的加载/实例化失败区分开——它不是可退避重试的错误，而是「该结果属于
/// 回退前的世界」；[ModuleBootstrap._acquireWithRetry] 捕获它后直接以
/// [ModuleInstallFailedException] 终结本次获取，绝不重试出陈旧实例。
class _AttemptInvalidated implements Exception {
  const _AttemptInvalidated();
}

/// 一次**底层**安装 ensure 尝试（未被 `Future.timeout` 取消的原始 future）。
///
/// `Future.timeout` 只让等待方超时，**不会取消**底层 `ensureModule`：超时后底层
/// 仍可能继续下载并在稍后回调进度/成功。本对象持有该原始 future 及其代次、整体
/// 截止时间与两条状态位，用于：
/// * 让**重试复用**仍在途的同一底层安装，避免并发跑起第二个安装；
/// * 让同一次尝试的**晚到进度**在其终结后被丢弃，绝不复活终态。
class _PendingEnsure {
  /// 构造一次底层尝试（[future] 随后由 `_startEnsureAttempt` 赋值）。
  _PendingEnsure(this.generation, this.moduleGeneration, this.deadline);

  /// 单调递增的代次序号（每个底层尝试一个）。
  final int generation;

  /// 创建该尝试时其**模块**的代次（[ModuleBootstrap.invalidate] 递增对应模块）。
  ///
  /// 与 [generation]（全局尝试序号）不同，这是**每模块**的「墓碑」：一旦回退
  /// 成功递增了模块代次，所有携带旧代次的尝试都成为过期尝试，既不可被复用、也不
  /// 可被对账为 `ready`（见 [_attemptIsStale] 在各复用/终结检查点的使用）。
  final int moduleGeneration;

  /// 该次底层安装的整体截止时间（自启动起算，重试复用时不重置）。
  final DateTime deadline;

  /// 原始 `ensureModule` future（未经超时包裹，故可被重试复用）。
  late final Future<bool> future;

  /// 是否**已为本次尝试发布过终态**。为 `true` 后，本次尝试的任何晚到进度
  /// （[reportProgress]）都被丢弃，防止把 `failed`/`ready` 翻回 `downloading`。
  bool settled = false;

  /// 是否正有 ensure 调用在 `await` 该 future（用于区分「在途」与「孤儿」）。
  bool claimed = false;

  /// 底层 future 是否已完成（成功或失败）；用于重试时的复用判定。
  bool completed = false;
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

  /// 按模块保存**尚未完成**的底层安装尝试（`Future.timeout` 不取消底层）。
  ///
  /// 单飞条目 [_ensureInFlight] 在终态后即移除，但底层 `ensureModule` 仍可能
  /// 在途；本表跨单飞保留该底层尝试，使重试可以复用它（await 同一个 future）而
  /// 非新起一次并发安装。尝试完成（成功或失败）后由监听器移除。
  final Map<String, _PendingEnsure> _pendingEnsure = <String, _PendingEnsure>{};

  /// 底层安装尝试的代次序号（单调递增，供孤儿/晚到回调诊断）。
  int _ensureGenerationSeq = 0;

  /// 每模块代次（「墓碑」）：[invalidate] 时递增。
  ///
  /// 用于作废回退前已启动的底层尝试：[_PendingEnsure.moduleGeneration] 在创建时
  /// 取当前值；任何复用/终结点只要发现其与当前值不符，即判定该尝试过期，绝不
  /// 复用、也绝不对账为 `ready`。缺失键默认 0。
  final Map<String, int> _moduleGeneration = <String, int>{};

  /// 按 `module#instanceKey` 去重的实例在途表。
  final Map<String, Future<RustModuleInstance>> _instanceInFlight =
      <String, Future<RustModuleInstance>>{};

  /// 已创建实例缓存（键为 `module#instanceKey`）。
  ///
  /// **所有权契约**：
  /// * 默认键（`instanceKey == ''`）由本门**自有**，在单例生命周期内缓存不淘汰；
  ///   同一模块的重复 [acquire] 会命中同一实例。
  /// * 非默认键（如 repo 多源的身份键）由**调用方自有**：本门只保证同一键返回同一
  ///   实例且按 key 单飞，**不会**自动淘汰。调用方在某个身份不再使用时必须调用
  ///   [release] 显式释放，否则该实例会随单例存活，导致缓存按模块无界增长。
  ///
  /// 多个不同 `instanceKey` 的实例互不影响：不同键各自缓存、各自创建（repo 多源
  /// 依赖此行为）。
  final Map<String, RustModuleInstance> _instances =
      <String, RustModuleInstance>{};

  // ---- 挂起保护 ----

  /// ensure 安装的**单一整体期限**（自底层安装启动起算的一次性 deadline）。
  ///
  /// 语义：这是**整体（overall）**而非**每次尝试（per-attempt）**的期限。底层
  /// `ensureModule` 一旦启动，其截止时间即固定；后续重试通过 [_pendingEnsure]
  /// 复用**同一个**底层 future 并共享该 deadline，因此：
  /// * 慢而健康的大模块（如 llm）不会被反复重新下载（不会每轮重设 10 分钟）；
  /// * 一个安装的总等待上限为 [_stepTimeout]，失败也不会拖到 ~30 分钟。
  ///
  /// 期限耗尽时底层 future **不可取消**：门不会（也无法）开启「全新安装」，只会
  /// 发布终态 `failed` 并释放单飞；真正的恢复依赖该底层 future 自行结束——届时
  /// loader 释放其每模块单飞，后续调用才可能重新安装。
  ///
  /// 该值对慢速网络下的大模块下载足够宽松；测试可经 [debugConfigure] 注入更短值。
  static const Duration defaultStepTimeout = Duration(minutes: 10);

  /// 当前生效的 ensure 整体期限（生产为 [defaultStepTimeout]）；
  /// 同时作为句柄加载/实例化单步的超时上限。
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
  ///
  /// 订阅时**同步发布当前快照**，并在同一同步块内订阅广播流；因此二者之间
  /// 不可能插入一次 [_emit]，不会丢失快照与后续事件之间的状态。
  Stream<List<ModuleBootstrapState>> get states =>
      Stream<List<ModuleBootstrapState>>.multi((multi) {
        // 同一同步块：读快照 + 订阅广播，单线程下两者之间无法发生 _emit。
        multi.add(_snapshot());
        final subscription = _statesController.stream.listen(
          multi.add,
          onError: multi.addError,
          onDone: multi.close,
        );
        multi.onCancel = subscription.cancel;
      });

  /// 订阅某模块的状态流（广播；仅该模块的状态）。
  ///
  /// 订阅时**同步发布该模块的当前缓存状态**（若存在），并在同一同步块内订阅
  /// 广播流，因此监听一个已 `ready` 的模块会立即收到 `ready`，且缓存状态与随后
  /// 事件之间不存在「读取缓存 → 订阅」的时间窗——该窗口内的 [_emit] 不会被丢弃。
  ///
  /// 相较 `async*` 实现的关键差异：这里在 `onListen` 的**同一同步块**内完成
  /// 读缓存与订阅，二者之间无法插入一次 [_emit]（`async*` 的 `yield cached`
  /// 会让出事件循环，导致订阅前的状态事件永久丢失）。转发用 `sync: true`
  /// 控制器，使广播事件对监听方**同步可见**（与旧 `async*` 的即时性一致，
  /// 不引入额外的微任务延迟）。
  Stream<ModuleBootstrapState> watch(String module) {
    final controller = StreamController<ModuleBootstrapState>(sync: true);
    StreamSubscription<ModuleBootstrapState>? subscription;
    controller.onListen = () {
      // 同一同步块：读缓存 + 订阅广播，单线程下两者之间无法发生 _emit。
      final cached = _lastStates[module];
      if (cached != null) controller.add(cached);
      subscription = _stateController.stream
          .where((state) => state.module == module)
          .listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
    };
    controller.onCancel = () {
      subscription?.cancel();
      subscription = null;
    };
    return controller.stream;
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
    if (cached != null) {
      // 缓存命中：实例必然可用。若门的可观测阶段因任何路径掉出 ready（例如
      // loader 的 `_isLoaded` 短路使一次 ensureOnly 成功却无终态），这里补发一次
      // ready，保证「有缓存实例 ⇒ 可观测终态 ready」，绝不把 downloading 冻结。
      if (_lastStates[module]?.phase != ModuleBootstrapPhase.ready) {
        _emit(ModuleBootstrapState(
          module: module,
          phase: ModuleBootstrapPhase.ready,
          progress: 1.0,
        ));
      }
      return Future<RustModuleInstance>.value(cached);
    }

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
    // 身份感知清理：只有当前条目仍是本次 future 时才移除。这样 [invalidate] 已
    // 移除旧条目、且后续 acquire 已登记新 future 时，旧 future 的完成绝不误删
    // 新条目的单飞条目（否则会破坏同一键的并发去重）。
    future.whenComplete(() {
      if (identical(_instanceInFlight[key], future)) {
        _instanceInFlight.remove(key);
      }
    }).ignore();
    return future;
  }

  /// 显式释放一个已缓存实例（按 `module#instanceKey`）。
  ///
  /// 只从 [_instances] 缓存移除，**不**销毁底层实例/句柄——其生命周期由调用方
  /// 负责。用于非默认实例键（如 repo 多源的身份键）在对应源不再使用时清理，
  /// 避免缓存随单例无界增长。默认键（`instanceKey == ''`）同样可被释放。
  ///
  /// 返回是否确有缓存被移除。在途实例不会被移除（等待其完成后再释放即可）。
  bool release(String module, {String instanceKey = ''}) =>
      _instances.remove('$module#$instanceKey') != null;

  /// 模块是否已有可用的缓存实例（默认实例键 `''`）。
  ///
  /// 判据是 [_instances] 中 `module#` 条目存在——实例存在即代表产物已就绪、
  /// [acquire] 可立即复用。相较读取 [_lastStates] 的 `ready`，此判据不会因
  /// [release] 淘汰实例后仍残留 `ready` 缓存而误报「可用」。
  ///
  /// 供热路径（如 `QrRustDecoder.prewarm`）判断是否可跳过重复 `ensureStarted`，
  /// 避免对已安装模块发布一次会被 loader `_isLoaded` 短路吞掉的 `downloading`。
  bool hasInstance(String module, {String instanceKey = ''}) =>
      _instances['$module#$instanceKey'] != null;

  /// 作废模块 [module] 的缓存实例与可观测状态（**回退到内置成功后**调用）。
  ///
  /// 语义与 [release] **不同且不可互相替代**：
  /// * [release] 只从缓存移除实例，供调用方管理自有实例键（如 repo 多源身份键），
  ///   **不**触碰状态机、**不**作废在途安装。
  /// * [invalidate] 是回退后的状态清理：淘汰目标 `module#instanceKey` 缓存实例
  ///   （best-effort [RustModuleInstance.dispose]）、移除其（若有）在途实例单飞
  ///   条目、清空 [_lastStates]（发布 [ModuleBootstrapPhase.absent]），并**递增该
  ///   模块代次**，使回退前启动的任何确保尝试（孤儿复用/晚到完成/实例创建）全部
  ///   过期：既不会被复用，也不会被对账/写回为 `ready`，[acquire] 因而真正重新安装。
  ///
  /// **绝不**强制移除或完成在途的**安装确保**（[_ensureInFlight] / [_pendingEnsure]）：
  /// `ensureModule` 的 future 不可取消，且 loader 的每模块安装锁仍持有它；强行移除
  /// 会让后续调用发起第二次并发安装。此处只打「代次墓碑」，让真正在途的尝试自然
  /// 结束后由 [_attemptIsStale] 丢弃其晚到结果（见三处检查点：孤儿复用、晚到对账、
  /// 实例写回）。
  void invalidate(String module, {String instanceKey = ''}) {
    final key = '$module#$instanceKey';
    // 1) 淘汰缓存实例：best-effort dispose（实例类型暴露 dispose），绝不阻塞调用方。
    final cached = _instances.remove(key);
    if (cached != null) {
      _disposeQuietly(cached).ignore();
    }
    // 2) 移除在途实例单飞条目：后续 acquire 不得复用一个必然陈旧的创建 future；
    //    其晚到完成由 _acquireWithRetry 的代次守卫阻止写回缓存。
    _instanceInFlight.remove(key);
    // 3) 递增模块代次：回退前启动的确保尝试全部作废（不可复用、不可对账 ready）。
    _moduleGeneration[module] = _currentModuleGeneration(module) + 1;
    // 4) 清空可观测状态（_lastStates 移除该模块），发布 absent。
    _emit(ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.absent,
    ));
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
  ///
  /// [maxAttempts] 透传给 [acquire]：只读消费方（如 analyzer）可传 `1`，
  /// 在「安装未进行且不可安装」时立即降级，**不等待退避重试**；安装已在途时
  /// 仍会经单飞等待其完成（gate 语义不变）。
  Future<T> run<T>(
    String module,
    Future<T> Function(RustModuleInstance instance) task, {
    String instanceKey = '',
    ModuleInstallPolicy? policy,
    int maxAttempts = 3,
  }) async {
    final instance = await acquire(
      module,
      instanceKey: instanceKey,
      policy: policy,
      maxAttempts: maxAttempts,
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

  /// 注入测试接缝：安装确保/句柄加载/工厂/退避等待/确认处理器/整体超时。
  ///
  /// [stepTimeout] 为一次底层安装的**整体期限**（同时作为加载/实例化的单步上限），
  /// 重试复用同一底层尝试时不重置。
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
    _ensureGenerationSeq = 0;
    _moduleGeneration.clear();
    _ensureInFlight.clear();
    _pendingEnsure.clear();
    _instanceInFlight.clear();
    _instances.clear();
    _lastStates.clear();
  }

  /// 当前在途的 ensure 单飞条目数（测试专用，用于断言不被永久污染）。
  @visibleForTesting
  int get debugEnsureInFlightCount => _ensureInFlight.length;

  /// 当前仍保存的底层安装尝试数（测试专用；用于断言孤儿被复用而非重下）。
  @visibleForTesting
  int get debugPendingEnsureCount => _pendingEnsure.length;

  /// 当前在途的实例单飞条目数（测试专用）。
  @visibleForTesting
  int get debugInstanceInFlightCount => _instanceInFlight.length;

  /// 当前已缓存的实例数（测试专用；用于验证 [release] 显式淘汰）。
  @visibleForTesting
  int get debugInstanceCacheCount => _instances.length;

  /// 当前生效的步骤超时（测试专用）。
  @visibleForTesting
  Duration get debugStepTimeout => _stepTimeout;

  // ---- 内部实现 ----

  /// 模块 [module] 的当前代次（无记录时默认 0）。
  int _currentModuleGeneration(String module) => _moduleGeneration[module] ?? 0;

  /// 尝试 [attempt] 是否已过期（其模块代次已因 [invalidate] 改变）。
  bool _attemptIsStale(String module, _PendingEnsure attempt) =>
      attempt.moduleGeneration != _currentModuleGeneration(module);

  /// best-effort 释放实例：实例类型暴露 [RustModuleInstance.dispose]；任何异常
  /// （含同步抛出的伪造实现）都被吞掉并记录，绝不阻断回退/作废流程。
  Future<void> _disposeQuietly(RustModuleInstance instance) async {
    try {
      await instance.dispose();
    } catch (error) {
      debugPrint('ModuleBootstrap: 释放模块实例失败（已忽略）- $error');
    }
  }

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
  ///
  /// 重试语义：`Future.timeout` 不取消底层 `ensureModule`，超时后底层仍可能在途。
  /// 因此若 [_pendingEnsure] 中仍存有**未完成**的同一模块尝试，本方法直接复用该
  /// 底层 future（受同一整体 deadline 的剩余期限约束），**绝不**再调一次
  /// `ensureModule`，从根源消除并发重复安装。该次尝试终结后，其晚到的进度回调
  /// 由 [_PendingEnsure.settled] 丢弃；若孤儿最终成功，则由
  /// [_startEnsureAttempt] 的完成监听显式对账为 `ready`。
  ///
  /// 若该尝试**已过整体期限**却仍未完成：底层 future 不可取消且 loader 每模块单飞
  /// 仍持有它，**无法**开启全新安装。此时保持终态 `failed`（不发布 downloading）、
  /// 保留该尝试（以便晚到成功对账 `ready`），并**不**重发 `ensureModule`；恢复依赖
  /// 该底层 future 自行结束。
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
      // 处理器异常（非超时）视为拒绝，但**保留原始错误**作为拒绝的 cause，使
      // 「确认处理器坏了」与「用户主动拒绝」在诊断上可区分，而非不可分辨的静默拒绝。
      Object? handlerError;
      try {
        accepted = await handler(module).timeout(_stepTimeout);
      } on TimeoutException catch (error, stackTrace) {
        // 挂起的确认处理器：用同一整体期限兜底。超时视作**非接受**（失败，非拒绝），
        // 发布终态 failed 后正常返回，使单飞条目被释放、后续调用可重试；绝不让一个
        // 永不返回的确认处理器永久污染单飞。
        debugPrint(
          'ModuleBootstrap: 模块 "$module" 的确认处理器超时'
          '（>${_stepTimeout.inMilliseconds}ms），按未接受处理',
        );
        _emit(ModuleBootstrapState(
          module: module,
          phase: ModuleBootstrapPhase.failed,
          error: error,
        ));
        return _EnsureOutcome.failure(error, stackTrace);
      } catch (error) {
        // 处理器异常一律视为拒绝（不安装、不崩溃），但绝不静默：记录原始错误并
        // 作为拒绝 cause 透出，保留真实失败原因。
        debugPrint(
          'ModuleBootstrap: 模块 "$module" 的确认处理器抛错，按拒绝处理: $error',
        );
        handlerError = error;
        accepted = false;
      }
      if (!accepted) {
        // 拒绝/未同意（含处理器异常）立即向上抛出（零退避、不进入 ensure）；
        // 后续调用可重新询问。处理器异常时 cause 携带原始错误。
        throw ModuleInstallDeclinedException(module, handlerError);
      }
    }

    // 已缓存默认实例 → 模块产物必然已就绪（实例只会在一次成功 ensure 之后创建）。
    // 直接发布终态 ready 并短路，**绝不**再发 downloading、也不再调用 loader：
    // 这正是「已安装模块被再次 ensureOnly（如 QrRustDecoder.prewarm 重入）」的
    // 场景——生产 loader 的 `_isLoaded` 短路会让 ensureModule 立即返回 true，一次
    // 「成功却无终态」的 ensure 会把已 ready 的可观测阶段翻回 downloading 并永久
    // 冻结（扫码页卡在「下载中」）。仅**有缓存实例**这一种情况发 ready，未创建
    // 实例的 ensureOnly 仍保持既有「成功不发布终态」契约。
    if (_instances['$module#'] != null) {
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.ready,
        progress: 1.0,
      ));
      return const _EnsureOutcome.success();
    }

    // 已过整体期限却仍未完成的底层尝试：其 `ensureModule` future **不可取消**，
    // 且（生产下）loader 的每模块单飞仍持有它——此刻再调 `ensureModule` 只会拿到
    // **同一个**陈旧 future，绝不可能开启一次真正的新安装。因此这里不再谎称
    // 「重新发起安装」，也**不**先发布 downloading：直接保持**终态失败**，把该尝试
    // 标记 `settled`（丢弃晚到进度）但**保留**在 [_pendingEnsure] 中——它稍后若真正
    // 成功，完成监听仍能对账为 `ready`。真正的恢复条件是**底层 loader future 结束**
    // （届时其每模块单飞条目释放，后续调用才会开启一次全新安装）；在此之前重复调用
    // 快速返回失败，绝不重复安装，也就绝不会与在途落盘并发。
    // 仅复用**未被回退作废**的在途尝试：若其模块代次已过期（[invalidate] 递增
    // 后），立即忽略它——过期尝试既不得被复用，也不得在其晚到成功时对账 ready。
    // 忽略（而非移除）使底层不可取消的 future 仍能自然结束；真正的全新尝试由
    // 下方 _startEnsureAttempt 登记（生产下 loader 每模块单飞仍会返回同一底层
    // future，故绝不并发安装）。
    final pendingOrphan = _pendingEnsure[module];
    final orphan = (pendingOrphan != null && !_attemptIsStale(module, pendingOrphan))
        ? pendingOrphan
        : null;
    if (orphan != null &&
        !orphan.completed &&
        orphan.deadline.difference(DateTime.now()) <= Duration.zero) {
      orphan.settled = true;
      final error = TimeoutException(
        '模块 $module 安装确保整体超时（>${_stepTimeout.inMilliseconds}ms）',
        _stepTimeout,
      );
      debugPrint(
        'ModuleBootstrap: 模块 "$module" 的第 ${orphan.generation} 次底层尝试'
        '已超过整体期限且其 loader future 不可取消（每模块单飞仍持有），'
        '不重发安装；仅当该 future 结束后后续调用才会真正重新安装',
      );
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.failed,
        error: error,
      ));
      return _EnsureOutcome.failure(error);
    }

    _emit(ModuleBootstrapState(
      module: module,
      phase: ModuleBootstrapPhase.downloading,
    ));

    final _PendingEnsure attempt;
    if (orphan == null || orphan.completed) {
      attempt = _startEnsureAttempt(module);
    } else {
      attempt = orphan;
    }

    // 单一整体期限：自底层安装启动起算，复用同一尝试时不重置。剩余时间耗尽即
    // 判超时——避免慢而健康的安装被反复重下，也避免总耗时无限累积。
    final remaining = attempt.deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      // 新尝试的 remaining 即 _stepTimeout；仅当注入的超时为非正值等退化场景可达。
      attempt.settled = true;
      final error = TimeoutException(
        '模块 $module 安装确保整体超时（>${_stepTimeout.inMilliseconds}ms）',
        _stepTimeout,
      );
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.failed,
        error: error,
      ));
      return _EnsureOutcome.failure(error);
    }

    attempt.claimed = true;
    final bool ok;
    try {
      ok = await attempt.future.timeout(remaining);
    } on TimeoutException catch (error, stackTrace) {
      // 底层 future 仍在途（timeout 不取消它）：标记本次尝试已终结，使晚到进度
      // 被丢弃；尝试保留在 _pendingEnsure 中供下一次重试复用（不重下）。
      attempt.settled = true;
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
      attempt.settled = true;
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.failed,
        error: error,
      ));
      return _EnsureOutcome.failure(error, stackTrace);
    } finally {
      attempt.claimed = false;
    }

    if (!ok) {
      attempt.settled = true;
      final error = StateError('模块 $module 安装/确保失败');
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.failed,
        error: error,
      ));
      return _EnsureOutcome.failure(error);
    }
    // 成功同样标记终结：本次尝试后的晚到进度不得把终态翻回 downloading。
    attempt.settled = true;
    // 回退守卫：若本尝试在 await 期间被 [invalidate] 作废（模块代次已变），其「成功」
    // 属于回退前的世界，绝不能返回 success（否则 acquire 会继续 initializing→ready
    // 并写回陈旧实例）。改为 failure：调用方（acquire）随后经代次检查放弃本次获取。
    if (_attemptIsStale(module, attempt)) {
      debugPrint(
        'ModuleBootstrap: 模块 "$module" 的第 ${attempt.generation} 次底层尝试'
        '已在回退后作废，丢弃其成功结果',
      );
      return _EnsureOutcome.failure(
        StateError('模块 $module 安装尝试已在回退后作废'),
      );
    }
    return const _EnsureOutcome.success();
  }

  /// 启动/登记一次底层安装 ensure（生产委托 [RustModuleLoader.ensureModule]），
  /// 并登记其完成监听。
  ///
  /// **不保证**底层会开启一次全新安装：`ensureModule` 每模块单飞，若它仍持有同一
  /// 模块的在途 future（例如上一次尝试已超时但不可取消），本次调用只会拿到
  /// **同一个**陈旧 future。因此本方法只承诺「启动/复用一个底层尝试」，绝不承诺
  /// 「重新下载」；真正全新安装的前提是该 future 已结束（单飞条目被释放）。
  ///
  /// 不使用超时包裹，故返回的 future 是真正的底层安装：超时后仍可被后续重试
  /// 复用（见 [_ensureOnlyInternal]）。[reportProgress] 绑定本次尝试的
  /// [_PendingEnsure.settled]：一旦终结，晚到进度一律丢弃，绝不复活终态。
  ///
  /// 完成对账：若该尝试已是**无人 await 的孤儿**（`!claimed`）且此前已发布终态
  /// （`settled`），却在稍后真正成功，则显式发布一次 `ready`（产物确实就绪），
  /// 而不是让它停留在 `failed` 或假装仍在 `downloading`。若确有调用方在 await，
  /// 则由该调用方经 [acquire] 的正常 `initializing → ready` 路径发布。
  _PendingEnsure _startEnsureAttempt(String module) {
    final attempt = _PendingEnsure(
      ++_ensureGenerationSeq,
      _currentModuleGeneration(module),
      DateTime.now().add(_stepTimeout),
    );
    // 下载进度单调不减：忽略任何小于上一次已发布值的 fraction；已终结则丢弃。
    // 记住最近一次非空 sizeBytes（权威资产体积），使每个状态都携带体积。
    double? lastProgress;
    int? lastSizeBytes;
    void reportProgress(double fraction, {int? sizeBytes}) {
      if (sizeBytes != null) lastSizeBytes = sizeBytes;
      if (attempt.settled) return;
      final previous = lastProgress;
      if (previous != null && fraction < previous) return;
      lastProgress = fraction;
      _emit(ModuleBootstrapState(
        module: module,
        phase: ModuleBootstrapPhase.downloading,
        progress: fraction,
        sizeBytes: lastSizeBytes,
      ));
    }

    // `Future.sync` 把 `_invokeEnsure` 的**同步**抛错也转换为 error future，
    // 使其落入下面的 catch 并发布终态 failed（与旧实现语义一致）。
    attempt.future = Future<bool>.sync(() => _invokeEnsure(
          module,
          allowDownload: true,
          onProgress: reportProgress,
        ));
    _pendingEnsure[module] = attempt;
    unawaited(attempt.future.then(
      (ok) {
        attempt.completed = true;
        final tracked = identical(_pendingEnsure[module], attempt);
        if (tracked) _pendingEnsure.remove(module);
        if (ok && attempt.settled && !attempt.claimed && tracked &&
            !_attemptIsStale(module, attempt)) {
          // 孤儿在被放弃后成功：显式对账为 ready（产物确实就绪）。
          // 但若该尝试已被 [invalidate] 作废（模块代次已变），绝不复活回退前状态。
          debugPrint(
            'ModuleBootstrap: 模块 "$module" 的孤儿安装（第 ${attempt.generation} '
            '次底层尝试）稍后成功，对账为 ready',
          );
          _emit(ModuleBootstrapState(
            module: module,
            phase: ModuleBootstrapPhase.ready,
            progress: 1.0,
          ));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        attempt.completed = true;
        if (identical(_pendingEnsure[module], attempt)) {
          _pendingEnsure.remove(module);
        }
        // 孤儿失败：终态 failed 早已发布且保留原始错误，此处不覆盖。
      },
    ));
    return attempt;
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
    // 本次获取所属的模块代次：与 [invalidate] 的墓碑比较。一旦回退递增了代次，
    // 本获取的任何结果（ensure 成功/实例创建成功）都属于回退前的世界，直接放弃，
    // 绝不写回缓存/发布 ready（后续 acquire 会以新代次真正重新安装）。
    final generation = _currentModuleGeneration(module);
    var attempt = 0;
    while (true) {
      // 退避期间也可能被作废：下一轮开始前先复核，避免为已作废的获取再发起安装。
      if (generation != _currentModuleGeneration(module)) {
        throw ModuleInstallFailedException(
          module,
          StateError('模块 $module 安装尝试已在回退后作废'),
        );
      }
      attempt++;
      final outcome = await _ensureSingleFlight(module, policy);
      // ensure 在途期间被作废：其 outcome 不可信（_ensureOnlyInternal 已把过期尝试
      // 的成功转为 failure），此处直接放弃本获取，不进入 initializing/ready。
      if (generation != _currentModuleGeneration(module)) {
        throw ModuleInstallFailedException(
          module,
          StateError('模块 $module 安装尝试已在回退后作废'),
        );
      }
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
          // 实例创建期间被作废：丢弃实例，绝不写回缓存。
          if (generation != _currentModuleGeneration(module)) {
            await _disposeQuietly(instance);
            throw const _AttemptInvalidated();
          }
          _instances[key] = instance;
          _emit(ModuleBootstrapState(
            module: module,
            phase: ModuleBootstrapPhase.ready,
            progress: 1.0,
            attempt: attempt,
          ));
          return instance;
        } on _AttemptInvalidated {
          // 专用哨兵：该失败不可退避重试，直接以 [ModuleInstallFailedException]
          // 终结本次获取（否则通用 catch 会把它当作可重试的实例化失败）。
          throw ModuleInstallFailedException(
            module,
            StateError('模块 $module 实例创建已在回退后作废'),
          );
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

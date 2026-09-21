import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_service.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

/// [IDownloadService] 的**惰性路由**：把 Rust 内核的决策从启动期推迟到
/// 首次真实使用（第一个**变更类**调用），并在内核不可用时静默回落到 Dart。
///
/// 为什么要有这一层：启动期探测内核不仅拖慢冷启动，还会把下载能力绑死在
/// 启动那一刻的状态上（模块当时不在，就整个进程回退 Dart）。这里改成：
/// [getTask] / [listTasks] / [watch] / [watchAll] 这类入口先用构造时传入的
/// Dart 实现顶着，真正的 [download] / [pause] / … 才去解析内核；解析单飞、
/// 结果缓存。探测**超时**是可恢复的：发起解析的**首个**调用最多等待
/// `resolutionTimeout` 才以 Dart 执行（有界，绝不无限挂起）；随后处于重试冷却
/// 期内的调用**不等待**、直接以 Dart 执行，待冷却结束后由下一次调用在有限预算
/// 内重试，预算耗尽才永久回落。探测 false / 抛异常 / 工厂构造失败则一次即永久
/// 回落 Dart。
///
/// **不存在"绕过清单直连 URL"的兜底**：模块若不在 manifest 里，
/// [RustDownloadService] 的门无法解析到任何远端目标（`_remoteTarget`
/// 在直接链接回退之前就返回 `null`），因此本路由的回退目标**只有** Dart
/// 实现——不能指望"拿 URL 直接下 `.so`"来救场。该约束由清单校验固化。
///
/// 事件流语义：每次 [watch] / [watchAll] 只建立一个**长期**订阅——先订阅
/// Dart 实现，解析完成后原子切换到 Rust 流；**同一条订阅**在切换后继续投递
/// Rust 事件，消费方无需（也不应）重新绑定。订阅事件流本身**不**触发解析。
class LazyDownloadService implements IDownloadService {
  /// 单次内核解析（探测 + 工厂构造）允许的最长耗时。
  ///
  /// 为什么需要上限：[_resolve] 只捕获**抛出**的异常，捕获不了**永不完成**的
  /// 探测（例如原生层/线程池卡死）。此时所有变更类调用都会 `await` 同一个永不
  /// 完成的 Future，[_active] 永远停在 Dart、且没有终态信号——整个下载能力被
  /// 无限期挂起且无法恢复。加一个有界超时后，超时即判定本次不可用，服务始终
  /// 可用（绝不无限挂起）。
  ///
  /// 取值 10 秒：探测是「内核是否已挂载」的本地握手，正常在毫秒级返回；但首次
  /// FFI 通道往返 / `dlopen` 在低端设备冷启动时可能明显偏慢，过短的 2 秒会把
  /// 「健康但慢」的冷启动误判为不可用。10 秒为慢冷启动留出余量，同时保持有界：
  /// 单次调用最多等 10 秒即回落。测试经构造参数 `resolutionTimeout` 注入更短值。
  static const Duration defaultResolutionTimeout = Duration(seconds: 10);

  /// 超时属于**可恢复**失败：在预算内，后来的调用允许重新解析。
  ///
  /// 取值 3：慢冷启动只需一次成功的重试即可切回 Rust；对真正卡死的探测，最多
  /// 尝试 3 次后**永久**回落 Dart，避免整个进程反复付出
  /// [defaultResolutionTimeout] 的等待。探测返回 false / 抛异常 / 工厂构造失败
  /// 仍视为**不可恢复**——一次即永久回落（语义不变）。
  static const int defaultMaxResolutionAttempts = 3;

  /// 两次超时重试之间的最小间隔。
  ///
  /// 冷却期内变更类调用直接走 Dart、不再等待，避免连续多次撞上同一个卡死探测
  /// （每次都等满 [defaultResolutionTimeout]）；冷却结束后由下一次调用发起重试。
  /// 测试注入 `Duration.zero` 可立即重试。
  static const Duration defaultResolutionRetryCooldown = Duration(seconds: 30);

  /// 构造惰性路由。
  ///
  /// [dartFallback] 是构造时即持有的 Dart 实现（只读入口与回落目标）。
  /// [rustProbe] / [rustServiceFactory] 仅用于测试注入：默认分别取
  /// `RustDownloadService.instance.isAvailable` 与 `RustDownloadService.instance`。
  /// [resolutionTimeout] 为单次解析上限，默认 [defaultResolutionTimeout]；
  /// [maxResolutionAttempts] 为超时重试预算，默认
  /// [defaultMaxResolutionAttempts]；[resolutionRetryCooldown] 为超时重试冷却，
  /// 默认 [defaultResolutionRetryCooldown]。
  LazyDownloadService(
    IDownloadService dartFallback, {
    Future<bool> Function()? rustProbe,
    IDownloadService Function()? rustServiceFactory,
    Duration resolutionTimeout = defaultResolutionTimeout,
    int maxResolutionAttempts = defaultMaxResolutionAttempts,
    Duration resolutionRetryCooldown = defaultResolutionRetryCooldown,
  })  : _dart = dartFallback,
        _rustProbe =
            rustProbe ?? (() => RustDownloadService.instance.isAvailable),
        _rustServiceFactory =
            rustServiceFactory ?? (() => RustDownloadService.instance),
        _resolutionTimeout = resolutionTimeout,
        _maxResolutionAttempts = maxResolutionAttempts,
        _resolutionRetryCooldown = resolutionRetryCooldown;

  final IDownloadService _dart;
  final Future<bool> Function() _rustProbe;
  final IDownloadService Function() _rustServiceFactory;
  final Duration _resolutionTimeout;
  final int _maxResolutionAttempts;
  final Duration _resolutionRetryCooldown;

  /// 解析出的 Rust 实现；回退时为 null。
  IDownloadService? _rust;

  /// 单飞：首次变更类调用创建，后续调用复用同一个 Future。
  Future<void>? _resolution;

  /// 解析是否已经**终态**（永久选中 Rust 或永久回退 Dart）。
  bool _resolved = false;

  /// 是否选中 Rust。
  bool _useRust = false;

  /// 已进行的解析尝试次数（含当前正在进行的这次）。
  int _resolutionAttempts = 0;

  /// 超时重试冷却截止时刻；非空且未到期时，变更类调用直接走 Dart，不发起新尝试。
  DateTime? _retryNotBefore;

  /// 解析完成广播（供订阅中的事件流切换数据源，不重放历史）。
  final StreamController<void> _resolutionEvents = StreamController<void>.broadcast();

  /// 当前应使用的实现：解析完成且选中 Rust 时用 Rust，否则用 Dart。
  IDownloadService get _active {
    final rust = _rust;
    return (_resolved && _useRust && rust != null) ? rust : _dart;
  }

  /// 任务 id → **创建该任务的实现**（按任务固定归属）。
  ///
  /// 为什么需要：一个任务可能在解析尚未完成（或超时冷却期内）由 Dart 创建，随后
  /// 一次外部变更调用把路由 promotion 到 Rust。若事后仍按全局 [_active] 查找/监听该
  /// 任务，它就会"消失"在 Rust 侧（Rust 的 store 里没有它）——[getTask] 取不到，
  /// [watch] 的合并流还会被换源，其终态事件永远无法送达（调用方一直等到超时）。
  /// 固定归属保证：由谁创建，就始终由谁承载读取、监听与变更派发。
  ///
  /// **id 不是全局唯一**：Dart 实现（Floor 自增主键）与 Rust 内核（模块自有 store）
  /// 各自维护独立序列，通常都从 1 开始，同一个 int 可能指向两个不同的任务。因此本
  /// 表只在「本路由亲自创建过该 id」时有意义；若多实现产生相同 id，则后创建者覆盖
  /// （last-write-wins）。跨实现去重不在本层职责内。
  ///
  /// **恢复任务（post-restart residual）**：应用重启后从 Floor 恢复的未完成任务未经
  /// 过 [download]，因此由 [_resolve] 在 promotion 那一刻通过 [_pinDartTasks] 统一
  /// 登记归属，使其与新建任务享受同一套固定归属语义；即便列举失败，[getTask] 的
  /// 回退读取与 [listTasks] / [watchAll] 的并集仍能兜底。
  final Map<int, IDownloadService> _taskOwner = <int, IDownloadService>{};

  /// 某任务应使用的实现：优先创建它的实现（固定归属），否则按当前活跃实现。
  IDownloadService _implForTask(int id) => _taskOwner[id] ?? _active;

  /// promotion 时列举 Dart 实现当前任务并登记固定归属。
  ///
  /// 覆盖 [download] / [downloadWithContext] 覆盖不到的场景：应用启动时从 Floor
  /// 恢复的未完成任务从未经过本路由，若不在此登记，promotion 后它们会"消失"。
  ///
  /// 失败**不得**中止 promotion：捕获并记录后继续（禁止空 catch）。列举失败只
  /// 意味着这些任务暂未固定归属——[getTask] 的回退读取仍能取到，[listTasks] /
  /// [watchAll] 的并集仍会把它们带回，服务不会因此不可用。
  Future<void> _pinDartTasks() async {
    try {
      // 必须**有界**：`_resolve()` 位于变更类调用的关键路径上，若 `listTasks`
      // 永不完成（Floor 卡死等），promotion 会被无限期拖住、连带所有变更调用一起
      // 挂起——这正是本类用 [_resolutionTimeout] 约束探测的同一个理由。超时按
      // 「本次列举未登记」处理：promotion 照常进行，可达性由 [getTask] 的回退读取
      // 兜底，绝不因一次枚举失败而丢失整个下载能力。
      final dartTasks = await _dart.listTasks().timeout(_resolutionTimeout);
      for (final task in dartTasks) {
        final id = task.id;
        if (id != null) _taskOwner[id] = _dart;
      }
    } catch (e) {
      debugPrint(
        'LazyDownloadService: promotion 时列举 Dart 任务失败（$e），'
        '已恢复任务暂不固定归属（getTask 有回退兜底）',
      );
    }
  }

  /// 单飞解析：首个调用创建 `_resolve()`，其余调用复用其 Future。
  ///
  /// 已终态直接返回；超时冷却期内返回已完成的 Future（本次调用走 Dart，不挂起、
  /// 不重新探测）；冷却结束后发起新尝试。
  Future<void> _ensureResolved() {
    if (_resolved) return Future<void>.value();
    final retryNotBefore = _retryNotBefore;
    if (retryNotBefore != null && DateTime.now().isBefore(retryNotBefore)) {
      return Future<void>.value();
    }
    return _resolution ??= _resolve();
  }

  /// 尝试解析一次内核（**有界**）。
  ///
  /// 超时 → **可恢复**：不冻结结果，留给冷却后的下一次调用在预算内重试；预算
  /// 耗尽才永久回落。探测 false / 抛异常 / 工厂构造抛错 → 永久回落。
  /// 每次尝试至多打印一条告警（超时重试场景最多 [defaultMaxResolutionAttempts]
  /// 条；false/异常等永久失败只一条）。
  Future<void> _resolve() async {
    _resolutionAttempts++;
    _retryNotBefore = null;

    var available = false;
    Object? cause;
    var timedOut = false;
    try {
      available = await _rustProbe().timeout(_resolutionTimeout);
    } on TimeoutException catch (e) {
      // 探测永不完成（或慢于上限）：本次判定不可用，但保留可恢复性。
      timedOut = true;
      cause = e;
      available = false;
    } catch (e) {
      cause = e;
      available = false;
    }

    if (available) {
      try {
        _rust = _rustServiceFactory();
      } catch (e) {
        cause = e;
        _rust = null;
      }
    }
    _useRust = _rust != null;

    if (_useRust) {
      // promotion 前必须先登记 Dart 侧现有任务（含应用启动时从 Floor 恢复、
      // 未经 download() 的任务）的固定归属：否则切到 Rust 后它们会从
      // getTask / watch / listTasks / 变更派发中"消失"。
      await _pinDartTasks();
      _resolved = true;
      _resolution = null;
      if (!_resolutionEvents.isClosed) _resolutionEvents.add(null);
      return;
    }

    final detail = cause == null ? '' : '（$cause）';
    final attemptNote = timedOut
        ? '（第 $_resolutionAttempts/$_maxResolutionAttempts 次尝试超时，'
            '${_resolutionAttempts < _maxResolutionAttempts ? '冷却后重试' : '已达上限'}）'
        : '';
    debugPrint(
      'LazyDownloadService: Rust 下载内核不可用$detail$attemptNote，回落到 Dart 实现',
    );

    // 单飞结束，允许后续调用（冷却后）发起新尝试。
    _resolution = null;

    final canRetry = timedOut && _resolutionAttempts < _maxResolutionAttempts;
    if (canRetry) {
      // 可恢复：本次调用已走 Dart；冷却后由下一次调用重试。
      _resolved = false;
      _retryNotBefore = DateTime.now().add(_resolutionRetryCooldown);
      return;
    }

    // 预算耗尽，或不可恢复失败：永久回落 Dart。
    _resolved = true;
    if (!_resolutionEvents.isClosed) _resolutionEvents.add(null);
  }

  // ---------------------------------------------------------------------------
  // 变更类方法：首次调用触发一次内核解析
  // ---------------------------------------------------------------------------

  @override
  Future<DownloadTask> download(
    String appid,
    String appName,
    String version,
    String url,
    String fileName, {
    int? downloadSize,
    bool breakPoint = true,
    String? saveFileName,
    bool forceDownload = false,
    bool installAfterDownload = true,
  }) async {
    await _ensureResolved();
    // 先捕获本次调用实际使用的实现，再在其上创建任务；任务 id 一旦返回即固定归属，
    // 之后无论路由是否 promotion 到 Rust，该任务都留在创建它的实现上。
    final impl = _active;
    final task = await impl.download(
      appid,
      appName,
      version,
      url,
      fileName,
      downloadSize: downloadSize,
      breakPoint: breakPoint,
      saveFileName: saveFileName,
      forceDownload: forceDownload,
      installAfterDownload: installAfterDownload,
    );
    final id = task.id;
    if (id != null) _taskOwner[id] = impl;
    return task;
  }

  @override
  Future<DownloadTask> downloadWithContext(
    DownloadRequest request,
    String appid,
    String appName,
    String version,
    String fileName, {
    bool breakPoint = true,
    String? saveFileName,
    bool installAfterDownload = true,
  }) async {
    await _ensureResolved();
    final impl = _active;
    final task = await impl.downloadWithContext(
      request,
      appid,
      appName,
      version,
      fileName,
      breakPoint: breakPoint,
      saveFileName: saveFileName,
      installAfterDownload: installAfterDownload,
    );
    final id = task.id;
    if (id != null) _taskOwner[id] = impl;
    return task;
  }

  // 变更类方法保留 [_ensureResolved]（promotion 仍会发生），但派发到任务的**固定
  // 归属**实现：由 Dart 创建的任务即使内核已就绪，也继续在 Dart 上暂停/取消等，
  // 否则该 id 在 Rust store 里不存在，变更会被误派发或静默丢弃。

  @override
  Future<void> pause(int id) async {
    await _ensureResolved();
    return _implForTask(id).pause(id);
  }

  @override
  Future<void> resume(int id) async {
    await _ensureResolved();
    return _implForTask(id).resume(id);
  }

  @override
  Future<void> cancel(int id) async {
    await _ensureResolved();
    return _implForTask(id).cancel(id);
  }

  @override
  Future<void> retry(int id) async {
    await _ensureResolved();
    return _implForTask(id).retry(id);
  }

  @override
  Future<void> restart(int id) async {
    await _ensureResolved();
    return _implForTask(id).restart(id);
  }

  @override
  Future<void> remove(int id) async {
    await _ensureResolved();
    final impl = _implForTask(id);
    // 任务被移除后固定归属也随之失效：后续同 id 查询回到活跃实现
    // （该 id 可能对应另一实现上的任务）。
    _taskOwner.remove(id);
    return impl.remove(id);
  }

  // ---------------------------------------------------------------------------
  // 只读方法：不触发解析，按当前活跃实现代理
  // ---------------------------------------------------------------------------

  // 只读入口按任务的固定归属路由（不触发解析）：由 Dart 创建的任务即使路由已
  // promotion 到 Rust，仍可从 Dart 取回，不会"消失"。

  /// 读取任务，按固定归属路由（不触发解析）。
  ///
  /// **回退读取**：若未固定归属、当前活跃实现不是 Dart，且活跃实现取不到该 id，
  /// 则再向 Dart 读一次。promotion 后仍可能只有 Dart 侧存在该任务（启动时恢复
  /// 但 [listTasks] 列举失败/竞态而未被固定归属）。回退**只读**——不解析、不安装、
  /// 不修改归属，仅一次额外查询；固定归属的 id 不会进入回退分支。
  @override
  Future<DownloadTask?> getTask(int id) async {
    final impl = _implForTask(id);
    final task = await impl.getTask(id);
    if (task != null || identical(impl, _dart)) return task;
    return _dart.getTask(id);
  }

  /// 列出全部任务。
  ///
  /// 无固定归属任务时（[_taskOwner] 为空）**与旧实现逐字节同语义**：直接代理
  /// 当前活跃实现。一旦存在固定归属任务，则返回 Dart 与活跃实现的**并集**（按
  /// id 去重，归属条目获胜，见 [_mergeByOwnership]），避免 promotion 后 Dart 侧
  /// 遗留任务从下载面板消失。
  @override
  Future<List<DownloadTask>> listTasks() async {
    if (_taskOwner.isEmpty) return _active.listTasks();
    final active = _active;
    final dartTasks = await _dart.listTasks();
    final rustTasks = identical(active, _dart)
        ? const <DownloadTask>[]
        : await active.listTasks();
    return _mergeByOwnership(dartTasks, rustTasks);
  }

  /// 按 id 合并 Dart 与 Rust 任务列表。
  ///
  /// 优先级规则（确定性）：
  /// - 某 id 在 [_taskOwner] 中有归属：由该归属实现的条目获胜
  ///   （归属 Dart → Dart 条目；归属 Rust → Rust 条目）；
  /// - 无归属的 id：优先 Dart（Dart 有则用 Dart，否则用 Rust）；
  /// - 无 id 的任务（理论不应出现）按出现顺序追加，不做去重。
  ///
  /// 输出顺序：先 Dart 侧顺序，再补 Rust 独有的 id。
  List<DownloadTask> _mergeByOwnership(
    List<DownloadTask> dartTasks,
    List<DownloadTask> rustTasks,
  ) {
    final merged = <int, DownloadTask>{};
    final unkeyed = <DownloadTask>[];

    // Dart 条目先入（无归属 id 的默认胜者）。
    for (final task in dartTasks) {
      final id = task.id;
      if (id == null) {
        unkeyed.add(task);
      } else {
        merged[id] = task;
      }
    }
    // Rust 条目仅在「无归属」或「归属为 Rust」时覆盖/补齐。
    for (final task in rustTasks) {
      final id = task.id;
      if (id == null) {
        unkeyed.add(task);
        continue;
      }
      final owner = _taskOwner[id];
      if (owner == null) {
        merged.putIfAbsent(id, () => task); // 无归属：Dart 优先
      } else if (!identical(owner, _dart)) {
        merged[id] = task; // 归属非 Dart（即 Rust）：Rust 条目获胜
      }
      // 归属为 Dart：保留已放入的 Dart 条目。
    }
    return <DownloadTask>[...merged.values, ...unkeyed];
  }

  // ---------------------------------------------------------------------------
  // 事件流：单条长期订阅，解析后原地换源
  // ---------------------------------------------------------------------------

  @override
  Stream<DownloadTask> watch(int id) {
    // 固定归属的任务：直接绑定创建它的实现，**不订阅** [_resolutionEvents]，
    // 因此 promotion 时不会换源、不会取消该订阅——终态事件必达。
    final owner = _taskOwner[id];
    if (owner != null) {
      return owner.watch(id);
    }
    // 未固定 id：先绑定 Dart；若 promotion 把该 id 固定归属 Dart（恢复任务），
    // 则**不换源**，同一条订阅继续投递 Dart 事件。
    return _mergedStream(
      () => _dart.watch(id),
      () => _rust!.watch(id),
      taskId: id,
    );
  }

  /// 全局任务流。
  ///
  /// 复用同一条「先 Dart、解析终态后按固定归属决定去向」的长期流：无固定归属
  /// 任务时与旧实现逐字节同语义（只换源）；一旦存在固定归属任务（promotion 时
  /// 登记，含 Floor 恢复任务），则在换源/初始绑定时**并集** Dart 与 Rust，避免
  /// Dart 侧遗留任务的更新被冻结。
  @override
  Stream<DownloadTask> watchAll() =>
      _mergedStream(() => _dart.watchAll(), () => _rust!.watchAll());

  /// 构造一条"先 Dart、解析后原地换源 Rust"的长期流。
  ///
  /// 关键点：
  /// - 立即订阅 Dart（回退事件不断流）；
  /// - 解析**终态**后按**固定归属**决定去向：若 [taskId] 被固定到 Dart，保持
  ///   Dart 订阅不换源；[taskId] 为 null（[watchAll]）且已存在固定归属任务时，
  ///   保留 Dart 订阅并**叠加** Rust（并集）；其余情况取消 Dart、改订阅 Rust；
  ///   同一条外层订阅继续投递；
  /// - 超时可恢复期间持续保留 Dart 订阅，待后续重试成功后仍能换源；
  /// - [onListen] 绝不调用 [_ensureResolved]，所以订阅 `watchAll` 不触发安装；
  /// - 已解析后再订阅，直接绑定当前活跃实现（[watchAll] 在存在固定归属任务时
  ///   同时绑定 Dart 与活跃实现）。
  Stream<DownloadTask> _mergedStream(
    Stream<DownloadTask> Function() dartStream,
    Stream<DownloadTask> Function() rustStream, {
    int? taskId,
  }) {
    late StreamController<DownloadTask> controller;
    StreamSubscription<DownloadTask>? dartSub;
    StreamSubscription<DownloadTask>? rustSub;
    StreamSubscription<void>? resolutionSub;
    var closed = false;
    var dartDone = false;

    void add(DownloadTask task) {
      if (!controller.isClosed) controller.add(task);
    }

    void addError(Object error, StackTrace stack) {
      if (!controller.isClosed) controller.addError(error, stack);
    }

    void close() {
      if (!controller.isClosed) controller.close();
    }

    bool noSubs() => dartSub == null && rustSub == null;

    void bindDart() {
      dartSub = dartStream().listen(
        add,
        onError: addError,
        onDone: () {
          dartSub = null;
          dartDone = true;
          // 解析终态且已无其它源时照实结束；未终态（超时重试冷却中）或仍有
          // Rust 订阅（并集）时保持外层存活。
          if (_resolved && noSubs()) close();
        },
      );
    }

    void bindRust() {
      rustSub = rustStream().listen(
        add,
        onError: addError,
        onDone: () {
          rustSub = null;
          if (noSubs()) close();
        },
      );
    }

    Future<void> switchToResolved() async {
      if (closed) return;
      final rust = _rust;
      if (_resolved && _useRust && rust != null) {
        // 本流关心的 id 已固定归属 Dart：保持 Dart 订阅，绝不换源。
        if (taskId != null && identical(_taskOwner[taskId], _dart)) return;
        // watchAll 且已有固定归属任务：保留 Dart 并叠加 Rust（并集）。
        if (taskId == null && _taskOwner.isNotEmpty) {
          if (rustSub == null) bindRust();
          return;
        }
        // 其余：取消 Dart，换源 Rust。
        final old = dartSub;
        dartSub = null;
        if (old != null) await old.cancel();
        if (closed) return;
        if (rustSub == null) bindRust();
        return;
      }
      // 解析已永久回退 Dart：Dart 流若已结束且无其它源，同步结束外层流。
      // 未终态（超时重试冷却中）则什么都不做，保持 Dart 订阅等待后续结果。
      if (_resolved && dartDone && noSubs()) close();
    }

    void bindInitial() {
      if (_resolved) {
        if (_useRust && _rust != null) {
          // 单任务若已固定归属 Dart 必绑 Dart；watchAll 有固定归属任务时并集
          // （Dart + Rust）；否则绑 Rust。
          if (taskId != null && identical(_taskOwner[taskId], _dart)) {
            bindDart();
          } else if (taskId == null && _taskOwner.isNotEmpty) {
            bindDart();
            bindRust();
          } else {
            bindRust();
          }
        } else {
          bindDart();
        }
        return;
      }
      bindDart();
      // 超时可能只产生「可恢复」结果，故持续监听直到解析真正终态。
      resolutionSub = _resolutionEvents.stream.listen(
        (_) {
          switchToResolved();
          if (_resolved) {
            resolutionSub?.cancel();
            resolutionSub = null;
          }
        },
        onError: (Object error, StackTrace stack) {
          debugPrint('LazyDownloadService: 解析事件流异常（$error）');
        },
      );
    }

    controller = StreamController<DownloadTask>(
      onListen: bindInitial,
      onCancel: () async {
        closed = true;
        final resSub = resolutionSub;
        resolutionSub = null;
        await resSub?.cancel();
        final oldDart = dartSub;
        dartSub = null;
        await oldDart?.cancel();
        final oldRust = rustSub;
        rustSub = null;
        await oldRust?.cancel();
      },
    );

    return controller.stream;
  }
}

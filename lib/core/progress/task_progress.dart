import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

/// 任务的**宏观阶段**（与底层下载/解析步骤解耦）。
///
/// * [running] —— 任务进行中（可带进度、阶段文案与详情）。
/// * [ready]   —— 任务已成功完成（终态；短暂停留后自动移除）。
/// * [failed]  —— 任务失败（终态；短暂停留后自动移除）。
///
/// 终态**不粘滞**：同一 [TaskProgressState.id] 再次 `begin` 会立刻以新的
/// [TaskProgressState.generation] 取代旧条目。
enum TaskPhase { running, ready, failed }

/// 单个任务的进度快照（不可变）。
///
/// 由 [TaskProgressHub.states] / [TaskProgressHub.watch] 对外发布；UI 层只读取，
/// 不直接构造。`==` / `hashCode` 有意不实现——消费方按 [id] / [cardKey] 归并，
/// 不依赖值相等。
class TaskProgressState {
  /// 任务唯一标识（如 `'module:repo'`、`'fdroid-sync'`）。
  final String id;

  /// 归并/去重键：UI 用它在多来源之间合并同一张卡片。
  ///
  /// [TaskProgressHub.begin] 未显式给 `groupKey` 时等于 [id]。
  final String cardKey;

  /// 当前阶段。
  final TaskPhase phase;

  /// 卡片标题（中文，面向用户）。
  final String label;

  /// 阶段文案（如 `'下载中'` / `'下载索引 42%'` / `'解析入库'` / `'已就绪'`）。
  final String? stage;

  /// 详情文案（如 `'约 12.3 MB · 仅需一次'`）。
  final String? detail;

  /// 完成比例 `[0,1]`；`null` 表示**不确定进度**（UI 应显示为无限滚动）。
  final double? progress;

  /// 期望/实际字节数（用于格式化体积）；未知为 `null`。
  final int? sizeBytes;

  /// 失败时的原始错误对象（非失败为 `null`）；保留原文供诊断。
  final Object? error;

  /// 该条目的**代次**（单调递增）。
  ///
  /// 用于**过期票据守卫**：票据只在其 `generation` 等于该 id 当前条目的
  /// `generation` 时才能修改状态，从而杜绝「旧任务的迟到回调覆盖新任务」。
  final int generation;

  /// 构造一个状态快照。
  const TaskProgressState({
    required this.id,
    required this.cardKey,
    required this.phase,
    required this.label,
    this.stage,
    this.detail,
    this.progress,
    this.sizeBytes,
    this.error,
    required this.generation,
  });

  /// 派生一个新快照（未传入的字段保持不变）。
  ///
  /// 注意：可空字段采用「非空参数覆盖」语义——无法用本方法把字段**显式清回
  /// `null`**。内部更新路径只**追加**信息（进度/阶段/详情/体积），不依赖清除
  /// 语义，故保持签名简洁。
  TaskProgressState copyWith({
    String? id,
    String? cardKey,
    TaskPhase? phase,
    String? label,
    String? stage,
    String? detail,
    double? progress,
    int? sizeBytes,
    Object? error,
    int? generation,
  }) {
    return TaskProgressState(
      id: id ?? this.id,
      cardKey: cardKey ?? this.cardKey,
      phase: phase ?? this.phase,
      label: label ?? this.label,
      stage: stage ?? this.stage,
      detail: detail ?? this.detail,
      progress: progress ?? this.progress,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      error: error ?? this.error,
      generation: generation ?? this.generation,
    );
  }

  @override
  String toString() => 'TaskProgressState(id=$id, cardKey=$cardKey, '
      'phase=$phase, label=$label, stage=$stage, detail=$detail, '
      'progress=$progress, sizeBytes=$sizeBytes, generation=$generation, '
      'error=$error)';
}

/// 一次任务的写句柄。
///
/// 由 [TaskProgressHub.begin] 返回；持有发起时的 [generation] 作为**过期守卫**：
/// 若该 id 已被后续 `begin` 取代（或已被移除），[update]/[ready]/[fail] 会被
/// **静默忽略**，绝不污染新条目。这与 `ModuleBootstrap._PendingEnsure` 的代次
/// 守卫是同一惯用法。
class TaskTicket {
  TaskTicket._(this._hub, this.id, this.generation);

  final TaskProgressHub _hub;

  /// 任务唯一标识。
  final String id;

  /// 发起本票据时的代次（见 [TaskProgressState.generation]）。
  final int generation;

  /// 更新进行中的进度/文案（仅当本票据仍为当前代次时生效）。
  ///
  /// 传入的非空参数会覆盖对应字段；未传入的字段保持不变。
  void update({
    double? progress,
    String? stage,
    String? detail,
    int? sizeBytes,
  }) {
    _hub._update(
      id,
      generation,
      progress: progress,
      stage: stage,
      detail: detail,
      sizeBytes: sizeBytes,
    );
  }

  /// 标记任务成功：发布 `ready`，并在 [TaskProgressHub] 配置的 ready 停留期后
  /// 自动移除该条目（停留期仍可被 UI 展示「已就绪」）。
  void ready() => _hub._settle(id, generation, TaskPhase.ready, null);

  /// 标记任务失败：发布携带 [error] 的 `failed`，并在 failed 停留期后自动移除。
  void fail(Object error) => _hub._settle(id, generation, TaskPhase.failed, error);
}

/// 全局任务进度中枢（UI 无关）。
///
/// 任何长任务（模块安装、F-Droid 仓库索引同步、以及未来任务）都向此单例上报，
/// 顶部进度条订阅 [states] 后即可统一展示，而无需各自持有状态。
///
/// 设计要点：
/// * **快照即订阅**：[states] 在订阅的同一同步块内先发当前快照、再订阅广播流，
///   二者之间不可能插入一次发布（沿用 `ModuleBootstrap.states` 的正确性）。
/// * **过期票据守卫**：每个条目带单调递增代次；旧票据的迟到写操作被静默丢弃。
/// * **停留期可注入**：终态经 [_scheduler] 接缝延时移除，测试无需真实等待。
///
/// 单例**不依赖 Flutter 绑定**，可在纯 Dart 环境构造。
class TaskProgressHub {
  TaskProgressHub._();

  static TaskProgressHub? _instance;

  /// 单例入口。
  static TaskProgressHub get instance => _instance ??= TaskProgressHub._();

  /// `ready` 终态的默认停留时长（让 UI 有机会展示「已就绪」）。
  static const Duration defaultReadyLinger = Duration(milliseconds: 1500);

  /// `failed` 终态的默认停留时长（略长，便于用户看清错误）。
  static const Duration defaultFailedLinger = Duration(milliseconds: 4000);

  /// 当前全部非空条目（键为 [TaskProgressState.id]）。
  ///
  /// 同 id 再次 `begin` 只替换值、不改变键顺序；快照另行排序保证确定性。
  final Map<String, TaskProgressState> _entries = <String, TaskProgressState>{};

  /// 单任务状态广播流（[watch] 使用；不广播「移除」，见 [watch] 文档）。
  final StreamController<TaskProgressState> _stateController =
      StreamController<TaskProgressState>.broadcast();

  /// 聚合状态广播流（[states] 使用）。
  final StreamController<List<TaskProgressState>> _statesController =
      StreamController<List<TaskProgressState>>.broadcast();

  /// 每个 id 的**待移除令牌**：clear/再次 begin/debugReset 会移除令牌，使已排定
  /// 的停留回调失效（schedule 接缝返回 `void`，无法取消真实 `Timer`，故用令牌
  /// 做代次失效，回调即使触发也不再触碰条目）。
  final Map<String, int> _lingerTokens = <String, int>{};

  /// 单调递增的代次序号（[TaskProgressState.generation] 的来源）。
  int _generationSeq = 0;

  /// 停留调度的令牌序号（每次排定自增）。
  int _lingerSerial = 0;

  /// 生效的 ready 停留时长（可经 [debugConfigure] 注入）。
  Duration _readyLinger = defaultReadyLinger;

  /// 生效的 failed 停留时长（可经 [debugConfigure] 注入）。
  Duration _failedLinger = defaultFailedLinger;

  /// 调度接缝覆盖（`null` 时用 [Timer]）。
  void Function(Duration, void Function())? _scheduleOverride;

  /// 当前全部条目的聚合流。
  ///
  /// 订阅时**同步发布当前快照**，并在同一同步块内订阅广播流；因此二者之间
  /// 不可能插入一次发布，不会丢失快照与后续事件之间的状态（与
  /// `ModuleBootstrap.states` 同构）。每次发布都是**新列表实例**，绝不原地修改
  /// 已发出的列表。快照按 `cardKey` 再按 `id` 升序，保证顺序确定。
  ///
  /// 多监听者各自独立收到快照与后续事件，互不影响。
  Stream<List<TaskProgressState>> get states =>
      Stream<List<TaskProgressState>>.multi((multi) {
        // 同一同步块：读快照 + 订阅广播，单线程下两者之间无法发生发布。
        multi.add(_snapshot());
        final subscription = _statesController.stream.listen(
          multi.add,
          onError: multi.addError,
          onDone: multi.close,
        );
        multi.onCancel = subscription.cancel;
      });

  /// 订阅某 id 的状态流（广播）。
  ///
  /// 订阅时**同步发布该 id 的当前条目**（若存在），并在同一同步块内订阅广播流，
  /// 因此不存在「读缓存 → 订阅」的时间窗。
  ///
  /// **移除语义（有意决策）**：条目被自动移除（终态停留期结束）或 [clear] 后，
  /// 本流**不发布任何移除事件，也**不关闭**；订阅保持打开，且在**同一 id 再次
  /// `begin`** 时恢复发布。消费方若需要感知移除，应改订 [states]（其聚合快照会
  /// 不再包含该条目）。这样选择是为了与 `ModuleBootstrap.watch`（只转发存在的
  /// 状态）保持一致，并避免调用方在终态后仍需自行重订阅。
  Stream<TaskProgressState> watch(String id) {
    final controller = StreamController<TaskProgressState>(sync: true);
    StreamSubscription<TaskProgressState>? subscription;
    controller.onListen = () {
      // 同一同步块：读缓存 + 订阅广播，单线程下两者之间无法发生发布。
      final cached = _entries[id];
      if (cached != null) controller.add(cached);
      subscription = _stateController.stream
          .where((state) => state.id == id)
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

  /// 开始（或取代）一个任务，返回其写票据。
  ///
  /// [groupKey] 非空时作为 [TaskProgressState.cardKey]（供 UI 归并），否则等于
  /// [TaskProgressState.id]。
  ///
  /// 若该 id 已有条目（无论进行中还是尚未移除的终态），本次调用会**取代**它：
  /// 分配新 [TaskProgressState.generation]、替换条目、并使任何旧的停留回调与旧
  /// 票据失效——旧票据的 `update`/`ready`/`fail` 从此被静默忽略。
  TaskTicket begin({
    required String id,
    required String label,
    String? groupKey,
    String? stage,
    String? detail,
    int? sizeBytes,
  }) {
    final generation = ++_generationSeq;
    // 取代旧条目：先失效其待移除令牌，防止旧停留回调删除新条目。
    _invalidateLinger(id);
    _entries[id] = TaskProgressState(
      id: id,
      cardKey: groupKey ?? id,
      phase: TaskPhase.running,
      label: label,
      stage: stage,
      detail: detail,
      sizeBytes: sizeBytes,
      generation: generation,
    );
    _emit(id);
    return TaskTicket._(this, id, generation);
  }

  /// 立即移除某 id 的条目，并使任何待触发的停留回调失效。
  ///
  /// 用于任务被取消/放弃的场景：移除后旧停留回调即使触发也不会「复活」或误删。
  void clear(String id) {
    _invalidateLinger(id);
    if (_entries.remove(id) != null) {
      _publishSnapshot();
    }
  }

  /// 注入测试接缝：停留时长与调度器。
  ///
  /// [schedule] 为 `(duration, callback)`；生产默认 `Timer(duration, callback)`。
  /// 测试可捕获回调并手动触发，从而**不等待真实定时器**。未传入的项恢复默认。
  @visibleForTesting
  void debugConfigure({
    Duration? readyLinger,
    Duration? failedLinger,
    void Function(Duration, void Function())? schedule,
  }) {
    _readyLinger = readyLinger ?? defaultReadyLinger;
    _failedLinger = failedLinger ?? defaultFailedLinger;
    _scheduleOverride = schedule;
  }

  /// 清空全部条目、使所有待移除令牌失效、并恢复默认时长与调度器。
  ///
  /// 调度接缝返回 `void`，无法取消已排定的真实 `Timer`；此处通过使令牌失效达成
  /// 等价的「取消」——已排定回调触发时因令牌不匹配而空转。
  @visibleForTesting
  void debugReset() {
    _entries.clear();
    _lingerTokens.clear();
    _generationSeq = 0;
    _lingerSerial = 0;
    _readyLinger = defaultReadyLinger;
    _failedLinger = defaultFailedLinger;
    _scheduleOverride = null;
  }

  // ---- 内部实现 ----

  /// 更新进行中字段（过期票据守卫见类文档）。
  void _update(
    String id,
    int generation, {
    double? progress,
    String? stage,
    String? detail,
    int? sizeBytes,
  }) {
    final current = _entries[id];
    if (current == null || current.generation != generation) {
      debugPrint(
        'TaskProgressHub: 忽略过期/已移除票据的 update（id=$id, '
        'ticket=$generation, current=${current?.generation}）',
      );
      return;
    }
    _entries[id] = current.copyWith(
      progress: progress,
      stage: stage,
      detail: detail,
      sizeBytes: sizeBytes,
    );
    _emit(id);
  }

  /// 发布终态并排定停留期后的自动移除（移除同样受代次守卫）。
  void _settle(String id, int generation, TaskPhase phase, Object? error) {
    final current = _entries[id];
    if (current == null || current.generation != generation) {
      debugPrint(
        'TaskProgressHub: 忽略过期/已移除票据的 $phase（id=$id, '
        'ticket=$generation, current=${current?.generation}）',
      );
      return;
    }
    _entries[id] = current.copyWith(phase: phase, error: error);
    _emit(id);
    _scheduleRemoval(
      id,
      generation,
      phase == TaskPhase.ready ? _readyLinger : _failedLinger,
    );
  }

  /// 经调度接缝排定一次停留期后的移除。
  ///
  /// 排定前记录本次令牌；clear/再次 begin/debugReset 会使令牌失效，回调据此
  /// 空转。真正的移除仍调用 [_removeWhenCurrent] 再做一次代次校验——双重保险，
  /// 保证**过期停留绝不会删除同 id 的新条目**。
  void _scheduleRemoval(String id, int generation, Duration linger) {
    final serial = ++_lingerSerial;
    _lingerTokens[id] = serial;
    _scheduler(linger, () {
      if (_lingerTokens[id] != serial) return;
      _lingerTokens.remove(id);
      _removeWhenCurrent(id, generation);
    });
  }

  /// 仅当该 id 当前条目仍为给定代次时才移除（代次守卫）。
  void _removeWhenCurrent(String id, int generation) {
    final current = _entries[id];
    if (current == null || current.generation != generation) return;
    _entries.remove(id);
    _publishSnapshot();
  }

  /// 使某 id 的待移除令牌失效（清 clear/取代/reset 时调用）。
  void _invalidateLinger(String id) {
    _lingerTokens.remove(id);
  }

  /// 生效的调度器：注入优先，否则真实 [Timer]。
  void Function(Duration, void Function()) get _scheduler =>
      _scheduleOverride ?? _defaultSchedule;

  /// 生产默认调度器：真实定时器。
  static void _defaultSchedule(Duration duration, void Function() callback) {
    Timer(duration, callback);
  }

  /// 发布某 id 的状态到单条流，并发布一次聚合快照。
  void _emit(String id) {
    final state = _entries[id];
    if (state == null) return;
    if (!_stateController.isClosed) _stateController.add(state);
    _publishSnapshot();
  }

  /// 发布一次聚合快照（新列表实例）。
  void _publishSnapshot() {
    if (!_statesController.isClosed) _statesController.add(_snapshot());
  }

  /// 当前全部条目的新列表（`cardKey` 再 `id` 升序）。
  List<TaskProgressState> _snapshot() {
    return _entries.values.toList()
      ..sort((a, b) {
        final byCard = a.cardKey.compareTo(b.cardKey);
        return byCard != 0 ? byCard : a.id.compareTo(b.id);
      });
  }
}

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
    return _active.download(
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
    return _active.downloadWithContext(
      request,
      appid,
      appName,
      version,
      fileName,
      breakPoint: breakPoint,
      saveFileName: saveFileName,
      installAfterDownload: installAfterDownload,
    );
  }

  @override
  Future<void> pause(int id) async {
    await _ensureResolved();
    return _active.pause(id);
  }

  @override
  Future<void> resume(int id) async {
    await _ensureResolved();
    return _active.resume(id);
  }

  @override
  Future<void> cancel(int id) async {
    await _ensureResolved();
    return _active.cancel(id);
  }

  @override
  Future<void> retry(int id) async {
    await _ensureResolved();
    return _active.retry(id);
  }

  @override
  Future<void> restart(int id) async {
    await _ensureResolved();
    return _active.restart(id);
  }

  @override
  Future<void> remove(int id) async {
    await _ensureResolved();
    return _active.remove(id);
  }

  // ---------------------------------------------------------------------------
  // 只读方法：不触发解析，按当前活跃实现代理
  // ---------------------------------------------------------------------------

  @override
  Future<DownloadTask?> getTask(int id) => _active.getTask(id);

  @override
  Future<List<DownloadTask>> listTasks() => _active.listTasks();

  // ---------------------------------------------------------------------------
  // 事件流：单条长期订阅，解析后原地换源
  // ---------------------------------------------------------------------------

  @override
  Stream<DownloadTask> watch(int id) =>
      _mergedStream(() => _dart.watch(id), () => _rust!.watch(id));

  @override
  Stream<DownloadTask> watchAll() =>
      _mergedStream(() => _dart.watchAll(), () => _rust!.watchAll());

  /// 构造一条"先 Dart、解析后切 Rust"的长期流。
  ///
  /// 关键点：
  /// - 立即订阅 Dart（回退事件不断流）；
  /// - 解析**终态**后取消 Dart 内层订阅，改订阅 Rust；同一条外层订阅继续投递；
  /// - 超时可恢复期间持续保留 Dart 订阅，待后续重试成功后仍能换源；
  /// - [onListen] 绝不调用 [_ensureResolved]，所以订阅 `watchAll` 不触发安装；
  /// - 已解析后再订阅，直接绑定当前活跃实现。
  Stream<DownloadTask> _mergedStream(
    Stream<DownloadTask> Function() dartStream,
    Stream<DownloadTask> Function() rustStream,
  ) {
    late StreamController<DownloadTask> controller;
    StreamSubscription<DownloadTask>? sub;
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

    void bindDart() {
      sub = dartStream().listen(
        add,
        onError: addError,
        onDone: () {
          dartDone = true;
          // 解析终态时照实结束；未终态（例如超时重试冷却中）保持外层存活。
          if (_resolved) close();
        },
      );
    }

    Future<void> switchToResolved() async {
      if (closed) return;
      final rust = _rust;
      if (_resolved && _useRust && rust != null) {
        final old = sub;
        sub = null;
        if (old != null) {
          await old.cancel();
        }
        if (closed) return;
        sub = rustStream().listen(add, onError: addError, onDone: close);
        return;
      }
      // 解析已永久回退 Dart：Dart 流若已结束，同步结束外层流。
      // 未终态（超时重试冷却中）则什么都不做，保持 Dart 订阅等待后续结果。
      if (_resolved && dartDone) close();
    }

    controller = StreamController<DownloadTask>(
      onListen: () {
        if (_resolved) {
          if (_useRust && _rust != null) {
            sub = rustStream().listen(add, onError: addError, onDone: close);
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
      },
      onCancel: () async {
        closed = true;
        final resSub = resolutionSub;
        resolutionSub = null;
        await resSub?.cancel();
        final old = sub;
        sub = null;
        await old?.cancel();
      },
    );

    return controller.stream;
  }
}

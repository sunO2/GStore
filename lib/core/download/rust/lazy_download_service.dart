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
/// 结果缓存，探测失败或异常则本次进程一路 Dart。
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
  /// 无限期挂起且无法恢复。加一个有界超时后，超时即**永久**判定为 Dart 实现，
  /// 服务始终可用（失败粘滞于 Dart，绝不再挂起）。
  ///
  /// 取值 2 秒：探测是「内核是否已挂载」的本地握手，正常在毫秒级返回；2 秒足以
  /// 覆盖冷路径上的首次通道往返，又能在用户可感知前从卡死中恢复。测试经构造
  /// 参数 `resolutionTimeout` 注入更短值。
  static const Duration defaultResolutionTimeout = Duration(seconds: 2);

  /// 构造惰性路由。
  ///
  /// [dartFallback] 是构造时即持有的 Dart 实现（只读入口与回落目标）。
  /// [rustProbe] / [rustServiceFactory] 仅用于测试注入：默认分别取
  /// `RustDownloadService.instance.isAvailable` 与 `RustDownloadService.instance`。
  /// [resolutionTimeout] 为单次解析上限，默认 [defaultResolutionTimeout]。
  LazyDownloadService(
    IDownloadService dartFallback, {
    Future<bool> Function()? rustProbe,
    IDownloadService Function()? rustServiceFactory,
    Duration resolutionTimeout = defaultResolutionTimeout,
  })  : _dart = dartFallback,
        _rustProbe =
            rustProbe ?? (() => RustDownloadService.instance.isAvailable),
        _rustServiceFactory =
            rustServiceFactory ?? (() => RustDownloadService.instance),
        _resolutionTimeout = resolutionTimeout;

  final IDownloadService _dart;
  final Future<bool> Function() _rustProbe;
  final IDownloadService Function() _rustServiceFactory;
  final Duration _resolutionTimeout;

  /// 解析出的 Rust 实现；回退时为 null。
  IDownloadService? _rust;

  /// 单飞：首次变更类调用创建，后续调用复用同一个 Future。
  Future<void>? _resolution;

  /// 解析是否已经结束（无论选中 Rust 还是回退 Dart）。
  bool _resolved = false;

  /// 是否选中 Rust。
  bool _useRust = false;

  /// 解析完成广播（供订阅中的事件流切换数据源，不重放历史）。
  final StreamController<void> _resolutionEvents = StreamController<void>.broadcast();

  /// 当前应使用的实现：解析完成且选中 Rust 时用 Rust，否则用 Dart。
  IDownloadService get _active {
    final rust = _rust;
    return (_resolved && _useRust && rust != null) ? rust : _dart;
  }

  /// 单飞解析：首个调用创建 `_resolve()`，其余调用直接复用其 Future。
  Future<void> _ensureResolved() => _resolution ??= _resolve();

  /// 探测一次内核（**有界**）；失败/异常/超时都记为不可用，并**只打一条**告警。
  Future<void> _resolve() async {
    var available = false;
    Object? cause;
    try {
      available = await _rustProbe().timeout(_resolutionTimeout);
    } on TimeoutException catch (e) {
      // 探测永不完成：超时即判定不可用，永久停在 Dart，绝不让下载能力被挂起。
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

    if (!_useRust) {
      debugPrint(
        'LazyDownloadService: Rust 下载内核不可用'
        '${cause == null ? '' : '（$cause）'}，回落到 Dart 实现',
      );
    }

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
  /// - 解析完成后**取消** Dart 内层订阅，改订阅 Rust；同一条外层订阅继续投递；
  /// - [onListen] 绝不调用 [_ensureResolved]，所以订阅 `watchAll` 不触发安装；
  /// - 已解析后再订阅，直接绑定当前活跃实现。
  Stream<DownloadTask> _mergedStream(
    Stream<DownloadTask> Function() dartStream,
    Stream<DownloadTask> Function() rustStream,
  ) {
    late StreamController<DownloadTask> controller;
    StreamSubscription<DownloadTask>? sub;
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
          // 解析未定时保持外层存活，等待可能的换源；已解析则照实结束。
          if (_resolved) close();
        },
      );
    }

    Future<void> switchToResolved() async {
      if (closed) return;
      final rust = _rust;
      if (!_resolved || !_useRust || rust == null) {
        // 回退 Dart：Dart 流若已结束，同步结束外层流。
        if (dartDone) close();
        return;
      }
      final old = sub;
      sub = null;
      if (old != null) {
        await old.cancel();
      }
      if (closed) return;
      sub = rustStream().listen(add, onError: addError, onDone: close);
    }

    controller = StreamController<DownloadTask>(
      onListen: () {
        if (_resolved) {
          if (_useRust && _rust != null) {
            sub = rustStream().listen(add, onError: addError, onDone: close);
          } else {
            bindDart();
          }
        } else {
          bindDart();
          _resolutionEvents.stream
              .first
              .then((_) => switchToResolved())
              .catchError((_) {});
        }
      },
      onCancel: () async {
        closed = true;
        final old = sub;
        sub = null;
        await old?.cancel();
      },
    );

    return controller.stream;
  }
}

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken, DioException, DioExceptionType;
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../../module/interfaces/service_interfaces.dart';
import '../../service/download_notification_service.dart';
import '../core/download_engine.dart';
import '../core/download_event.dart';
import '../core/download_request.dart';
import '../model/download_task.dart';
import 'download_repository.dart';

/// 下载管理器：负责队列调度、并发控制、断点续传、状态持久化与文件校验。
///
/// 引擎只做纯传输（[DownloadEngine]），本类负责：
/// - 并发上限（[_active] 计数器 + [_queue]）
/// - 进度上报（3s 滚动窗口计算速度）
/// - 完成校验（APK 需带 ZIP 魔数 `PK`，且长度不小于声明大小）
/// - 暂停/恢复/取消/重试的状态机
class DownloadManager extends GetxService implements IDownloadService {
  final DownloadEngine engine;
  final DownloadRepository repository;

  /// APK 下载完成回调（Android 安装钩子，由 DI 注入，禁止在此引入 ModuleManager）。
  final void Function(String filePath)? onApkReady;

  /// 最大并发下载数。
  int maxConcurrent;

  final List<_QueuedRun> _queue = [];
  final Map<int, CancelToken> _cancelTokens = {};
  final Set<int> _pausedIds = {};
  int _active = 0;

  DownloadManager({
    required this.engine,
    required this.repository,
    this.onApkReady,
    this.maxConcurrent = 3,
  });

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
    final savePath = await _savePathFor(saveFileName, fileName);

    final ex = await repository.getByKey(appid, version, fileName);
    if (!forceDownload && ex != null && ex.isCompleted && _validAt(ex)) {
      return ex;
    }

    final size = ex?.total ?? downloadSize;
    final now = DateTime.now();
    final task = DownloadTask(
      id: forceDownload ? null : ex?.id,
      appId: appid,
      appName: appName,
      version: version,
      fileName: fileName,
      url: url,
      filePath: savePath,
      total: size ?? 0,
      received: forceDownload ? 0 : (ex?.received ?? 0),
      status: DownloadStatusEnum.queued,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      createdAt: ex?.createdAt ?? now,
      updatedAt: now,
    );

    final saved = await repository.save(task) ?? task;
    unawaited(_startRun(
      task: saved,
      url: url,
      headers: null,
      fileSize: size,
      resume: breakPoint,
      installAfterDownload: installAfterDownload,
    ));
    return saved;
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
    final savePath = await _savePathFor(saveFileName, fileName);
    final req = request.copyWithSavePath(savePath);

    final ex = await repository.getByKey(appid, version, fileName);
    if (ex != null && ex.isCompleted && _validAt(ex)) {
      return ex;
    }

    final size = ex?.total ?? req.fileSize;
    final now = DateTime.now();
    final task = DownloadTask(
      id: ex?.id,
      appId: appid,
      appName: appName,
      version: version,
      fileName: fileName,
      url: req.url,
      filePath: req.savePath!,
      total: size ?? 0,
      received: ex?.received ?? 0,
      status: DownloadStatusEnum.queued,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      createdAt: ex?.createdAt ?? now,
      updatedAt: now,
    );

    final saved = await repository.save(task) ?? task;
    unawaited(_startRun(
      task: saved,
      url: req.url,
      headers: req.headers,
      fileSize: size,
      resume: req.resume,
      installAfterDownload: installAfterDownload,
    ));
    return saved;
  }

  @override
  Future<void> pause(int id) async {
    _pausedIds.add(id);
    _queue.removeWhere((run) => run.task.id == id);
    _cancelTokens[id]?.cancel();
    final task = await repository.getById(id);
    if (task != null) {
      final disk = _diskBytes(task.filePath);
      final effective = task.received < disk ? disk : task.received;
      await repository.save(task.copyWith(
        status: DownloadStatusEnum.paused,
        received: effective,
        updatedAt: DateTime.now(),
      ));
    }
  }

  @override
  Future<void> resume(int id) async {
    final task = await repository.getById(id);
    if (task == null) return;
    _pausedIds.remove(id);
    final disk = _diskBytes(task.filePath);
    final effective = task.received < disk ? disk : task.received;
    final corrected = task.copyWith(received: effective);
    final updated = _resetError(corrected, DownloadStatusEnum.queued);
    await repository.save(updated);
    unawaited(_startRun(
      task: updated,
      url: task.url,
      headers: null,
      fileSize: task.total > 0 ? task.total : null,
      resume: true,
      installAfterDownload: true,
    ));
  }

  @override
  Future<void> cancel(int id) async {
    _cancelTokens[id]?.cancel();
    _queue.removeWhere((run) => run.task.id == id);
    if (_pausedIds.contains(id)) {
      return;
    }
    final task = await repository.getById(id);
    if (task != null) {
      await repository.save(
        _resetError(task, DownloadStatusEnum.cancelled),
      );
    }
  }

  @override
  Future<void> retry(int id) async {
    final task = await repository.getById(id);
    if (task == null) return;
    // 已完成任务的“重新下载”：强制整包重下（received=0 + resume:false），
    // 其余状态（failed/paused/cancelled）保持断点续传语义。
    final isReDownload = task.status == DownloadStatusEnum.completed;
    late final DownloadTask updated;
    if (isReDownload) {
      updated = _resetReceived(task, DownloadStatusEnum.queued);
    } else {
      final disk = _diskBytes(task.filePath);
      final effective = task.received < disk ? disk : task.received;
      updated = _resetError(
        task.copyWith(received: effective),
        DownloadStatusEnum.queued,
      );
    }
    await repository.save(updated);
    unawaited(_startRun(
      task: updated,
      url: task.url,
      headers: null,
      fileSize: task.total > 0 ? task.total : null,
      resume: !isReDownload,
      installAfterDownload: true,
    ));
  }

  @override
  Future<DownloadTask?> getTask(int id) => repository.getById(id);

  @override
  Stream<DownloadTask> watch(int id) => repository.watch(id);

  /// 启动一次下载运行，由 download/downloadWithContext/resume/retry/_processQueue 共用。
  Future<void> _startRun({
    required DownloadTask task,
    required String url,
    required Map<String, String>? headers,
    required int? fileSize,
    required bool resume,
    required bool installAfterDownload,
  }) async {
    final id = task.id!;

    final keepPartial = resume && task.received > 0;
    if (!keepPartial) {
      // 全新/强制重下：清空最终文件 + 临时文件 + 全部分段残留，避免旧 APK/旧 part 干扰判断
      for (final p in <String>[task.filePath, '${task.filePath}.temp']) {
        final f = File(p);
        if (await f.exists()) {
          try { await f.delete(); } catch (_) {}
        }
      }
      for (var i = 0; i < 100; i++) {
        final part = File('${task.filePath}.part$i');
        if (!await part.exists()) break;
        try { await part.delete(); } catch (_) {}
      }
    } else {
      // 断点续传：清理历史遗留的无索引 .part，保留 .temp 与 .part{i} 以便续传
      final legacy = File('${task.filePath}.part');
      if (await legacy.exists()) {
        try { await legacy.delete(); } catch (_) {}
      }
    }

    if (_active >= maxConcurrent) {
      final queued = task.copyWith(
        status: DownloadStatusEnum.queued,
        updatedAt: DateTime.now(),
      );
      await repository.save(queued);
      _queue.add(_QueuedRun(
        task: queued,
        url: url,
        headers: headers,
        fileSize: fileSize,
        resume: resume,
        installAfterDownload: installAfterDownload,
      ));
      return;
    }

    _active++;
    var terminalEnd = false;
    try {
      var current = task.copyWith(
        status: DownloadStatusEnum.downloading,
        updatedAt: DateTime.now(),
      );
      await repository.save(current);
      // 通知栏进度 + 前台服务保活（任务真正开始下载时才启动，排队任务不触发）。
      final notifId = id;
      final notifTitle =
          task.appName.isNotEmpty ? task.appName : task.appId;
      DownloadNotificationService.instance.onDownloadStart(
        notifId,
        notifTitle,
        task.fileName,
      );
      // 仅终态（completed/failed）关闭 watch 流；paused/cancelled 保持存活，
      // 让页面仍能收到 resume() 的 push。

      final cancelToken = CancelToken();
      _cancelTokens[id] = cancelToken;
      final samples = <(DateTime, int)>[];

      try {
        final req = DownloadRequest(
          url: url,
          savePath: task.filePath,
          headers: headers,
          fileSize: fileSize,
          resume: resume,
        );

        await for (final ev in engine.execute(req, cancelToken: cancelToken)) {
          if (ev is DownloadProgress) {
            // 暂停在途：忽略剩余进度，保持 paused，避免 downloading 反冲覆盖
            if (_pausedIds.contains(id)) continue;
            final now = DateTime.now();
            final speed = _computeSpeed(samples, now, ev.received);
            // 引擎已按 250ms 节流上报（≤4 次/秒），received=磁盘真值，
            // 直接落库即可，无需额外节流。
            current = current.copyWith(
              received: ev.received,
              // 服务器真实 total 优先：渠道元数据（如 vivo KB 换算）可能
              // 与实际字节数不一致，进度分母统一用引擎探测到的真实大小。
              total: ev.total ?? current.total,
              status: DownloadStatusEnum.downloading,
              speedBps: speed,
              updatedAt: now,
            );
            await repository.save(current);
            // 通知栏进度（服务内部 500ms 节流）
            DownloadNotificationService.instance.onDownloadProgress(
              notifId,
              notifTitle,
              task.fileName,
              current.received,
              current.total,
            );
          } else if (ev is DownloadMerging) {
            // 分片合并中：进度已满（引擎在 merge 入口已发 100%），
            // 落库总大小，避免 UI 卡在 90%~99% 空转。
            if (_pausedIds.contains(id)) continue;
            final now = DateTime.now();
            current = current.copyWith(
              // 合并入口：received/total 统一为服务器真实大小（引擎在 merge 前
              // 已按服务器 total 下完全部分片），避免元数据大小参与进度与校验。
              received: ev.total,
              total: ev.total,
              status: DownloadStatusEnum.downloading,
              updatedAt: now,
            );
            await repository.save(current);
            DownloadNotificationService.instance.onDownloadProgress(
              notifId,
              notifTitle,
              task.fileName,
              current.received,
              current.total,
            );
          } else if (ev is DownloadCompleted) {
            // 暂停竞态：引擎已下完但用户已暂停 → 不再安装，按暂停落库（finally 会跳过 disposeId）
            if (_pausedIds.contains(id)) {
              _pausedIds.remove(id);
              final disk = _diskBytes(task.filePath);
              final effective =
                  current.received < disk ? disk : current.received;
              await repository.save(current.copyWith(
                status: DownloadStatusEnum.paused,
                received: effective,
                updatedAt: DateTime.now(),
              ));
              DownloadNotificationService.instance.onDownloadCancel(notifId);
              return; // 跳过完成/安装路径，直接进 finally（terminalEnd=false → 保留 watch 流）
            }
            break;
          } else if (ev is DownloadFailed) {
            throw StateError(ev.message);
          }
        }

        // 完成收尾：以磁盘真值为准对账。引擎层已保证字节数（分片合并长度=
        // 服务器 total、单流 tempLength>=effectiveTotal），这里只做损坏性校验
        // （存在/非空/APK 魔数），不再拿渠道元数据 total（如 vivo KB 换算误差）
        // 与磁盘长度比对——否则会误删已完整下载的 APK。
        final finalFile = File(task.filePath);
        final diskLength =
            finalFile.existsSync() ? finalFile.lengthSync() : 0;
        if (!_isValidFile(task.filePath, diskLength)) {
          await repository.save(current.copyWith(
            status: DownloadStatusEnum.failed,
            error: '下载文件校验失败',
            updatedAt: DateTime.now(),
          ));
          try {
            await finalFile.delete();
          } catch (_) {}
          DownloadNotificationService.instance.onDownloadError(
              notifId, notifTitle);
          throw StateError('下载文件校验失败');
        }
        // 大小对账：以磁盘实际字节数为准收口（收到的即真实的）。
        current = current.copyWith(total: diskLength, received: diskLength);

        final done = current.copyWith(
          received: diskLength,
          status: DownloadStatusEnum.completed,
          speedBps: 0,
          etaSec: 0,
          error: null,
          updatedAt: DateTime.now(),
        );
        terminalEnd = true;
        await repository.save(done);
        _cancelTokens.remove(id);
        DownloadNotificationService.instance.onDownloadComplete(notifId);
        if (onApkReady != null && installAfterDownload) {
          unawaited(Future<void>(() => onApkReady!(task.filePath)));
        }
      } catch (e) {
        final isCancel = cancelToken.isCancelled ||
            (e is DioException && e.type == DioExceptionType.cancel);
        if (isCancel) {
          if (_pausedIds.remove(id)) {
            final disk = _diskBytes(task.filePath);
            final effective =
                current.received < disk ? disk : current.received;
            await repository.save(current.copyWith(
              status: DownloadStatusEnum.paused,
              received: effective,
              updatedAt: DateTime.now(),
            ));
            DownloadNotificationService.instance.onDownloadCancel(notifId);
          } else {
            await repository.save(current.copyWith(
              status: DownloadStatusEnum.cancelled,
              error: null,
              updatedAt: DateTime.now(),
            ));
            DownloadNotificationService.instance.onDownloadCancel(notifId);
          }
        } else {
          final message =
              e is DioException ? (e.message ?? e.toString()) : e.toString();
          terminalEnd = true;
          await repository.save(current.copyWith(
            status: DownloadStatusEnum.failed,
            error: message,
            updatedAt: DateTime.now(),
          ));
          DownloadNotificationService.instance.onDownloadError(
              notifId, notifTitle);
        }
      }
    } finally {
      _active--;
      _cancelTokens.remove(id);
      if (terminalEnd) repository.disposeId(id);
      _processQueue();
    }
  }

  void _processQueue() {
    while (_active < maxConcurrent && _queue.isNotEmpty) {
      final run = _queue.removeAt(0);
      unawaited(_startRun(
        task: run.task,
        url: run.url,
        headers: run.headers,
        fileSize: run.fileSize,
        resume: run.resume,
        installAfterDownload: run.installAfterDownload,
      ));
    }
  }

  /// 3 秒滚动窗口计算下载速度（bytes/s）。
  int _computeSpeed(List<(DateTime, int)> samples, DateTime now, int received) {
    samples.add((now, received));
    final cutoff = now.subtract(const Duration(seconds: 3));
    while (samples.length > 1 && samples.first.$1.isBefore(cutoff)) {
      samples.removeAt(0);
    }
    if (samples.length < 2) return 0;
    final first = samples.first;
    final last = samples.last;
    final deltaMs = last.$1.difference(first.$1).inMilliseconds;
    final deltaBytes = last.$2 - first.$2;
    if (deltaMs <= 0 || deltaBytes <= 0) return 0;
    return (deltaBytes * 1000 / deltaMs).round();
  }

  /// APK 需存在、非空、以 ZIP 魔数（PK）开头且不小于声明大小；
  /// 其它扩展名（zip/apks/xapk 等）只需存在且非空。
  bool _isValidFile(String filePath, int total) {
    final file = File(filePath);
    if (!file.existsSync()) return false;
    final length = file.lengthSync();
    if (length <= 0) return false;
    if (filePath.toLowerCase().endsWith('.apk')) {
      if (total > 0 && length < total) return false;
      try {
        final raf = file.openSync();
        final header = raf.readSync(2);
        raf.closeSync();
        return header.length == 2 && header[0] == 0x50 && header[1] == 0x4b;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  bool _validAt(DownloadTask t) => _isValidFile(t.filePath, t.total);

  Future<String> _savePathFor(String? saveFileName, String fileName) async {
    if (saveFileName != null && saveFileName.startsWith('/')) {
      return saveFileName;
    }
    final dir = await getDownloadsDirectory();
    return '${dir?.path ?? (await getApplicationDocumentsDirectory()).path}/$fileName';
  }

  /// 磁盘上实际已下载字节：优先最终文件，其次 .temp，其次 .part0..N 之和。
  int _diskBytes(String savePath) {
    final f = File(savePath);
    if (f.existsSync()) return f.lengthSync();
    final temp = File('$savePath.temp');
    if (temp.existsSync()) return temp.lengthSync();
    var total = 0;
    for (var i = 0; i < 100; i++) {
      final part = File('$savePath.part$i');
      if (!part.existsSync()) break;
      total += part.lengthSync();
    }
    return total;
  }

  /// 生成一份清除 error 的新任务（copyWith 无法把 error 置空）。
  DownloadTask _resetError(DownloadTask task, DownloadStatusEnum status) {
    return DownloadTask(
      id: task.id,
      appId: task.appId,
      appName: task.appName,
      version: task.version,
      fileName: task.fileName,
      url: task.url,
      filePath: task.filePath,
      total: task.total,
      received: task.received,
      status: status,
      speedBps: task.speedBps,
      etaSec: task.etaSec,
      error: null,
      segments: task.segments,
      createdAt: task.createdAt,
      updatedAt: DateTime.now(),
    );
  }

  /// 与 [_resetError] 相同，但强制把 received 归零（重新下载用），
  /// 避免保留旧的 received=total 导致引擎按 Range 直接续传完成。
  DownloadTask _resetReceived(DownloadTask task, DownloadStatusEnum status) {
    return DownloadTask(
      id: task.id,
      appId: task.appId,
      appName: task.appName,
      version: task.version,
      fileName: task.fileName,
      url: task.url,
      filePath: task.filePath,
      total: task.total,
      received: 0,
      status: status,
      speedBps: task.speedBps,
      etaSec: task.etaSec,
      error: null,
      segments: task.segments,
      createdAt: task.createdAt,
      updatedAt: DateTime.now(),
    );
  }
}

/// 排队运行所需的全部参数快照。
class _QueuedRun {
  final DownloadTask task;
  final String url;
  final Map<String, String>? headers;
  final int? fileSize;
  final bool resume;
  final bool installAfterDownload;

  const _QueuedRun({
    required this.task,
    required this.url,
    required this.headers,
    required this.fileSize,
    required this.resume,
    required this.installAfterDownload,
  });
}

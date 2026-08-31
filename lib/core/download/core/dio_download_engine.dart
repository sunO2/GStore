import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import 'download_engine.dart';
import 'download_event.dart';
import 'download_request.dart';

class DioDownloadEngine implements DownloadEngine {
  DioDownloadEngine({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  // ==== 分片参数（对齐 aria2/IDM 经验值，移动网络）====
  /// 逻辑分片单位：16MB。
  static const int _unitBytes = 16 * 1024 * 1024;
  static const int _minSegments = 2;
  static const int _maxSegments = 64;
  /// 并发 worker 数（移动 4 / Wi-Fi 6）。
  static const int _maxConcurrency = 4;
  /// 单段最大重试次数。
  static const int _maxRetries = 5;
  /// 小于该大小不走分片。
  static const int _singlePathMinSize = 2 * 1024 * 1024;
  /// 重试退避基数。
  static const int _retryBaseDelayMs = 500;
  /// 慢速探测：超过该时长无新字节 → 弃段重试（curl --speed-* 语义）。
  static const Duration _stallTimeout = Duration(seconds: 10);
  /// 进度上报最小间隔（≤4 次/秒）。
  static const Duration _progressInterval = Duration(milliseconds: 250);

  @override
  Stream<DownloadEvent> execute(
    DownloadRequest request, {
    CancelToken? cancelToken,
  }) {
    final controller = StreamController<DownloadEvent>();
    unawaited(_run(request, cancelToken, controller));
    return controller.stream;
  }

  Future<void> _run(
    DownloadRequest request,
    CancelToken? cancelToken,
    StreamController<DownloadEvent> controller,
  ) async {
    try {
      await _dispatch(request, cancelToken, controller.add);
    } catch (e) {
      controller.add(DownloadFailed(e.toString()));
    } finally {
      await controller.close();
    }
  }

  /// 惰性 URL 解析：请求发起前重新调用（代理拼接/签名过期刷新）。
  String _resolveUrl(DownloadRequest request) =>
      request.urlProvider?.call() ?? request.url;

  Future<void> _dispatch(
    DownloadRequest request,
    CancelToken? cancelToken,
    void Function(DownloadEvent) emit,
  ) async {
    final probe = await _probe(request, cancelToken);
    final total = probe.total;
    final segmented = !probe.isCompressed &&
        probe.supportsRange &&
        total != null &&
        total > 0 &&
        total >= _singlePathMinSize &&
        request.resume;
    if (segmented) {
      await _downloadSegmented(request, total, cancelToken, emit);
    } else {
      await _downloadSingle(
        request,
        probe.isCompressed,
        total,
        cancelToken,
        emit,
      );
    }
  }

  Future<({bool isCompressed, bool supportsRange, int? total})> _probe(
    DownloadRequest request,
    CancelToken? cancelToken,
  ) async {
    final response = await _dio.get<ResponseBody>(
      _resolveUrl(request),
      options: Options(
        responseType: ResponseType.stream,
        headers: {...?request.headers, 'Range': 'bytes=0-0'},
      ),
      cancelToken: cancelToken,
    );
    final body = response.data;
    if (body != null) {
      await body.stream.listen(null, cancelOnError: true).cancel();
    }
    return (
      isCompressed:
          response.headers.value('x-gstore-decoded-encoding') != null,
      supportsRange: response.statusCode == 206,
      total: _parseTotal(response.headers),
    );
  }

  int? _parseTotal(Headers headers) {
    final contentRange = headers.value('content-range');
    if (contentRange != null) {
      final slash = contentRange.lastIndexOf('/');
      if (slash >= 0) {
        final right = contentRange.substring(slash + 1).trim();
        if (right.isNotEmpty && right != '*') {
          return int.tryParse(right);
        }
      }
    }
    final contentLength = headers.value('content-length');
    if (contentLength != null) {
      final length = int.tryParse(contentLength.trim());
      if (length != null && length >= 0) {
        return length;
      }
    }
    return null;
  }

  // ==================== 单流下载 ====================

  Future<void> _downloadSingle(
    DownloadRequest request,
    bool isCompressed,
    int? total,
    CancelToken? cancelToken,
    void Function(DownloadEvent) emit,
  ) async {
    if (request.savePath == null || request.savePath!.isEmpty) {
      emit(DownloadFailed('savePath is empty'));
      return;
    }
    final savePath = request.savePath!;
    final tempFile = File('$savePath.temp');
    var start = 0;
    if (request.resume && await tempFile.exists()) {
      start = await tempFile.length();
    }
    final headers = <String, String>{...?request.headers};
    if (request.resume && start > 0) {
      headers['Range'] = 'bytes=$start-';
    }
    final response = await _dio.get<ResponseBody>(
      _resolveUrl(request),
      options: Options(responseType: ResponseType.stream, headers: headers),
      cancelToken: cancelToken,
    );
    var effectiveTotal = isCompressed ? null : total;
    if (!isCompressed && response.statusCode == 200) {
      final cl = response.headers.value('content-length');
      final parsed = int.tryParse(cl?.trim() ?? '');
      if (parsed != null && parsed > 0) effectiveTotal = parsed;
    }
    final sink = tempFile.openWrite(mode: FileMode.writeOnlyAppend);
    var sizeUnknown = false;
    var received = 0;
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      var first = true;
      await for (final chunk in response.data!.stream) {
        if (cancelToken?.isCancelled == true) break; // 暂停/取消：立即停止写入
        if (first) {
          first = false;
          if (chunk.length >= 2 && chunk[0] == 0x1f && chunk[1] == 0x8b) {
            sizeUnknown = true;
          }
        }
        sink.add(chunk);
        received += chunk.length;
        // 进度节流：单流也按 250ms 上报，避免高频 emit。
        final now = DateTime.now();
        if (now.difference(lastEmit) >= _progressInterval) {
          lastEmit = now;
          emit(DownloadProgress(start + received, effectiveTotal));
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    final tempLength = await tempFile.length();
    if (cancelToken?.isCancelled == true) {
      emit(DownloadFailed('cancelled'));
      return;
    }
    if (!sizeUnknown &&
        effectiveTotal != null &&
        effectiveTotal > 0 &&
        tempLength < effectiveTotal) {
      emit(DownloadFailed('incomplete'));
      return;
    }
    // 收尾：进度打满后完成（压缩/未知大小流 total 保持 null，与逐 chunk 语义一致）。
    final finalTotal = effectiveTotal ?? tempLength;
    emit(DownloadProgress(finalTotal, effectiveTotal));
    await tempFile.rename(savePath);
    emit(DownloadCompleted());
  }

  // ==================== 分片下载（动态工作队列）====================

  Future<void> _downloadSegmented(
    DownloadRequest request,
    int total,
    CancelToken? cancelToken,
    void Function(DownloadEvent) emit,
  ) async {
    final savePath = request.savePath;
    if (savePath == null || savePath.isEmpty) {
      emit(DownloadFailed('savePath is empty'));
      return;
    }

    // 动态工作队列：unit 16MB 静态切分（段数独立于并发），worker 领取式 checkout。
    final segmentCount =
        ((total + _unitBytes - 1) ~/ _unitBytes).clamp(_minSegments, _maxSegments).toInt();
    final ranges = <({int start, int end})>[];
    final base = total ~/ segmentCount;
    var remainder = total % segmentCount;
    var cursor = 0;
    for (var i = 0; i < segmentCount; i++) {
      var length = base;
      if (remainder > 0) {
        length += 1;
        remainder -= 1;
      }
      ranges.add((start: cursor, end: cursor + length - 1));
      cursor += length;
    }

    // resume 对账：以「磁盘已有分片 vs 服务器 total」为准，而非调用方元数据 fileSize。
    // 元数据（如 vivo size×1024）与服务器真实 total 存在尾部字节差（KB 换算误差），
    // 用 fileSize 判断会导致 resume 误清 .part → 整包重下。
    // 仅当磁盘已有分片总量超过新 total（文件被替换/缩小）时才清场重规划。
    final existingParts = _partsDiskBytes(savePath, segmentCount);
    if (request.resume && existingParts > total) {
      await _cleanupAllParts(savePath);
      final stale = File('$savePath.temp');
      if (await stale.exists()) {
        try {
          await stale.delete();
        } catch (_) {}
      }
    }

    final receivedBySegment = List<int>.filled(segmentCount, 0);
    final reporter = _ProgressReporter(
      total: total,
      diskBytes: () => _partsDiskBytes(savePath, segmentCount),
      emit: emit,
    );

    // 共享活跃段 CancelToken 集：全局取消（暂停）时统一级联取消所有在途段。
    final segTokens = <CancelToken>{};
    if (cancelToken != null) {
      unawaited(cancelToken.whenCancel.then((_) {
        for (final t in segTokens) {
          if (!t.isCancelled) t.cancel();
        }
      }));
    }

    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final idx = nextIndex++;
        if (idx >= segmentCount) break;
        await _downloadSegment(
          request: request,
          index: idx,
          start: ranges[idx].start,
          end: ranges[idx].end,
          total: total,
          cancelToken: cancelToken,
          segTokens: segTokens,
          reporter: reporter,
          receivedBySegment: receivedBySegment,
        );
      }
    }

    try {
      await Future.wait(
        List.generate(_maxConcurrency, (_) => worker()),
      );

      // merge 入口：进度打满 + merging 阶段标识，杜绝 90% 卡死。
      emit(DownloadMerging(total));
      emit(DownloadProgress(total, total));

      final tempFile = File('$savePath.temp');
      final sink = tempFile.openWrite();
      try {
        for (var i = 0; i < segmentCount; i++) {
          final partFile = File('$savePath.part$i');
          await sink.addStream(partFile.openRead());
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      final mergedLength = await tempFile.length();
      if (mergedLength != total) {
        throw StateError('merged length $mergedLength != $total');
      }
      await tempFile.rename(savePath);
      await _cleanupParts(savePath, segmentCount);
      emit(DownloadCompleted());
    } catch (_) {
      // 取消（暂停）：保留分片文件供断点续传，不清 part；
      // 仅非取消的失败才清理，避免 resume 整包重下。
      if (cancelToken?.isCancelled != true) {
        await _cleanupParts(savePath, segmentCount);
      }
      rethrow;
    }
  }

  /// 下载单个分片：Range → 写 .part{i} → 长度校验；段级重试 + 慢速探测 + 独立 CancelToken。
  Future<void> _downloadSegment({
    required DownloadRequest request,
    required int index,
    required int start,
    required int end,
    required int total,
    required CancelToken? cancelToken,
    required Set<CancelToken> segTokens,
    required _ProgressReporter reporter,
    required List<int> receivedBySegment,
  }) async {
    final partFile = File('${request.savePath}.part$index');
    final partTotal = end - start + 1;
    final random = Random();

    for (var attempt = 1; attempt <= _maxRetries; attempt++) {
      final segToken = CancelToken();
      segTokens.add(segToken);
      Timer? stallTimer;
      try {
        // 续传定位：以磁盘 part 长度为唯一依据。
        var offset = start;
        if (await partFile.exists()) {
          final len = await partFile.length();
          if (len == partTotal) {
            // 该段已完整下载（暂停前已下完）→ 计入进度并跳过。
            receivedBySegment[index] = partTotal;
            reporter.maybeEmit();
            return;
          }
          if (len > partTotal) {
            // 文件收缩/损坏 → 删除重下。
            try {
              await partFile.delete();
            } catch (_) {}
            offset = start;
          } else {
            offset = start + len;
          }
        }

        final response = await _dio.get<ResponseBody>(
          _resolveUrl(request),
          options: Options(
            responseType: ResponseType.stream,
            headers: {
              ...?request.headers,
              'Range': 'bytes=$offset-$end',
            },
          ),
          cancelToken: segToken,
        );

        var lastActivity = DateTime.now();
        stallTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (DateTime.now().difference(lastActivity) > _stallTimeout) {
            // 慢速卡死：主动取消本段，由段级重试接管。
            if (!segToken.isCancelled) segToken.cancel();
          }
        });

        final sink = partFile.openWrite(mode: FileMode.writeOnlyAppend);
        var received = offset - start;
        try {
          await for (final chunk in response.data!.stream) {
            lastActivity = DateTime.now();
            if (cancelToken?.isCancelled == true) {
              if (!segToken.isCancelled) segToken.cancel();
              break;
            }
            sink.add(chunk);
            received += chunk.length;
            receivedBySegment[index] = received;
            reporter.maybeEmit();
          }
        } finally {
          stallTimer.cancel();
          await sink.flush();
          await sink.close();
        }

        if (cancelToken?.isCancelled == true) {
          throw DioException(
            requestOptions: RequestOptions(path: _resolveUrl(request)),
            type: DioExceptionType.cancel,
          );
        }
        final partLength = await partFile.length();
        if (partLength != partTotal) {
          throw StateError('segment $index length $partLength != $partTotal');
        }
        return;
      } catch (e) {
        if (cancelToken?.isCancelled == true) rethrow; // 全局暂停/取消：立即上抛
        if (attempt >= _maxRetries) rethrow;
        // 指数退避 + ±20% 抖动。
        final jitter = (random.nextDouble() * 0.4 - 0.2);
        final delayMs =
            (_retryBaseDelayMs * attempt * (1 + jitter)).round().clamp(0, 10000);
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      } finally {
        stallTimer?.cancel();
        segTokens.remove(segToken);
      }
    }
  }

  /// 磁盘真值：Σ 各 .part{i} 实际长度。
  int _partsDiskBytes(String savePath, int segmentCount) {
    var total = 0;
    for (var i = 0; i < segmentCount; i++) {
      final p = File('$savePath.part$i');
      if (p.existsSync()) total += p.lengthSync();
    }
    return total;
  }

  Future<void> _cleanupParts(String savePath, int count) async {
    for (var i = 0; i < count; i++) {
      final partFile = File('$savePath.part$i');
      if (await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _cleanupAllParts(String savePath) async {
    for (var i = 0; i < _maxSegments * 2; i++) {
      final partFile = File('$savePath.part$i');
      if (await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      } else if (i >= _maxSegments) {
        break;
      }
    }
  }
}

/// 进度上报器：250ms 节流 + 磁盘真值采样，唯一 emit DownloadProgress 的出口。
class _ProgressReporter {
  _ProgressReporter({
    required this.total,
    required this.diskBytes,
    required this.emit,
  });

  final int total;
  final int Function() diskBytes;
  final void Function(DownloadEvent) emit;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  /// 节流上报（≥250ms 一次），received 取磁盘真值。
  void maybeEmit() {
    final now = DateTime.now();
    if (now.difference(_lastEmit) < DioDownloadEngine._progressInterval) {
      return;
    }
    _lastEmit = now;
    emit(DownloadProgress(diskBytes(), total));
  }
}

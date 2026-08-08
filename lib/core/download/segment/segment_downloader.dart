import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
import 'package:gstore/core/download/segment/segment_planner.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

/// 服务器不支持分段下载（多段中某段返回非 206）
class _ServerNoRangeException implements Exception {
  const _ServerNoRangeException();
}

/// 多段下载结果
class SegmentDownloadResult {
  /// 是否成功
  final bool success;

  /// 是否被取消
  final bool cancelled;

  /// 是否应回退单段下载（服务器不支持 Range）
  final bool fallback;

  /// 错误消息（失败时）
  final String? errorMessage;

  const SegmentDownloadResult.success()
      : success = true,
        cancelled = false,
        fallback = false,
        errorMessage = null;

  const SegmentDownloadResult.cancelled()
      : success = false,
        cancelled = true,
        fallback = false,
        errorMessage = null;

  const SegmentDownloadResult.failure(String message, {this.fallback = false})
      : success = false,
        cancelled = false,
        errorMessage = message;
}

/// 多段并行下载器
///
/// 职责：
/// - 并发下载各分段（每段独立 Range 请求，写入独立 .part{index} 文件）
/// - 段级失败自动重试（失败段单独重试，不影响其他段）
/// - 汇总进度上报（各段已下载字节之和 → downloadStatus.updateDownload）
/// - 支持取消（取消所有段）
/// - 支持断点续传（已存在的 .part 文件长度作为该段起点）
class SegmentDownloader {
  final Dio _dio;

  /// 段失败最大重试次数
  final int maxRetryCount;

  /// 段级并发上限（控制同时进行的段下载数，避免过多 TCP 连接）
  final int maxConcurrency;

  SegmentDownloader(
    this._dio, {
    this.maxRetryCount = 3,
    this.maxConcurrency = 4,
  });

  /// 并发下载所有分段
  ///
  /// [plan] 段规划结果（必须 isMultiSegment）
  /// [status] 下载状态（用于更新进度、取消令牌）
  /// [context] 下载上下文（headers/proxy/超时）
  /// [onProgress] 进度回调（每次收到数据块时触发，可空）
  /// [onSegmentComplete] 单段完成回调（可空，参数为段索引）
  ///
  /// 返回下载结果。所有段成功 → success；任一不可恢复失败 → failure；
  /// 被取消 → cancelled（保留已下载的 .part 文件，供续传）。
  Future<SegmentDownloadResult> downloadSegments({
    required SegmentPlan plan,
    required DownloadStatus status,
    DownloadContext? context,
    void Function(int downloadedBytes, int totalBytes)? onProgress,
    void Function(int segmentIndex)? onSegmentComplete,
  }) async {
    final url = context?.downloadUrl ?? status.downloadUrl;
    final segments = plan.segments;
    if (segments.isEmpty) {
      return const SegmentDownloadResult.failure('多段下载：无可用分段');
    }

    // 确保保存目录存在
    final file = File(status.savePath);
    await file.parent.create(recursive: true);

    // 段下载进度映射（每段已下载字节）
    final segmentBytes = List<int>.filled(segments.length, 0);
    var totalDownloaded = 0;

    // 段结果收集：failed = 已耗尽重试或不可恢复错误
    final segmentErrors = <int, String>{};
    final cancelled = Completer<void>();
    // 服务器不支持 Range 信号（任一触发即回退单段）
    final fallback = Completer<void>();

    // 并发控制信号量
    final semaphore = _SegmentSemaphore(maxConcurrency);

    // 启动所有段下载任务
    final futures = <Future<void>>[];
    for (final segment in segments) {
      futures.add(_downloadSegmentWithRetry(
        segment: segment,
        url: url,
        status: status,
        context: context,
        semaphore: semaphore,
        cancelled: cancelled,
        segmentBytes: segmentBytes,
        onProgress: (bytes) {
          // 更新该段字节数
          segmentBytes[segment.index] = bytes;
          final total = _sumSegmentBytes(segmentBytes, segments);
          // 更新状态 + 通知
          status.updateDownload(total, plan.totalBytes);
          onProgress?.call(total, plan.totalBytes);
        },
        onComplete: () {
          onSegmentComplete?.call(segment.index);
        },
        onError: (message) {
          segmentErrors[segment.index] = message;
        },
        onFallback: () {
          if (!fallback.isCompleted) {
            fallback.complete();
          }
        },
      ));
    }

    // 等待所有段结束（成功或失败）
    await Future.wait(futures, eagerError: false);

    // 判断结果
    if (fallback.isCompleted) {
      // 服务器不支持分段：清理所有 part，回退单段
      await SegmentMerger.cleanupParts(status.savePath, segments.length);
      return const SegmentDownloadResult.failure('服务器不支持分段', fallback: true);
    }
    if (cancelled.isCompleted) {
      return const SegmentDownloadResult.cancelled();
    }
    if (segmentErrors.isNotEmpty) {
      final firstError = segmentErrors.values.first;
      return SegmentDownloadResult.failure(
          '多段下载失败（${segmentErrors.length}/${segments.length} 段出错）: $firstError');
    }

    // 校验总字节
    totalDownloaded = _sumSegmentBytes(segmentBytes, segments);
    debugPrint('SegmentDownloader: 全部 ${segments.length} 段完成, 合计 $totalDownloaded / ${plan.totalBytes} B');
    return const SegmentDownloadResult.success();
  }

  /// 单个段下载（带重试）
  Future<void> _downloadSegmentWithRetry({
    required DownloadSegment segment,
    required String url,
    required DownloadStatus status,
    required DownloadContext? context,
    required _SegmentSemaphore semaphore,
    required Completer<void> cancelled,
    required List<int> segmentBytes,
    required void Function(int bytes) onProgress,
    required VoidCallback onComplete,
    required void Function(String message) onError,
    required VoidCallback onFallback,
  }) async {
    var attempt = 0;
    while (attempt <= maxRetryCount) {
      // 若已取消，立即停止
      if (cancelled.isCompleted) {
        return;
      }

      // 段重试退避（非首次）
      if (attempt > 0) {
        debugPrint('SegmentDownloader: 段[${segment.index}] 重试 ($attempt/$maxRetryCount)');
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }

      try {
        await semaphore.acquire();
        try {
          if (cancelled.isCompleted) {
            return;
          }
          final success = await _downloadOneSegment(
            segment: segment,
            url: url,
            status: status,
            context: context,
            cancelled: cancelled,
            onProgress: onProgress,
          );
          if (success) {
            onComplete();
            return;
          }
        } finally {
          semaphore.release();
        }
      } on _ServerNoRangeException {
        // 服务器不支持 Range：清理本段部分文件，通知上层回退单段
        debugPrint('SegmentDownloader: 段[${segment.index}] 服务器不支持 Range，回退单段');
        final partFile = File(segment.partPath(status.savePath));
        try {
          if (await partFile.exists()) {
            await partFile.delete();
          }
        } catch (_) {}
        onFallback();
        return;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e) || cancelled.isCompleted) {
          // 用户暂停/取消：通知上层
          if (!cancelled.isCompleted) {
            cancelled.complete();
          }
          return;
        }
        debugPrint('SegmentDownloader: 段[${segment.index}] 异常 - ${e.message}');
      } catch (e) {
        debugPrint('SegmentDownloader: 段[${segment.index}] 异常 - $e');
      }

      attempt++;
    }

    // 耗尽重试
    onError('段[${segment.index}] 重试 $maxRetryCount 次仍失败');
  }

  /// 下载单个段，写入 .part{index} 文件
  /// 返回 true = 段下载成功
  Future<bool> _downloadOneSegment({
    required DownloadSegment segment,
    required String url,
    required DownloadStatus status,
    required DownloadContext? context,
    required Completer<void> cancelled,
    required void Function(int bytes) onProgress,
  }) async {
    final partPath = segment.partPath(status.savePath);
    final partFile = File(partPath);

    // 断点续传：已存在的 part 文件长度作为起点
    var start = 0;
    if (await partFile.exists()) {
      start = await partFile.length();
    }

    // 段已完整（part 文件达到段大小），跳过
    if (start >= segment.length) {
      onProgress(segment.length);
      return true;
    }

    // 构建 Range 头：从 part 文件当前长度继续
    final rangeStart = segment.startByte + start;
    final requestHeaders = <String, String>{
      'Range': 'bytes=$rangeStart-${segment.endByte}',
      ...?context?.headers,
    };

    // 超时配置
    final options = Options(
      headers: requestHeaders,
      responseType: ResponseType.stream,
    );
    if (context?.timeoutInSeconds != null) {
      options.sendTimeout = Duration(seconds: context!.timeoutInSeconds!);
      options.receiveTimeout = Duration(seconds: context.timeoutInSeconds!);
    }

    try {
      final response = await _dio.get(
        url,
        cancelToken: status.getSegmentCancelToken(segment.index),
        options: options,
      );

      final statusCode = response.statusCode;
      // 206 = 支持 Range（正常）；其他状态码说明服务器行为异常
      // （多段下载中某段返回 200 表示服务器不支持分段，数据会错乱），
      // 抛出特殊错误让上层回退单段。
      if (statusCode != 206) {
        debugPrint('SegmentDownloader: 段[${segment.index}] 状态码 $statusCode（非206，无法分段）');
        throw const _ServerNoRangeException();
      }

      // 写入 part 文件（追加模式）
      final fileStream = partFile.openWrite(mode: FileMode.writeOnlyAppend);
      try {
        var received = 0;
        await for (final data in response.data.stream) {
          if (cancelled.isCompleted) {
            break;
          }
          fileStream.add(data);
          received += data.length as int;
          // 该段已下载字节 = 起始部分(start) + 本次收到
          onProgress(start + received);
        }
        await fileStream.flush();
        await fileStream.close();
      } catch (e) {
        await fileStream.close();
        rethrow;
      }

      // 校验该段是否完整
      final partLen = await partFile.length();
      if (partLen < segment.length) {
        throw DioException(
          requestOptions: response.requestOptions,
          type: DioExceptionType.connectionError,
          message: 'Segment incomplete: $partLen/${segment.length}',
        );
      }

      onProgress(segment.length);
      return true;
    } catch (e) {
      // 若取消，不要标记为失败（外层会判断 cancelled）
      if (cancelled.isCompleted) {
        return false;
      }
      rethrow;
    }
  }

  /// 汇总各段已下载字节
  int _sumSegmentBytes(List<int> segmentBytes, List<DownloadSegment> segments) {
    var total = 0;
    for (var i = 0; i < segmentBytes.length; i++) {
      // 防止超过段大小（部分段可能重复上报）
      final maxBytes = segments[i].length;
      total += segmentBytes[i].clamp(0, maxBytes);
    }
    return total;
  }
}

/// 段级并发控制信号量
class _SegmentSemaphore {
  final int _maxConcurrent;
  int _active = 0;
  final List<Completer<void>> _queue = [];

  _SegmentSemaphore(this._maxConcurrent);

  Future<void> acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final completer = Completer<void>();
    _queue.add(completer);
    await completer.future;
    _active++;
  }

  void release() {
    _active--;
    if (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      next.complete();
    }
  }
}

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';

/// 单段下载范围
class DownloadSegment {
  /// 段索引（从 0 开始）
  final int index;

  /// 起始字节（含）
  final int startByte;

  /// 结束字节（含）
  final int endByte;

  const DownloadSegment({
    required this.index,
    required this.startByte,
    required this.endByte,
  });

  /// 段大小
  int get length => endByte - startByte + 1;

  /// 对应 Range 头值
  String get rangeHeader => 'bytes=$startByte-$endByte';

  /// 段部分文件路径
  String partPath(String savePath) => '${savePath}.part$index';

  @override
  String toString() => 'Segment[$index]($startByte-${endByte}B)';
}

/// 段规划结果
class SegmentPlan {
  /// 文件总大小（0 = 未知）
  final int totalBytes;

  /// 是否支持 Range
  final bool supportsRange;

  /// 规划的分段列表（不支持 Range 时为单段 [0, total-1]）
  final List<DownloadSegment> segments;

  /// 是否为多段下载
  bool get isMultiSegment => segments.length > 1;

  /// 段数
  int get segmentCount => segments.length;

  const SegmentPlan({
    required this.totalBytes,
    required this.supportsRange,
    required this.segments,
  });
}

/// 段规划器
/// 负责：
/// 1. 探测服务器是否支持 Range（发送 Range: bytes=0-0，判断 206）
/// 2. 按文件大小自适应计算分段数
/// 3. 生成每段的起止字节
///
/// 分段策略：
/// - 文件 < [minMultiSegmentSize] 或服务器不支持 Range → 单段（回退）
/// - 否则按 [segmentSizeBytes] 均分，最多 [maxSegments] 段
class SegmentPlanner {
  /// 默认段大小（8MB）
  static const int defaultSegmentSizeBytes = 8 * 1024 * 1024;

  /// 触发多段的最小文件大小（2MB 以下直接单段，避免小文件分段开销）
  static const int minMultiSegmentSize = 2 * 1024 * 1024;

  /// 最大段数
  static const int maxSegments = 8;

  /// 探测 Range 支持的请求
  /// 返回 true = 支持 Range（206），false = 不支持或探测失败
  static Future<bool> probeRangeSupport({
    required String url,
    required Dio dio,
    CancelToken? cancelToken,
    Map<String, String>? headers,
    int timeoutSeconds = 10,
  }) async {
    try {
      final response = await dio.get(
        url,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            ...?headers,
            'Range': 'bytes=0-0',
          },
        ),
        onReceiveProgress: (count, total) {},
      );
      // 206 = 支持 Range；200 = 服务器忽略 Range（需回退单段）
      return response.statusCode == 206;
    } catch (e) {
      debugPrint('SegmentPlanner: Range 探测失败（回退单段）- $e');
      return false;
    }
  }

  /// 规划下载分段
  ///
  /// [totalBytes] 已知文件大小；[supportBreakpoint] 是否允许分段。
  /// 返回 null 表示无法规划（应回退单连接）。
  static Future<SegmentPlan?> plan({
    required String url,
    required int totalBytes,
    required bool supportBreakpoint,
    required Dio dio,
    CancelToken? cancelToken,
    Map<String, String>? headers,
    int timeoutSeconds = 10,
  }) async {
    // 文件过小或明确不支持断点 → 单段
    if (totalBytes <= 0 || !supportBreakpoint || totalBytes < minMultiSegmentSize) {
      return SegmentPlan(
        totalBytes: totalBytes,
        supportsRange: false,
        segments: const [],
      );
    }

    // 探测服务器是否支持 Range
    final supportsRange = await probeRangeSupport(
      url: url,
      dio: dio,
      cancelToken: cancelToken,
      headers: headers,
      timeoutSeconds: timeoutSeconds,
    );

    if (!supportsRange) {
      // 不支持 Range：由调用方走单连接逻辑（现有 200 从头下载）
      return SegmentPlan(
        totalBytes: totalBytes,
        supportsRange: false,
        segments: const [],
      );
    }

    // 自适应段数：min(maxSegments, max(1, totalBytes / segmentSize))
    final segmentCount = _calcSegmentCount(totalBytes);

    return SegmentPlan(
      totalBytes: totalBytes,
      supportsRange: true,
      segments: divideSegments(totalBytes, segmentCount),
    );
  }

  /// 均分文件为 [segmentCount] 段（公开供测试）
  /// 余数分配到前几个段，保证所有段覆盖 [0, totalBytes-1]
  static List<DownloadSegment> divideSegments(int totalBytes, int segmentCount) {
    final segments = <DownloadSegment>[];
    final partSize = totalBytes ~/ segmentCount;
    var remainder = totalBytes % segmentCount;

    var start = 0;
    for (var i = 0; i < segmentCount; i++) {
      // 把余数平均分配到前几个段
      final size = partSize + (i < remainder ? 1 : 0);
      final end = start + size - 1;
      segments.add(DownloadSegment(
        index: i,
        startByte: start,
        endByte: end,
      ));
      start = end + 1;
    }
    return segments;
  }

  /// 自适应计算段数（公开供测试）
  static int calcSegmentCountForSize(int totalBytes) => _calcSegmentCount(totalBytes);

  /// 自适应计算段数
  static int _calcSegmentCount(int totalBytes) {
    final bySize = (totalBytes / defaultSegmentSizeBytes).ceil();
    if (bySize <= 1) return 1;
    return bySize.clamp(2, maxSegments);
  }
}

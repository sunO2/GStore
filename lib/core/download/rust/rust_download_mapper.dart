import 'package:gstore/core/download/model/download_task.dart';

/// 把 Rust 下载模块回传的任务 DTO 映射为面板直接消费的 [DownloadTask]。
///
/// 为什么要单独一层：面板（`lib/page/download/`）读的是 Dart 模型，
/// 而模块的真源是它自己的 SQLite。这层是两者之间**唯一的**翻译点，
/// 保证「换内核不改面板」。
///
/// 契约要点（改这里等于改契约）：
/// - `status` 是 **Dart 枚举索引**（Rust 侧 `TaskStatus` 的判别值与之逐一对齐）；
///   错位会让状态显示张冠李戴。
/// - 时间戳是**毫秒**。
/// - `kind`/`resourceId`/`dedupKey` 是模块新增的通用资源字段；
///   面板暂未使用，但解析保留，后续做「按资源类型分组」不必再改契约。
class RustDownloadMapper {
  RustDownloadMapper._();

  /// 解析单条任务 DTO。结构不符时抛 [FormatException]（不静默吞错，
  /// 否则面板会显示一条状态错乱的任务）。
  static DownloadTask fromDto(Map<String, dynamic> dto) {
    final statusIndex = _asInt(dto['status']);
    if (statusIndex < 0 || statusIndex >= DownloadStatusEnum.values.length) {
      throw FormatException('未知的任务状态索引: $statusIndex');
    }

    return DownloadTask(
      id: _asInt(dto['id']),
      appId: _asString(dto['appId']),
      appName: _asString(dto['appName']),
      version: _asString(dto['version']),
      fileName: _asString(dto['fileName']),
      url: _asString(dto['url']),
      filePath: _asString(dto['filePath']),
      total: _asInt(dto['total']),
      received: _asInt(dto['received']),
      status: DownloadStatusEnum.values[statusIndex],
      speedBps: _asInt(dto['speedBps']),
      etaSec: dto['etaSec'] == null ? null : _asInt(dto['etaSec']),
      error: dto['error'] as String?,
      segments: _segments(dto['segments']),
      headers: _headers(dto['headers']),
      installAfterDownload: dto['installAfterDownload'] == true,
      lastStartedAt: _asMs(dto['lastStartedAt']),
      createdAt: DateTime.fromMillisecondsSinceEpoch(_asInt(dto['createdAt'])),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(_asInt(dto['updatedAt'])),
    );
  }

  /// 解析任务列表。
  static List<DownloadTask> fromDtoList(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>) fromDto(e),
    ];
  }

  /// 进度事件载荷（`download.progress`）也是同一套字段，直接复用。
  /// 把「增量进度事件」合并到已有任务上，**只覆盖会变化的字段**。
  ///
  /// 进度事件刻意不带 url / 保存路径等不变字段（省带宽）。若直接用它构造任务，
  /// 面板里该任务的下载地址与保存路径会被清空 —— 表现为"下载过程中信息弹框
  /// 看不到地址"。所以订阅时必须先取一次全量任务作基底，之后都走本方法合并。
  static DownloadTask mergeProgress(DownloadTask? base, Map<String, dynamic> event) {
    final progress = fromProgressEvent(event);
    if (base == null) {
      return progress;
    }
    return base.copyWith(
      total: progress.total,
      received: progress.received,
      status: progress.status,
      speedBps: progress.speedBps,
      etaSec: progress.etaSec,
      error: progress.error,
      segments: progress.segments ?? base.segments,
    );
  }

  static DownloadTask fromProgressEvent(Map<String, dynamic> event) {
    // 进度事件只带传输态字段，其余字段补默认值即可（面板只用进度相关字段）
    return fromDto({
      'id': event['taskId'],
      'appId': '',
      'appName': '',
      'version': '',
      'fileName': '',
      'url': '',
      'filePath': '',
      'total': event['total'] ?? 0,
      'received': event['received'] ?? 0,
      'status': event['status'] ?? 2,
      'speedBps': event['speedBps'] ?? 0,
      'etaSec': event['etaSec'],
      'error': event['error'],
      'segments': event['segments'],
      'createdAt': 0,
      'updatedAt': 0,
    });
  }

  static List<SegmentInfo>? _segments(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    return [
      for (final e in raw)
        if (e is Map<String, dynamic>)
          SegmentInfo(
            index: _asInt(e['index']),
            startByte: _asInt(e['startByte']),
            endByte: _asInt(e['endByte']),
            received: _asInt(e['received']),
          ),
    ];
  }

  /// JSON 数字可能是 int 也可能是 double（部分平台会把整型解成 double）
  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static String _asString(Object? v) => v is String ? v : '';
}


/// DTO 的 `headers` 是 `[[k, v], …]`（JSON 的 map 不保证键序），这里转回 Map。
Map<String, String> _headers(Object? raw) {
  if (raw is! List) return const {};
  final out = <String, String>{};
  for (final e in raw) {
    if (e is List && e.length >= 2) out['${e[0]}'] = '${e[1]}';
  }
  return out;
}

/// 毫秒时间戳（容忍 int / double / 字符串）
int _asMs(Object? raw) {
  if (raw is int) return raw;
  if (raw is double) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  return 0;
}

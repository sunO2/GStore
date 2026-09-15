enum DownloadStatusEnum {
  queued,
  connecting,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

class SegmentInfo {
  final int index;
  final int startByte;
  final int endByte;
  final int received;

  const SegmentInfo({
    required this.index,
    required this.startByte,
    required this.endByte,
    this.received = 0,
  });

  Map<String, dynamic> toMap() => {
        'index': index,
        'startByte': startByte,
        'endByte': endByte,
        'received': received,
      };

  factory SegmentInfo.fromMap(Map<String, dynamic> map) => SegmentInfo(
        index: map['index'] as int,
        startByte: map['startByte'] as int,
        endByte: map['endByte'] as int,
        received: map['received'] as int? ?? 0,
      );
}

class DownloadTask {
  final int? id;
  final String appId;
  final String appName;
  final String version;
  final String fileName;
  final String url;
  final String filePath;
  final int total;
  final int received;
  final DownloadStatusEnum status;
  final int speedBps;
  final int? etaSec;
  final String? error;
  final List<SegmentInfo>? segments;

  /// 发起下载时携带的请求头（GitHub/OPPO 等源需要；面板展示用）
  final Map<String, String> headers;

  /// 下载完成后是否自动安装（跨重启保留，Rust 侧持久化）
  final bool installAfterDownload;

  /// 最后一次开始时间（毫秒）。列表按它置顶；重试/重新下载会刷新
  final int lastStartedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DownloadTask({
    required this.id,
    required this.appId,
    required this.appName,
    required this.version,
    required this.fileName,
    required this.url,
    required this.filePath,
    required this.total,
    required this.received,
    required this.status,
    required this.speedBps,
    required this.etaSec,
    required this.error,
    required this.segments,
    this.headers = const {},
    this.installAfterDownload = false,
    this.lastStartedAt = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isCompleted => status == DownloadStatusEnum.completed;

  bool get isActive =>
      status == DownloadStatusEnum.downloading ||
      status == DownloadStatusEnum.queued ||
      status == DownloadStatusEnum.connecting;

  DownloadTask copyWith({
    int? id,
    String? appId,
    String? appName,
    String? version,
    String? fileName,
    String? url,
    String? filePath,
    int? total,
    int? received,
    DownloadStatusEnum? status,
    int? speedBps,
    int? etaSec,
    String? error,
    List<SegmentInfo>? segments,
    Map<String, String>? headers,
    bool? installAfterDownload,
    int? lastStartedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      appId: appId ?? this.appId,
      appName: appName ?? this.appName,
      version: version ?? this.version,
      fileName: fileName ?? this.fileName,
      url: url ?? this.url,
      filePath: filePath ?? this.filePath,
      total: total ?? this.total,
      received: received ?? this.received,
      status: status ?? this.status,
      speedBps: speedBps ?? this.speedBps,
      etaSec: etaSec ?? this.etaSec,
      error: error ?? this.error,
      segments: segments ?? this.segments,
      headers: headers ?? this.headers,
      installAfterDownload: installAfterDownload ?? this.installAfterDownload,
      lastStartedAt: lastStartedAt ?? this.lastStartedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
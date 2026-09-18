import 'package:gstore/core/download/model/download_task.dart';

/// 下载管理页筛选条件
enum DownloadFilter { all, downloading, completed, failed }

/// 下载状态归类
enum DownloadStatusKind { waiting, downloading, queued, completed, failed }

/// 主操作按钮
enum DownloadAction { pause, resume, retry, install, cancel }

/// 判断条目是否命中筛选条件
bool matchesFilter(DownloadTask item, DownloadFilter filter) {
  switch (filter) {
    case DownloadFilter.all:
      return true;
    case DownloadFilter.downloading:
      // 下载中 = 正在下载（downloading/connecting）或已暂停（paused，原 READY）
      // 或排队中（queued）或已取消（cancelled，取消后仍可恢复）
      return item.status == DownloadStatusEnum.downloading ||
          item.status == DownloadStatusEnum.connecting ||
          item.status == DownloadStatusEnum.paused ||
          item.status == DownloadStatusEnum.queued ||
          item.status == DownloadStatusEnum.cancelled;
    case DownloadFilter.completed:
      return item.status == DownloadStatusEnum.completed;
    case DownloadFilter.failed:
      // 仅 failed 算失败；paused/cancelled 表示等待重试/开始，不算失败
      return item.status == DownloadStatusEnum.failed;
  }
}

/// 将底层 status 归类为 DownloadStatusKind
DownloadStatusKind statusKindOf(DownloadTask item) {
  switch (item.status) {
    case DownloadStatusEnum.downloading:
    case DownloadStatusEnum.connecting:
      return DownloadStatusKind.downloading;
    case DownloadStatusEnum.completed:
      return DownloadStatusKind.completed;
    case DownloadStatusEnum.failed:
      return DownloadStatusKind.failed;
    case DownloadStatusEnum.queued:
      return DownloadStatusKind.queued;
    case DownloadStatusEnum.paused:
    case DownloadStatusEnum.cancelled:
      return DownloadStatusKind.waiting;
  }
}

/// 已完成任务的文件是否已被外部删除（如缓存管理页删除下载文件）。
///
/// 命中时 UI 应将"已完成/安装"降级为"已删除"（徽标变色、隐藏安装按钮）。
bool isCompletedFileMissing(DownloadTask item, Set<int> missingFileIds) {
  if (item.status != DownloadStatusEnum.completed) return false;
  final id = item.id;
  return id != null && missingFileIds.contains(id);
}

/// 主操作按钮：downloading/connecting→pause、paused/cancelled→resume、
/// queued→cancel、failed→retry、completed 且文件名以 .apk 结尾→install，否则 null
DownloadAction? primaryActionFor(DownloadTask item) {
  switch (item.status) {
    case DownloadStatusEnum.downloading:
    case DownloadStatusEnum.connecting:
      return DownloadAction.pause;
    case DownloadStatusEnum.paused:
    case DownloadStatusEnum.cancelled:
      return DownloadAction.resume;
    case DownloadStatusEnum.queued:
      return DownloadAction.cancel;
    case DownloadStatusEnum.failed:
      return DownloadAction.retry;
    case DownloadStatusEnum.completed:
      return item.fileName.endsWith('.apk') ? DownloadAction.install : null;
  }
}

/// 多文件组（同一 appId + version）的聚合状态类别。
///
/// 优先级：失败 > 下载中 > 排队 > 等待 > 全部完成。
/// 只要组内有失败就报失败，避免"失败被折叠藏起来"。
enum DownloadGroupKind { downloading, queued, waiting, failed, completed }

/// 一组下载任务的聚合结果（多文件组折叠态与徽标展示用）。
///
/// 折叠态不再用组内第一条代表整组：条数、总大小、聚合进度、合计速度、
/// 失败/已删除计数都由这里给出。
class DownloadGroupSummary {
  /// 文件总数
  final int total;

  /// 已完成数（含文件已被外部删除的）
  final int completed;

  /// 失败数
  final int failed;

  /// 已完成但磁盘文件已被外部删除的数量
  final int deleted;

  /// 下载中/连接中数量
  final int active;

  /// 排队中数量
  final int queued;

  /// 等待中数量（paused / cancelled）
  final int waiting;

  /// 组内已接收字节合计
  final int receivedBytes;

  /// 组内总字节合计（大小未知的任务按 0 计）
  final int totalBytes;

  /// 组内下载中任务的合计速度（bytes/s）
  final int speedBps;

  /// 组级预估剩余时间（秒）；速度未知或已下完时为 null
  final int? etaSec;

  /// 聚合状态类别
  final DownloadGroupKind kind;

  const DownloadGroupSummary({
    required this.total,
    required this.completed,
    required this.failed,
    required this.deleted,
    required this.active,
    required this.queued,
    required this.waiting,
    required this.receivedBytes,
    required this.totalBytes,
    required this.speedBps,
    required this.etaSec,
    required this.kind,
  });

  /// 是否多文件组（单文件组不走折叠展示）
  bool get isMulti => total > 1;

  /// 组内是否全部完成
  bool get allCompleted => total > 0 && completed == total;

  /// 是否有可展示的聚合进度（已知总大小且尚未全部完成）
  bool get hasProgress => totalBytes > 0 && !allCompleted;

  /// 聚合进度 0.0~1.0（多文件并发时这才是整组进度）
  double get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  int get percent => (progress * 100).round();
}

/// 聚合组内所有任务的状态 / 进度 / 速度。
///
/// ETA 用「剩余字节 ÷ 合计速度」估算，只有下载中才有意义。
DownloadGroupSummary summarizeGroup(
  List<DownloadTask> items,
  Set<int> missingFileIds,
) {
  var completed = 0;
  var failed = 0;
  var deleted = 0;
  var active = 0;
  var queued = 0;
  var waiting = 0;
  var receivedBytes = 0;
  var totalBytes = 0;
  var speedBps = 0;

  for (final item in items) {
    switch (item.status) {
      case DownloadStatusEnum.completed:
        completed++;
        if (isCompletedFileMissing(item, missingFileIds)) deleted++;
        break;
      case DownloadStatusEnum.failed:
        failed++;
        break;
      case DownloadStatusEnum.downloading:
      case DownloadStatusEnum.connecting:
        active++;
        break;
      case DownloadStatusEnum.queued:
        queued++;
        break;
      case DownloadStatusEnum.paused:
      case DownloadStatusEnum.cancelled:
        waiting++;
        break;
    }
    receivedBytes += item.received;
    totalBytes += item.total;
    if (item.status == DownloadStatusEnum.downloading) {
      speedBps += item.speedBps;
    }
  }

  final remaining = totalBytes - receivedBytes;
  final etaSec =
      (speedBps > 0 && remaining > 0) ? (remaining / speedBps).ceil() : null;

  final kind = failed > 0
      ? DownloadGroupKind.failed
      : active > 0
          ? DownloadGroupKind.downloading
          : queued > 0
              ? DownloadGroupKind.queued
              : waiting > 0
                  ? DownloadGroupKind.waiting
                  : DownloadGroupKind.completed;

  return DownloadGroupSummary(
    total: items.length,
    completed: completed,
    failed: failed,
    deleted: deleted,
    active: active,
    queued: queued,
    waiting: waiting,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
    speedBps: speedBps,
    etaSec: etaSec,
    kind: kind,
  );
}

/// 格式化下载速度
/// bytesPerSec → "12.5 MB/s" / "856 KB/s" / "1.2 KB/s"
String formatSpeed(num bytesPerSec) {
  if (bytesPerSec <= 0) return '';
  if (bytesPerSec >= 1024 * 1024) {
    return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(1)} MB/s';
  } else if (bytesPerSec >= 1024) {
    return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
  } else {
    return '${bytesPerSec.toStringAsFixed(0)} B/s';
  }
}

/// 格式化持续时间
/// seconds → "剩余 7s" / "剩余 2m 15s" / "剩余 1h 5m"
String formatDuration(int seconds) {
  if (seconds <= 0) return '';
  if (seconds < 60) return '剩余 ${seconds}s';
  if (seconds < 3600) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s > 0 ? '剩余 ${m}m ${s}s' : '剩余 ${m}m';
  }
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return m > 0 ? '剩余 ${h}h ${m}m' : '剩余 ${h}h';
}

/// 从下载链接推断来源渠道（展示用）
///
/// DownloadTask 无渠道字段，依据 URL 域名推断：
/// - 含 api.github.com / github.com / raw.githubusercontent.com → GitHub
///   （含代理前缀 URL，如 ghfast.top/https://github.com/...，仍能命中）
/// - 含 vivo 应用市场域名 → vivo 应用市场
/// - 其余无法识别 → null（展示时省略渠道行）
String? inferChannelLabel(String downloadUrl) {
  final url = downloadUrl.toLowerCase();
  if (url.isEmpty) return null;
  if (url.contains('github.com') ||
      url.contains('api.github.com') ||
      url.contains('raw.githubusercontent.com')) {
    return 'GitHub';
  }
  if (url.contains('vivo') || url.contains('app.vss')) {
    return 'vivo 应用市场';
  }
  return null;
}

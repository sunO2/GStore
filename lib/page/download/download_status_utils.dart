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

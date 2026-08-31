sealed class DownloadEvent {}

/// 低频进度快照（引擎侧节流，≤4 次/秒）。
///
/// [received] 是**磁盘已落盘字节**（下载期 = Σ 各 .part{i} 长度；merge 起 = total），
/// 而非内存事件计数——避免事件时序/DB 落库滞后导致进度与磁盘脱节。
class DownloadProgress extends DownloadEvent {
  final int received;

  /// total null = size unknown (e.g. gzip-decoded)。
  final int? total;

  DownloadProgress(this.received, this.total);
}

/// merge 阶段标识：所有分片已下完、正在顺序串流合并写入最终文件。
/// UI 可显示"正在合并/写入…"，进度保持 100%。
class DownloadMerging extends DownloadEvent {
  final int total;

  DownloadMerging(this.total);
}

class DownloadCompleted extends DownloadEvent {}

class DownloadFailed extends DownloadEvent {
  final String message;

  DownloadFailed(this.message);
}

import 'package:gstore/http/download/DownloadStatus.dart';

/// 下载管理页筛选条件
enum DownloadFilter { all, downloading, completed, failed }

/// 下载状态归类
enum DownloadStatusKind { waiting, downloading, completed, failed }

/// 主操作按钮
enum DownloadAction { pause, resume, retry, install }

/// 判断条目是否命中筛选条件
bool matchesFilter(DownloadStatus item, DownloadFilter filter) {
  switch (filter) {
    case DownloadFilter.all:
      return true;
    case DownloadFilter.downloading:
      // 下载中 = 正在下载（LOADING）或准备就绪（READY）
      return item.status == DownloadStatus.DOWNLOAD_LOADING ||
          item.status == DownloadStatus.DOWNLOAD_READY;
    case DownloadFilter.completed:
      return item.status == DownloadStatus.DOWNLOAD_SUCCESS;
    case DownloadFilter.failed:
      // 仅 DOWNLOAD_ERROR 算失败；READY 表示等待重试/开始，不算失败
      return item.status == DownloadStatus.DOWNLOAD_ERROR;
  }
}

/// 将底层 status 数值归类为 DownloadStatusKind
DownloadStatusKind statusKindOf(DownloadStatus item) {
  switch (item.status) {
    case DownloadStatus.DOWNLOAD_LOADING:
      return DownloadStatusKind.downloading;
    case DownloadStatus.DOWNLOAD_SUCCESS:
      return DownloadStatusKind.completed;
    case DownloadStatus.DOWNLOAD_ERROR:
      return DownloadStatusKind.failed;
    case DownloadStatus.DOWNLOAD_READY:
    default:
      return DownloadStatusKind.waiting;
  }
}

/// 主操作按钮：LOADING→pause、READY→resume、ERROR→retry、
/// SUCCESS 且文件名以 .apk 结尾→install，否则 null
DownloadAction? primaryActionFor(DownloadStatus item) {
  switch (item.status) {
    case DownloadStatus.DOWNLOAD_LOADING:
      return DownloadAction.pause;
    case DownloadStatus.DOWNLOAD_READY:
      return DownloadAction.resume;
    case DownloadStatus.DOWNLOAD_ERROR:
      return DownloadAction.retry;
    case DownloadStatus.DOWNLOAD_SUCCESS:
      return item.fileName.endsWith('.apk')
          ? DownloadAction.install
          : null;
    default:
      return null;
  }
}

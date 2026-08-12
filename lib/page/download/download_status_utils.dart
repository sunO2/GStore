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

/// 从下载链接推断来源渠道（展示用）
///
/// DownloadStatus 无渠道字段，依据 URL 域名推断：
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

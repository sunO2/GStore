/// A pure-data description of a single download to perform.
///
/// Produced by [DownloadStrategyManager] and consumed by [DownloadEngine].
/// This is passive data only — it does not perform any orchestration,
/// queueing, or side effects on its own.
class DownloadRequest {
  final String url;
  final String? savePath;
  final Map<String, String>? headers;
  final int? fileSize;
  final bool resume;

  /// 惰性 URL 解析：非空时每次发起请求（探测/每段/重试）前重新调用，
  /// 用于代理拼接、签名 URL 过期后重新解析等场景。返回 null 则回退 [url]。
  final String? Function()? urlProvider;

  DownloadRequest({
    required this.url,
    required this.savePath,
    this.headers,
    this.fileSize,
    this.resume = true,
    this.urlProvider,
  });

  /// 复制当前请求并填充保存路径
  /// [savePath] 最终保存的文件路径
  DownloadRequest copyWithSavePath(String savePath) =>
      DownloadRequest(
        url: url,
        savePath: savePath,
        headers: headers,
        fileSize: fileSize,
        resume: resume,
        urlProvider: urlProvider,
      );
}

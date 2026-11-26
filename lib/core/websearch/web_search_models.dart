/// 联网检索的数据模型（P3-7）
library;

/// 一条搜索结果
class WebSearchHit {
  const WebSearchHit({
    required this.title,
    required this.url,
    this.snippet = '',
    this.content,
    this.publishedAt,
    this.score,
  });

  final String title;
  final String url;

  /// 摘要（Tavily 的 `content` 精简片段）
  final String snippet;

  /// 更长的正文片段（provider 提供时）
  final String? content;

  /// 发布时间（provider 原样字符串，不保证可解析）
  final String? publishedAt;

  final double? score;

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        if (snippet.isNotEmpty) 'snippet': snippet,
        if (content != null) 'content': content,
        if (publishedAt != null) 'publishedAt': publishedAt,
        if (score != null) 'score': score,
      };
}

/// 抓取到的网页正文
class WebFetchPage {
  const WebFetchPage({
    required this.url,
    required this.title,
    required this.content,
    this.publishedAt,
    this.via = 'direct',
    this.truncated = false,
  });

  final String url;
  final String title;
  final String content;
  final String? publishedAt;

  /// `direct` | `jina`
  final String via;
  final bool truncated;
}

/// 原始 HTTP 响应（接口探测/联调用，不走正文抽取）
class WebHttpResponse {
  const WebHttpResponse({
    required this.url,
    required this.method,
    required this.statusCode,
    this.reasonPhrase = '',
    this.headers = const <String, String>{},
    this.contentType = '',
    this.body = '',
    this.truncated = false,
    this.binary = false,
    this.bytes = 0,
  });

  final String url;
  final String method;
  final int statusCode;
  final String reasonPhrase;

  /// 响应头（已去掉 Set-Cookie 等敏感项，值超长会截断）。
  final Map<String, String> headers;
  final String contentType;

  /// 文本响应体；二进制响应为空字符串。
  final String body;
  final bool truncated;
  final bool binary;

  /// 响应体原始字节数（二进制响应也保留）。
  final int bytes;
}

/// 联网检索的统一异常：`code` 用于给模型/用户可操作的提示。
class WebSearchException implements Exception {
  WebSearchException(this.code, this.message, {this.retryAfterSeconds});

  /// `quota_exceeded` | `rate_limited` | `unauthorized` | `network` |
  /// `bad_response` | `blocked_url` | `disabled`
  final String code;
  final String message;
  final int? retryAfterSeconds;

  @override
  String toString() => message;
}

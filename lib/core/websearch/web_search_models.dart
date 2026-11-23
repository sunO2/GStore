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

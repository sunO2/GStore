/// 「请求调试」原始请求文本纯逻辑（plan todo 18）。
///
/// 把 [DebugRequest] 草稿渲染为可读的原始 HTTP 请求文本（方法 / 完整 URL /
/// 启用的请求头 / 请求体），供 `RawRequestView` 展示。纯函数、无 UI。
library;

import 'debug_models.dart';
import 'query_codec.dart';

/// 组合原始 HTTP 请求文本。
///
/// - 请求行：`METHOD <完整 URL> HTTP/1.1`（启用查询参数按 [rebuildUrl] 规则
///   编码并置于 fragment 之前）；
/// - 请求头：仅启用的、名字非空的头，按草稿顺序逐行输出；
/// - 请求体：非空时在空行后原样附上（不解码、不美化）。
String composeRawRequest(DebugRequest request) {
  final params = request.query.where((q) => q.enabled).toList();
  final url = rebuildUrl(request.url, null, params);
  final buffer = StringBuffer('${request.method} $url HTTP/1.1');
  for (final header in request.headers) {
    if (!header.enabled || header.name.trim().isEmpty) continue;
    buffer.write('\n${header.name}: ${header.value}');
  }
  if (request.body.isNotEmpty) {
    buffer.write('\n\n${request.body}');
  }
  return buffer.toString();
}

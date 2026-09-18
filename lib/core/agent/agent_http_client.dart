/// Agent 框架（Genkit）网络层：AI 请求使用标准 `package:http` 客户端。
///
/// 背景：曾尝试用 rhttp（curl 栈）作为 AI 请求客户端，实测发现
/// `RhttpCompatibleClient` 对流式 SSE 响应体的解码不可靠——模型流式回复
/// 中偶发 `RhttpUnknownException: error decoding response body`（连接中断 /
/// Content-Encoding 处理/字节流异常），被 Genkit 包成
/// `GenkitException(INTERNAL, Code 13)` 导致对话失败率明显上升。
///
/// 结论：AI 对话是**低频长连接请求**（用户发一条等几秒），rhttp 的连接池/
/// HTTP/2 性能优势在这里几乎无收益，而 SSE 流式的可靠性是硬要求。因此
/// 回退到标准 `http.Client()`（IOClient，Dart 原生 socket），与 AI 场景匹配。
/// （app 其余网络层仍走 Dio/rhttp，不受影响。）
library;

import 'package:http/http.dart' as http;

/// 创建注入给 Genkit 插件的 http.Client。
///
/// 标准 `package:http` 客户端（IOClient）——对流式 SSE 逐字节可靠解码，
/// 无 rhttp 兼容层的响应体解码缺陷。
Future<http.Client> buildAgentHttpClient() async {
  return http.Client();
}

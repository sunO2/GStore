/// 内联 think 标签解析
///
/// 部分模型（DeepSeek-R1 系、部分 Qwen/GLM 部署）把推理内容以
/// ` thinking…<｜end▁of▁thinking｜>` 内联在正文里输出。Genkit 的 OpenAI 兼容插件
/// （genkit_openai 0.3.7）流式只发 TextPart，既不会把
/// `reasoning_content` 映射成 ReasoningPart，也不会剥离内联 think，
/// 因此需要在此统一拆分，避免思考内容混进可见回答。
///
/// 说明：
/// - 大小写不敏感（`<THINK>` 亦可）；`<thinking>` 因前缀匹配同样生效
/// - 流式分片下开始标签可能接收不完整（如 "正文<thi"），此时先扣住不展示
/// - Gemini 等原生支持 thinking 的 provider 由 Genkit 映射为
///   `ReasoningPart`（`part.isReasoning`），不经过本解析器
library;

/// 开始标签（小写）
const String _thinkTag = '<think';

/// 拆分内联 think 块，返回 (reasoning, visibleText)
///
/// - 无标签：reasoning 为空，正文原样返回
/// - 有开始标签但未闭合：视为思考进行中，正文为空，剩余内容全归思考
/// - 已闭合：开始标签前的内容 + 结束标签后的内容 记为正文
(String, String) splitThink(String raw) {
  if (raw.isEmpty) return ('', '');

  // 大小写不敏感（标签仅含 ASCII，转小写不改变长度/索引）
  final lower = raw.toLowerCase();
  final open = lower.indexOf(_thinkTag);
  if (open < 0) {
    // 尾部可能是尚未接收完整的开始标签：扣住不展示
    final hold = _trailingTagPrefixLen(lower);
    if (hold > 0) return ('', raw.substring(0, raw.length - hold));
    return ('', raw);
  }

  final openEnd = raw.indexOf('>', open);
  // 开始标签尚未接收完整：暂不展示任何正文
  if (openEnd < 0) return ('', '');

  final head = raw.substring(0, open).trim();
  final close = lower.indexOf('</think', openEnd);
  final body = close < 0
      ? raw.substring(openEnd + 1)
      : raw.substring(openEnd + 1, close);
  final tail = close < 0 ? '' : raw.substring(raw.indexOf('>', close) + 1);
  final reasoning = body.trim();
  final visible = head.isEmpty ? tail : '$head\n$tail';
  return (reasoning, visible.trimLeft());
}

/// raw 末尾作为 `_thinkTag` 前缀的长度（0 表示没有可扣部分）
int _trailingTagPrefixLen(String lowerRaw) {
  for (var len = _thinkTag.length - 1; len >= 1; len--) {
    if (lowerRaw.endsWith(_thinkTag.substring(0, len))) return len;
  }
  return 0;
}

/// 从 OpenAI 兼容端点的**最终响应 raw** 中取思考内容。
///
/// 背景：`genkit_openai 0.3.7` 的流式只把 `chunk.textDelta` 放进 chunk
/// （见其 `_handleStreaming`），`reasoning_content` 不会出现在任何 chunk 里；
/// 但底层 `openai_dart` 的累积器会把 `reasoning_content` / `reasoning`
/// 合并进最终 `ChatCompletion.choices[0].message`，而该对象以
/// `ModelResponse.raw` 的形式透传回来。因此这里做一次"事后补取"。
///
/// 兼容两种字段名：
/// - `reasoning_content`：DeepSeek-R1 系、多数国产兼容实现
/// - `reasoning`：OpenRouter 等聚合网关
String reasoningFromOpenAiRaw(Object? raw) {
  if (raw is! Map) return '';
  final choices = raw['choices'];
  if (choices is! List || choices.isEmpty) return '';
  final first = choices.first;
  if (first is! Map) return '';
  final message = first['message'];
  if (message is! Map) return '';
  final value = message['reasoning_content'] ?? message['reasoning'];
  return value is String ? value : '';
}


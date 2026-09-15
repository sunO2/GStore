/// 自建 OpenAI 兼容 model provider —— 让「思考过程」**流式**下发
///
/// ## 为什么需要它
///
/// `genkit_openai 0.3.7` 的 `_handleStreaming` 只做了一件事：
/// ```dart
/// final textDelta = chunk.textDelta;              // = choices[0].delta.content
/// if (textDelta != null) ctx.sendChunk(... TextPart(text: textDelta) ...);
/// ```
/// 而 `openai_dart` 的 `ChatCompletionChunk.firstChoice.delta` 上其实**逐片带着**
/// `reasoningContent`（DeepSeek-R1 系）与 `reasoning`（OpenRouter 等），
/// 插件没有转发 → 应用侧只能等生成结束、从最终响应 `raw` 里"事后补取"，
/// 表现为思考内容是**整段出现**而不是流式。
///
/// ## 做法
///
/// 用 `Genkit.defineModel` 自建一个模型，复用官方插件**已导出**的
/// `GenkitConverter`（消息/工具/回包的转换完全一致），只在流式循环里
/// 额外把 reasoning delta 作为 `ReasoningPart` 发出去。
/// 工具调用协议不受影响：请求侧 `toOpenAIMessages` / `toOpenAITool`，
/// 回包侧 `fromOpenAIAssistantMessage`（含 ToolRequestPart）都走同一套转换。
library;

import 'package:genkit/genkit.dart';
import 'package:genkit_openai/genkit_openai.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:openai_dart/openai_dart.dart' as sdk;

/// 注册名命名空间（与官方插件的 `openai` / `custom` 区分开）
const String kOpenAiReasoningNamespace = 'openai_reasoning';

/// 把一次 OpenAI 流式 delta 映射为 genkit 的 chunk 内容（纯函数，便于单测）
///
/// - `reasoningContent` / `reasoning` → [ReasoningPart]（思考过程）
/// - `content` → [TextPart]（正文）
///
/// 返回 null 表示该 delta 无可用内容（例如首包只有 role）。
List<Part>? openAiDeltaToParts({
  String? content,
  String? reasoningContent,
  String? reasoning,
}) {
  final parts = <Part>[];
  // 兼容两类字段名：DeepSeek 系用 reasoningContent，OpenRouter 等用 reasoning
  final think = (reasoningContent != null && reasoningContent.isNotEmpty)
      ? reasoningContent
      : ((reasoning != null && reasoning.isNotEmpty) ? reasoning : null);
  if (think != null) parts.add(ReasoningPart(reasoning: think));
  if (content != null && content.isNotEmpty) {
    parts.add(TextPart(text: content));
  }
  return parts.isEmpty ? null : parts;
}

/// 定义「思考过程可流式」的 OpenAI 兼容模型
///
/// 返回的 [Model] 本身即 [ModelRef]，可直接作为 `generateStream(model:)` 的入参。
/// [modelId] 是真正写进请求体的模型名（如 `deepseek-reasoner`）。
Model defineReasoningAwareOpenAIModel(
  Genkit ai, {
  required String modelId,
  required String apiKey,
  required String baseUrl,
}) {
  final client = sdk.OpenAIClient.withApiKey(
    apiKey,
    baseUrl: baseUrl.isEmpty ? null : baseUrl,
  );

  sdk.ChatCompletionCreateRequest buildRequest(ModelRequest request) {
    final supports = supportsTools(modelId);
    return sdk.ChatCompletionCreateRequest(
      model: modelId,
      // 第二个位置参数是图片细节级别（本应用不传，保持默认）
      messages: GenkitConverter.toOpenAIMessages(request.messages, null),
      tools: supports
          ? request.tools?.map(GenkitConverter.toOpenAITool).toList()
          : null,
    );
  }

  return ai.defineModel(
    name: '$kOpenAiReasoningNamespace/$modelId',
    fn: (request, ctx) async {
      try {
        // 非流式调用（本应用只用 generateStream，此处仅作兜底）
        if (!ctx.streamingRequested) {
          final res = await client.chat.completions.create(buildRequest(request));
          final choice = res.choices.first;
          return ModelResponse(
            finishReason:
                GenkitConverter.mapFinishReason(choice.finishReason?.name),
            message: GenkitConverter.fromOpenAIAssistantMessage(choice.message),
            raw: res.toJson(),
          );
        }

        final accumulator = sdk.ChatStreamAccumulator();
        // AIAgentResponse 日志：证明"思考分片是否真的从模型层发出"——
        // 若这里 reasoningChunks==0，说明端点本次没返回思维链（不是解析问题）。
        var reasoningChunks = 0;
        var textChunks = 0;
        await for (final chunk
            in client.chat.completions.createStream(buildRequest(request))) {
          accumulator.add(chunk);
          final delta = chunk.firstChoice?.delta;
          final rc = delta?.reasoningContent;
          final reasoning = (rc != null && rc.isNotEmpty) ? rc : delta?.reasoning;
          if (reasoning != null && reasoning.isNotEmpty) {
            reasoningChunks++;
            if (reasoningChunks == 1) {
              appLog.info('[AIAgentResponse] ◆ 模型层发出思考分片',
                  data: {'model': modelId, 'head': reasoning});
            }
          }
          final parts = openAiDeltaToParts(
            content: chunk.textDelta,
            reasoningContent: delta?.reasoningContent,
            reasoning: delta?.reasoning,
          );
          if (parts != null) {
            final t = chunk.textDelta;
            if (t != null && t.isNotEmpty) textChunks++;
            ctx.sendChunk(ModelResponseChunk(index: 0, content: parts));
          }
        }

        final completion = accumulator.toChatCompletion();
        appLog.info('[AIAgentResponse] ◆ 模型层流式汇总', data: {
          'model': modelId,
          'reasoningChunks': reasoningChunks,
          'textChunks': textChunks,
          'finalReasoningLen':
              completion.choices.first.message.reasoningContent?.length ?? 0,
        });
        final choice = completion.choices.first;
        return ModelResponse(
          finishReason:
              GenkitConverter.mapFinishReason(choice.finishReason?.name),
          message: GenkitConverter.fromOpenAIAssistantMessage(choice.message),
          raw: completion.toJson(),
        );
      } catch (e, stackTrace) {
        if (e is GenkitException) rethrow;
        throw GenkitException(
          'OpenAI 兼容模型（含 reasoning 流式）调用失败: $e',
          underlyingException: e,
          stackTrace: stackTrace,
        );
      }
    },
  );
}

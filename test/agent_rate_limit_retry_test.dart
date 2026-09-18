import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:genkit/genkit.dart';
import 'package:gstore/core/agent/openai_reasoning_model.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openai_dart/openai_dart.dart' as sdk;

void main() {
  group('withRateLimitRetry', () {
    test('遇 RateLimitException 重试成功后返回结果', () async {
      var calls = 0;
      Future<String> fn() async {
        calls++;
        if (calls == 1) {
          throw const sdk.RateLimitException(message: 'rate limited');
        }
        return 'ok';
      }

      final result = await withRateLimitRetry(fn);

      expect(result, 'ok');
      expect(calls, 2);
    });

    test('超过 maxRetries 仍抛 429 时 rethrow 原始异常', () async {
      var calls = 0;
      Future<String> fn() async {
        calls++;
        throw const sdk.RateLimitException(message: 'rate limited');
      }

      await expectLater(
        withRateLimitRetry(fn, maxRetries: 1),
        throwsA(
          isA<sdk.RateLimitException>()
              .having((e) => e.statusCode, 'statusCode', 429),
        ),
      );
      expect(calls, 2); // 初始 1 次 + maxRetries(1) 次重试
    });

    test('非 429 异常不重试，直接抛出', () async {
      var calls = 0;
      Future<String> fn() async {
        calls++;
        throw Exception('boom');
      }

      await expectLater(
        withRateLimitRetry(fn),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message',
            contains('boom'))),
      );
      expect(calls, 1);
    });

    test('尊重服务端 retryAfter 延时后重试', () async {
      var calls = 0;
      Future<String> fn() async {
        calls++;
        if (calls == 1) {
          throw const sdk.RateLimitException(
            message: 'rate limited',
            retryAfter: Duration(milliseconds: 1),
          );
        }
        return 'ok';
      }

      final sw = Stopwatch()..start();
      final result = await withRateLimitRetry(fn, maxRetries: 1);
      sw.stop();

      expect(result, 'ok');
      expect(calls, 2);
      // 验证确实走过了重试延时逻辑（而非立刻返回）：至少等待了 1ms
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(1));
    });

    test('withRateLimitRetry 能捕获 lazy Stream 消费阶段抛出的 429（流式路径回归）',
        () async {
      var calls = 0;
      // 模拟 createStream：返回 lazy 生成器，第一次 listen 时抛 429，第二次 yield 数据
      Stream<int> lazyStream() async* {
        calls++;
        if (calls == 1) {
          throw const sdk.RateLimitException(
              message: 'rate limited', retryAfter: Duration(milliseconds: 1));
        }
        yield 42;
      }

      final result = await withRateLimitRetry(() async {
        final collected = <int>[];
        await for (final v in lazyStream()) {
          collected.add(v);
        }
        return collected;
      });

      expect(calls, 2, reason: 'lazy 流第一次抛 429 后应重试（重新建立流）');
      expect(result, [42]);
    });
  });

  group('defineReasoningAwareOpenAIModel 生产路径', () {
    test('真实 SDK 流式调用首次返回 429，重试后收到文本（MockClient 驱动）', () async {
      // 计数闭包：记录 openai_dart 经 httpClient.send 发起的真实请求次数
      final requests = <http.Request>[];
      final mockClient = MockClient((request) async {
        requests.add(request);
        // 第一次：HTTP 429（JSON error body）——由 parseStreamError 转成
        // sdk.RateLimitException（注意其 retryAfter 为 null，正是生产路径行为）
        if (requests.length == 1) {
          return http.Response(
            jsonEncode({
              'error': {
                'message': 'rate limited',
                'type': 'rate_limit_error',
              },
            }),
            429,
            headers: {'content-type': 'application/json'},
          );
        }
        // 第二次：200 + SSE 流，返回一个含 "hi" 的 chat.completion.chunk
        const sse = 'data: {"id":"x","object":"chat.completion.chunk",'
            '"created":1,"model":"test-model","choices":[{"index":0,'
            '"delta":{"content":"hi"},"finish_reason":null}]}\n\n'
            'data: [DONE]\n\n';
        return http.Response(
          sse,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });

      final ai = Genkit(isDevEnv: false, promptDir: null);
      // 走生产入口：defineReasoningAwareOpenAIModel 内部使用传入的 httpClient
      final model = defineReasoningAwareOpenAIModel(
        ai,
        modelId: 'test-model',
        apiKey: 'k',
        baseUrl: 'https://example.com/v1',
        httpClient: mockClient,
      );

      final text = StringBuffer();
      final chunks = <String>[];
      await for (final chunk in ai.generateStream<dynamic, void>(
        model: model,
        messages: [
          Message(role: Role.user, content: [TextPart(text: 'hi')]),
        ],
      )) {
        if (chunk.text.isNotEmpty) {
          chunks.add(chunk.text);
          text.write(chunk.text);
        }
      }

      // mock 被调用 2 次 = 首次 429 + 重试一次，证明 429 确实驱动了重试
      expect(requests.length, 2,
          reason: '首次 429 应驱动一次重试（真实 SDK 请求 mock 被调用 2 次）');
      expect(text.toString(), contains('hi'));
      expect(chunks, isNotEmpty);
      await ai.shutdown();
    });
  });
}

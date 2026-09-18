import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/agent/openai_model_catalog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 构造一个 /models 正常响应
http.Response _okResponse(List<Map<String, dynamic>> data) {
  return http.Response(
    jsonEncode({'object': 'list', 'data': data}),
    200,
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  group('fetchOpenAiModelIds', () {
    test('请求 {baseUrl}/models 且带 Bearer 鉴权；返回去重 + 空白剔除 + 升序', () async {
      late http.Request captured;
      final mock = MockClient((request) async {
        captured = request;
        return _okResponse([
          {'id': 'gpt-4o-mini', 'object': 'model'},
          {'id': 'gpt-4o', 'object': 'model'},
          {'id': 'gpt-4o', 'object': 'model'}, // 重复 → 去重
          {'id': '   ', 'object': 'model'}, // 空白 → 剔除
        ]);
      });

      final ids = await fetchOpenAiModelIds(
        baseUrl: 'https://proxy.example.com/v1',
        apiKey: 'sk-test',
        httpClient: mock,
      );

      expect(captured.method, 'GET');
      expect(
        captured.url.toString(),
        'https://proxy.example.com/v1/models',
        reason: '必须走与聊天请求同一套 baseUrl 拼接',
      );
      expect(captured.headers['Authorization'], 'Bearer sk-test');
      expect(ids, ['gpt-4o', 'gpt-4o-mini']);
    });

    test('baseUrl 为空 → 回退到 openai_dart 默认地址（与默认 Base URL 一致）', () async {
      late Uri captured;
      final mock = MockClient((request) async {
        captured = request.url;
        return _okResponse([
          {'id': 'gpt-4o', 'object': 'model'},
        ]);
      });

      await fetchOpenAiModelIds(
        baseUrl: '',
        apiKey: 'sk-test',
        httpClient: mock,
      );

      expect(captured.toString(), 'https://api.openai.com/v1/models');
    });

    test('baseUrl 带尾斜杠 → 不产生双斜杠', () async {
      late Uri captured;
      final mock = MockClient((request) async {
        captured = request.url;
        return _okResponse(const []);
      });

      await fetchOpenAiModelIds(
        baseUrl: 'https://proxy.example.com/v1/',
        apiKey: 'sk-test',
        httpClient: mock,
      );

      expect(captured.toString(), 'https://proxy.example.com/v1/models');
    });

    test('401 → 抛异常（不吞掉，交给调用方提示）', () async {
      final mock = MockClient((request) async => http.Response(
            jsonEncode({
              'error': {'message': 'Invalid API key'},
            }),
            401,
            headers: {'content-type': 'application/json'},
          ));

      expect(
        () => fetchOpenAiModelIds(
          baseUrl: 'https://proxy.example.com/v1',
          apiKey: 'bad',
          httpClient: mock,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('响应缺 data 字段 → 抛错（不静默返回空列表）', () async {
      final mock = MockClient((request) async => http.Response(
            jsonEncode({'object': 'list'}),
            200,
            headers: {'content-type': 'application/json'},
          ));

      // SDK 内部对畸形结构抛的是 TypeError（Error 而非 Exception），
      // 这里只要求"不吞掉"——调用方的 try/catch 会照常提示失败。
      expect(
        () => fetchOpenAiModelIds(
          baseUrl: 'https://proxy.example.com/v1',
          apiKey: 'sk-test',
          httpClient: mock,
        ),
        throwsA(anything),
      );
    });
  });
}

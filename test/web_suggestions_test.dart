import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/web_suggestions.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('解析必应搜索建议', () async {
    final client = MockClient((request) async {
      expect(request.url.host, 'api.bing.com');
      expect(request.url.queryParameters['q'], 'termux');
      return http.Response(
        jsonEncode({
          'AS': {
            'Query': 'termux',
            'Results': [
              {
                'Suggests': [
                  {'Txt': 'termux'},
                  {'Txt': 'termux apk'},
                  {'Txt': 'termux'},
                ],
              },
            ],
          },
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });

    expect(
      await fetchBingSuggestions('termux', httpClient: client),
      ['termux', 'termux apk'],
    );
  });

  test('非 200 或异常时返回空列表', () async {
    final failing = MockClient((_) async => http.Response('', 500));
    expect(await fetchBingSuggestions('x', httpClient: failing), isEmpty);

    final throwing = MockClient((_) async => throw Exception('network'));
    expect(await fetchBingSuggestions('x', httpClient: throwing), isEmpty);
  });

  test('空输入不发起请求', () async {
    var called = false;
    final client = MockClient((_) async {
      called = true;
      return http.Response('{}', 200);
    });
    expect(await fetchBingSuggestions('   ', httpClient: client), isEmpty);
    expect(called, isFalse);
  });
}

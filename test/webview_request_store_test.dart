import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/webview/webview_models.dart';
import 'package:gstore/core/webview/webview_request_store.dart';

void main() {
  test('shouldInterceptRequest 元数据会被 XHR/fetch 详情合并', () {
    final store = WebViewRequestStore();
    store.begin(
      url: 'https://api.example.com/search',
      method: 'POST',
      headers: {'content-type': 'application/json'},
    );

    store.complete(
      source: WebViewRequestSource.fetch,
      url: 'https://api.example.com/search',
      method: 'POST',
      requestHeaders: {'content-type': 'application/json'},
      requestBody: '{"q":"termux"}',
      status: 200,
      responseHeaders: {'content-type': 'application/json'},
      responseBody: '{"items":[1,2]}',
      durationMs: 86,
    );

    expect(store.length, 1, reason: 'placeholder must be upgraded, not duplicated');
    final record = store.records.single;
    expect(record.source, WebViewRequestSource.fetch);
    expect(record.status, 200);
    expect(record.durationMs, 86);
    expect(record.requestBody, contains('termux'));
    expect(record.responseBody, contains('items'));
  });

  test('敏感请求头脱敏，body 超长截断', () {
    final store = WebViewRequestStore();
    store.begin(
      url: 'https://example.com/api',
      method: 'GET',
      headers: {
        'Authorization': 'Bearer secret-token',
        'Cookie': 'sid=secret',
        'Accept': 'application/json',
      },
    );
    store.complete(
      source: WebViewRequestSource.fetch,
      url: 'https://example.com/api',
      method: 'GET',
      status: 200,
      responseHeaders: {'set-cookie': 'sid=secret'},
      responseBody: 'x' * (WebViewRequestStore.maxBodyChars + 10),
    );

    final record = store.records.single;
    expect(record.requestHeaders['Authorization'], 'Bearer ***');
    expect(record.requestHeaders['Cookie'], '***');
    expect(record.requestHeaders['Accept'], 'application/json');
    expect(record.responseHeaders['set-cookie'], '***');
    expect(record.responseBody, contains('<截断>'));
    expect(record.responseBody!.length,
        lessThan(WebViewRequestStore.maxBodyChars + 20));
  });

  test('filter/method/limit/includeBodies 影响输出', () {
    final store = WebViewRequestStore();
    for (var i = 0; i < 3; i++) {
      store.begin(url: 'https://example.com/api/$i', method: 'GET');
      store.complete(
        source: WebViewRequestSource.fetch,
        url: 'https://example.com/api/$i',
        method: 'GET',
        status: 200,
        responseBody: 'body-$i',
      );
    }
    store.begin(url: 'https://cdn.example.com/a.png', method: 'GET');

    final all = store.format(limit: 10);
    expect(all, contains('api/2'));
    expect(all, contains('a.png'));

    final filtered = store.format(filter: '/api/', limit: 10);
    expect(filtered, contains('api/2'));
    expect(filtered, isNot(contains('a.png')));

    final latest = store.format(limit: 1);
    expect(latest, contains('共 4 条，显示最近 1 条'));

    final noBodies = store.format(includeBodies: false, limit: 10);
    expect(noBodies, isNot(contains('res body:')));
  });

  test('HAR 导出包含请求与响应条目', () {
    final store = WebViewRequestStore();
    store.begin(
      url: 'https://api.example.com/search',
      method: 'POST',
      headers: {'content-type': 'application/json'},
    );
    store.complete(
      source: WebViewRequestSource.fetch,
      url: 'https://api.example.com/search',
      method: 'POST',
      requestBody: '{"q":"termux"}',
      status: 200,
      responseHeaders: {'content-type': 'application/json'},
      responseBody: '{"items":[]}',
      durationMs: 42,
    );

    final har = jsonDecode(store.toHar()) as Map<String, dynamic>;
    final entries = (har['log'] as Map)['entries'] as List;
    expect(entries, hasLength(1));
    final entry = entries.single as Map;
    expect((entry['request'] as Map)['method'], 'POST');
    expect((entry['request'] as Map)['url'], contains('/search'));
    expect((entry['response'] as Map)['status'], 200);
    expect((entry['response'] as Map)['content']['text'], contains('items'));
    expect(entry['time'], 42);
  });

  test('超过上限时淘汰最旧记录', () {
    final store = WebViewRequestStore();
    for (var i = 0; i < WebViewRequestStore.maxRecords + 5; i++) {
      store.begin(url: 'https://example.com/$i', method: 'GET');
    }
    expect(store.length, WebViewRequestStore.maxRecords);
    expect(store.records.first.url, 'https://example.com/5');
  });
}

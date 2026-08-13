import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:gstore/core/image/app_image_loader.dart';
import 'package:gstore/core/image/image_type_detector.dart';

void main() {
  final loader = AppImageLoader.instance;

  setUp(() {
    loader.clearCache();
  });

  /// 记录请求次数并按 [handler] 返回响应的 MockClient。
  http.Client countingClient(
    int Function() onRequest,
    Future<http.Response> Function(http.Request) handler,
  ) {
    return MockClient((request) {
      onRequest();
      return handler(request);
    });
  }

  final pngBytes = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0],
  );
  final svgBytes = Uint8List.fromList(
    utf8.encode('<svg xmlns="http://www.w3.org/2000/svg"></svg>'),
  );

  test('首次 load 下载并缓存；二次 load 同 URL 命中缓存（requestCount == 1）', () async {
    var requestCount = 0;
    loader.debugClient = countingClient(
      () => requestCount++,
      (_) async => http.Response.bytes(pngBytes, 200),
    );

    final first = await loader.load('https://example.com/a.png');
    expect(first.bytes, pngBytes);
    expect(first.format, ImageFormat.png);
    expect(requestCount, 1);

    final second = await loader.load('https://example.com/a.png');
    expect(second.bytes, pngBytes);
    expect(requestCount, 1, reason: '二次 load 应命中缓存，不重复下载');
  });

  test('下载 bytes 应用了判型（svg 文本 bytes → format == svg）', () async {
    loader.debugClient = countingClient(
      () => 0,
      (_) async => http.Response.bytes(svgBytes, 200),
    );

    final result = await loader.load('https://example.com/icon.svg');
    expect(result.format, ImageFormat.svg);
  });

  test('clearCache 后再次 load → 重新下载（requestCount == 2）', () async {
    var requestCount = 0;
    loader.debugClient = countingClient(
      () => requestCount++,
      (_) async => http.Response.bytes(pngBytes, 200),
    );

    await loader.load('https://example.com/a.png');
    expect(requestCount, 1);

    loader.clearCache();

    await loader.load('https://example.com/a.png');
    expect(requestCount, 2);
  });

  test('下载失败（404）→ load 抛异常传播', () async {
    loader.debugClient = countingClient(
      () => 0,
      (_) async => http.Response('not found', 404),
    );

    expect(
      () => loader.load('https://example.com/missing.png'),
      throwsA(isA<http.ClientException>()),
    );
  });

  test('下载失败（ClientException）→ load 抛异常传播', () async {
    loader.debugClient = countingClient(
      () => 0,
      (_) async => throw http.ClientException('network down'),
    );

    expect(
      () => loader.load('https://example.com/broken.png'),
      throwsA(isA<http.ClientException>()),
    );
  });

  test('不同 URL 分别下载（requestCount == 2）', () async {
    var requestCount = 0;
    loader.debugClient = countingClient(
      () => requestCount++,
      (_) async => http.Response.bytes(pngBytes, 200),
    );

    await loader.load('https://example.com/a.png');
    await loader.load('https://example.com/b.png');
    expect(requestCount, 2);
  });
}

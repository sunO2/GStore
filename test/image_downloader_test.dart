import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:gstore/core/image/image_downloader.dart';

void main() {
  const testUrl = 'https://example.com/icon.png';

  group('ImageDownloader.fetchBytes', () {
    test('200 + 字节 -> 返回 bodyBytes', () async {
      final bytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03]);
      ImageDownloader.instance.debugClient = MockClient((request) async {
        return http.Response.bytes(bytes, 200);
      });

      final result = await ImageDownloader.instance.fetchBytes(testUrl);

      expect(result, equals(bytes));
    });

    test('请求 URL 正确 且 请求头含 User-Agent == browserUserAgent', () async {
      late Uri capturedUrl;
      late String? capturedUserAgent;
      ImageDownloader.instance.debugClient = MockClient((request) async {
        capturedUrl = request.url;
        capturedUserAgent = request.headers['User-Agent'];
        return http.Response.bytes(
          Uint8List.fromList([0x01, 0x02]),
          200,
        );
      });

      await ImageDownloader.instance.fetchBytes(testUrl);

      expect(capturedUrl, equals(Uri.parse(testUrl)));
      expect(capturedUserAgent, equals(ImageDownloader.browserUserAgent));
    });

    test('404 -> 抛异常（含状态码信息）', () async {
      ImageDownloader.instance.debugClient = MockClient((request) async {
        return http.Response('Not Found', 404);
      });

      expect(
        () => ImageDownloader.instance.fetchBytes(testUrl),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'toString',
            contains('404'),
          ),
        ),
      );
    });

    test('200 + 空 body -> 抛异常', () async {
      ImageDownloader.instance.debugClient = MockClient((request) async {
        return http.Response('', 200);
      });

      expect(
        () => ImageDownloader.instance.fetchBytes(testUrl),
        throwsA(isA<Exception>()),
      );
    });

    test('MockClient 抛 ClientException -> 异常传播', () async {
      ImageDownloader.instance.debugClient = MockClient((request) async {
        throw http.ClientException('connection refused');
      });

      expect(
        () => ImageDownloader.instance.fetchBytes(testUrl),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('connection refused'),
          ),
        ),
      );
    });
  });
}

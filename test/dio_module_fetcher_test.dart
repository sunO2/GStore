import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/DioModuleFetcher.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.payload, {this.statusCode = 200});

  final List<int> payload;
  final int statusCode;
  final List<Uri> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    if (statusCode < 200 || statusCode >= 300) {
      return ResponseBody.fromString('', statusCode);
    }
    return ResponseBody.fromBytes(payload, statusCode);
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(HttpClientAdapter adapter) => Dio()..httpClientAdapter = adapter;

void main() {
  test('代理仅在原始 host 通过校验后施加，并返回字节', () async {
    final adapter = _FakeAdapter(<int>[1, 2, 3, 4]);
    final fetcher = DioModuleFetcher(
      dio: _dioWith(adapter),
      allowedHosts: {'github.com'},
      proxyProvider: () => 'https://gh-proxy.org/',
      maxAttempts: 1,
    );

    final bytes = await fetcher.fetch(
      'https://github.com/sunO2/GStore/releases/download/v1/a.so',
    );

    expect(bytes, <int>[1, 2, 3, 4]);
    expect(
      adapter.requested.single.toString(),
      'https://gh-proxy.org/https://github.com/sunO2/GStore/releases/'
      'download/v1/a.so',
    );
  });

  test('空代理直连已校验的原始 URL', () async {
    final adapter = _FakeAdapter(<int>[5]);
    final fetcher = DioModuleFetcher(
      dio: _dioWith(adapter),
      allowedHosts: {'github.com'},
      proxyProvider: () => '',
      maxAttempts: 1,
    );

    final bytes = await fetcher.fetch('https://github.com/a.so');

    expect(bytes, <int>[5]);
    expect(adapter.requested.single.toString(), 'https://github.com/a.so');
  });

  test('非白名单 host 被拒且不产生请求', () async {
    final adapter = _FakeAdapter(<int>[9]);
    final fetcher = DioModuleFetcher(
      dio: _dioWith(adapter),
      allowedHosts: {'github.com'},
      proxyProvider: () => 'https://gh-proxy.org/',
      maxAttempts: 1,
    );

    expect(await fetcher.fetch('https://evil.com/a.so'), isNull);
    expect(adapter.requested, isEmpty);
  });

  test('超出 maxBytes 返回 null', () async {
    final adapter = _FakeAdapter(List<int>.filled(100, 7));
    final fetcher = DioModuleFetcher(
      dio: _dioWith(adapter),
      allowedHosts: {'github.com'},
      proxyProvider: () => '',
      maxAttempts: 1,
    );

    expect(await fetcher.fetch('https://github.com/a.so', maxBytes: 10), isNull);
  });
}

// `DioModuleFetcher` 字节进度上报测试（无真实网络：注入流式 HttpClientAdapter）。
//
// 证明 `fetchWithProgress` 会经 Dio 的 `onReceiveProgress` 在上传/接收过程中按
// 收到的字节数多次回调；`total < 0`（未知/压缩）被映射为 `null`；`fetch` 委托给
// `fetchWithProgress`（无回调时仍正常下载）。
//
// ignore_for_file: file_names

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/DioModuleFetcher.dart';

/// 逐块流式返回响应体的假适配器；`contentLength` 写入 `content-length` 头
/// （省略 → Dio 视为 -1），用于驱动/验证 Dio 的接收进度回调。
class _StreamingAdapter implements HttpClientAdapter {
  _StreamingAdapter(this.chunks, {this.contentLength});

  final List<List<int>> chunks;
  final int? contentLength;
  final List<Uri> requested = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri);
    final stream = Stream<Uint8List>.fromIterable(
      chunks.map((List<int> c) => Uint8List.fromList(c)),
    );
    return ResponseBody(
      stream,
      200,
      headers: contentLength == null
          ? const <String, List<String>>{}
          : <String, List<String>>{
              'content-length': <String>['$contentLength'],
            },
    );
  }

  @override
  void close({bool force = false}) {}
}

DioModuleFetcher _fetcher(HttpClientAdapter adapter) => DioModuleFetcher(
      dio: Dio()..httpClientAdapter = adapter,
      allowedHosts: const <String>{'github.com'},
      proxyProvider: () => '',
      maxAttempts: 1,
    );

/// 4 块 × 30 字节 = 120 字节。
List<List<int>> _chunks() => <List<int>>[
      List<int>.generate(30, (i) => i),
      List<int>.generate(30, (i) => i + 30),
      List<int>.generate(30, (i) => i + 60),
      List<int>.generate(30, (i) => i + 90),
    ];

void main() {
  test('fetchWithProgress：按字节多次递增回调，total 为已知总长', () async {
    final adapter = _StreamingAdapter(_chunks(), contentLength: 120);
    final received = <int>[];
    final totals = <int?>[];

    final bytes = await _fetcher(adapter).fetchWithProgress(
      'https://github.com/a.so',
      onProgress: (r, t) {
        received.add(r);
        totals.add(t);
      },
    );

    expect(bytes, isNotNull);
    expect(bytes!.length, 120);
    expect(received.length, greaterThanOrEqualTo(2),
        reason: '流式响应应产生多次进度回调，而非仅有起止两点');
    for (var i = 1; i < received.length; i++) {
      expect(received[i], greaterThan(received[i - 1]),
          reason: 'received 必须单调递增');
    }
    expect(received.last, 120);
    expect(totals.every((t) => t == 120), isTrue,
        reason: '下载层已知总长应原样透传');
  });

  test('fetchWithProgress：无 content-length（total=-1）映射为 null', () async {
    final adapter = _StreamingAdapter(_chunks());
    final totals = <int?>[];

    final bytes = await _fetcher(adapter)
        .fetchWithProgress('https://github.com/a.so', onProgress: (_, t) {
      totals.add(t);
    });

    expect(bytes!.length, 120);
    expect(totals, isNotEmpty);
    expect(totals.every((t) => t == null), isTrue,
        reason: 'total < 0 视为未知，必须回传 null 而非负数');
  });

  test('fetchWithProgress：content-length 显式 -1 也映射为 null', () async {
    final adapter = _StreamingAdapter(_chunks(), contentLength: -1);
    final totals = <int?>[];

    await _fetcher(adapter)
        .fetchWithProgress('https://github.com/a.so', onProgress: (_, t) {
      totals.add(t);
    });

    expect(totals, isNotEmpty);
    expect(totals.every((t) => t == null), isTrue);
  });

  test('fetch() 委托 fetchWithProgress：无回调仍返回完整字节', () async {
    final adapter = _StreamingAdapter(_chunks(), contentLength: 120);
    final bytes = await _fetcher(adapter).fetch('https://github.com/a.so');

    expect(bytes, isNotNull);
    expect(bytes!.length, 120);
    expect(adapter.requested.single.toString(), 'https://github.com/a.so');
  });
}

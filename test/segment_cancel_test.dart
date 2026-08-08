import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/DownloadContext.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/download/segment/segment_downloader.dart';
import 'package:gstore/core/download/segment/segment_planner.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

/// 本地测试服务器：支持 Range 请求，返回 1MB 的数据
class _TestServer {
  final HttpServer server;
  final int totalBytes = 1024 * 1024; // 1MB
  int segmentRequests = 0;

  _TestServer._(this.server);

  static Future<_TestServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ts = _TestServer._(server);
    server.listen((request) async {
      ts.segmentRequests++;
      final range = request.headers.value('range');
      if (range != null && range.startsWith('bytes=')) {
        // 返回 206
        final parts = range.substring(6).split('-');
        final start = int.parse(parts[0]);
        final end = parts[1].isEmpty
            ? ts.totalBytes - 1
            : int.parse(parts[1]);
        final chunkSize = end - start + 1;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('Content-Range',
            'bytes $start-$end/${ts.totalBytes}');
        request.response.contentLength = chunkSize;
        // 写入数据（分块，模拟真实下载，慢速便于测试取消）
        var sent = 0;
        const blockSize = 8 * 1024;
        while (sent < chunkSize) {
          final n = (chunkSize - sent).clamp(0, blockSize);
          request.response.add(List<int>.filled(n, 0x41));
          sent += n;
          await Future.delayed(const Duration(milliseconds: 20));
        }
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.contentLength = ts.totalBytes;
        request.response.add(List<int>.filled(ts.totalBytes, 0x41));
        await request.response.close();
      }
    });
    return ts;
  }

  String get url =>
      'http://${server.address.address}:${server.port}/file.bin';

  Future<void> close() => server.close(force: true);
}

void main() {
  group('SegmentDownloader 取消/暂停', () {
    late _TestServer testServer;
    late Dio dio;
    late DownloadStatus status;

    setUp(() async {
      testServer = await _TestServer.start();
      dio = Dio();
      status = DownloadStatus(
        'test.app',
        'TestApp',
        '1.0.0',
        'file.bin',
        testServer.url,
        '${Directory.systemTemp.createTempSync('gstore_test_').path}/file.bin',
        total: testServer.totalBytes,
      );
    });

    tearDown(() async {
      await testServer.close();
    });

    test('暂停后取消所有段 token，返回 cancelled', () async {
      final plan = SegmentPlan(
        totalBytes: testServer.totalBytes,
        supportsRange: true,
        segments: SegmentPlanner.divideSegments(testServer.totalBytes, 4),
      );

      // 启动下载
      final downloader = SegmentDownloader(dio, maxConcurrency: 4);
      final resultFuture = downloader.downloadSegments(
        plan: plan,
        status: status,
      );

      // 等待一段时间让下载进行（慢速服务器，确保未完成）
      await Future.delayed(const Duration(milliseconds: 100));

      // 模拟暂停：取消所有段 token
      status.cancelDownload();

      final result = await resultFuture.timeout(const Duration(seconds: 10));

      expect(result.cancelled, true, reason: '暂停后应返回 cancelled 状态');
      expect(result.success, false);
    });
  });
}

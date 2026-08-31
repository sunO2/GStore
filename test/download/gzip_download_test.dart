import 'dart:io';

// crypto 为 flutter_test 传递依赖（未列入 pubspec.dev_dependencies），
// 仅用于测试期做 sha256 校验，避免额外依赖。
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart' show sha256;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/dio_download_engine.dart';
import 'package:gstore/core/download/core/download_engine.dart';
import 'package:gstore/core/download/core/download_event.dart';
import 'package:gstore/core/download/core/download_request.dart';

/// 本地测试服务器：对 `/a.apk` 返回 gzip 压缩体。
///
/// 采用与生产 `RhttpAdapter` 相同的“已解码”契约：响应体是 gzip 字节流、
/// 头部带 `Content-Encoding: gzip`，同时附带 `x-gstore-decoded-encoding: gzip`
/// 标记（该标记正是引擎判断 `probe.isCompressed` 的唯一依据，见
/// dio_download_engine.dart:90）。底层 `Dart:io HttpClient`（IOHttpClientAdapter
/// 默认 autoUncompress=true）会把 gzip 流透明解压，因此引擎收到的是解压后的字节。
class _GzipServer {
  final HttpServer server;
  final List<int> payload;

  _GzipServer._(this.server, this.payload);

  static Future<_GzipServer> start() async {
    // 伪 ZIP 文件头（0x50 0x4b ...）+ 大段可压缩正文：
    // 保证解压后的长度(≈256KB) 远大于 gzip 压缩体，无论 dart 是否剥离
    // content-length，都不会触发引擎的 `incomplete` 误判。
    final payload = <int>[
      0x50, 0x4b, 0x03, 0x04, // fake ZIP local file header magic
      0x41,
      ...List<int>.filled(256 * 1024, 0x42),
    ];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ts = _GzipServer._(server, payload);
    final wire = gzip.encode(payload);
    server.listen((request) async {
      // 忽略 Range（probe 也会带 Range: bytes=0-0），一律返回 200 + 完整 gzip 体。
      request.response.headers.set('content-encoding', 'gzip');
      request.response.headers.set('x-gstore-decoded-encoding', 'gzip');
      request.response.contentLength = wire.length;
      request.response.add(wire);
      await request.response.close();
    });
    return ts;
  }

  String get url => 'http://${server.address.address}:${server.port}/a.apk';

  Future<void> close() => server.close(force: true);
}

Future<List<DownloadEvent>> _collect(
  DownloadEngine engine,
  DownloadRequest request,
) async {
  final events = <DownloadEvent>[];
  await for (final e in engine.execute(request)) {
    events.add(e);
  }
  return events;
}

void main() {
  group('DioDownloadEngine 压缩响应（Content-Encoding: gzip）', () {
    late _GzipServer testServer;
    late Directory tmpDir;
    late String savePath;

    setUp(() async {
      testServer = await _GzipServer.start();
      tmpDir = Directory.systemTemp.createTempSync('gstore_gzip_test_');
      savePath = '${tmpDir.path}/a.apk';
    });

    tearDown(() async {
      await testServer.close();
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('gzip 响应：落盘字节为解压后的原始内容（PK 魔数 + sha256）', () async {
      final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
      final engine = DioDownloadEngine(dio: dio);

      final events = await _collect(
        engine,
        DownloadRequest(url: testServer.url, savePath: savePath, resume: false),
      );

      expect(events.whereType<DownloadFailed>(), isEmpty,
          reason: 'gzip 流下载不应失败，实际事件: ${events.map((e) => e.runtimeType)}');
      expect(events.whereType<DownloadCompleted>(), hasLength(1));

      final file = File(savePath);
      expect(await file.exists(), isTrue, reason: '下载完成后文件应存在');
      final bytes = await file.readAsBytes();
      expect(bytes.length, greaterThan(0));
      expect(bytes.sublist(0, 2), [0x50, 0x4b],
          reason: '落盘内容必须是解压后的原始字节（ZIP 魔数在前），而不是 gzip 头');
      expect(sha256.convert(bytes).toString(),
          sha256.convert(testServer.payload).toString());

      // 引擎对压缩流上报：总大小未知（dio_download_engine.dart:157
      // 对 isCompressed 场景总是传 total=null）。
      for (final p in events.whereType<DownloadProgress>()) {
        expect(p.total, isNull,
            reason: '压缩（已解码）流的进度不应携带 content-length 总量');
      }
    });

    test('不确定压缩场景下引擎不误判 incomplete（单路径下载完成）', () async {
      // 首 chunk 为解压后的 PK 头（非 gzip 魔数 0x1f 0x8b），sizeUnknown=false；
      // 但 content-length 若被 dart 剥离则 total 为 null，若保留则解压后长度更大，
      // 两种情况都不应触发 `incomplete` 失败（dio_download_engine.dart:164）。
      final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
      final engine = DioDownloadEngine(dio: dio);

      final events = await _collect(
        engine,
        DownloadRequest(url: testServer.url, savePath: savePath, resume: false),
      );

      expect(events.whereType<DownloadFailed>(), isEmpty);
      expect(events.whereType<DownloadCompleted>(), hasLength(1));
      expect((await File(savePath).readAsBytes()), testServer.payload);
    });
  });
}
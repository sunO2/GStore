import 'dart:io';

// crypto 为 flutter_test 传递依赖（未列入 pubspec.dev_dependencies），
// 仅用于测试期做 sha256 校验，避免额外依赖。
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart' show sha256;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/core/dio_download_engine.dart';
import 'package:gstore/core/download/core/download_event.dart';
import 'package:gstore/core/download/core/download_request.dart';

/// 本地测试服务器：支持 HTTP Range，返回 206 + Content-Range。
///
/// - `Range: bytes=0-0`（probe）→ 206 + 1 字节，用于探测 supportsRange/total。
/// - `Range: bytes=A-B` → 206 + 精确的 [A, B] 切片。
/// - [overstateSegmentZero] 为 true 时模拟“服务器 bug”：段 0 的响应比请求多返回
///   若干字节（超出 Content-Range 声明范围），用于验证引擎必须失败而非产出坏文件。
class _SegmentedServer {
  final HttpServer server;
  final List<int> payload;
  final bool overstateSegmentZero;
  int requests = 0;

  /// 记录收到的所有 Range 起始值（用于断言续传起点，验证 resume 不重下）。
  final List<int> rangeStarts = [];

  _SegmentedServer._(this.server, this.payload, this.overstateSegmentZero);

  static Future<_SegmentedServer> start({
    required int totalBytes,
    bool overstateSegmentZero = false,
  }) async {
    // 伪随机内容：不可压缩，且不被 http 层误判为 zip gzip 等魔数开头。
    final payload = List<int>.generate(totalBytes, (i) => (i * 31 + 7) & 0xff);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ts = _SegmentedServer._(server, payload, overstateSegmentZero);
    server.listen((request) async {
      ts.requests++;
      final range = request.headers.value('range');
      if (range != null && range.startsWith('bytes=')) {
        final parts = range.substring(6).split('-');
        final start = int.parse(parts[0]);
        final end = parts[1].isEmpty ? payload.length - 1 : int.parse(parts[1]);
        ts.rangeStarts.add(start);
        var length = end - start + 1;
        var chunk = payload.sublist(start, start + length);

        // 模拟服务器 bug：段 0（start>=0 且 end>0，排除 probe 的 bytes=0-0）
        // 返回比请求更多的字节数。
        if (ts.overstateSegmentZero && start >= 0 && end > 0) {
          chunk = <int>[...chunk, ...List<int>.filled(64, 0xEE)];
        }

        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
            'Content-Range', 'bytes $start-$end/${payload.length}');
        request.response.contentLength = chunk.length;
        request.response.add(chunk);
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.contentLength = payload.length;
      request.response.add(payload);
      await request.response.close();
    });
    return ts;
  }

  String get url => 'http://${server.address.address}:${server.port}/a.apk';

  int get totalBytes => payload.length;

  Future<void> close() => server.close(force: true);
}

Future<List<DownloadEvent>> _collect(
  DioDownloadEngine engine,
  DownloadRequest request,
) async {
  final events = <DownloadEvent>[];
  await for (final e in engine.execute(request)) {
    events.add(e);
  }
  return events;
}

void main() {
  const totalBytes = 10 * 1024 * 1024; // 10MB > _singlePathMinSize(2MB) → 分片路径

  group('DioDownloadEngine 分片下载（Range/206）', () {
    late _SegmentedServer? testServer;
    late Directory tmpDir;
    late String savePath;

    setUp(() async {
      tmpDir = Directory.systemTemp.createTempSync('gstore_seg_test_');
      savePath = '${tmpDir.path}/a.apk';
    });

    tearDown(() async {
      await testServer?.close();
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('多段并发下载：合并文件 sha256 与原始一致，长度 == total', () async {
      testServer = await _SegmentedServer.start(totalBytes: totalBytes);
      // 探测段字节长度检查：server 必须至少收到一次 Range 请求。
      final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
      final engine = DioDownloadEngine(dio: dio);

      final events = await _collect(
        engine,
        DownloadRequest(
            url: testServer!.url, savePath: savePath, resume: true),
      );

      expect(events.whereType<DownloadFailed>(), isEmpty,
          reason: '分段下载不应失败');
      expect(events.whereType<DownloadCompleted>(), hasLength(1));
      expect(testServer!.requests, greaterThan(1),
          reason: '分片路径应发出多次 Range 请求');

      final file = File(savePath);
      expect(await file.exists(), isTrue);
      final bytes = await file.readAsBytes();
      expect(bytes.length, testServer!.totalBytes);
      expect(sha256.convert(bytes).toString(),
          sha256.convert(_seededPayload(totalBytes)).toString(),
          reason: '合并后文件必须与原始负载逐字节一致');

      // 分段合并后不应残留 .part 文件
      expect(File('$savePath.part0').existsSync(), isFalse);
    });

    test('resume 续传：磁盘已有部分分片时从既有长度继续，不整包重下', () async {
      testServer = await _SegmentedServer.start(totalBytes: totalBytes);
      final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
      final engine = DioDownloadEngine(dio: dio);

      // 模拟暂停后残留：part0 已有前 2MB，part1 已完成。
      // totalBytes=10MB → segmentCount=clamp(10MB/16MB,2,64)=2，每段 5MB。
      final payload = _seededPayload(totalBytes);
      final part0 = File('$savePath.part0');
      await part0.parent.create(recursive: true);
      await part0.writeAsBytes(payload.sublist(0, 2 * 1024 * 1024),
          flush: true);
      final part1 = File('$savePath.part1');
      await part1.writeAsBytes(
          payload.sublist(5 * 1024 * 1024, 10 * 1024 * 1024),
          flush: true);

      final events = await _collect(
        engine,
        DownloadRequest(
            url: testServer!.url, savePath: savePath, resume: true),
      );

      expect(events.whereType<DownloadFailed>(), isEmpty,
          reason: '续传不应失败');
      expect(events.whereType<DownloadCompleted>(), hasLength(1));

      // 关键断言：引擎应请求 part0 的剩余部分（从 2MB 起），而非从 0 重下。
      // 注：probe（bytes=0-0）也会记 start=0，因此只断言包含 2MB 的段请求。
      expect(testServer!.rangeStarts, contains(2 * 1024 * 1024),
          reason: 'resume 必须从已有分片长度继续，不得整包重下');

      final file = File(savePath);
      expect(await file.exists(), isTrue);
      final bytes = await file.readAsBytes();
      expect(bytes.length, testServer!.totalBytes);
      expect(sha256.convert(bytes).toString(),
          sha256.convert(payload).toString(),
          reason: '续传合并后文件必须与原始负载逐字节一致');
    });

    test('某段返回超过请求的字节（服务器 bug）：引擎必须 DownloadFailed，不产出坏文件',
        () async {
      testServer = await _SegmentedServer.start(
          totalBytes: totalBytes, overstateSegmentZero: true);
      final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
      final engine = DioDownloadEngine(dio: dio);

      final events = await _collect(
        engine,
        DownloadRequest(
            url: testServer!.url, savePath: savePath, resume: true),
      );

      expect(events.whereType<DownloadCompleted>(), isEmpty,
          reason: '段长度与实际不符时禁止报完成');
      expect(events.whereType<DownloadFailed>(), isNotEmpty,
          reason: '引擎必须通过 DownloadFailed 暴露错误而非产出损坏文件');
      expect(await File(savePath).exists(), isFalse,
          reason: '失败时不得留下合并产物');
      for (var i = 0; i < 4; i++) {
        expect(File('$savePath.part$i').existsSync(), isFalse,
            reason: '失败后段文件应被清理');
      }
    });
  });

  group('DioDownloadEngine 探测 total 错报（pingan MCD 代理）', () {
    late _BogusTotalServer? testServer;
    late Directory tmpDir;
    late String savePath;

    setUp(() async {
      tmpDir = Directory.systemTemp.createTempSync('gstore_bogus_total_');
      savePath = '${tmpDir.path}/a.apk';
    });

    tearDown(() async {
      await testServer?.close();
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('探测 total=1 但完整 GET 返回真实 Content-Length：进度 total 应为 N', () async {
      const n = 4 * 1024 * 1024; // 4MB，走单连接路径
      testServer = await _BogusTotalServer.start(totalBytes: n);
      final dio = Dio()..httpClientAdapter = IOHttpClientAdapter();
      final engine = DioDownloadEngine(dio: dio);

      final events = await _collect(
        engine,
        DownloadRequest(url: testServer!.url, savePath: savePath, resume: false),
      );

      final progress = events.whereType<DownloadProgress>().toList();
      expect(progress, isNotEmpty);
      for (final p in progress) {
        expect(p.total, n, reason: '进度 total 必须是真实文件大小 N，而非探测的 1');
      }
      expect(events.whereType<DownloadCompleted>(), hasLength(1));
      expect(events.whereType<DownloadFailed>(), isEmpty);

      final file = File(savePath);
      expect(await file.exists(), isTrue);
      expect(await file.length(), n, reason: '落盘文件长度必须等于 N');
    });
  });
}

/// 与 `_SegmentedServer.start` 相同的种子负载，供校验合并结果。
List<int> _seededPayload(int n) =>
    List<int>.generate(n, (i) => (i * 31 + 7) & 0xff);

/// 模拟 pingan MCD 代理的 bug：Range 探测（bytes=0-0）返回
/// 206 + Content-Range: bytes 0-0/1（total 错报为 1），但完整 GET 返回真实大小。
class _BogusTotalServer {
  final HttpServer server;
  final List<int> payload;
  int requests = 0;

  _BogusTotalServer._(this.server, this.payload);

  static Future<_BogusTotalServer> start({required int totalBytes}) async {
    final payload = List<int>.generate(totalBytes, (i) => (i * 29 + 5) & 0xff);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ts = _BogusTotalServer._(server, payload);
    server.listen((request) async {
      ts.requests++;
      final range = request.headers.value('range');
      if (range == 'bytes=0-0') {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('Content-Range', 'bytes 0-0/1');
        request.response.contentLength = 1;
        request.response.add(payload.sublist(0, 1));
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('content-length', '${payload.length}');
      request.response.contentLength = payload.length;
      request.response.add(payload);
      await request.response.close();
    });
    return ts;
  }

  String get url => 'http://${server.address.address}:${server.port}/a.apk';

  int get totalBytes => payload.length;

  Future<void> close() => server.close(force: true);
}
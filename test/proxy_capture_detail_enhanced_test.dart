// Todo 23 验收测试：抓包详情增强（hex / 图片预览 / 正文搜索 / 按
// Content-Encoding 解码 / 存盘字节一致 / 未知编码回退）+ 列表首次加载失败不冻结。
//
// 密闭式：只注入假门面（[ProxyCaptureDetailFacade] / [ProxyRequestsFacade]），
// 不触碰 FFI / 原生模块。存盘走注入的 `saveFile` 接缝，断言写入字节与原字节一致。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_capture_detail_page.dart';
import 'package:gstore/page/proxy/proxy_requests_facade.dart';
import 'package:gstore/page/proxy/proxy_requests_page.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 解析一帧（避免 `pumpAndSettle` 与常驻 [AppLoading] 动画冲突）。
Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Future<void> _tapSegment(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(Key('seg_$name')));
  await tester.pump();
  await tester.pump();
}

// ==================== 假门面 ====================

class _FakeDetailFacade implements ProxyCaptureDetailFacade {
  _FakeDetailFacade(this.value);

  CaptureDetail value;

  @override
  Future<CaptureDetail> detail(int recordId) async => value;
}

/// 首次 `requestsGet` 抛错、之后成功的假门面（复现「首次加载失败冻结」）。
class _FlakyRequestsFacade implements ProxyRequestsFacade {
  int calls = 0;

  @override
  Future<RequestPage> requestsGet(RequestGetRequest request) async {
    calls++;
    if (calls == 1) {
      throw const ProxyModuleException(code: 'BOOM', message: '首次加载失败');
    }
    return const RequestPage(
      records: <RequestRecord>[
        RequestRecord(
          recordId: 1,
          connId: 'c-1',
          openTsMs: 1700000000000,
          domain: 'recover.test',
          dstIp: '93.184.216.34',
          src: '10.0.0.2:5555',
        ),
      ],
      nextCursor: 1,
      firstCursor: 1,
      retained: 1,
      capacity: 4096,
    );
  }

  @override
  Future<CapturePage> capturesGet(CapturesGetRequest request) async =>
      const CapturePage();

  @override
  Future<CaptureConfig> captureConfigGet() async =>
      const CaptureConfig(enabled: false);

  @override
  Future<CaptureConfig> captureConfigSet(CaptureConfig config) async => config;

  @override
  Future<void> requestsReset() async {}

  @override
  Future<void> capturesReset() async {}

  @override
  Future<RequestExportResult> requestsExport(
    RequestExportRequest request,
  ) async =>
      const RequestExportResult(rows: 0);
}

// ==================== 样例数据 ====================

CaptureDetail _detail({
  int recordId = 7,
  String method = 'GET',
  String url = 'https://example.com/api/data',
  String respHeaders = 'Content-Type: application/json',
  List<int> respBody = const <int>[],
  String contentType = 'application/json',
  int startedAtMs = 1700000000000,
  int finishedAtMs = 1700000000100,
  int durationMs = 100,
}) {
  return CaptureDetail(
    recordId: recordId,
    requestRecordId: 3,
    connId: 'conn-1',
    host: 'example.com',
    method: method,
    scheme: 'https',
    url: url,
    statusCode: 200,
    protocol: 'h2',
    reqHeaders: 'Accept: application/json',
    respHeaders: respHeaders,
    respBody: respBody,
    contentType: contentType,
    startedAtMs: startedAtMs,
    finishedAtMs: finishedAtMs,
    durationMs: durationMs,
  );
}

/// 合法的 1×1 透明 PNG（确保图片预览可解码）。
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

// ==================== 测试 ====================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hex 视图与图片预览：渲染无异常', (tester) async {
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(
        _detail(
          respHeaders: 'Content-Type: image/png',
          contentType: 'image/png',
          respBody: _png1x1,
        ),
      ),
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'response');

    // 图片预览键存在。
    expect(find.byKey(const Key('body_image_resp')), findsOneWidget);

    // 切到 hex 视图：十六进制键与内容存在，且不抛。
    await tester.tap(find.byKey(const Key('body_hex_resp')));
    await tester.pump();
    expect(find.byKey(const Key('body_hex_view_resp')), findsOneWidget);
    expect(find.textContaining('89 50 4e 47'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正文搜索命中：显示命中数量', (tester) async {
    final body = utf8.encode('alpha beta alpha gamma');
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(
        _detail(
          respHeaders: 'Content-Type: text/plain',
          contentType: 'text/plain',
          respBody: body,
        ),
      ),
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'response');

    await tester.enterText(find.byKey(const Key('body_search_resp')), 'alpha');
    await tester.pump();
    expect(find.byKey(const Key('body_search_hit_resp')), findsOneWidget);
    expect(find.textContaining('命中 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('按 Content-Encoding 解码：解码后大小正确', (tester) async {
    final plain = utf8.encode('gzip decoded payload 你好世界');
    final gz = gzip.encode(plain);
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(
        _detail(
          respHeaders: 'Content-Type: text/plain\r\nContent-Encoding: gzip',
          contentType: 'text/plain',
          respBody: gz,
        ),
      ),
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'response');

    // 展示解码后的明文，并显示解码后字节数。
    expect(find.textContaining('gzip decoded payload'), findsWidgets);
    expect(
      find.textContaining('解码后 ${plain.length} B'),
      findsOneWidget,
      reason: '解码后大小必须等于解压后字节数',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('未知 content-encoding：回退原文，不崩', (tester) async {
    final raw = utf8.encode('raw unknown-encoded body');
    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(
        _detail(
          respHeaders: 'Content-Type: text/plain\r\nContent-Encoding: br',
          contentType: 'text/plain',
          respBody: raw,
        ),
      ),
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'response');

    expect(find.textContaining('raw unknown-encoded body'), findsWidgets);
    // 未成功解码 → 不显示「解码后」标注。
    expect(find.textContaining('解码后'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('保存响应体：写入字节与原字节一致', (tester) async {
    final raw = <int>[1, 2, 3, 4, 250, 251, 252];
    Uint8List? saved;
    String? savedName;

    await tester.pumpWidget(_host(ProxyCaptureDetailPage(
      recordId: 7,
      facade: _FakeDetailFacade(
        _detail(
          respHeaders: 'Content-Type: application/octet-stream',
          contentType: 'application/octet-stream',
          respBody: raw,
        ),
      ),
      saveFile: ({
        required String fileName,
        required Uint8List bytes,
        required List<String> allowedExtensions,
      }) async {
        saved = bytes;
        savedName = fileName;
        return '/tmp/$fileName';
      },
    )));
    await _settleLoad(tester);
    await _tapSegment(tester, 'response');

    await tester.tap(find.byKey(const Key('body_save_resp')));
    await tester.pumpAndSettle();

    expect(saved, isNotNull, reason: '保存接缝必须被调用');
    expect(saved, equals(raw), reason: '写入字节必须与原字节逐字节一致');
    expect(savedName, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首次加载失败后实时刷新恢复：列表不冻结', (tester) async {
    final events = StreamController<ProxyEvent>.broadcast();
    final fake = _FlakyRequestsFacade();

    await tester.pumpWidget(_host(ProxyRequestsPage(
      facade: fake,
      events: events.stream,
      initialLive: true,
    )));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // 首次加载失败 → 错误态。
    expect(find.text('请求列表不可用'), findsOneWidget);

    // 一次实时脏信号触发 `_poll`（第二次 requestsGet 成功）→ 必须恢复列表。
    events.add(const ProxyRequestEvent(seq: 1, count: 1, tsMs: 0));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('请求列表不可用'), findsNothing,
        reason: '成功后必须清除首次加载失败的错误态，不得冻结');
    expect(find.byKey(const ValueKey('request_row_1')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await events.close();
    // 卸载页面，取消兜底定时器。
    await tester.pumpWidget(const SizedBox());
  });
}

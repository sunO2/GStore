// Todo 22 验收测试：抓包列表的游标分页（去重）/ 稳定排序 / 单删计数 / 导出筛选。
//
// 密闭式：只注入假门面（[ProxyRequestsFacade] + [ProxyCaptureDeleteFacade]），
// 不触碰 FFI / 原生模块。分页假门面**故意在第二页重叠一条 recordId**，以证明
// 展示层跨页去重（`mergeById`）真实生效，而不是依赖后端恰好不重叠。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_capture_detail_page.dart';
import 'package:gstore/page/proxy/proxy_requests_facade.dart';
import 'package:gstore/page/proxy/proxy_requests_page.dart';
import 'package:gstore/page/proxy/proxy_requests_paging.dart';

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

void _useLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

RequestRecord _record({
  required int recordId,
  String domain = 'example.com',
  int openTsMs = 1700000000000,
  int uploadBytes = 10,
  int downloadBytes = 2048,
}) {
  return RequestRecord(
    recordId: recordId,
    connId: 'c-$recordId',
    openTsMs: openTsMs,
    closeTsMs: openTsMs + 200,
    durationMs: 200,
    domain: domain,
    domainKnown: true,
    dstIp: '93.184.216.34',
    dstPort: 443,
    src: '10.0.0.2:5555',
    network: 'tcp',
    uid: 10123,
    packages: const <String>['com.example.app'],
    uidState: ProxyUidState.known,
    rule: 'DOMAIN-SUFFIX',
    rulePayload: domain,
    outbound: 'PROXY',
    uploadBytes: uploadBytes,
    downloadBytes: downloadBytes,
    closeReason: 'closed',
  );
}

CaptureRecord _capture({
  int recordId = 1,
  int requestRecordId = 1,
  String host = 'example.com',
  String url = 'https://example.com/p?q=1',
  int statusCode = 200,
}) {
  return CaptureRecord(
    recordId: recordId,
    requestRecordId: requestRecordId,
    connId: 'conn-$recordId',
    host: host,
    method: 'GET',
    scheme: 'https',
    url: url,
    statusCode: statusCode,
    protocol: 'h1',
    reqBytes: 100,
    respBytes: 900,
    durationMs: 42,
    startedAtMs: 1700000000000,
  );
}

/// 游标分页假门面：按 `recordId >= cursor` 切片（**故意重叠边界一条**以验证去重），
/// 同时实现删除门面以便删除后重载读到最新状态。
class _PagedFacade implements ProxyRequestsFacade, ProxyCaptureDeleteFacade {
  _PagedFacade({
    List<RequestRecord>? requests,
    List<CaptureRecord>? captures,
    int? requestsRetained,
    int? capturesRetained,
  })  : requests = requests ?? <RequestRecord>[],
        captures = captures ?? <CaptureRecord>[],
        requestsRetained = requestsRetained ?? (requests?.length ?? 0),
        capturesRetained = capturesRetained ?? (captures?.length ?? 0);

  List<RequestRecord> requests;
  List<CaptureRecord> captures;
  int requestsRetained;
  int capturesRetained;

  int requestsGetCalls = 0;
  int capturesGetCalls = 0;
  int deleteCalls = 0;
  int? lastDeleted;
  final List<int?> requestCursors = <int?>[];
  final List<int?> captureCursors = <int?>[];
  RequestExportRequest? lastExport;

  @override
  Future<RequestPage> requestsGet(RequestGetRequest request) async {
    requestsGetCalls++;
    requestCursors.add(request.cursor);
    final cursor = request.cursor ?? 0;
    final limit = request.limit ?? 256;
    final matched =
        requests.where((r) => r.recordId >= cursor).take(limit).toList();
    return RequestPage(
      records: matched,
      nextCursor: requests.isEmpty ? 0 : requests.last.recordId,
      firstCursor: requests.isEmpty ? 0 : requests.first.recordId,
      retained: requestsRetained,
      capacity: 4096,
    );
  }

  @override
  Future<CapturePage> capturesGet(CapturesGetRequest request) async {
    capturesGetCalls++;
    captureCursors.add(request.cursor);
    final cursor = request.cursor ?? 0;
    final limit = request.limit ?? 256;
    final matched =
        captures.where((c) => c.recordId >= cursor).take(limit).toList();
    return CapturePage(
      records: matched,
      nextCursor: captures.isEmpty ? 0 : captures.last.recordId,
      firstCursor: captures.isEmpty ? 0 : captures.first.recordId,
      retained: capturesRetained,
      capacity: 256,
    );
  }

  @override
  Future<CaptureConfig> captureConfigGet() async =>
      const CaptureConfig(enabled: false);

  @override
  Future<CaptureConfig> captureConfigSet(CaptureConfig config) async => config;

  @override
  Future<void> requestsReset() async {
    requests = <RequestRecord>[];
    requestsRetained = 0;
  }

  @override
  Future<void> capturesReset() async {
    captures = <CaptureRecord>[];
    capturesRetained = 0;
  }

  @override
  Future<RequestExportResult> requestsExport(
    RequestExportRequest request,
  ) async {
    lastExport = request;
    return const RequestExportResult(csvPath: '/tmp/out.csv', rows: 1);
  }

  @override
  Future<CaptureDeleteResult> delete(int recordId) async {
    deleteCalls++;
    lastDeleted = recordId;
    final before = captures.length;
    captures = captures.where((c) => c.recordId != recordId).toList();
    if (captures.length != before && capturesRetained > 0) capturesRetained--;
    return const CaptureDeleteResult(ok: true, removed: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('纯函数：mergeById / stableSortBy', () {
    test('mergeById 跨页去重且保留首现顺序', () {
      final first = <RequestRecord>[_record(recordId: 1), _record(recordId: 2)];
      final second = <RequestRecord>[_record(recordId: 2), _record(recordId: 3)];
      final merged = mergeById(first, second, (r) => r.recordId);
      expect(merged.map((r) => r.recordId).toList(), <int>[1, 2, 3]);
    });

    test('stableSortBy 对相等键保持原始相对顺序', () {
      final items = <RequestRecord>[
        _record(recordId: 1, domain: 'a', openTsMs: 100),
        _record(recordId: 2, domain: 'b', openTsMs: 100),
        _record(recordId: 3, domain: 'c', openTsMs: 50),
        _record(recordId: 4, domain: 'd', openTsMs: 100),
      ];
      final sorted = stableSortBy(
        items,
        (a, b) => b.openTsMs.compareTo(a.openTsMs),
      );
      expect(
        sorted.map((r) => r.domain).toList(),
        <String>['a', 'b', 'd', 'c'],
        reason: '100ms 的三个元素必须保持 a,b,d 的原始相对顺序',
      );
    });
  });

  testWidgets('游标分页：加载到第 2 页并按 recordId 去重，计数=已加载/保留',
      (tester) async {
    _useLargeViewport(tester);
    final requests = <RequestRecord>[
      for (var id = 1; id <= 230; id++) _record(recordId: id, domain: 'h$id.test'),
    ];
    final fake = _PagedFacade(requests: requests, requestsRetained: 250);

    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    // 分页假门面第 2 页故意重叠 recordId=200：原始追加=231，去重后必须=230。
    expect(fake.requestsGetCalls, greaterThanOrEqualTo(2));
    expect(fake.requestCursors, contains(200));
    expect(find.text('共 230 条'), findsOneWidget, reason: '跨页去重后的已加载数');
    expect(find.textContaining('保留'), findsOneWidget);
    expect(find.textContaining('250'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('排序：切换到「最新优先」后行顺序按时间倒序且稳定', (tester) async {
    _useLargeViewport(tester);
    final fake = _PagedFacade(
      requests: <RequestRecord>[
        _record(recordId: 1, domain: 'old.test', openTsMs: 100),
        _record(recordId: 2, domain: 'new.test', openTsMs: 300),
        _record(recordId: 3, domain: 'mid.test', openTsMs: 200),
      ],
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_sort_newest')));
    await tester.pumpAndSettle();

    final newTop = tester.getTopLeft(find.text('new.test')).dy;
    final midTop = tester.getTopLeft(find.text('mid.test')).dy;
    final oldTop = tester.getTopLeft(find.text('old.test')).dy;
    expect(newTop, lessThan(midTop));
    expect(midTop, lessThan(oldTop));
    expect(tester.takeException(), isNull);
  });

  testWidgets('单删：长按孤儿抓包行删除，列表与计数（已加载/保留）同步更新',
      (tester) async {
    _useLargeViewport(tester);
    final fake = _PagedFacade(
      requests: <RequestRecord>[_record(recordId: 7, domain: 'skeleton.test')],
      captures: <CaptureRecord>[
        _capture(
          recordId: 5,
          requestRecordId: 0,
          host: 'orphan.test',
          url: 'https://orphan.test/x',
        ),
      ],
      requestsRetained: 1,
      capturesRetained: 1,
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(
        facade: fake,
        initialLive: false,
        captureDeleteFacade: fake,
      )),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('共 2 条'), findsOneWidget);
    expect(find.text('保留 请求 1 · 抓包 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('capture_row_5')), findsOneWidget);

    await tester.longPress(find.byKey(const ValueKey('capture_row_5')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('row_action_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(fake.deleteCalls, 1);
    expect(fake.lastDeleted, 5);
    expect(find.byKey(const ValueKey('capture_row_5')), findsNothing);
    expect(find.text('共 1 条'), findsOneWidget, reason: '删除后已加载数减一');
    expect(
      find.text('保留 请求 1 · 抓包 0'),
      findsOneWidget,
      reason: '删除后抓包保留数同步更新',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('长按：复制域名与分享（剪贴板）可用', (tester) async {
    _useLargeViewport(tester);
    final fake = _PagedFacade(
      requests: <RequestRecord>[_record(recordId: 1, domain: 'copy.test')],
    );
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const ValueKey('request_row_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('row_action_copy_host')));
    await tester.pumpAndSettle();
    expect(clipboard, contains('copy.test'));

    await tester.longPress(find.byKey(const ValueKey('request_row_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('row_action_share')));
    await tester.pumpAndSettle();
    expect(clipboard.any((text) => text.contains('copy.test')), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出遵循当前筛选：network 过滤器被转发到 requests.export',
      (tester) async {
    _useLargeViewport(tester);
    final fake = _PagedFacade(
      requests: <RequestRecord>[_record(recordId: 1, domain: 'net.test')],
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(
        facade: fake,
        initialLive: false,
        saveFile: ({
          required String fileName,
          required Uint8List bytes,
          required List<String> allowedExtensions,
        }) async =>
            '/tmp/$fileName',
        readFile: (path) async => Uint8List.fromList(<int>[1, 2, 3]),
      )),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_filter_open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_filter_network_tcp')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('requests_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_export_csv')));
    await tester.pumpAndSettle();

    expect(fake.lastExport, isNotNull);
    expect(fake.lastExport!.filter, isNotNull);
    expect(
      fake.lastExport!.filter!.network,
      'tcp',
      reason: '导出必须携带当前 network 筛选，仅导出筛选结果',
    );
    expect(tester.takeException(), isNull);
  });
}

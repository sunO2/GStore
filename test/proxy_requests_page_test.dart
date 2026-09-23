// Todo 15 widget tests：实时「请求域名 / IP 收集」页。
//
// 全部密闭式：只注入假门面（[ProxyRequestsFacade]）与假事件流，不触碰 FFI /
// 原生模块。弹层宿主复用生产全局通道 `appNavigatorKey` +
// `AppDialogs.scaffoldMessengerKey`，因此走真实的 `AppSheet` 呈现路径。
//
// 覆盖：
// * 空态（facade 返回空页）；
// * 含数据列表 + 概览聚合值（断言渲染出的**值**，非仅存在性）；
// * 应用筛选后行数变化；
// * `uid == null` 渲染「未知应用」；
// * 脏信号（`proxy.request`）触发精确次数的拉取，非请求事件不触发；
// * 超长域名 / IP 不溢出（大视口 + ensureVisible）；
// * 点击行经统一 [AppSheet] 打开详情；
// * 对抗：门面抛错 → 显式错误态且不崩溃；卸载后事件 / 定时器不再 setState。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_requests_facade.dart';
import 'package:gstore/page/proxy/proxy_requests_page.dart';

// ==================== 测试宿主 ====================

/// 与 `lib/main.dart` 相同的全局通道（Navigator / ScaffoldMessenger）。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 放大测试视口：列表 + 分组视图需要更大视口才能同屏渲染，且用于长串溢出验证。
void _useLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

// ==================== 假门面 ====================

class _FakeRequestsFacade implements ProxyRequestsFacade {
  _FakeRequestsFacade({
    this.page = const RequestPage(),
    this.fail = false,
    this.exportResult = const RequestExportResult(),
    this.exportFail = false,
  });

  RequestPage page;
  bool fail;
  RequestExportResult exportResult;
  bool exportFail;
  int getCalls = 0;
  int resetCalls = 0;
  int exportCalls = 0;
  RequestGetRequest? lastGet;
  RequestExportRequest? lastExport;

  @override
  Future<RequestPage> requestsGet(RequestGetRequest request) async {
    getCalls++;
    lastGet = request;
    if (fail) {
      throw const ProxyModuleException(code: 'TEST_FAIL', message: 'boom');
    }
    return page;
  }

  @override
  Future<void> requestsReset() async {
    resetCalls++;
  }

  @override
  Future<RequestExportResult> requestsExport(
    RequestExportRequest request,
  ) async {
    exportCalls++;
    lastExport = request;
    if (exportFail) {
      throw const ProxyModuleException(code: 'EXPORT_FAIL', message: '导出后端失败');
    }
    return exportResult;
  }
}

/// 假另存接缝：记录调用参数并返回预设路径（`null` = 用户取消）。
class _FakeSaveFile {
  _FakeSaveFile({this.result = '/tmp/out.csv'});

  String? result;
  final List<String> fileNames = <String>[];
  final List<List<String>> extensions = <List<String>>[];
  final List<int> byteLengths = <int>[];

  Future<String?> call({
    required String fileName,
    required Uint8List bytes,
    required List<String> allowedExtensions,
  }) async {
    fileNames.add(fileName);
    extensions.add(allowedExtensions);
    byteLengths.add(bytes.length);
    return result;
  }
}

// ==================== fixture ====================

RequestRecord _record({
  required int recordId,
  String domain = 'example.com',
  bool domainKnown = true,
  String dstIp = '93.184.216.34',
  int dstPort = 443,
  int? uid = 10123,
  List<String> packages = const <String>['com.example.app'],
  String network = 'tcp',
  String outbound = 'PROXY',
  String rule = 'DOMAIN-SUFFIX',
  String src = '10.0.0.2:5555',
  int uploadBytes = 10,
  int downloadBytes = 2048,
  int? durationMs = 200,
  int openTsMs = 1700000000000,
  String closeReason = 'closed',
}) {
  return RequestRecord(
    recordId: recordId,
    connId: 'c-$recordId',
    openTsMs: openTsMs,
    closeTsMs: durationMs == null ? null : openTsMs + durationMs,
    durationMs: durationMs,
    domain: domain,
    domainKnown: domainKnown,
    dstIp: dstIp,
    dstPort: dstPort,
    src: src,
    network: network,
    uid: uid,
    packages: packages,
    uidState: uid == null ? ProxyUidState.unknown : ProxyUidState.known,
    rule: rule,
    rulePayload: domain,
    outbound: outbound,
    uploadBytes: uploadBytes,
    downloadBytes: downloadBytes,
    closeReason: closeReason,
  );
}

/// 两条样本：已知域名 + `uid != null`；未知域名 + `uid == null`。
RequestPage _samplePage() => RequestPage(
      records: <RequestRecord>[
        _record(recordId: 1),
        _record(
          recordId: 2,
          domain: '1.1.1.1',
          domainKnown: false,
          dstIp: '1.1.1.1',
          dstPort: 53,
          uid: null,
          packages: const <String>[],
          outbound: 'DIRECT',
          rule: '',
          src: '10.0.0.3:53000',
          uploadBytes: 0,
          downloadBytes: 0,
          durationMs: null,
          closeReason: 'open',
        ),
      ],
      nextCursor: 2,
      firstCursor: 1,
      retained: 2,
      capacity: 4096,
      dropped: 0,
      evicted: 0,
      windowStartMs: 1600000000000,
    );

// ==================== 测试 ====================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('空态：facade 返回空页 -> 显式空态且不崩溃', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade();
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(fake.getCalls, 1);
    expect(find.text('暂无请求记录'), findsOneWidget);
    expect(find.text('采集概览'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('含数据：列表字段与概览聚合值正确渲染', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(page: _samplePage());
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    // 列表行（域名出现在行与分组视图中）。
    expect(find.text('example.com'), findsWidgets);
    expect(find.textContaining('93.184.216.34:443'), findsWidgets);
    expect(find.textContaining('com.example.app'), findsWidgets);
    expect(find.textContaining('未知应用'), findsWidgets);
    // 概览：请求数 2 / 未知域名 1（50%）。
    expect(find.text('请求数'), findsOneWidget);
    expect(find.text('未知域名'), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    // 活跃：closeReason == open 的 1 条 -> 行耗时显示「进行中」。
    expect(find.text('进行中'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选：应用子串过滤后仅保留匹配行', (tester) async {
    _useLargeViewport(tester);
    final page = RequestPage(
      records: <RequestRecord>[
        _record(recordId: 1, domain: 'example.com'),
        _record(
          recordId: 2,
          domain: 'other.org',
          dstIp: '10.0.0.1',
          uid: 555,
          packages: const <String>['org.other.app'],
          outbound: 'DIRECT',
        ),
      ],
      nextCursor: 2,
      firstCursor: 1,
      retained: 2,
    );
    final fake = _FakeRequestsFacade(page: page);
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('other.org'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('requests_app_filter')),
      'org.other',
    );
    await tester.pump();

    expect(find.text('other.org'), findsWidgets);
    expect(find.text('example.com'), findsNothing);
    expect(tester.takeException(), isNull);

    // 清空后恢复（本地过滤可逆）。
    await tester.enterText(find.byKey(const Key('requests_app_filter')), '');
    await tester.pump();
    expect(find.text('example.com'), findsWidgets);
  });

  testWidgets('uid == null 渲染「未知应用」而非空', (tester) async {
    _useLargeViewport(tester);
    final page = RequestPage(
      records: <RequestRecord>[
        _record(
          recordId: 9,
          domain: '1.1.1.1',
          domainKnown: false,
          dstIp: '1.1.1.1',
          uid: null,
          packages: const <String>[],
        ),
      ],
      nextCursor: 9,
      firstCursor: 9,
      retained: 1,
    );
    final fake = _FakeRequestsFacade(page: page);
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('未知应用'), findsWidgets);
    expect(find.textContaining('UID null'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('脏信号触发精确次数拉取，非请求事件不触发', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(page: _samplePage());
    final controller = StreamController<ProxyEvent>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          events: controller.stream,
          initialLive: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(fake.getCalls, 1, reason: '首屏一次拉取');

    // 一个 `proxy.request` 脏信号 -> 恰好多一次拉取。
    controller.add(const ProxyRequestEvent(seq: 1, count: 3, tsMs: 10));
    await tester.pump();
    expect(fake.getCalls, 2);

    // 非请求事件（`proxy.stats`）不触发拉取。
    controller.add(
      const ProxyStatsEvent(
        uploadBytes: 1,
        downloadBytes: 2,
        activeConns: 1,
        upBps: 0,
        downBps: 0,
      ),
    );
    await tester.pump();
    expect(fake.getCalls, 2);

    // 第二个脏信号 -> 又一次。
    controller.add(const ProxyRequestEvent(seq: 2, count: 1, tsMs: 20));
    await tester.pump();
    expect(fake.getCalls, 3);

    // 卸载以取消 2s 兜底定时器（避免 pending timer）。
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('超长域名 / IP 不溢出（大视口 + ensureVisible）', (tester) async {
    _useLargeViewport(tester);
    final longDomain = '${'a' * 300}.very-long-subdomain.example.com';
    final longIp = '2001:0db8:${'1234:' * 12}abcd';
    final page = RequestPage(
      records: <RequestRecord>[
        _record(
          recordId: 77,
          domain: longDomain,
          dstIp: longIp,
          src: '10.0.0.2:${'9' * 40}',
        ),
      ],
      nextCursor: 77,
      firstCursor: 77,
      retained: 1,
    );
    final fake = _FakeRequestsFacade(page: page);
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    await tester.ensureVisible(find.byKey(const ValueKey('request_row_77')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击行经统一 AppSheet 打开详情', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(page: _samplePage());
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('request_row_1')));
    await tester.pumpAndSettle();

    expect(find.text('连接 ID'), findsOneWidget);
    expect(find.text('c-1'), findsOneWidget);
    expect(find.text('结束原因'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：门面抛错 -> 显式错误态且不崩溃', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(fail: true);
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(fake.getCalls, 1);
    expect(find.text('请求列表不可用'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：卸载后事件 / 定时器不再 setState，无泄漏', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(page: _samplePage());
    final controller = StreamController<ProxyEvent>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          events: controller.stream,
          initialLive: true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final before = fake.getCalls;

    // 卸载页面（取消订阅 + 定时器）。
    await tester.pumpWidget(const SizedBox());
    controller.add(const ProxyRequestEvent(seq: 1, count: 1, tsMs: 1));
    await tester.pump(const Duration(seconds: 3));

    expect(fake.getCalls, before, reason: '卸载后不应再拉取');
    expect(tester.takeException(), isNull);
  });

  // ==================== 导出 UI（Todo 16） ====================

  testWidgets('导出 CSV：调用 saveFile 且成功提示含真实行数', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      exportResult: const RequestExportResult(
        csvPath: '/data/proxy_requests_1.csv',
        rows: 3,
        bytes: 42,
      ),
    );
    final save = _FakeSaveFile(result: '/tmp/gstore_requests.csv');

    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          saveFile: save.call,
          readFile: (path) async => Uint8List.fromList(<int>[1, 2, 3]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_export_csv')));
    await tester.pumpAndSettle();

    expect(fake.exportCalls, 1);
    expect(fake.lastExport?.format, 'csv');
    expect(save.fileNames, hasLength(1));
    expect(save.fileNames.single, endsWith('.csv'));
    expect(save.fileNames.single, startsWith('gstore_requests_'));
    expect(save.extensions.single, <String>['csv']);
    expect(save.byteLengths.single, 3);
    // 成功提示必须包含真实行数（非仅存在性）。
    expect(find.textContaining('已导出 3 条请求记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出取消（saveFile 返回 null）：无错误、无失败提示', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      exportResult: const RequestExportResult(
        csvPath: '/data/proxy_requests_1.csv',
        rows: 3,
      ),
    );
    final save = _FakeSaveFile(result: null);

    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          saveFile: save.call,
          readFile: (path) async => Uint8List.fromList(<int>[1]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_export_csv')));
    await tester.pumpAndSettle();

    expect(fake.exportCalls, 1);
    expect(save.fileNames, hasLength(1), reason: 'saveFile 仍应被调用一次');
    expect(find.byType(SnackBar), findsNothing, reason: '取消不应提示成功或失败');
    expect(find.text('导出失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导出失败：showError 且不崩溃', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(page: _samplePage(), exportFail: true);
    final save = _FakeSaveFile();

    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          saveFile: save.call,
          readFile: (path) async => Uint8List.fromList(<int>[1]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_export_csv')));
    await tester.pumpAndSettle();

    expect(fake.exportCalls, 1);
    expect(save.fileNames, isEmpty, reason: '导出失败不应调用 saveFile');
    expect(find.text('导出失败'), findsOneWidget);
    expect(find.textContaining('导出后端失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('边界：同时选择 CSV + JSON -> saveFile 调用两次', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      exportResult: const RequestExportResult(
        csvPath: '/data/proxy_requests_1.csv',
        jsonPath: '/data/proxy_requests_1.json',
        rows: 7,
      ),
    );
    final save = _FakeSaveFile(result: '/tmp/out');

    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          saveFile: save.call,
          readFile: (path) async => Uint8List.fromList(<int>[9]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_export_both')));
    await tester.pumpAndSettle();

    expect(fake.lastExport?.format, 'both');
    expect(save.extensions, <List<String>>[
      <String>['csv'],
      <String>['json'],
    ]);
    expect(find.textContaining('已导出 7 条请求记录'), findsOneWidget);
    expect(find.textContaining('CSV + JSON'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：facade 返回空路径（malformed）-> showError 不崩溃', (tester) async {
    _useLargeViewport(tester);
    // 无 csvPath / jsonPath（两键均 null）。
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      exportResult: const RequestExportResult(rows: 0),
    );
    final save = _FakeSaveFile();

    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          saveFile: save.call,
          readFile: (path) async => Uint8List.fromList(<int>[1]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_export_json')));
    await tester.pumpAndSettle();

    expect(save.fileNames, isEmpty);
    expect(find.text('导出失败'), findsOneWidget);
    expect(find.textContaining('未生成可导出的文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：导出中卸载 -> 无 dispose 后 setState', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      exportResult: const RequestExportResult(
        csvPath: '/data/proxy_requests_1.csv',
        rows: 1,
      ),
    );
    final gate = Completer<void>();
    String? saveResult;

    Future<String?> pendingSave({
      required String fileName,
      required Uint8List bytes,
      required List<String> allowedExtensions,
    }) async {
      await gate.future;
      return saveResult;
    }

    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          saveFile: pendingSave,
          readFile: (path) async => Uint8List.fromList(<int>[1]),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_export_csv')));
    await tester.pump();

    // 另存仍挂起时卸载页面。
    await tester.pumpWidget(const SizedBox());
    saveResult = '/tmp/out.csv';
    gate.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

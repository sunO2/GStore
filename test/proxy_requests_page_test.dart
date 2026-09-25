// Todo 22 widget tests：列表优先的「请求域名 / IP」页（requests 骨架 + captures 叠加）。
//
// 全部密闭式：只注入假门面（[ProxyRequestsFacade]）与假事件流，不触碰 FFI /
// 原生模块。弹层宿主复用生产全局通道 `appNavigatorKey` +
// `AppDialogs.scaffoldMessengerKey`，因此走真实的 `AppSheet` 呈现路径。
//
// 覆盖（Todo 22 验收）：
// * 合并展示：`requests.get` 骨架 + 按 `requestRecordId` 叠加 `captures.get` 详情；
// * 一个流叠加多条 capture → 取最新一条作行摘要；
// * 无 capture 的流显示「未解密」（仅流级字段）；
// * 孤儿 capture（`requestRecordId == 0`）自成一行，不得被丢弃；
// * 筛选（搜索框 + `AppSheet` 过滤器）与行渲染；
// * 空态 / 错误态 / 大视口不溢出；
// * 对抗：`captures.get` 失败不影响 `requests.get` 列表（降级）。
// * 保留：导出 UI、脏信号拉取、抓包迷你开关、分析可展开区、行点击详情。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_capture_bridge.dart';
import 'package:gstore/page/proxy/proxy_capture_detail_page.dart';
import 'package:gstore/page/proxy/proxy_requests_facade.dart';
import 'package:gstore/page/proxy/proxy_requests_page.dart';

// ==================== 测试宿主 ====================

/// 与 `lib/main.dart` 相同的全局通道（Navigator / ScaffoldMessenger）。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 放大测试视口：列表 + 分析区需要更大视口才能同屏渲染，且用于长串溢出验证。
void _useLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

// ==================== 假门面 ====================

class _FakeRequestsFacade implements ProxyRequestsFacade {
  _FakeRequestsFacade({
    this.page = const RequestPage(),
    this.capturePage = const CapturePage(),
    this.captureConfig = const CaptureConfig(enabled: false),
    this.fail = false,
    this.capturesFail = false,
    this.configGetFail = false,
    this.configSetFail = false,
    this.exportResult = const RequestExportResult(),
    this.exportFail = false,
    this.resetFail = false,
    this.capturesResetFail = false,
  });

  RequestPage page;
  CapturePage capturePage;
  CaptureConfig captureConfig;
  bool fail;
  bool capturesFail;
  bool configGetFail;
  bool configSetFail;
  RequestExportResult exportResult;
  bool exportFail;
  bool resetFail;
  bool capturesResetFail;

  int getCalls = 0;
  int capturesCalls = 0;
  int configGetCalls = 0;
  int configSetCalls = 0;
  int resetCalls = 0;
  int capturesResetCalls = 0;
  int exportCalls = 0;
  RequestGetRequest? lastGet;
  CapturesGetRequest? lastCaptures;
  CaptureConfig? lastConfigSet;
  RequestExportRequest? lastExport;
  final List<String> resetOrder = <String>[];

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
  Future<CapturePage> capturesGet(CapturesGetRequest request) async {
    capturesCalls++;
    lastCaptures = request;
    if (capturesFail) {
      throw const ProxyModuleException(
        code: 'CAPTURES_FAIL',
        message: 'captures 后端失败',
      );
    }
    return capturePage;
  }

  @override
  Future<CaptureConfig> captureConfigGet() async {
    configGetCalls++;
    if (configGetFail) {
      throw const ProxyModuleException(code: 'CFG_FAIL', message: '配置失败');
    }
    return captureConfig;
  }

  @override
  Future<CaptureConfig> captureConfigSet(CaptureConfig config) async {
    configSetCalls++;
    lastConfigSet = config;
    if (configSetFail) {
      throw const ProxyModuleException(code: 'CFG_SET_FAIL', message: '下发失败');
    }
    captureConfig = config;
    return config;
  }

  @override
  Future<void> requestsReset() async {
    resetCalls++;
    resetOrder.add('requests');
    if (resetFail) {
      throw const ProxyModuleException(code: 'RESET_FAIL', message: '请求清空失败');
    }
    // 模拟后端真实清空，便于断言 reload 后行消失。
    page = const RequestPage();
  }

  @override
  Future<void> capturesReset() async {
    capturesResetCalls++;
    resetOrder.add('captures');
    if (capturesResetFail) {
      throw const ProxyModuleException(
        code: 'CAP_RESET_FAIL',
        message: '抓包清空失败',
      );
    }
    capturePage = const CapturePage();
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

/// 假详情门面：记录被请求的 `recordId` 并返回预设 [CaptureDetail]。
class _FakeCaptureDetailFacade implements ProxyCaptureDetailFacade {
  _FakeCaptureDetailFacade({this.value = const CaptureDetail()});

  CaptureDetail value;
  int calls = 0;
  int? lastRecordId;

  @override
  Future<CaptureDetail> detail(int recordId) async {
    calls++;
    lastRecordId = recordId;
    return value;
  }
}

/// 假删除门面（D8b）：记录被删除的 `recordId`，可注入失败。
class _FakeCaptureDeleteFacade implements ProxyCaptureDeleteFacade {
  _FakeCaptureDeleteFacade({this.fail = false});

  bool fail;
  int calls = 0;
  int? lastRecordId;

  @override
  Future<CaptureDeleteResult> delete(int recordId) async {
    calls++;
    lastRecordId = recordId;
    if (fail) {
      throw const ProxyModuleException(code: 'DEL_FAIL', message: '删除失败');
    }
    return const CaptureDeleteResult(ok: true, removed: true);
  }
}

/// 假动作桥：仅记录调用（证明导航 seam 把详情页回调绑定到桥）。
class _FakeCaptureBridge implements CaptureBridge {
  int saveCalls = 0;
  int ruleCalls = 0;

  @override
  Future<void> saveToCollection(CaptureDetail detail) async {
    saveCalls++;
  }

  @override
  Future<void> openRewriteRuleEditor(CaptureRulePrefill prefill) async {
    ruleCalls++;
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

CaptureRecord _capture({
  int recordId = 1,
  int requestRecordId = 1,
  String host = 'example.com',
  String method = 'GET',
  String scheme = 'https',
  String url = 'https://example.com/p?q=1',
  int statusCode = 200,
  String protocol = 'h1',
  int reqBytes = 100,
  int respBytes = 900,
  int durationMs = 42,
  int startedAtMs = 1700000000000,
  bool mitmFailed = false,
}) {
  return CaptureRecord(
    recordId: recordId,
    requestRecordId: requestRecordId,
    connId: 'conn-$recordId',
    host: host,
    method: method,
    scheme: scheme,
    url: url,
    statusCode: statusCode,
    protocol: protocol,
    reqBytes: reqBytes,
    respBytes: respBytes,
    durationMs: durationMs,
    startedAtMs: startedAtMs,
    mitmFailed: mitmFailed,
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

/// 空配置（未开启抓包）。
const CaptureConfig _configOff = CaptureConfig(enabled: false);

// ==================== 测试 ====================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('空态：requests + captures 均空 -> 显式空态 + 顶部 chips 且不崩溃',
      (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade();
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(fake.getCalls, 1);
    expect(fake.capturesCalls, 1);
    expect(find.text('暂无请求记录'), findsOneWidget);
    expect(find.byKey(const Key('requests_capture_toggle')), findsOneWidget);
    expect(find.byKey(const Key('requests_live_toggle')), findsOneWidget);
    expect(find.byKey(const Key('requests_count_chip')), findsOneWidget);
    expect(find.text('共 0 条'), findsOneWidget);
    expect(find.byKey(const Key('requests_search')), findsOneWidget);
    expect(find.byKey(const Key('requests_analysis_toggle')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('合并展示：requests 骨架叠加 captures 详情，无 capture 显示「未解密」',
      (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(
            recordId: 11,
            requestRecordId: 1,
            host: 'api.example.com',
            method: 'POST',
            url: 'https://api.example.com/v1/items?page=1',
            statusCode: 201,
            protocol: 'h2',
            reqBytes: 100,
            respBytes: 900,
            durationMs: 42,
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('共 2 条'), findsOneWidget);
    // 叠加行：方法徽标 / 域名 / 路径 / 状态 / 耗时（断言真实字段值）。
    expect(find.byKey(const ValueKey('request_row_1')), findsOneWidget);
    expect(find.text('POST'), findsOneWidget);
    expect(find.text('api.example.com'), findsOneWidget);
    expect(find.text('/v1/items'), findsOneWidget);
    expect(find.text('201'), findsOneWidget);
    expect(find.textContaining('42 ms'), findsOneWidget);
    // 无 capture 的流（record 2）显示「未解密」（仅流级字段）。
    expect(find.byKey(const ValueKey('request_row_2')), findsOneWidget);
    expect(find.text('未解密'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('一个流叠加多条 capture -> 取最新一条作为行摘要', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 1)],
        firstCursor: 1,
        nextCursor: 1,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(recordId: 10, requestRecordId: 1, statusCode: 200),
          _capture(recordId: 11, requestRecordId: 1, statusCode: 503),
        ],
      ),
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    // 仅一行（流骨架），摘要取 recordId 更大的 capture（503）。
    expect(find.byKey(const ValueKey('request_row_1')), findsOneWidget);
    expect(find.text('503'), findsOneWidget);
    expect(find.text('200'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('孤儿 capture（requestRecordId == 0）自成一行，不被丢弃', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 7)],
        firstCursor: 7,
        nextCursor: 7,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(
            recordId: 5,
            requestRecordId: 0,
            host: 'orphan.test',
            method: 'PUT',
            url: 'https://orphan.test/x',
            statusCode: 500,
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    // 骨架行没有 capture -> 未解密；孤儿 capture 派生独立行。
    expect(find.byKey(const ValueKey('request_row_7')), findsOneWidget);
    expect(find.byKey(const ValueKey('capture_row_5')), findsOneWidget);
    expect(find.text('PUT'), findsOneWidget);
    expect(find.text('orphan.test'), findsOneWidget);
    expect(find.text('500'), findsOneWidget);
    expect(find.text('未解密'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未匹配骨架的非 0 capture 自成一行，不被丢弃', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 7)],
        firstCursor: 7,
        nextCursor: 7,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          // `requestRecordId != 0`，但骨架里不存在 id=999 的 request，
          // 该 capture 必须派生独立行，绝不能被 join 丢弃。
          _capture(
            recordId: 42,
            requestRecordId: 999,
            host: 'unmatched.test',
            method: 'DELETE',
            url: 'https://unmatched.test/gone',
            statusCode: 418,
            protocol: 'h2',
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    // 未匹配骨架的 capture 持独立 key，并携带自身 HTTP 详情。
    expect(find.byKey(const ValueKey('capture_row_42')), findsOneWidget);
    expect(find.text('DELETE'), findsOneWidget);
    expect(find.text('unmatched.test'), findsOneWidget);
    expect(find.text('/gone'), findsOneWidget);
    expect(find.text('418'), findsOneWidget);
    // 骨架行仍在（未匹配 capture 既不被丢弃也不顶替骨架行）。
    expect(find.byKey(const ValueKey('request_row_7')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索框：域名 / IP / 方法 / 路径 子串本地过滤且可逆', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[
          _record(recordId: 1, domain: 'example.com'),
          _record(
            recordId: 2,
            domain: 'other.org',
            dstIp: '10.0.0.9',
            uid: 555,
            packages: const <String>['org.other.app'],
            outbound: 'DIRECT',
          ),
        ],
        firstCursor: 1,
        nextCursor: 2,
        retained: 2,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(recordId: 21, requestRecordId: 1, host: 'example.com'),
          _capture(
            recordId: 22,
            requestRecordId: 2,
            host: 'other.org',
            method: 'POST',
            url: 'https://other.org/api',
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('other.org'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('requests_search')), 'org');
    await tester.pump();
    expect(find.text('other.org'), findsOneWidget);
    expect(find.text('example.com'), findsNothing);

    // 清空恢复。
    await tester.enterText(find.byKey(const Key('requests_search')), '');
    await tester.pump();
    expect(find.text('example.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AppSheet 筛选：仅错误 / 协议 / 方法 过滤生效', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[
          _record(recordId: 1, domain: 'ok.example.com'),
          _record(
            recordId: 2,
            domain: 'bad.example.com',
            dstIp: '10.0.0.8',
            outbound: 'DIRECT',
          ),
        ],
        firstCursor: 1,
        nextCursor: 2,
        retained: 2,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(
            recordId: 31,
            requestRecordId: 1,
            host: 'ok.example.com',
            method: 'GET',
            statusCode: 200,
            protocol: 'h1',
          ),
          _capture(
            recordId: 32,
            requestRecordId: 2,
            host: 'bad.example.com',
            method: 'POST',
            statusCode: 404,
            protocol: 'h2',
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    // 打开筛选 AppSheet。
    await tester.tap(find.byKey(const Key('requests_filter_open')));
    await tester.pumpAndSettle();
    expect(find.text('筛选'), findsWidgets);

    // 仅错误：只保留 404 的行。
    await tester.tap(find.byKey(const Key('requests_filter_errors_only')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('bad.example.com'), findsOneWidget);
    expect(find.text('ok.example.com'), findsNothing);

    // 再开筛选 -> 协议 h1：仅错误 + h1 => 无行（404 是 h2）。
    await tester.tap(find.byKey(const Key('requests_filter_open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_filter_protocol_h1')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('bad.example.com'), findsNothing);
    expect(find.text('无匹配请求'), findsOneWidget);

    // 重置筛选 -> 两行恢复。
    await tester.tap(find.byKey(const Key('requests_filter_open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_filter_reset')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('ok.example.com'), findsOneWidget);
    expect(find.text('bad.example.com'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('筛选过滤条件转发到 captures.get filter', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      capturePage: CapturePage(
        records: <CaptureRecord>[_capture(recordId: 1, requestRecordId: 1)],
      ),
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_filter_open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('requests_filter_method_GET')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(fake.lastCaptures, isNotNull);
    expect(fake.lastCaptures!.filter, isNotNull);
    expect(fake.lastCaptures!.filter!.method, 'GET');
    expect(tester.takeException(), isNull);
  });

  testWidgets('分析区：默认折叠，展开后显示 Top / 趋势 / DNS 质量', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(page: _samplePage());
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Top 域名'), findsNothing);
    await tester.tap(find.byKey(const Key('requests_analysis_toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Top 域名'), findsOneWidget);
    expect(find.text('时间线趋势'), findsOneWidget);
    expect(find.text('DNS 质量'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('超长域名 / 路径不溢出（大视口 + ensureVisible）', (tester) async {
    _useLargeViewport(tester);
    final longDomain = '${'a' * 300}.very-long-subdomain.example.com';
    final longPath = '/${'p' * 400}?q=${'8' * 200}';
    final longIp = '2001:0db8:${'1234:' * 12}abcd';
    final fake = _FakeRequestsFacade(
      page: RequestPage(
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
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(
            recordId: 88,
            requestRecordId: 77,
            host: longDomain,
            url: 'https://$longDomain$longPath',
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    await tester.ensureVisible(find.byKey(const ValueKey('request_row_77')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：captures.get 失败 -> requests 列表降级仍渲染，不报错', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      capturesFail: true,
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(fake.getCalls, 1);
    expect(fake.capturesCalls, 1);
    // requests 列表仍然完整渲染，全部降级为「未解密」。
    expect(find.byKey(const ValueKey('request_row_1')), findsOneWidget);
    expect(find.byKey(const ValueKey('request_row_2')), findsOneWidget);
    expect(find.text('未解密'), findsNWidgets(2));
    expect(find.textContaining('HTTP 详情不可用'), findsOneWidget);
    expect(find.text('请求列表不可用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：requests.get 失败 -> 显式错误态且不崩溃', (tester) async {
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

    controller.add(const ProxyRequestEvent(seq: 1, count: 3, tsMs: 10));
    await tester.pump();
    expect(fake.getCalls, 2);

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

    controller.add(const ProxyRequestEvent(seq: 2, count: 1, tsMs: 20));
    await tester.pump();
    expect(fake.getCalls, 3);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('抓包迷你开关：点击下发 capture.config.set(enabled)', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      captureConfig: _configOff,
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(fake.configGetCalls, 1);
    await tester.tap(find.byKey(const Key('requests_capture_toggle')));
    await tester.pumpAndSettle();

    expect(fake.configSetCalls, 1);
    expect(fake.lastConfigSet!.enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：抓包开关下发失败 -> showError 且开关回滚', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: _samplePage(),
      captureConfig: _configOff,
      configSetFail: true,
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_capture_toggle')));
    await tester.pumpAndSettle();

    expect(fake.configSetCalls, 1);
    expect(find.text('操作失败'), findsOneWidget);
    expect(find.textContaining('下发失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击请求行经统一 AppSheet 打开详情', (tester) async {
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

  testWidgets('点击抓包行 -> 进入全屏详情页且 recordId 正确（叠加行）', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 1)],
        firstCursor: 1,
        nextCursor: 1,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(
            recordId: 11,
            requestRecordId: 1,
            host: 'api.example.com',
            method: 'POST',
            url: 'https://api.example.com/v1/items',
            statusCode: 201,
          ),
        ],
      ),
    );
    final detailFacade = _FakeCaptureDetailFacade(
      value: const CaptureDetail(
        recordId: 11,
        requestRecordId: 1,
        host: 'api.example.com',
        method: 'POST',
        scheme: 'https',
        url: 'https://api.example.com/v1/items',
        statusCode: 201,
        protocol: 'h2',
      ),
    );
    final bridge = _FakeCaptureBridge();
    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          captureDetailFacade: detailFacade,
          captureActionBinder: CaptureDetailActionBinder(bridge: bridge),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('request_row_1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 必须真正进入全屏详情页（而非仅触发回调）。
    expect(
      find.byType(ProxyCaptureDetailPage),
      findsOneWidget,
      reason: '点击抓包行必须进入全屏详情页',
    );
    final page = tester.widget<ProxyCaptureDetailPage>(
      find.byType(ProxyCaptureDetailPage),
    );
    expect(page.recordId, 11, reason: '详情页必须携带该行 capture 的 recordId');
    expect(page.flow?.recordId, 1, reason: '骨架行的流记录应作为 flow 传入');
    expect(detailFacade.lastRecordId, 11, reason: '详情页应以正确 recordId 拉取');
    expect(find.text('https://api.example.com/v1/items'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击孤儿 capture 行 -> 全屏详情页 recordId 正确且 flow 为空',
      (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 7)],
        firstCursor: 7,
        nextCursor: 7,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(
            recordId: 5,
            requestRecordId: 0,
            host: 'orphan.test',
            method: 'PUT',
            url: 'https://orphan.test/x',
            statusCode: 500,
          ),
        ],
      ),
    );
    final detailFacade = _FakeCaptureDetailFacade(
      value: const CaptureDetail(
        recordId: 5,
        requestRecordId: 0,
        host: 'orphan.test',
        method: 'PUT',
        scheme: 'https',
        url: 'https://orphan.test/x',
        statusCode: 500,
        protocol: 'h1',
      ),
    );
    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          captureDetailFacade: detailFacade,
          captureActionBinder: CaptureDetailActionBinder(
            bridge: _FakeCaptureBridge(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('capture_row_5')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.byType(ProxyCaptureDetailPage), findsOneWidget);
    final page = tester.widget<ProxyCaptureDetailPage>(
      find.byType(ProxyCaptureDetailPage),
    );
    expect(page.recordId, 5);
    expect(page.flow, isNull, reason: '孤儿 capture 无流骨架，flow 应为空');
    expect(detailFacade.lastRecordId, 5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：capture.config.get 失败 -> 开关保持未知且列表可用', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(page: _samplePage(), configGetFail: true);
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    expect(fake.configGetCalls, 1);
    // 配置未读到 -> 开关显示未知/关闭，但列表仍完整渲染。
    expect(find.byKey(const Key('requests_capture_toggle')), findsOneWidget);
    expect(find.text('抓包'), findsOneWidget);
    expect(find.text('抓包中'), findsNothing);
    expect(find.byKey(const ValueKey('request_row_1')), findsOneWidget);
    expect(find.text('请求列表不可用'), findsNothing);
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

    await tester.pumpWidget(const SizedBox());
    controller.add(const ProxyRequestEvent(seq: 1, count: 1, tsMs: 1));
    await tester.pump(const Duration(seconds: 3));

    expect(fake.getCalls, before, reason: '卸载后不应再拉取');
    expect(tester.takeException(), isNull);
  });

  // ==================== 清空（D7：requests + captures 双清） ====================

  testWidgets('清空：确认后同时下发 captures.reset 与 requests.reset，解密行消失',
      (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 1)],
        firstCursor: 1,
        nextCursor: 1,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(
            recordId: 11,
            requestRecordId: 1,
            host: 'decrypted.example',
            method: 'GET',
            url: 'https://decrypted.example/secret',
            statusCode: 200,
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    // 前置：已解密行可见（叠加到 request_row_1 摘要）。
    expect(find.byKey(const ValueKey('request_row_1')), findsOneWidget);
    expect(find.text('decrypted.example'), findsOneWidget);

    await tester.tap(find.byKey(const Key('requests_reset')));
    await tester.pumpAndSettle();
    // 确认弹层必须声明同时清除抓包（含已解密）内容。
    expect(find.textContaining('抓包内容（含已解密内容）'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    // 两个 reset 都必须被调用，且抓包先于请求清空。
    expect(fake.capturesResetCalls, 1, reason: 'captures.reset 必须被调用');
    expect(fake.resetCalls, 1, reason: 'requests.reset 必须被调用');
    expect(fake.resetOrder, <String>['captures', 'requests']);
    expect(find.text('已清空请求记录'), findsOneWidget);

    // reload 路径：清空后解密行消失（不残留 captures.* 独立行）。
    expect(find.byKey(const ValueKey('request_row_1')), findsNothing);
    expect(find.text('decrypted.example'), findsNothing);
    expect(find.text('暂无请求记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：captures.reset 失败 -> showError、不调用 requests.reset、不提示成功',
      (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 1)],
        firstCursor: 1,
        nextCursor: 1,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(recordId: 11, requestRecordId: 1, host: 'decrypted.example'),
        ],
      ),
      capturesResetFail: true,
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(fake.capturesResetCalls, 1);
    expect(fake.resetCalls, 0, reason: '抓包清空失败后不得继续清空请求');
    expect(find.text('清空失败'), findsOneWidget);
    expect(find.textContaining('抓包清空失败'), findsOneWidget);
    expect(find.text('已清空请求记录'), findsNothing);
    // 抓包未清 -> 解密行仍在。
    expect(find.text('decrypted.example'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：requests.reset 失败 -> showError、不提示成功', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 1)],
        firstCursor: 1,
        nextCursor: 1,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(recordId: 11, requestRecordId: 1, host: 'decrypted.example'),
        ],
      ),
      resetFail: true,
    );
    await tester.pumpWidget(
      _host(ProxyRequestsPage(facade: fake, initialLive: false)),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('requests_reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(fake.capturesResetCalls, 1);
    expect(fake.resetCalls, 1);
    expect(find.text('清空失败'), findsOneWidget);
    expect(find.textContaining('请求清空失败'), findsOneWidget);
    expect(find.text('已清空请求记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // ==================== 导出 UI（保留） ====================

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
    expect(save.extensions.single, <String>['csv']);
    expect(save.byteLengths.single, 3);
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

  // ==================== D8b：详情页删除该记录 → 返回后列表刷新 ====================

  testWidgets('删除：详情页确认删除携带正确 recordId，pop 后触发列表 _load 刷新',
      (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 1)],
        firstCursor: 1,
        nextCursor: 1,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(
            recordId: 11,
            requestRecordId: 1,
            host: 'api.example.com',
            method: 'POST',
            url: 'https://api.example.com/v1/items',
            statusCode: 201,
          ),
        ],
      ),
    );
    final detailFacade = _FakeCaptureDetailFacade(
      value: const CaptureDetail(
        recordId: 11,
        requestRecordId: 1,
        host: 'api.example.com',
        method: 'POST',
        scheme: 'https',
        url: 'https://api.example.com/v1/items',
        statusCode: 201,
        protocol: 'h2',
      ),
    );
    final deleteFacade = _FakeCaptureDeleteFacade();
    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          captureDetailFacade: detailFacade,
          captureDeleteFacade: deleteFacade,
          captureActionBinder: CaptureDetailActionBinder(
            bridge: _FakeCaptureBridge(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final beforeGet = fake.getCalls;
    final beforeCaptures = fake.capturesCalls;

    // 进入全屏详情页。
    await tester.tap(find.byKey(const ValueKey('request_row_1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(ProxyCaptureDetailPage), findsOneWidget);

    // 动作菜单 → 删除该记录 → 确认。
    await tester.tap(find.byKey(const Key('detail_actions_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail_delete_record')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 对抗：必须真的携带该行 capture 的 recordId，而非空/其它 id。
    expect(deleteFacade.calls, 1, reason: '确认后必须调用 delete 一次');
    expect(
      deleteFacade.lastRecordId,
      11,
      reason: '必须删除该行 capture 的 recordId',
    );
    expect(
      find.byType(ProxyCaptureDetailPage),
      findsNothing,
      reason: '删除成功后必须 pop 返回列表',
    );
    // 关键：pop 之后列表必须重新 _load（requests.get + captures.get 各再拉一次），
    // 而不是仅弹了个提示。
    expect(
      fake.getCalls,
      beforeGet + 1,
      reason: '返回列表后必须触发 requests.get 重新拉取',
    );
    expect(
      fake.capturesCalls,
      beforeCaptures + 1,
      reason: '返回列表后必须触发 captures.get 重新拉取',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('对抗：详情页取消失败均不刷新列表（返回才刷新）', (tester) async {
    _useLargeViewport(tester);
    final fake = _FakeRequestsFacade(
      page: RequestPage(
        records: <RequestRecord>[_record(recordId: 1)],
        firstCursor: 1,
        nextCursor: 1,
        retained: 1,
      ),
      capturePage: CapturePage(
        records: <CaptureRecord>[
          _capture(recordId: 11, requestRecordId: 1, host: 'api.example.com'),
        ],
      ),
    );
    final detailFacade = _FakeCaptureDetailFacade(
      value: const CaptureDetail(
        recordId: 11,
        requestRecordId: 1,
        host: 'api.example.com',
        method: 'GET',
        scheme: 'https',
        url: 'https://api.example.com/v1/items',
        statusCode: 200,
        protocol: 'h1',
      ),
    );
    final deleteFacade = _FakeCaptureDeleteFacade(fail: true);
    await tester.pumpWidget(
      _host(
        ProxyRequestsPage(
          facade: fake,
          initialLive: false,
          captureDetailFacade: detailFacade,
          captureDeleteFacade: deleteFacade,
          captureActionBinder: CaptureDetailActionBinder(
            bridge: _FakeCaptureBridge(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final beforeGet = fake.getCalls;

    await tester.tap(find.byKey(const ValueKey('request_row_1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    await tester.tap(find.byKey(const Key('detail_actions_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail_delete_record')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 失败：showError、留在详情页、列表不被刷新。
    expect(deleteFacade.calls, 1);
    expect(find.byType(ProxyCaptureDetailPage), findsOneWidget);
    expect(find.text('删除失败'), findsWidgets);
    expect(
      fake.getCalls,
      beforeGet,
      reason: '删除失败未 pop，不得触发列表刷新',
    );
    expect(tester.takeException(), isNull);
  });
}

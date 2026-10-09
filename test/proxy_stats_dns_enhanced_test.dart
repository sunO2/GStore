// Todo 26 widget tests：统计 / DNS 增强。
//
// 全部密闭式：只注入假门面（`ProxyStatsFacade` / `ProxyDnsFacade` /
// `ProxyRequestsFacade`），不触碰 FFI / 原生模块 / 网络。弹层宿主复用生产全局
// 通道 `appNavigatorKey` + `AppDialogs.scaffoldMessengerKey`，剪贴板经
// `SystemChannels.platform` mock 捕获。
//
// 覆盖：
// * 统计域名下钻 → 请求列表（携带域名筛选）；
// * 排序列 → 服务端 `stats.domain.get.sort` 键映射（无偏置）；
// * 统计复制域名 / 出站、导出 CSV；
// * DNS 近期查询 / 映射去除 20 条硬截断（展开 + 总数）、展示应答、复制；
// * 空统计显式空态。

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_dns_facade.dart';
import 'package:gstore/page/proxy/proxy_dns_page.dart';
import 'package:gstore/page/proxy/proxy_requests_facade.dart';
import 'package:gstore/page/proxy/proxy_requests_page.dart';
import 'package:gstore/page/proxy/proxy_stats_facade.dart';
import 'package:gstore/page/proxy/proxy_stats_helpers.dart';
import 'package:gstore/page/proxy/proxy_stats_page.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

void _useLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 捕获 `Clipboard.setData` 文本。
List<String> _captureClipboard(WidgetTester tester) {
  final captured = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments;
        if (args is Map && args['text'] is String) {
          captured.add(args['text'] as String);
        }
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return captured;
}

// ==================== 假门面 ====================

class _FakeStatsFacade implements ProxyStatsFacade {
  _FakeStatsFacade(
    this.domains, {
    this.traffic = const TrafficSnapshot(),
  });

  List<DomainStat> domains;
  TrafficSnapshot traffic;
  StatsDomainGetRequest? lastRequest;

  @override
  Future<DomainPage> statsDomainGet(StatsDomainGetRequest request) async {
    lastRequest = request;
    return DomainPage(
      domains: domains,
      count: domains.length,
      returned: domains.length,
      sort: request.sort ?? 'bytes',
      rangeMs: request.rangeMs ?? 0,
    );
  }

  @override
  Future<TrafficSnapshot> statsTrafficGet(StatsTrafficGetRequest request) async =>
      traffic;

  @override
  Future<StatsResetResult> statsDomainReset() async {
    final cleared = domains.length;
    domains = const <DomainStat>[];
    return StatsResetResult(ok: true, cleared: cleared);
  }
}

class _FakeDnsFacade implements ProxyDnsFacade {
  _FakeDnsFacade(this.snapshot);

  DnsSnapshot snapshot;

  @override
  Future<DnsSnapshot> dnsGet() async => snapshot;

  @override
  Future<DnsSetResult> dnsSet(Map<String, dynamic> payload) async =>
      DnsSetResult(ok: true, config: DnsConfig.fromJson(payload));

  @override
  Future<DnsClearResult> dnsClearCache() async =>
      const DnsClearResult(ok: true, flushed: 0);
}

/// 统计 CSV 另存接缝的假实现。
class _FakeStatsSaveFile {
  _FakeStatsSaveFile({this.result = '/tmp/stats.csv'});

  String? result;
  final List<String> fileNames = <String>[];
  final List<List<String>> extensions = <List<String>>[];
  Uint8List? lastBytes;

  Future<String?> call({
    required String fileName,
    required Uint8List bytes,
    required List<String> allowedExtensions,
  }) async {
    fileNames.add(fileName);
    extensions.add(allowedExtensions);
    lastBytes = bytes;
    return result;
  }
}

/// 请求列表页的最小假门面（仅用于验证下钻筛选透传）。
class _FakeRequestsFacade implements ProxyRequestsFacade {
  _FakeRequestsFacade(this.page);

  RequestPage page;

  @override
  Future<RequestPage> requestsGet(RequestGetRequest request) async => page;

  @override
  Future<void> requestsReset() async {}

  @override
  Future<void> capturesReset() async {}

  @override
  Future<RequestExportResult> requestsExport(
    RequestExportRequest request,
  ) async =>
      const RequestExportResult();

  @override
  Future<CapturePage> capturesGet(CapturesGetRequest request) async =>
      const CapturePage();

  @override
  Future<CaptureConfig> captureConfigGet() async =>
      const CaptureConfig(enabled: false);

  @override
  Future<CaptureConfig> captureConfigSet(CaptureConfig config) async => config;
}

// ==================== 夹具 ====================

const List<DomainStat> _statsFixture = [
  DomainStat(
    domain: 'b.example',
    connections: 2,
    uploadBytes: 200,
    downloadBytes: 5000,
    lastSeenMs: 1700000000000,
    rule: 'DOMAIN-SUFFIX',
    rulePayload: 'b.example',
    outbound: 'proxy',
  ),
  DomainStat(
    domain: 'a.example',
    connections: 10,
    uploadBytes: 100,
    downloadBytes: 1000,
    lastSeenMs: 1690000000000,
    rule: 'MATCH',
    outbound: 'DIRECT',
  ),
];

DnsSnapshot _dnsMany() => DnsSnapshot(
      mode: 'fake-ip',
      config: const DnsConfig(mode: 'fake-ip', nameservers: ['1.1.1.1']),
      stats: const DnsStats(queries: 25, failures: 0, cacheEntries: 25),
      mappings: [
        for (var i = 0; i < 25; i++)
          DnsMapping(
            domain: 'host$i.example',
            ip: '198.18.0.${i + 1}',
            fake: true,
          ),
      ],
      recentQueries: [
        for (var i = 0; i < 25; i++)
          DnsQueryRecord(
            tsMs: 1700000000000 + i,
            domain: 'q$i.example',
            qtype: 'A',
            rcode: 'NoError',
            ok: true,
            latencyMs: 5,
            answers: ['1.2.3.$i'],
          ),
      ],
    );

RequestRecord _request(int recordId, String domain) => RequestRecord(
      recordId: recordId,
      connId: 'c-$recordId',
      openTsMs: 1700000000000 + recordId,
      closeTsMs: 1700000000000 + recordId + 10,
      durationMs: 10,
      domain: domain,
      domainKnown: true,
      dstIp: '93.184.216.34',
      dstPort: 443,
      src: '10.0.0.2:5555',
      network: 'tcp',
      uid: 10123,
      packages: const <String>['com.example.app'],
      uidState: ProxyUidState.known,
      rule: 'MATCH',
      rulePayload: domain,
      outbound: 'PROXY',
      uploadBytes: 10,
      downloadBytes: 2048,
      closeReason: 'closed',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('统计：排序列 → 服务端 sort 键映射', () {
    test('纯映射：7 列逐一正确，无偏置（upload/download/outbound 无原生键）', () {
      expect(proxyStatsServerSortFor(ProxyStatSort.bytes), 'bytes');
      expect(proxyStatsServerSortFor(ProxyStatSort.connections), 'connections');
      expect(proxyStatsServerSortFor(ProxyStatSort.upload), isNull);
      expect(proxyStatsServerSortFor(ProxyStatSort.download), isNull);
      expect(proxyStatsServerSortFor(ProxyStatSort.lastSeen), 'lastSeen');
      expect(proxyStatsServerSortFor(ProxyStatSort.outbound), isNull);
      expect(proxyStatsServerSortFor(ProxyStatSort.domain), 'domain');

      // 枚举顺序即 UI 列顺序：按位置索引再断言一次，防「偏移」回归。
      expect(proxyStatsServerSortFor(ProxyStatSort.values[0]), 'bytes');
      expect(proxyStatsServerSortFor(ProxyStatSort.values[1]), 'connections');
      expect(proxyStatsServerSortFor(ProxyStatSort.values[4]), 'lastSeen');
      expect(proxyStatsServerSortFor(ProxyStatSort.values[6]), 'domain');

      // 任何非空键必须落在冻结契约允许集合内。
      for (final sort in ProxyStatSort.values) {
        final wire = proxyStatsServerSortFor(sort);
        if (wire != null) {
          expect(kStatsServerSortKeys, contains(wire));
        }
      }
    });

    testWidgets('widget：切换每列后下发的 sort 键正确', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeStatsFacade(List<DomainStat>.of(_statsFixture));
      await tester.pumpWidget(_host(ProxyStatsPage(facade: facade)));
      await tester.pumpAndSettle();

      expect(facade.lastRequest?.sort, 'bytes');

      await tester.tap(find.byKey(const Key('stats_sort_connections')));
      await tester.pumpAndSettle();
      expect(facade.lastRequest?.sort, 'connections');

      await tester.tap(find.byKey(const Key('stats_sort_upload')));
      await tester.pumpAndSettle();
      expect(facade.lastRequest?.sort, isNull);

      await tester.tap(find.byKey(const Key('stats_sort_download')));
      await tester.pumpAndSettle();
      expect(facade.lastRequest?.sort, isNull);

      await tester.tap(find.byKey(const Key('stats_sort_lastSeen')));
      await tester.pumpAndSettle();
      expect(facade.lastRequest?.sort, 'lastSeen');

      await tester.tap(find.byKey(const Key('stats_sort_outbound')));
      await tester.pumpAndSettle();
      expect(facade.lastRequest?.sort, isNull);

      await tester.tap(find.byKey(const Key('stats_sort_domain')));
      await tester.pumpAndSettle();
      expect(facade.lastRequest?.sort, 'domain');

      await tester.tap(find.byKey(const Key('stats_sort_bytes')));
      await tester.pumpAndSettle();
      expect(facade.lastRequest?.sort, 'bytes');
      expect(tester.takeException(), isNull);
    });
  });

  group('统计：下钻 / 复制 / 导出', () {
    testWidgets('下钻：点击域名卡片携带该域名筛选', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeStatsFacade(List<DomainStat>.of(_statsFixture));
      final drilled = <String>[];
      await tester.pumpWidget(_host(ProxyStatsPage(
        facade: facade,
        onDrilldown: (stat) => drilled.add(stat.domain),
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('stat_row_b.example')));
      await tester.pumpAndSettle();

      expect(drilled, ['b.example']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('下钻：请求列表按 initialDomain 本地过滤', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeRequestsFacade(
        RequestPage(
          records: [_request(1, 'a.example'), _request(2, 'b.example')],
          retained: 2,
        ),
      );
      await tester.pumpWidget(_host(ProxyRequestsPage(
        facade: facade,
        initialLive: false,
        initialDomain: 'a.example',
      )));
      await tester.pumpAndSettle();

      // 搜索框预填 'a.example'，列表仅保留匹配行（排除搜索框 EditableText）。
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == 'a.example'),
        findsOneWidget,
      );
      expect(find.text('b.example'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('复制：复制域名与出站到剪贴板', (tester) async {
      _useLargeViewport(tester);
      final clipboard = _captureClipboard(tester);
      final facade = _FakeStatsFacade(List<DomainStat>.of(_statsFixture));
      await tester.pumpWidget(_host(ProxyStatsPage(facade: facade)));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('stat_copy_domain_b.example')),
      );
      await tester.tap(find.byKey(const Key('stat_copy_domain_b.example')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('stat_copy_outbound_b.example')),
      );
      await tester.tap(find.byKey(const Key('stat_copy_outbound_b.example')));
      await tester.pumpAndSettle();

      expect(clipboard, contains('b.example'));
      expect(clipboard, contains('proxy'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('导出：CSV 含表头与数据行并经另存接缝落盘', (tester) async {
      _useLargeViewport(tester);
      final saveFile = _FakeStatsSaveFile();
      final facade = _FakeStatsFacade(List<DomainStat>.of(_statsFixture));
      await tester.pumpWidget(_host(ProxyStatsPage(
        facade: facade,
        saveFile: saveFile.call,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('stats_export')));
      await tester.pumpAndSettle();

      expect(saveFile.lastBytes, isNotNull);
      final csv = String.fromCharCodes(saveFile.lastBytes!);
      expect(csv, contains('domain,connections'));
      expect(csv, contains('b.example'));
      expect(csv, contains('proxy'));
      expect(saveFile.fileNames.single, endsWith('.csv'));
      expect(find.textContaining('已导出'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('DNS：去截断 / 应答 / 复制', () {
    testWidgets('近期查询与映射可展开超过 20 条并显示总数', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeDnsFacade(_dnsMany());
      await tester.pumpWidget(_host(ProxyDnsPage(facade: facade)));
      await tester.pumpAndSettle();

      // 总数提示（超过 20 条硬截断）
      expect(find.textContaining('共 25 条'), findsWidgets);
      // 默认只显示前 20 条：第 25 条不在树中
      expect(find.byKey(const Key('dns_query_24')), findsNothing);

      await tester.ensureVisible(find.byKey(const Key('dns_queries_more')));
      await tester.tap(find.byKey(const Key('dns_queries_more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dns_query_24')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('dns_mappings_more')));
      await tester.tap(find.byKey(const Key('dns_mappings_more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dns_mapping_24')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('展示应答记录', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeDnsFacade(_dnsMany());
      await tester.pumpWidget(_host(ProxyDnsPage(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dns_query_answers_0')), findsOneWidget);
      expect(find.textContaining('1.2.3.0'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('复制：查询域名与映射', (tester) async {
      _useLargeViewport(tester);
      final clipboard = _captureClipboard(tester);
      final facade = _FakeDnsFacade(_dnsMany());
      await tester.pumpWidget(_host(ProxyDnsPage(facade: facade)));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('dns_copy_query_0')));
      await tester.tap(find.byKey(const Key('dns_copy_query_0')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('dns_copy_mapping_0')));
      await tester.tap(find.byKey(const Key('dns_copy_mapping_0')));
      await tester.pumpAndSettle();

      expect(clipboard, contains('q0.example'));
      expect(clipboard, contains('host0.example 198.18.0.1'));
      expect(tester.takeException(), isNull);
    });
  });

  group('统计：空态', () {
    testWidgets('空统计渲染显式空态而非空白', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeStatsFacade(const <DomainStat>[]);
      await tester.pumpWidget(_host(ProxyStatsPage(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.text('暂无域名统计'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

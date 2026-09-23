// Todo 22 widget tests：DNS 设置 / 域名统计看板。
//
// 全部为密闭式：只注入假门面（`ProxyDnsFacade` / `ProxyStatsFacade`），
// 不触碰 FFI / 原生模块 / 网络。弹层宿主复用生产全局通道 `appNavigatorKey`
// + `AppDialogs.scaffoldMessengerKey`，因此走的是真实的
// `AppSheet` / `AppDialogs` 呈现路径。
//
// 覆盖：
// * happy：DNS 表单经统一弹层保存（`dns.set`）、统计按字节/连接排序并重置
//   （危险确认弹层）。
// * failure：空统计渲染显式空态（非空白、不崩溃）。
//
// 注：运行日志查看器 UI 已移除，其 `log.*` 能力保留；
// 契约仍在 `proxy_contract_test.dart` 中被校验。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_dns_facade.dart';
import 'package:gstore/page/proxy/proxy_dns_page.dart';
import 'package:gstore/page/proxy/proxy_stats_facade.dart';
import 'package:gstore/page/proxy/proxy_stats_page.dart';

// ==================== 测试宿主 ====================

/// 与 `lib/main.dart` 相同的全局通道（Navigator / ScaffoldMessenger）。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 放大测试视口：统计页新增总览后，Sliver 懒加载需要更大视口才能同屏
/// 渲染总览 + 控件 + 多张域名卡片（不影响断言强度）。
void _useLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

// ==================== 假门面 ====================

class _FakeDnsFacade implements ProxyDnsFacade {
  _FakeDnsFacade(this.snapshot);

  DnsSnapshot snapshot;
  int clearCalls = 0;
  Map<String, dynamic>? lastSetPayload;

  @override
  Future<DnsSnapshot> dnsGet() async => snapshot;

  @override
  Future<DnsSetResult> dnsSet(Map<String, dynamic> payload) async {
    lastSetPayload = payload;
    return DnsSetResult(
      ok: true,
      config: DnsConfig.fromJson(payload),
    );
  }

  @override
  Future<DnsClearResult> dnsClearCache() async {
    clearCalls++;
    return const DnsClearResult(ok: true, flushed: 3);
  }
}

class _FakeStatsFacade implements ProxyStatsFacade {
  _FakeStatsFacade(
    this.domains, {
    this.traffic = const TrafficSnapshot(),
    this.failTraffic = false,
    this.failDomains = false,
  });

  List<DomainStat> domains;
  TrafficSnapshot traffic;
  bool failTraffic;
  bool failDomains;
  int resetCalls = 0;
  int domainCalls = 0;
  int trafficCalls = 0;
  StatsDomainGetRequest? lastRequest;
  StatsTrafficGetRequest? lastTrafficRequest;

  @override
  Future<DomainPage> statsDomainGet(StatsDomainGetRequest request) async {
    domainCalls++;
    lastRequest = request;
    if (failDomains) {
      throw const ProxyModuleException(
        code: 'TEST_DOMAIN_FAIL',
        message: 'domain boom',
      );
    }
    return DomainPage(
      domains: domains,
      count: domains.length,
      returned: domains.length,
      sort: request.sort ?? 'bytes',
      rangeMs: request.rangeMs ?? 0,
    );
  }

  @override
  Future<TrafficSnapshot> statsTrafficGet(StatsTrafficGetRequest request) async {
    trafficCalls++;
    lastTrafficRequest = request;
    if (failTraffic) {
      throw const ProxyModuleException(
        code: 'TEST_TRAFFIC_FAIL',
        message: 'traffic boom',
      );
    }
    return traffic;
  }

  @override
  Future<StatsResetResult> statsDomainReset() async {
    resetCalls++;
    final cleared = domains.length;
    domains = const <DomainStat>[];
    return StatsResetResult(ok: true, cleared: cleared);
  }
}

// ==================== 夹具 ====================

const DnsSnapshot _dnsFixture = DnsSnapshot(
  mode: 'fake-ip',
  config: DnsConfig(
    mode: 'fake-ip',
    nameservers: ['1.1.1.1'],
    fallback: ['8.8.8.8'],
    doh: ['https://dns.example/dns-query'],
  ),
  stats: DnsStats(
    queries: 12,
    failures: 1,
    cacheEntries: 5,
    fakeIpActive: true,
    fakeIpRange: '198.18.0.0/16',
  ),
  mappings: [
    DnsMapping(domain: 'example.com', ip: '198.18.0.1', fake: true),
  ],
  recentQueries: [
    DnsQueryRecord(
      tsMs: 1700000000000,
      domain: 'example.com',
      qtype: 'A',
      rcode: 'NOERROR',
      ok: true,
      latencyMs: 8,
    ),
  ],
);

/// 高级字段全量夹具：用于验证回填与「清空」语义。
const DnsSnapshot _dnsAdvancedFixture = DnsSnapshot(
  mode: 'fake-ip',
  config: DnsConfig(
    mode: 'fake-ip',
    nameservers: ['1.1.1.1'],
    fallback: ['8.8.8.8'],
    doh: ['https://dns.example/dns-query'],
    dot: ['tls://1.1.1.1:853'],
    defaultNameservers: ['223.5.5.5'],
    fakeIpRange: '198.18.0.0/16',
    fakeIpRangeV6: 'fdfe:dcba:9876::/48',
    fakeIpTtlMs: 300,
    fakeIpFilter: ['filter.example'],
    fakeIpFilterMode: 'whitelist',
    useHosts: false,
    ipv6: false,
    hijack: false,
    hosts: {'example.com': ['1.2.3.4', '5.6.7.8']},
  ),
  stats: DnsStats(queries: 1, failures: 0, cacheEntries: 0),
);

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

/// `stats.traffic.get` 夹具：总量 / 速率 / 活动连接 / Top 域名。
const TrafficSnapshot _trafficFixture = TrafficSnapshot(
  uploadBytes: 1024,
  downloadBytes: 2 * 1024 * 1024,
  activeConns: 3,
  upBps: 100,
  downBps: 2048,
  domainCount: 2,
  topDomains: [
    DomainStat(
      domain: 'top.example',
      connections: 5,
      uploadBytes: 512,
      downloadBytes: 1536,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProxyDnsPage（Todo 22a）', () {
    testWidgets('happy：渲染 fixture 并经受控弹层保存 dns.set', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeDnsFacade(_dnsFixture);
      await tester.pumpWidget(_host(ProxyDnsPage(facade: facade)));
      await tester.pumpAndSettle();

      // 渲染配置 / 统计 / 近期查询 / 映射
      expect(find.text('fake-ip'), findsOneWidget);
      expect(find.text('1.1.1.1'), findsOneWidget);
      expect(find.text('8.8.8.8'), findsOneWidget);
      expect(find.textContaining('198.18.0.0/16'), findsOneWidget);
      expect(find.text('example.com'), findsWidgets);

      // 打开编辑表单（统一 AppSheet）
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('DNS 配置'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('dns_nameservers_field')),
        '9.9.9.9',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(facade.lastSetPayload, isNotNull);
      expect(facade.lastSetPayload!['mode'], 'fake-ip');
      expect(
        (facade.lastSetPayload!['nameservers'] as List).cast<String>(),
        ['9.9.9.9'],
      );
      // 新增字段在未编辑时也显式提交（空集合 / null），保证「清空」语义确定。
      expect(facade.lastSetPayload!['defaultNameservers'], isEmpty);
      expect(facade.lastSetPayload!['fakeIpRange'], isNull);
      expect(facade.lastSetPayload!['fakeIpRangeV6'], isNull);
      expect(facade.lastSetPayload!['fakeIpTtlMs'], isNull);
      expect(facade.lastSetPayload!['fakeIpFilter'], isEmpty);
      expect(facade.lastSetPayload!['fakeIpFilterMode'], 'blacklist');
      expect(facade.lastSetPayload!['hosts'], isEmpty);
      expect(facade.lastSetPayload!['useHosts'], true);
      expect(facade.lastSetPayload!['ipv6'], true);
      expect(facade.lastSetPayload!['hijack'], true);
      // 弹层已关闭
      expect(find.text('DNS 配置'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('happy：高级字段回填、显式清空并可解析 hosts / 开关 / 过滤模式',
        (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeDnsFacade(_dnsAdvancedFixture);
      await tester.pumpWidget(_host(ProxyDnsPage(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      // 初始值回填到表单控件
      expect(
        find.descendant(
          of: find.byKey(const Key('dns_bootstrap_field')),
          matching: find.text('223.5.5.5'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('dns_fake_ip_range_field')),
          matching: find.text('198.18.0.0/16'),
        ),
        findsOneWidget,
      );

      // 清空可选标量：空文本 → null
      await tester.enterText(find.byKey(const Key('dns_fake_ip_range_field')), '');
      await tester.enterText(
        find.byKey(const Key('dns_fake_ip_range_v6_field')),
        '',
      );
      await tester.enterText(find.byKey(const Key('dns_fake_ip_ttl_field')), '');
      // 清空列表：空文本 → []
      await tester.enterText(find.byKey(const Key('dns_bootstrap_field')), '');
      await tester.enterText(find.byKey(const Key('dns_fake_ip_filter_field')), '');
      // hosts：合法行解析、坏行忽略
      await tester.enterText(
        find.byKey(const Key('dns_hosts_field')),
        'a.example 1.1.1.1\nbadline\nb.example 2.2.2.2,3.3.3.3\n',
      );

      // 过滤模式切到 blacklist
      await tester.tap(
        find.byKey(const Key('dns_fake_ip_filter_mode_blacklist')),
      );
      await tester.pumpAndSettle();

      // 开关初始 false → 切到 true
      for (final key in const [
        'dns_use_hosts_switch',
        'dns_ipv6_switch',
        'dns_hijack_switch',
      ]) {
        final finder = find.byKey(Key(key));
        await tester.ensureVisible(finder);
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final payload = facade.lastSetPayload!;
      expect(payload['defaultNameservers'], isEmpty);
      expect(payload['fakeIpRange'], isNull);
      expect(payload['fakeIpRangeV6'], isNull);
      expect(payload['fakeIpTtlMs'], isNull);
      expect(payload['fakeIpFilter'], isEmpty);
      expect(payload['fakeIpFilterMode'], 'blacklist');
      expect(payload['useHosts'], true);
      expect(payload['ipv6'], true);
      expect(payload['hijack'], true);
      expect(payload['hosts'], {
        'a.example': ['1.1.1.1'],
        'b.example': ['2.2.2.2', '3.3.3.3'],
      });
      expect(find.text('DNS 配置'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failure：非数字 fake-IP TTL 显示错误且不提交 dns.set', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeDnsFacade(_dnsFixture);
      await tester.pumpWidget(_host(ProxyDnsPage(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('dns_fake_ip_ttl_field')),
        'abc',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(facade.lastSetPayload, isNull);
      expect(find.text('fake-IP TTL 需为整数（毫秒）'), findsOneWidget);
      expect(find.text('DNS 配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('happy：清空缓存走危险确认弹层后调用 dns.clear_cache', (tester) async {
      final facade = _FakeDnsFacade(_dnsFixture);
      await tester.pumpWidget(_host(ProxyDnsPage(facade: facade)));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('清空缓存'));
      await tester.pumpAndSettle();
      expect(find.text('清空 DNS 缓存'), findsOneWidget);

      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();

      expect(facade.clearCalls, 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('ProxyStatsPage（Todo 22c）', () {
    testWidgets('happy：渲染 fixture、按字节排序、切连接数并危险确认重置', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeStatsFacade(
        List<DomainStat>.of(_statsFixture),
        traffic: _trafficFixture,
      );
      await tester.pumpWidget(_host(ProxyStatsPage(facade: facade)));
      await tester.pumpAndSettle();

      // 默认按字节降序：b(5200) 在 a(1100) 之上
      expect(facade.lastRequest?.sort, 'bytes');
      final yb = tester
          .getTopLeft(find.byKey(const ValueKey('stat_row_b.example')))
          .dy;
      final ya = tester
          .getTopLeft(find.byKey(const ValueKey('stat_row_a.example')))
          .dy;
      expect(yb, lessThan(ya));

      // 切换按连接数排序 → 重新拉取 sort=connections，且 a(10) 在 b(2) 之上
      await tester.tap(find.byKey(const Key('stats_sort_connections')));
      await tester.pumpAndSettle();

      expect(facade.lastRequest?.sort, 'connections');
      final yb2 = tester
          .getTopLeft(find.byKey(const ValueKey('stat_row_b.example')))
          .dy;
      final ya2 = tester
          .getTopLeft(find.byKey(const ValueKey('stat_row_a.example')))
          .dy;
      expect(ya2, lessThan(yb2));

      // 重置：危险确认弹层 → stats.domain.reset → 空态
      await tester.tap(find.byTooltip('重置统计'));
      await tester.pumpAndSettle();
      expect(find.text('重置域名统计'), findsOneWidget);

      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();

      expect(facade.resetCalls, 1);
      expect(find.text('暂无域名统计'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('happy：流量总览渲染后端聚合值（总量 / 速率 / 活动连接 / Top）', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeStatsFacade(
        const <DomainStat>[],
        traffic: _trafficFixture,
      );
      await tester.pumpWidget(_host(ProxyStatsPage(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.text('流量总览'), findsOneWidget);
      // 请求了 Top 域名条数，后端字段用于展示（Dart 不聚合）。
      expect(facade.lastTrafficRequest?.topDomains, 5);
      expect(find.text('1.00 KB'), findsOneWidget); // 上传总量
      expect(find.text('100 B/s'), findsOneWidget); // 上行速率
      expect(find.text('2.00 MB'), findsOneWidget); // 下载总量
      expect(find.text('2.00 KB/s'), findsOneWidget); // 下行速率
      expect(find.text('3'), findsOneWidget); // 活动连接
      expect(find.text('Top 域名'), findsOneWidget);
      expect(find.text('top.example'), findsOneWidget);
      expect(find.text('512 B'), findsOneWidget); // Top 域名上行
      expect(find.text('1.50 KB'), findsOneWidget); // Top 域名下行
      expect(tester.takeException(), isNull);
    });

    testWidgets('happy：实时开关每 2s 重拉总览与域名，关闭后停止', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeStatsFacade(
        List<DomainStat>.of(_statsFixture),
        traffic: _trafficFixture,
      );
      await tester.pumpWidget(_host(ProxyStatsPage(facade: facade)));
      await tester.pumpAndSettle();

      expect(facade.trafficCalls, 1);
      expect(facade.domainCalls, 1);

      // 打开实时刷新
      await tester.tap(find.byKey(const Key('stats_live_toggle')));
      await tester.pumpAndSettle();

      // 2s 后触发一次重拉（总览 + 域名都被重拉）
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(facade.trafficCalls, 2);
      expect(facade.domainCalls, 2);

      // 关闭实时 → 定时器取消，不再重拉
      await tester.tap(find.byKey(const Key('stats_live_toggle')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(facade.trafficCalls, 2);
      expect(facade.domainCalls, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failure：总览与表格分别渲染错误态并可重试', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeStatsFacade(
        const <DomainStat>[],
        traffic: _trafficFixture,
        failTraffic: true,
        failDomains: true,
      );
      await tester.pumpWidget(_host(ProxyStatsPage(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.text('traffic boom'), findsOneWidget);
      expect(find.text('domain boom'), findsOneWidget);
      expect(find.text('统计不可用'), findsOneWidget);
      expect(find.text('重试'), findsWidgets);

      // 恢复后点总览内联重试 → 总览渲染成功数据
      facade.failTraffic = false;
      await tester.tap(find.text('重试').first);
      await tester.pumpAndSettle();
      expect(find.text('top.example'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('failure：空统计渲染显式空态而非空白', (tester) async {
      _useLargeViewport(tester);
      final facade = _FakeStatsFacade(const <DomainStat>[]);
      await tester.pumpWidget(_host(ProxyStatsPage(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.text('暂无域名统计'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

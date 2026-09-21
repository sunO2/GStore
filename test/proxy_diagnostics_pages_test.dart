// Todo 22 widget tests：DNS 设置 / 日志查看器 / 域名统计看板。
//
// 全部为密闭式：只注入假门面（`ProxyDnsFacade` / `ProxyLogsFacade` /
// `ProxyStatsFacade`）与假日志源，不触碰 FFI / 原生模块 / 网络。弹层宿主复用
// 生产全局通道 `appNavigatorKey` + `AppDialogs.scaffoldMessengerKey`，因此
// 走的是真实的 `AppSheet` / `AppDialogs` 呈现路径。
//
// 覆盖：
// * happy：DNS 表单经统一弹层保存（`dns.set`）、日志按级别过滤（`log.set_level`）
//   与搜索/复制、统计按字节/连接排序并重置（危险确认弹层）。
// * failure：空统计 / 无日志渲染显式空态（非空白、不崩溃）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_dns_facade.dart';
import 'package:gstore/page/proxy/proxy_dns_page.dart';
import 'package:gstore/page/proxy/proxy_logs_facade.dart';
import 'package:gstore/page/proxy/proxy_logs_page.dart';
import 'package:gstore/page/proxy/proxy_stats_facade.dart';
import 'package:gstore/page/proxy/proxy_stats_page.dart';

// ==================== 测试宿主 ====================

/// 与 `lib/main.dart` 相同的全局通道（Navigator / ScaffoldMessenger）。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

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
      config: DnsConfig(
        mode: payload['mode']?.toString() ?? 'fake-ip',
        nameservers: (payload['nameservers'] as List?)?.cast<String>() ?? const [],
      ),
    );
  }

  @override
  Future<DnsClearResult> dnsClearCache() async {
    clearCalls++;
    return const DnsClearResult(ok: true, flushed: 3);
  }
}

class _FakeLogSource implements ProxyLogSource {
  _FakeLogSource(this._entries);

  final List<LogEntry> _entries;
  final StreamController<List<LogEntry>> _controller =
      StreamController<List<LogEntry>>.broadcast();

  @override
  List<LogEntry> get logs => _entries;

  @override
  Stream<List<LogEntry>> get stream => _controller.stream;

  Future<void> close() => _controller.close();
}

class _FakeLogsFacade implements ProxyLogsFacade {
  LogPage page = const LogPage();
  final List<String> setLevels = <String>[];
  LogGetRequest? lastRequest;

  @override
  Future<LogPage> logGet(LogGetRequest request) async {
    lastRequest = request;
    return page;
  }

  @override
  Future<LogSetLevelResult> logSetLevel(String level) async {
    setLevels.add(level);
    return LogSetLevelResult(ok: true, level: ProxyLogLevel.fromWire(level));
  }
}

class _FakeStatsFacade implements ProxyStatsFacade {
  _FakeStatsFacade(this.domains);

  List<DomainStat> domains;
  int resetCalls = 0;
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProxyDnsPage（Todo 22a）', () {
    testWidgets('happy：渲染 fixture 并经受控弹层保存 dns.set', (tester) async {
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
      // 弹层已关闭
      expect(find.text('DNS 配置'), findsNothing);
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

  group('ProxyLogsPage（Todo 22b）', () {
    testWidgets('happy：级别过滤经 log.set_level，搜索与复制可用', (tester) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );

      final source = _FakeLogSource([
        LogEntry(
          level: LogLevel.info,
          message: 'info-line',
          timestamp: DateTime(2026, 1, 1, 10, 0, 0),
        ),
        LogEntry(
          level: LogLevel.error,
          message: 'error-line',
          timestamp: DateTime(2026, 1, 1, 10, 0, 1),
        ),
      ]);
      final facade = _FakeLogsFacade();
      await tester.pumpWidget(
        _host(ProxyLogsPage(facade: facade, logSource: source)),
      );
      await tester.pumpAndSettle();

      // 默认 info 级别：两条都显示
      expect(find.text('info-line'), findsOneWidget);
      expect(find.text('error-line'), findsOneWidget);

      // 切到 ERROR：info 被过滤，且调用 log.set_level
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('log_level_selector')),
          matching: find.text('ERROR'),
        ),
      );
      await tester.pumpAndSettle();

      expect(facade.setLevels, contains('error'));
      expect(facade.lastRequest?.level, 'error');
      expect(find.text('info-line'), findsNothing);
      expect(find.text('error-line'), findsOneWidget);

      // 复制该行 → 剪贴板收到内容
      await tester.tap(find.byIcon(Icons.copy));
      await tester.pumpAndSettle();
      expect(clipboardText, contains('error-line'));

      // 搜索：无匹配时显示显式空态
      await tester.enterText(
        find.byKey(const Key('log_search_field')),
        'no-such-entry',
      );
      await tester.pumpAndSettle();
      expect(find.text('无匹配日志'), findsOneWidget);

      await source.close();
      expect(tester.takeException(), isNull);
    });

    testWidgets('failure：无日志渲染显式空态而非空白', (tester) async {
      final source = _FakeLogSource(const <LogEntry>[]);
      final facade = _FakeLogsFacade();
      await tester.pumpWidget(
        _host(ProxyLogsPage(facade: facade, logSource: source)),
      );
      await tester.pumpAndSettle();

      expect(find.text('暂无日志'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await source.close();
    });
  });

  group('ProxyStatsPage（Todo 22c）', () {
    testWidgets('happy：渲染 fixture、按字节排序、切连接数并危险确认重置', (tester) async {
      final facade = _FakeStatsFacade(List<DomainStat>.of(_statsFixture));
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

    testWidgets('failure：空统计渲染显式空态而非空白', (tester) async {
      final facade = _FakeStatsFacade(const <DomainStat>[]);
      await tester.pumpWidget(_host(ProxyStatsPage(facade: facade)));
      await tester.pumpAndSettle();

      expect(find.text('暂无域名统计'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

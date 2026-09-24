import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/page/proxy/proxy_site_probe.dart';
import 'package:gstore/page/proxy/proxy_site_probe_card.dart';

const List<SiteProbeTarget> _catalog = <SiteProbeTarget>[
  SiteProbeTarget(
    label: 'Claude',
    url: 'https://claude.ai/robots.txt',
    method: 'GET',
  ),
  SiteProbeTarget(
    label: 'Google',
    url: 'https://www.gstatic.com/generate_204',
    method: 'HEAD',
  ),
  SiteProbeTarget(
    label: 'Baidu',
    url: 'https://www.baidu.com/robots.txt',
    method: 'GET',
  ),
];

/// 假探测核心：`probeAllStream` 返回可控流，测试自行逐站发射 / 完成。
class _FakeProbe extends SiteProbe {
  _FakeProbe() : super(targets: _catalog);

  int probeCalls = 0;

  /// 订阅被取消（卡片 dispose）的次数。
  int cancelCount = 0;

  /// 最近一次 `probeAllStream()` 创建的控制器（点按后才非空）。
  StreamController<SiteProbeResult>? controller;

  @override
  Stream<SiteProbeResult> probeAllStream() {
    probeCalls++;
    final StreamController<SiteProbeResult> c =
        StreamController<SiteProbeResult>();
    c.onCancel = () => cancelCount++;
    controller = c;
    return c.stream;
  }

  /// 当前运行的流控制器；未运行时抛错以暴露测试错误。
  StreamController<SiteProbeResult> get _active {
    final StreamController<SiteProbeResult>? c = controller;
    if (c == null) {
      throw StateError('probeAllStream 尚未被调用');
    }
    return c;
  }

  /// 发射一条逐站结果。
  void emit(SiteProbeResult result) => _active.add(result);

  /// 关闭流（模拟全部站点完成）。
  Future<void> finish() => _active.close();
}

SiteProbeResult _result(
  SiteProbeTarget target,
  SiteProbeVerdict verdict, {
  int? status,
  int? ms,
}) =>
    SiteProbeResult(
      target: target,
      verdict: verdict,
      statusCode: status,
      latencyMs: ms,
    );

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Color _chipColor(WidgetTester tester, String label, String text) {
  final Finder finder = find.descendant(
    of: find.byKey(Key('proxy-site-probe-row-$label')),
    matching: find.text(text),
  );
  return tester.widget<Text>(finder).style!.color!;
}

void main() {
  testWidgets('渲染标题/说明/按钮/逐站行/汇总；不在构建时自动探测', (tester) async {
    final probe = _FakeProbe();
    await tester.pumpWidget(_wrap(ProxySiteProbeCard(probe: probe)));

    expect(find.byKey(const Key('proxy-site-probe-card')), findsOneWidget);
    expect(find.text('网站连通性'), findsOneWidget);
    expect(find.text('检测遵循当前隧道与规则（未连接则直连）'), findsOneWidget);
    expect(find.byKey(const Key('proxy-site-probe-run')), findsOneWidget);
    expect(find.text('开始检测'), findsOneWidget);
    for (final SiteProbeTarget t in _catalog) {
      expect(find.byKey(Key('proxy-site-probe-row-${t.label}')), findsOneWidget);
    }
    expect(find.text('未检测'), findsNWidgets(_catalog.length));
    // 首次运行前不显示汇总（避免「0/3 可达」被误读为失败）。
    expect(find.byKey(const Key('proxy-site-probe-summary')), findsNothing);
    // 手动触发：构建后绝不自动探测。
    expect(probe.probeCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点按「开始检测」逐步渲染判定/延迟/汇总', (tester) async {
    final probe = _FakeProbe();
    await tester.pumpWidget(_wrap(ProxySiteProbeCard(probe: probe)));

    await tester.tap(find.byKey(const Key('proxy-site-probe-run')));
    await tester.pump();
    probe.emit(_result(_catalog[0], SiteProbeVerdict.ok, status: 200, ms: 150));
    probe.emit(
        _result(_catalog[1], SiteProbeVerdict.restricted, status: 403));
    probe.emit(_result(_catalog[2], SiteProbeVerdict.timeout));
    await _flush(tester);
    await probe.finish();
    await _flush(tester);

    expect(probe.probeCalls, 1);
    expect(find.text('可达'), findsOneWidget);
    expect(find.text('受限'), findsOneWidget);
    expect(find.text('超时'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-latency-Claude')))
          .data,
      '150 ms',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-latency-Google')))
          .data,
      '—',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-summary')))
          .data,
      '2/3 可达',
    );
    expect(find.text('重新检测'), findsOneWidget);
    expect(find.text('开始检测'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('渐进渲染：首个结果先出，其余仍为检测中；完成后汇总', (tester) async {
    final probe = _FakeProbe();
    await tester.pumpWidget(_wrap(ProxySiteProbeCard(probe: probe)));
    await tester.tap(find.byKey(const Key('proxy-site-probe-run')));
    await tester.pump();

    // 运行中、尚无结果：全部行 pending，按钮禁用 + AppLoading，实时汇总为 0/3。
    expect(find.text('检测中'), findsNWidgets(_catalog.length));
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-latency-Claude')))
          .data,
      '…',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-summary')))
          .data,
      '0/3 · 0 可达',
    );
    expect(find.byType(AppLoading), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('proxy-site-probe-run')))
          .onPressed,
      isNull,
    );

    // 第一个结果（Claude, ok, 150ms）：仅该行出判定，其余仍 pending。
    probe.emit(_result(_catalog[0], SiteProbeVerdict.ok, status: 200, ms: 150));
    await _flush(tester);

    expect(find.text('可达'), findsOneWidget);
    expect(find.text('检测中'), findsNWidgets(_catalog.length - 1));
    expect(find.text('未检测'), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-latency-Claude')))
          .data,
      '150 ms',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-latency-Google')))
          .data,
      '…',
      reason: '其余站点仍未完成',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-summary')))
          .data,
      '1/3 · 1 可达',
    );
    expect(find.byType(AppLoading), findsOneWidget, reason: '流未关闭仍在运行');

    // 完成剩余两站后关闭流。
    probe.emit(
        _result(_catalog[1], SiteProbeVerdict.restricted, status: 403));
    probe.emit(_result(_catalog[2], SiteProbeVerdict.timeout));
    await _flush(tester);
    await probe.finish();
    await _flush(tester);

    expect(find.text('检测中'), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-summary')))
          .data,
      '2/3 可达',
    );
    expect(find.byType(AppLoading), findsNothing);
    expect(find.text('重新检测'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('运行中：按钮禁用 + AppLoading，流关闭后恢复', (tester) async {
    final probe = _FakeProbe();
    await tester.pumpWidget(_wrap(ProxySiteProbeCard(probe: probe)));

    await tester.tap(find.byKey(const Key('proxy-site-probe-run')));
    await tester.pump();

    final FilledButton button = tester.widget<FilledButton>(
      find.byKey(const Key('proxy-site-probe-run')),
    );
    expect(button.onPressed, isNull, reason: '运行中按钮必须禁用');
    expect(find.byType(AppLoading), findsOneWidget);

    probe.emit(_result(_catalog[0], SiteProbeVerdict.ok, status: 200, ms: 120));
    await _flush(tester);
    expect(find.byType(AppLoading), findsOneWidget, reason: '仍有站点未完成');

    await probe.finish();
    await _flush(tester);

    expect(probe.probeCalls, 1);
    expect(find.byType(AppLoading), findsNothing);
    final FilledButton done = tester.widget<FilledButton>(
      find.byKey(const Key('proxy-site-probe-run')),
    );
    expect(done.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ok 延迟阈值配色：≤200 tertiary / ≤600 primary / >600 error',
      (tester) async {
    final probe = _FakeProbe();
    await tester.pumpWidget(_wrap(ProxySiteProbeCard(probe: probe)));
    await tester.tap(find.byKey(const Key('proxy-site-probe-run')));
    await tester.pump();
    probe.emit(_result(_catalog[0], SiteProbeVerdict.ok, status: 200, ms: 150));
    probe.emit(_result(_catalog[1], SiteProbeVerdict.ok, status: 200, ms: 400));
    probe.emit(_result(_catalog[2], SiteProbeVerdict.ok, status: 200, ms: 900));
    await _flush(tester);
    await probe.finish();
    await _flush(tester);

    final BuildContext ctx =
        tester.element(find.byKey(const Key('proxy-site-probe-card')));
    final ColorScheme scheme = Theme.of(ctx).colorScheme;

    expect(_chipColor(tester, 'Claude', '可达'), scheme.tertiary);
    expect(_chipColor(tester, 'Google', '可达'), scheme.primary);
    expect(_chipColor(tester, 'Baidu', '可达'), scheme.error);
    expect(tester.takeException(), isNull);
  });

  testWidgets('失败态配色统一 error：受限/超时/不可达', (tester) async {
    final probe = _FakeProbe();
    await tester.pumpWidget(_wrap(ProxySiteProbeCard(probe: probe)));
    await tester.tap(find.byKey(const Key('proxy-site-probe-run')));
    await tester.pump();
    probe.emit(
        _result(_catalog[0], SiteProbeVerdict.restricted, status: 403));
    probe.emit(_result(_catalog[1], SiteProbeVerdict.timeout));
    probe.emit(_result(_catalog[2], SiteProbeVerdict.unreachable));
    await _flush(tester);
    await probe.finish();
    await _flush(tester);

    final BuildContext ctx =
        tester.element(find.byKey(const Key('proxy-site-probe-card')));
    final ColorScheme scheme = Theme.of(ctx).colorScheme;

    expect(_chipColor(tester, 'Claude', '受限'), scheme.error);
    expect(_chipColor(tester, 'Google', '超时'), scheme.error);
    expect(_chipColor(tester, 'Baidu', '不可达'), scheme.error);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('proxy-site-probe-summary')))
          .data,
      '1/3 可达',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispose 取消订阅：卸载后事件不再触发且无异常', (tester) async {
    final probe = _FakeProbe();
    await tester.pumpWidget(_wrap(ProxySiteProbeCard(probe: probe)));
    await tester.tap(find.byKey(const Key('proxy-site-probe-run')));
    await tester.pump();
    probe.emit(_result(_catalog[0], SiteProbeVerdict.ok, status: 200, ms: 100));
    await _flush(tester);
    expect(probe.cancelCount, 0);

    // 卸载卡片：dispose 必须取消订阅。
    await tester.pumpWidget(_wrap(const SizedBox()));
    await tester.pump();
    expect(probe.cancelCount, 1, reason: 'dispose 必须取消 StreamSubscription');

    // 取消后继续发射不得触发 setState / 抛异常。
    probe.emit(_result(_catalog[1], SiteProbeVerdict.ok, status: 200, ms: 100));
    await _flush(tester);
    expect(tester.takeException(), isNull);
  });
}

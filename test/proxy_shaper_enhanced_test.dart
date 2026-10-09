// Todo 29 测试：弱网模拟完整参数（burst / 抖动分布 / 丢包模型 / 复制 / 重排 /
// gap / seed）+ 运行计数器 + GilbertElliot 编辑保留。
//
// 全部密闭式：
// * 纯函数组直接验证 [buildShaperDirectionFromStrings] 的往返与越界拒绝；
// * widget 组注入假门面（[ProxySettingsFacade]），不触碰 FFI / 原生模块 /
//   平台通道，走真实的设置页与统一弹层呈现路径。
//
// RED 目标（修复前）：
// * 自定义编辑把 `lossModel:"gilbertElliot"` 静默改写成 `random` / `none`；
// * 除 rate/delay/jitter/loss 外的契约参数与计数器无 UI 暴露。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_engine_settings_store.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';
import 'package:gstore/page/proxy/proxy_settings_page.dart';
import 'package:gstore/page/proxy/proxy_shaper_presets.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 让整个设置页在测试视口内完整布局（参数增多后需要更高的视口）。
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 9000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

// ==================== 假门面 ====================

class _FakeShaperFacade implements ProxySettingsFacade {
  ProxyShaperSnapshot shaperSnapshot = const ProxyShaperSnapshot();
  ProxyShaperConfig? lastShaperSaved;
  int shaperSaveCalls = 0;
  bool failShaperSave = false;

  @override
  Future<ProxyShaperSnapshot> loadShaperConfig() async => shaperSnapshot;

  @override
  Future<ProxyShaperSnapshot> saveShaperConfig(ProxyShaperConfig next) async {
    shaperSaveCalls++;
    if (failShaperSave) {
      throw StateError('保存失败（测试注入）');
    }
    lastShaperSaved = next;
    shaperSnapshot = ProxyShaperSnapshot(
      config: next,
      effective: next,
      applied: next.enabled,
      engineRunning: true,
      counters: shaperSnapshot.counters,
    );
    return shaperSnapshot;
  }

  @override
  Future<ProxySettingsConfig> loadSettings() async =>
      const ProxySettingsConfig();

  @override
  Future<void> saveSplitTunnel({
    required ProxySplitTunnelMode mode,
    required Set<String> apps,
  }) async {}

  @override
  Future<void> setAlwaysOnIntent(bool value) async {}

  @override
  Future<ProxyEngineSettings> loadEngineSettings() async =>
      const ProxyEngineSettings();

  @override
  Future<void> saveEngineSettings(ProxyEngineSettings settings) async {}

  @override
  Future<ProxyLanConfig> loadLanConfig() async => const ProxyLanConfig();

  @override
  Future<ProxyLanStatus> loadLanStatus() async => const ProxyLanStatus();

  @override
  Future<ProxyLanStatus> saveLanConfig(ProxyLanConfig config) async =>
      const ProxyLanStatus();

  @override
  Future<LogSetLevelResult> setLogLevel(ProxyLogLevel level) async =>
      LogSetLevelResult(ok: true, level: level);

  @override
  Future<StatsResetResult> resetStats() async =>
      const StatsResetResult(ok: true, cleared: 0);

  @override
  Future<List<InstalledAppOption>> loadInstalledApps() async =>
      const <InstalledAppOption>[];

  @override
  Future<ProxyEngineInfo> loadEngineInfo() async => const ProxyEngineInfo();
}

// ==================== 纯函数测试辅助 ====================

/// 用默认值 + 覆盖项构造一个方向；越界返回 `null`。
ProxyShaperDirection? _build({
  String rateKbps = '200',
  String delayMs = '100',
  String jitterMs = '20',
  String burstBytes = '32768',
  String jitterDistribution = 'normal',
  String lossPct = '5',
  String lossModel = 'random',
  String lossGoodToBadPct = '10',
  String lossBadToGoodPct = '20',
  String duplicatePct = '2',
  String reorderPct = '3',
  String reorderGap = '4',
  String order = 'reorder',
}) =>
    buildShaperDirectionFromStrings(
      rateKbps: rateKbps,
      delayMs: delayMs,
      jitterMs: jitterMs,
      burstBytes: burstBytes,
      jitterDistribution: jitterDistribution,
      lossPct: lossPct,
      lossModel: lossModel,
      lossGoodToBadPct: lossGoodToBadPct,
      lossBadToGoodPct: lossBadToGoodPct,
      duplicatePct: duplicatePct,
      reorderPct: reorderPct,
      reorderGap: reorderGap,
      order: order,
    );

const ProxyShaperDirection _geDirection = ProxyShaperDirection(
  rateBps: 200000,
  burstBytes: 32768,
  delayMs: 100,
  jitterMs: 10,
  jitterDistribution: 'normal',
  lossPct: 0,
  lossModel: 'gilbertElliot',
  lossGoodToBadPct: 10,
  lossBadToGoodPct: 20,
  duplicatePct: 2,
  reorderPct: 0,
  reorderGap: 0,
  order: 'preserve',
);

ProxyShaperSnapshot _snapshotFor(
  ProxyShaperDirection dir, {
  int? seed,
  ProxyShaperCounters counters = const ProxyShaperCounters(),
}) {
  final config = ProxyShaperConfig(
    enabled: true,
    seed: seed,
    uplink: dir,
    downlink: dir,
  );
  return ProxyShaperSnapshot(
    config: config,
    effective: config,
    applied: true,
    engineRunning: true,
    counters: counters,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('完整参数构造与校验（纯函数）', () {
    test('new_parameters_round_trip_through_json', () {
      final direction = _build();
      expect(direction, isNotNull);
      final d = direction!;
      expect(d.rateBps, 200000);
      expect(d.burstBytes, 32768);
      expect(d.delayMs, 100);
      expect(d.jitterMs, 20);
      expect(d.jitterDistribution, 'normal');
      expect(d.lossPct, 5);
      expect(d.lossModel, 'random');
      expect(d.lossGoodToBadPct, 10);
      expect(d.lossBadToGoodPct, 20);
      expect(d.duplicatePct, 2);
      expect(d.reorderPct, 3);
      expect(d.reorderGap, 4);
      expect(d.order, 'reorder');

      // JSON 往返逐字段一致（契约 wire 形状）。
      final restored = ProxyShaperDirection.fromJson(d.toJson());
      expect(restored, d);
    });

    test('gilbert_elliot_loss_model_is_preserved_by_builder', () {
      final d = _build(lossModel: 'gilbertElliot', lossPct: '0');
      expect(d, isNotNull);
      expect(d!.lossModel, 'gilbertElliot');
      expect(d.lossGoodToBadPct, 10);
      expect(d.lossBadToGoodPct, 20);
    });

    test('out_of_range_values_are_rejected', () {
      final cases = <String, ProxyShaperDirection?>{
        'burst_low': _build(burstBytes: '1499'),
        'burst_high': _build(burstBytes: '65536'),
        'gap_high': _build(reorderGap: '256'),
        'loss_high': _build(lossPct: '101'),
        'duplicate_high': _build(duplicatePct: '100.5'),
        'ge_high': _build(lossModel: 'gilbertElliot', lossGoodToBadPct: '101'),
        'bad_jitter_dist': _build(jitterDistribution: 'bogus'),
        'bad_loss_model': _build(lossModel: 'bogus'),
        'bad_order': _build(order: 'bogus'),
        'reorder_without_rate': _build(rateKbps: '0'),
        'non_numeric_burst': _build(burstBytes: 'abc'),
        'empty_gap': _build(reorderGap: ''),
      };
      cases.forEach((name, value) {
        expect(value, isNull, reason: '$name 必须被拒（返回 null）');
      });
    });
  });

  group('ProxySettingsPage 完整参数与计数器', () {
    testWidgets('编辑 GilbertElliot 自定义配置保留 lossModel（不重置 random/none）',
        (tester) async {
      _useTallSurface(tester);
      final facade = _FakeShaperFacade()
        ..shaperSnapshot = _snapshotFor(_geDirection, seed: 42);
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      // 加载 GE 配置 → 自定义档，丢包模型选择器显示 gilbertElliot。
      final selector = tester.widget<AppSegmentedButton<String>>(
        find.byKey(const Key('shaper_loss_model_selector')),
      );
      expect(selector.value, 'gilbertElliot');
      expect(
        find.byKey(const Key('shaper_loss_good_to_bad_field')),
        findsOneWidget,
      );

      // 只改延迟后应用。
      await tester.enterText(find.byKey(const Key('shaper_delay_field')), '123');
      await tester.tap(find.byKey(const Key('shaper_apply_button')));
      await tester.pumpAndSettle();

      expect(facade.shaperSaveCalls, 1);
      expect(facade.lastShaperSaved?.uplink.delayMs, 123);
      expect(
        facade.lastShaperSaved?.uplink.lossModel,
        'gilbertElliot',
        reason: '自定义编辑绝不能把 gilbertElliot 重置为 random/none',
      );
      expect(facade.lastShaperSaved?.uplink.lossGoodToBadPct, 10);
      expect(facade.lastShaperSaved?.uplink.lossBadToGoodPct, 20);
    });

    testWidgets('新参数经 UI 回读一致', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeShaperFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.enterText(find.byKey(const Key('shaper_rate_field')), '200');
      await tester.enterText(find.byKey(const Key('shaper_delay_field')), '120');
      await tester.enterText(find.byKey(const Key('shaper_jitter_field')), '30');
      await tester.enterText(find.byKey(const Key('shaper_burst_field')), '5000');
      await tester.enterText(find.byKey(const Key('shaper_loss_field')), '5');
      await tester
          .enterText(find.byKey(const Key('shaper_duplicate_field')), '4');
      await tester.enterText(find.byKey(const Key('shaper_seed_field')), '12345');

      // 抖动分布 normal。
      await tester.tap(find.byKey(const Key('shaper_jitter_dist_normal')));
      await tester.pump();
      // 丢包模型 random。
      await tester.tap(find.byKey(const Key('shaper_loss_model_random')));
      await tester.pump();
      // 包序 reorder → 出现 reorderPct / gap。
      await tester.tap(find.byKey(const Key('shaper_order_reorder')));
      await tester.pump();
      await tester
          .enterText(find.byKey(const Key('shaper_reorder_pct_field')), '3');
      await tester
          .enterText(find.byKey(const Key('shaper_reorder_gap_field')), '7');

      await tester.tap(find.byKey(const Key('shaper_apply_button')));
      await tester.pumpAndSettle();

      final saved = facade.lastShaperSaved;
      expect(facade.shaperSaveCalls, 1);
      expect(saved?.seed, 12345);
      final up = saved?.uplink;
      expect(up?.rateBps, 200000);
      expect(up?.burstBytes, 5000);
      expect(up?.delayMs, 120);
      expect(up?.jitterMs, 30);
      expect(up?.jitterDistribution, 'normal');
      expect(up?.lossPct, 5);
      expect(up?.lossModel, 'random');
      expect(up?.duplicatePct, 4);
      expect(up?.order, 'reorder');
      expect(up?.reorderPct, 3);
      expect(up?.reorderGap, 7);
    });

    testWidgets('展示运行计数器', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeShaperFacade()
        ..shaperSnapshot = _snapshotFor(
          const ProxyShaperDirection(rateBps: 200000),
          counters: const ProxyShaperCounters(
            upFramesShaped: 8,
            downFramesShaped: 9,
            upBytesShaped: 10,
            downBytesShaped: 11,
            lossDropped: 7,
            bufferDropped: 3,
            duplicated: 2,
            reordered: 1,
            bufferedFrames: 4,
            bufferedBytes: 5,
            maxBufferedFrames: 6,
          ),
        );
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      String? counterText(String name) => tester
          .widget<Text>(find.byKey(Key('shaper_counter_${name}_value')))
          .data;

      expect(counterText('up_frames'), '8');
      expect(counterText('down_frames'), '9');
      expect(counterText('loss_dropped'), '7');
      expect(counterText('buffer_dropped'), '3');
      expect(counterText('duplicated'), '2');
      expect(counterText('reordered'), '1');
      expect(counterText('buffered_frames'), '4');
      expect(counterText('buffered_bytes'), '5');
      expect(counterText('max_buffered_frames'), '6');
      expect(tester.takeException(), isNull);
    });

    testWidgets('越界新参数报错且不下发', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeShaperFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      // burst 越界（< 1500）。
      await tester.enterText(find.byKey(const Key('shaper_rate_field')), '1000');
      await tester.enterText(find.byKey(const Key('shaper_delay_field')), '100');
      await tester.enterText(find.byKey(const Key('shaper_jitter_field')), '50');
      await tester.enterText(find.byKey(const Key('shaper_burst_field')), '100');
      await tester.tap(find.byKey(const Key('shaper_apply_button')));
      await tester.pumpAndSettle();
      expect(facade.shaperSaveCalls, 0, reason: 'burst 越界不得下发');
      expect(find.textContaining('请填写有效数值'), findsOneWidget);

      // reorderGap 越界（> 255）。
      await tester.enterText(find.byKey(const Key('shaper_burst_field')), '32768');
      await tester.tap(find.byKey(const Key('shaper_order_reorder')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('shaper_reorder_pct_field')), '5');
      await tester.enterText(find.byKey(const Key('shaper_reorder_gap_field')), '256');
      await tester.tap(find.byKey(const Key('shaper_apply_button')));
      await tester.pumpAndSettle();
      expect(facade.shaperSaveCalls, 0, reason: 'reorderGap 越界不得下发');
    });
  });
}

// C4 widget tests：抓包应用范围（appScope）与 VPN 分流的耦合。
//
// 全部密闭式：只注入假「抓包配置门面」（[ProxyCaptureSettingsFacade]）+
// 假「分流门面」（[ProxySplitTunnelFacade]）+ 假已安装应用来源。走**真实生产**
// [ProxyCaptureSettingsPage] 与真实 `showConfirmSheet` / `AppDialogs` 呈现路径
// （宿主挂载全局 `appNavigatorKey` + `AppDialogs.scaffoldMessengerKey`）。
//
// 覆盖：
// * 启用 routing 应用范围抓包 → 经 `showConfirmSheet` 提议把分流切到 `allow`
//   且清单 == `appAllowlist`；确认后**精确校验**实际落库的分流清单（并据其推导
//   Kotlin `allowedApps` 载荷）。
// * 拒绝 → 不写分流，应用范围抓包保持关闭（`enabled:false`）。
// * 漂移（`full`/`disallow` 或清单不一致）→ 加载时自动关闭抓包 + 提示。
// * `uid` 范围不触发任何分流耦合。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_capture_settings_page.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

const List<InstalledAppOption> _sampleApps = <InstalledAppOption>[
  InstalledAppOption(packageName: 'com.apple', name: 'Apple'),
  InstalledAppOption(packageName: 'com.banana', name: 'Banana'),
];

// ==================== 假实现 ====================

class _FakeInstalledAppsProvider implements ProxyInstalledAppsProvider {
  _FakeInstalledAppsProvider([this.apps = _sampleApps]);

  final List<InstalledAppOption> apps;

  @override
  Future<List<InstalledAppOption>> list() async => apps;
}

class _FakeCaptureFacade implements ProxyCaptureSettingsFacade {
  _FakeCaptureFacade({CaptureConfig? config})
      : config = config ?? const CaptureConfig();

  CaptureConfig config;
  CaptureConfig? lastSet;
  int setCalls = 0;

  @override
  Future<CaptureConfig> configGet() async => config;

  @override
  Future<CaptureConfig> configSet(CaptureConfig next) async {
    setCalls++;
    lastSet = next;
    config = next;
    return next;
  }

  @override
  Future<CaptureStorageStats> storageStats() async => const CaptureStorageStats(
        retained: 1,
        capacity: 16,
      );
}

class _FakeSplitTunnelFacade implements ProxySplitTunnelFacade {
  _FakeSplitTunnelFacade({ProxySettingsConfig? config})
      : config = config ?? const ProxySettingsConfig();

  ProxySettingsConfig config;
  int loadCalls = 0;
  int saveCalls = 0;
  ProxySplitTunnelMode? lastMode;
  Set<String>? lastApps;

  @override
  Future<ProxySettingsConfig> loadSplitTunnel() async {
    loadCalls++;
    return config;
  }

  @override
  Future<void> saveSplitTunnel({
    required ProxySplitTunnelMode mode,
    required Set<String> apps,
  }) async {
    saveCalls++;
    lastMode = mode;
    lastApps = apps;
    config = config.copyWith(splitMode: mode, selectedApps: apps);
  }
}

// ==================== 工具 ====================

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// `initState` 的加载 + 非致命统计拉取都已解析。
Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Map<String, dynamic> _vpnPayload(ProxySettingsConfig config) =>
    jsonDecode(config.toVpnConfigJson()) as Map<String, dynamic>;

void main() {
  group('ProxyCaptureSettingsPage appScope ↔ VPN routing coupling', () {
    testWidgets(
        '启用 routing 应用范围抓包 → 提议 allow 且 allowedApps == appAllowlist',
        (tester) async {
      _useTallSurface(tester);
      final capture = _FakeCaptureFacade(
        config: const CaptureConfig(
          appAllowlist: <String>['com.apple', 'com.banana'],
        ),
      );
      final split = _FakeSplitTunnelFacade(
        config: const ProxySettingsConfig(), // full + 空清单 = 未镜像
      );
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: capture,
        routing: split,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      // 选择「VPN 分流」范围并打开 MITM 总开关。
      await tester.tap(find.byKey(const Key('capture_scope_routing')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('capture_mitm_switch')));
      await _pumpFrames(tester);

      // 保存 → 弹出统一确认弹层（底部弹层）。
      await tester.tap(find.byKey(const Key('capture_settings_save')));
      await tester.pumpAndSettle();
      expect(find.text('切换分流'), findsOneWidget);

      await tester.tap(find.text('切换分流'));
      await tester.pumpAndSettle();

      // 真实落库的分流镜像：mode=allow、清单 == appAllowlist。
      expect(split.saveCalls, 1);
      expect(split.lastMode, ProxySplitTunnelMode.allow);
      expect(split.lastApps, <String>{'com.apple', 'com.banana'});

      // 由镜像推导的实际 Kotlin `allowedApps` 载荷（单一数据源 = appAllowlist）。
      final vpn = _vpnPayload(split.config);
      expect(vpn['mode'], 'allow');
      expect(vpn['allowedApps'], <String>['com.apple', 'com.banana']);

      expect(capture.setCalls, 1);
      expect(capture.lastSet!.enabled, isTrue);
      expect(capture.lastSet!.appScope, ProxyCaptureAppScope.routing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('拒绝切换分流 → 应用范围抓包保持关闭', (tester) async {
      _useTallSurface(tester);
      final capture = _FakeCaptureFacade(
        config: const CaptureConfig(
          appAllowlist: <String>['com.apple'],
        ),
      );
      final split = _FakeSplitTunnelFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: capture,
        routing: split,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_scope_routing')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('capture_mitm_switch')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('capture_settings_save')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 绝不静默重定路由；抓包保持关闭。
      expect(split.saveCalls, 0);
      expect(capture.setCalls, 1);
      expect(capture.lastSet!.enabled, isFalse);
      expect(find.textContaining('保持关闭'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('漂移：分流 full → 加载时自动关闭抓包 + 提示', (tester) async {
      _useTallSurface(tester);
      final capture = _FakeCaptureFacade(
        config: const CaptureConfig(
          enabled: true,
          appScope: ProxyCaptureAppScope.routing,
          appAllowlist: <String>['com.apple'],
        ),
      );
      final split = _FakeSplitTunnelFacade(
        config: const ProxySettingsConfig(
          splitMode: ProxySplitTunnelMode.full,
        ),
      );
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: capture,
        routing: split,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      // 实际下发的 `capture.config.set`：enabled:false（不得静默改路由）。
      expect(capture.setCalls, 1);
      expect(capture.lastSet!.enabled, isFalse);
      expect(split.saveCalls, 0);
      expect(find.textContaining('自动关闭'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('漂移：allow 但清单 ≠ appAllowlist → 自动关闭抓包 + 提示', (tester) async {
      _useTallSurface(tester);
      final capture = _FakeCaptureFacade(
        config: const CaptureConfig(
          enabled: true,
          appScope: ProxyCaptureAppScope.routing,
          appAllowlist: <String>['com.apple'],
        ),
      );
      final split = _FakeSplitTunnelFacade(
        config: const ProxySettingsConfig(
          splitMode: ProxySplitTunnelMode.allow,
          selectedApps: <String>{'com.other'},
        ),
      );
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: capture,
        routing: split,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      expect(capture.setCalls, 1);
      expect(capture.lastSet!.enabled, isFalse);
      expect(split.saveCalls, 0);
      expect(find.textContaining('自动关闭'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('uid 范围：不触发分流耦合', (tester) async {
      _useTallSurface(tester);
      final capture = _FakeCaptureFacade(
        config: const CaptureConfig(
          enabled: true,
          appScope: ProxyCaptureAppScope.uid,
          appAllowlist: <String>['com.apple'],
        ),
      );
      final split = _FakeSplitTunnelFacade(
        config: const ProxySettingsConfig(
          splitMode: ProxySplitTunnelMode.allow,
          selectedApps: <String>{'com.other'},
        ),
      );
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: capture,
        routing: split,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      // uid 范围既不读也不写分流，更不自动关闭。
      expect(split.loadCalls, 0);
      expect(split.saveCalls, 0);
      expect(capture.setCalls, 0);
      expect(find.textContaining('自动关闭'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

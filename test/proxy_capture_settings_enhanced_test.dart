// Todo 27 widget / unit tests：抓包设置增强。
//
// 覆盖：
// * 域名白名单批量解析 + 去重（纯函数 + 页面批量粘贴弹层）。
// * `maxBodyBytes` / `tlsPorts` 回读一致 + 保存载荷精确匹配。
// * 无 CA 时 MITM 开关被拦（与首页同一 CA 门控文案 / 流程）。
// * 未保存返回时弹统一确认弹层。
// * 非法值（`maxBodyBytes` / `tlsPorts`）被拦、不落库。
// * 列表页抓包开关复用同一 CA 门控。
//
// 全部密闭式：只注入假门面（[ProxyCaptureSettingsFacade] / [ProxyRequestsFacade]
// + [ProxyCaptureCaGate]），不触碰 FFI / 原生模块 / 平台通道。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_capture_ca_gate.dart';
import 'package:gstore/page/proxy/proxy_capture_settings_page.dart';
import 'package:gstore/page/proxy/proxy_capture_settings_parsing.dart';
import 'package:gstore/page/proxy/proxy_requests_facade.dart';
import 'package:gstore/page/proxy/proxy_requests_page.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

/// 把页面推入真实路由栈，以便 `pageBack()` / `Navigator.pop` 生效。
Widget _hostPushed(Widget page) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open_settings'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => page),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

const List<InstalledAppOption> _sampleApps = <InstalledAppOption>[
  InstalledAppOption(packageName: 'com.apple', name: 'Apple'),
  InstalledAppOption(packageName: 'com.banana', name: 'Banana'),
];

// ==================== 假实现 ====================

class _FakeInstalledAppsProvider implements ProxyInstalledAppsProvider {
  _FakeInstalledAppsProvider();

  @override
  Future<List<InstalledAppOption>> list() async => _sampleApps;
}

class _FakeCaptureFacade
    implements ProxyCaptureSettingsFacade, ProxyCaptureCaGate {
  _FakeCaptureFacade({
    CaptureConfig? config,
    this.ca = const CaptureCaInfo(generated: true),
  }) : config = config ?? const CaptureConfig();

  CaptureConfig config;
  CaptureCaInfo ca;
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
        retained: 3,
        capacity: 256,
      );

  @override
  Future<CaptureCaInfo> captureCaGet() async => ca;
}

class _FakeRequestsFacade
    implements ProxyRequestsFacade, ProxyCaptureCaGate {
  _FakeRequestsFacade({this.ca = const CaptureCaInfo(generated: false)});

  CaptureConfig config = const CaptureConfig(enabled: false);
  CaptureCaInfo ca;
  int configSetCalls = 0;
  CaptureConfig? lastConfigSet;

  @override
  Future<RequestPage> requestsGet(RequestGetRequest request) async =>
      const RequestPage();

  @override
  Future<CapturePage> capturesGet(CapturesGetRequest request) async =>
      const CapturePage();

  @override
  Future<void> requestsReset() async {}

  @override
  Future<void> capturesReset() async {}

  @override
  Future<RequestExportResult> requestsExport(RequestExportRequest request) async =>
      const RequestExportResult();

  @override
  Future<CaptureConfig> captureConfigGet() async => config;

  @override
  Future<CaptureConfig> captureConfigSet(CaptureConfig next) async {
    configSetCalls++;
    lastConfigSet = next;
    config = next;
    return next;
  }

  @override
  Future<CaptureCaInfo> captureCaGet() async => ca;
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

void main() {
  // ==================== 纯函数：域名批量解析 ====================

  group('parseDomainBulk', () {
    test('按换行 / 逗号 / 空格 / 分号切分、去空、去重（大小写不敏感）', () {
      final result = parseDomainBulk(
        'api.example.com\nAPI.EXAMPLE.COM, other.test;  third.test  ',
        maxEntries: 256,
        maxEntryBytes: 253,
      );
      expect(result.accepted, <String>['api.example.com', 'other.test', 'third.test']);
      expect(result.duplicates, 1);
      expect(result.rejected, isEmpty);
      expect(result.overLimit, 0);
    });

    test('超长条目被拒（rejected），不影响其余', () {
      final tooLong = 'a' * 254;
      final result = parseDomainBulk(
        'ok.test\n$tooLong',
        maxEntries: 256,
        maxEntryBytes: 253,
      );
      expect(result.accepted, <String>['ok.test']);
      expect(result.rejected, <String>[tooLong]);
    });

    test('与既有白名单合并去重，并遵守条数上限（overLimit）', () {
      final result = parseDomainBulk(
        'a.test\nb.test\nc.test',
        maxEntries: 3,
        maxEntryBytes: 253,
        existing: <String>['A.TEST', 'x.test'],
      );
      // A.TEST 已存在（大小写不敏感）→ 重复；只剩 1 个额度 → b.test 入，c.test 超限。
      expect(result.accepted, <String>['b.test']);
      expect(result.duplicates, 1);
      expect(result.overLimit, 1);
    });
  });

  // ==================== 纯函数：端口 / Body 上限 ====================

  group('parseTlsPorts / parseMaxBodyBytes', () {
    test('端口解析去重且范围合法', () {
      expect(parseTlsPorts('443, 8443;443 9443'), <int>[443, 8443, 9443]);
    });

    test('端口为空或越界 → null', () {
      expect(parseTlsPorts(''), isNull);
      expect(parseTlsPorts('0'), isNull);
      expect(parseTlsPorts('65536'), isNull);
      expect(parseTlsPorts('abc'), isNull);
    });

    test('maxBodyBytes 范围 [1,1048576]', () {
      expect(parseMaxBodyBytes('2048'), 2048);
      expect(parseMaxBodyBytes('1'), 1);
      expect(parseMaxBodyBytes('1048576'), 1048576);
      expect(parseMaxBodyBytes('0'), isNull);
      expect(parseMaxBodyBytes('1048577'), isNull);
      expect(parseMaxBodyBytes(''), isNull);
    });
  });

  // ==================== 设置页增强 ====================

  group('ProxyCaptureSettingsPage enhanced', () {
    testWidgets('maxBodyBytes / tlsPorts 回读并保存载荷精确匹配', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade(
        config: const CaptureConfig(
          maxBodyBytes: 2048,
          tlsPorts: <int>[443, 9443],
        ),
      );
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      // 回读。
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('capture_max_body_bytes_field')))
            .controller!
            .text,
        '2048',
      );
      expect(find.text('端口集合：443 / 9443'), findsOneWidget);

      // 编辑 maxBodyBytes。
      await tester.enterText(
        find.byKey(const Key('capture_max_body_bytes_field')),
        '4096',
      );
      await _pumpFrames(tester);

      // 编辑 tlsPorts。
      await tester.tap(find.byKey(const Key('capture_tls_ports_edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('capture_tls_ports_field')),
        '443, 8443',
      );
      await tester.tap(find.byKey(const Key('capture_tls_ports_confirm')));
      await tester.pumpAndSettle();
      expect(find.text('端口集合：443 / 8443'), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_settings_save')));
      await _pumpFrames(tester);

      expect(facade.setCalls, 1);
      expect(facade.lastSet!.maxBodyBytes, 4096);
      expect(facade.lastSet!.tlsPorts, <int>[443, 8443]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('非法 maxBodyBytes 被拦（错误提示 + 不落库）', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.enterText(
        find.byKey(const Key('capture_max_body_bytes_field')),
        '0',
      );
      await _pumpFrames(tester);
      expect(find.byKey(const Key('capture_max_body_bytes_error')), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_settings_save')));
      await _pumpFrames(tester);
      expect(facade.setCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('非法 tlsPorts 被拦且端口不变', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_tls_ports_edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('capture_tls_ports_field')),
        '70000',
      );
      await tester.tap(find.byKey(const Key('capture_tls_ports_confirm')));
      await tester.pumpAndSettle();

      // 弹层保持打开（非法未提交），展示错误。
      expect(find.textContaining('端口'), findsWidgets);
      expect(find.text('端口集合：443 / 8443'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 CA 时 MITM 开关被拦（与首页同一门控文案）', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade(ca: const CaptureCaInfo());
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_mitm_switch')));
      await tester.pumpAndSettle();

      expect(find.text(kCaptureNeedsCaTitle), findsOneWidget);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('capture_mitm_switch')))
            .value,
        isFalse,
      );
      expect(facade.setCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有 CA 时 MITM 开关可开', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_mitm_switch')));
      await _pumpFrames(tester);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('capture_mitm_switch')))
            .value,
        isTrue,
      );
    });

    testWidgets('域名批量粘贴：解析 + 去重后保存', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_domain_bulk')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('capture_domain_bulk_field')),
        'api.example.com\nAPI.EXAMPLE.COM, other.test',
      );
      await tester.tap(find.byKey(const Key('capture_domain_bulk_confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('capture_domain_chip_api.example.com')), findsOneWidget);
      expect(find.byKey(const Key('capture_domain_chip_other.test')), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_settings_save')));
      await _pumpFrames(tester);
      expect(facade.lastSet!.domainAllowlist, <String>['api.example.com', 'other.test']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('App 白名单全选 / 清空', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_apps_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture_apps_select_all')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('capture_apps_confirm')));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 个应用'), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_apps_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture_apps_clear')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('capture_apps_confirm')));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 个应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未保存返回 → 弹确认；继续编辑保留，放弃则返回', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_hostPushed(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await tester.tap(find.byKey(const Key('open_settings')));
      await tester.pumpAndSettle();

      // 制造未保存修改。
      await tester.tap(find.byKey(const Key('capture_toggle_body')));
      await _pumpFrames(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);

      // 继续编辑：留在页面。
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('抓包设置'), findsOneWidget);

      // 再次返回并放弃 → 页面被弹出。
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(find.text('抓包设置'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== 列表页复用 CA 门控 ====================

  group('ProxyRequestsPage capture toggle CA gate', () {
    testWidgets('无 CA 时列表页抓包开关被拦，不下发', (tester) async {
      tester.view.physicalSize = const Size(1600, 3600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final facade = _FakeRequestsFacade(ca: const CaptureCaInfo());
      await tester.pumpWidget(_host(ProxyRequestsPage(
        facade: facade,
        events: const Stream<ProxyEvent>.empty(),
        initialLive: false,
      )));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const Key('requests_capture_toggle')));
      await tester.pumpAndSettle();

      expect(find.text(kCaptureNeedsCaTitle), findsOneWidget);
      expect(facade.configSetCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('有 CA 时列表页抓包开关正常下发', (tester) async {
      tester.view.physicalSize = const Size(1600, 3600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final facade = _FakeRequestsFacade(
        ca: const CaptureCaInfo(generated: true),
      );
      await tester.pumpWidget(_host(ProxyRequestsPage(
        facade: facade,
        events: const Stream<ProxyEvent>.empty(),
        initialLive: false,
      )));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const Key('requests_capture_toggle')));
      await tester.pumpAndSettle();

      expect(facade.configSetCalls, 1);
      expect(facade.lastConfigSet!.enabled, isTrue);
      expect(tester.takeException(), isNull);
    });
  });
}

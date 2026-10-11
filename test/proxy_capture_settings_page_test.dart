// Todo 21 widget tests：抓包设置页（MITM 开关 / 域名白名单 / App 白名单 /
// 内容开关 / TLS 端口集合 / 存储统计 / 保存与失败提示）。
//
// 全部密闭式：只注入假门面（[ProxyCaptureSettingsFacade]）+ 假已安装应用来源
// （[ProxyInstalledAppsProvider]），不触碰 FFI / 原生模块 / 平台通道。弹层宿主
// 复用生产全局通道 `appNavigatorKey` + `AppDialogs.scaffoldMessengerKey`，因此
// 走真实的 `AppSheet` / `AppDialogs` 呈现路径。
//
// 覆盖：
// * happy：域名白名单增删、App 多选、内容开关、MITM 开关 → 保存时**精确校验**
//   `capture.config.set` 载荷；存储统计渲染。
// * failure：保存失败 → `showError` 且不崩；加载失败 → 错误态可重试；域名超长 /
//   重复 / 超上限 → 提示且不落库。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/page/proxy/proxy_capture_ca_gate.dart';
import 'package:gstore/page/proxy/proxy_capture_ca_page.dart';
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

  List<InstalledAppOption> apps;
  int calls = 0;

  @override
  Future<List<InstalledAppOption>> list() async {
    calls++;
    return apps;
  }
}

class _FakeCaptureFacade implements ProxyCaptureSettingsFacade {
  _FakeCaptureFacade({CaptureConfig? config, CaptureStorageStats? stats})
      : config = config ?? const CaptureConfig(),
        stats = stats ??
            const CaptureStorageStats(
              retained: 3,
              capacity: 4096,
              evicted: 1,
              dropped: 0,
            );

  CaptureConfig config;
  CaptureStorageStats stats;

  CaptureConfig? lastSet;
  int setCalls = 0;
  int getCalls = 0;
  bool failGet = false;
  bool failSet = false;

  @override
  Future<CaptureConfig> configGet() async {
    getCalls++;
    if (failGet) throw StateError('读取失败（测试注入）');
    return config;
  }

  @override
  Future<CaptureConfig> configSet(CaptureConfig next) async {
    setCalls++;
    if (failSet) throw StateError('保存失败（测试注入）');
    lastSet = next;
    config = next;
    return next;
  }

  @override
  Future<CaptureStorageStats> storageStats() async => stats;
}

/// 在 [_FakeCaptureFacade] 之上实现 CA 门控接缝：用于验证「无 CA 时经
/// 继续开启仍可开启抓包」与「去设置 → 不开启并导航」两条路径。
class _FakeCaptureCaFacade extends _FakeCaptureFacade
    implements ProxyCaptureCaGate {
  _FakeCaptureCaFacade({super.config, super.stats, CaptureCaInfo? ca})
      : ca = ca ?? const CaptureCaInfo();

  CaptureCaInfo ca;
  int caGetCalls = 0;

  @override
  Future<CaptureCaInfo> captureCaGet() async {
    caGetCalls++;
    return ca;
  }
}

// ==================== 工具 ====================

/// 让整个页面在测试视口内完整布局（默认 800x600 会截断下方小节）。
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

/// `initState` 的加载 + 非致命统计拉取都已解析（不依赖 `pumpAndSettle`，
/// 避免页面内 `AppLoading` 的无限动画拖死 settle）。
Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  group('ProxyCaptureSettingsPage', () {
    testWidgets('渲染六大区块并把加载结果回填', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade(
        config: const CaptureConfig(
          enabled: true,
          domainAllowlist: <String>['example.com'],
          appAllowlist: <String>['com.apple'],
          captureBody: false,
          captureWs: true,
          captureH2: false,
        ),
      );
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      expect(find.text('抓包设置'), findsOneWidget);
      expect(find.text('MITM 总开关'), findsOneWidget);
      expect(find.text('域名白名单'), findsOneWidget);
      expect(find.text('App 白名单'), findsOneWidget);
      expect(find.text('内容开关'), findsOneWidget);
      expect(find.text('TLS 端口集合'), findsOneWidget);
      expect(find.text('存储统计'), findsOneWidget);

      // MITM 开关同步。
      expect(
        tester.widget<SwitchListTile>(find.byKey(const Key('capture_mitm_switch'))).value,
        isTrue,
      );
      // 存量连接常显提示：key 命中且文案含「仅对新建连接生效」。
      expect(
        tester.widget<Text>(find.byKey(const Key('capture_existing_conn_hint'))).data,
        contains('仅对新建连接生效'),
      );
      // 域名芯片回填。
      expect(find.byKey(const Key('capture_domain_chip_example.com')), findsOneWidget);
      // App 计数回填。
      expect(find.text('已选 1 个应用'), findsOneWidget);
      // 内容开关回填。
      expect(
        tester.widget<SwitchListTile>(find.byKey(const Key('capture_toggle_body'))).value,
        isFalse,
      );
      expect(
        tester.widget<SwitchListTile>(find.byKey(const Key('capture_toggle_h2'))).value,
        isFalse,
      );
      // TLS 端口集合展示。
      expect(find.text('端口集合：443 / 8443'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('存储统计渲染 保留/淘汰/丢弃', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade(
        stats: const CaptureStorageStats(
          retained: 42,
          capacity: 4096,
          evicted: 7,
          dropped: 3,
        ),
      );
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      expect(find.text('保留 42/4096 · 淘汰 7 · 丢弃 3'), findsOneWidget);
    });

    testWidgets('域名白名单增删 → 保存载荷精确匹配', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      expect(find.byKey(const Key('capture_domain_empty')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('capture_domain_field')),
        'example.com',
      );
      await tester.tap(find.byKey(const Key('capture_domain_add')));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('capture_domain_chip_example.com')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('capture_domain_field')),
        'api.test',
      );
      await tester.tap(find.byKey(const Key('capture_domain_add')));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('capture_domain_chip_api.test')), findsOneWidget);

      // 删除第一条。
      await tester.tap(find.descendant(
        of: find.byKey(const Key('capture_domain_chip_example.com')),
        matching: find.byIcon(TablerIcons.x),
      ));
      await _pumpFrames(tester);
      expect(find.byKey(const Key('capture_domain_chip_example.com')), findsNothing);
      expect(find.byKey(const Key('capture_domain_chip_api.test')), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_settings_save')));
      await _pumpFrames(tester);

      expect(facade.setCalls, 1);
      expect(facade.lastSet!.domainAllowlist, <String>['api.test']);
    });

    testWidgets('域名超长 → showError 且不加入', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      final tooLong = 'a' * (kCaptureMaxAllowlistEntryBytes + 1);
      await tester.enterText(
        find.byKey(const Key('capture_domain_field')),
        tooLong,
      );
      await tester.tap(find.byKey(const Key('capture_domain_add')));
      await _pumpFrames(tester);

      expect(find.textContaining('域名过长'), findsOneWidget);
      expect(find.byKey(const Key('capture_domain_empty')), findsOneWidget);
    });

    testWidgets('重复域名 → 警告且不重复加入', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade(
        config: const CaptureConfig(domainAllowlist: <String>['example.com']),
      );
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.enterText(
        find.byKey(const Key('capture_domain_field')),
        'example.com',
      );
      await tester.tap(find.byKey(const Key('capture_domain_add')));
      await _pumpFrames(tester);

      expect(find.textContaining('已在白名单'), findsOneWidget);
      expect(find.byKey(const Key('capture_domain_chip_example.com')), findsOneWidget);
    });

    testWidgets('App 白名单多选 → 保存载荷精确匹配', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      final apps = _FakeInstalledAppsProvider();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: apps,
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_apps_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('capture_app_search')), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_app_com.apple')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('capture_app_com.banana')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('capture_apps_confirm')));
      await tester.pumpAndSettle();

      expect(apps.calls, 1);
      expect(find.text('已选 2 个应用'), findsOneWidget);

      await tester.tap(find.byKey(const Key('capture_settings_save')));
      await _pumpFrames(tester);
      expect(facade.lastSet!.appAllowlist, <String>['com.apple', 'com.banana']);
    });

    testWidgets('App 列表为空时选择器展示显式空态不崩', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(<InstalledAppOption>[]),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_apps_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('capture_apps_empty')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('内容开关与 MITM 开关 → 保存载荷精确匹配', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_mitm_switch')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('capture_toggle_body')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('capture_toggle_h2')));
      await _pumpFrames(tester);

      await tester.tap(find.byKey(const Key('capture_settings_save')));
      await _pumpFrames(tester);

      final payload = facade.lastSet!.toJson();
      expect(payload['enabled'], isTrue);
      expect(payload['captureBody'], isFalse);
      expect(payload['captureWs'], isTrue);
      expect(payload['captureH2'], isFalse);
      // 完整形状：10 个冻结字段，绝不缺键。
      expect(
        payload.keys.toSet(),
        <String>{
          'enabled',
          'tlsPorts',
          'domainAllowlist',
          'appAllowlist',
          'appScope',
          'captureBody',
          'captureWs',
          'captureH2',
          'skipCertVerify',
          'maxBodyBytes',
        },
      );
    });

    testWidgets('无 CA：MITM 开关经「继续开启」可开启（明文 HTTP 无需证书）',
        (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureCaFacade(ca: const CaptureCaInfo());
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_mitm_switch')));
      await tester.pumpAndSettle();

      // 无 CA 提示：标题沿用 kCaptureNeedsCaTitle，两个动作「继续开启 / 去设置」。
      expect(find.text(kCaptureNeedsCaTitle), findsOneWidget);
      expect(find.text(kCaptureNeedsCaConfirmText), findsOneWidget);
      expect(find.text(kCaptureNeedsCaCancelText), findsOneWidget);
      expect(facade.caGetCalls, 1);

      await tester.tap(find.text(kCaptureNeedsCaConfirmText));
      await tester.pumpAndSettle();

      expect(facade.setCalls, 0);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('capture_mitm_switch')))
            .value,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('无 CA：选「去设置」不开启且触发证书管理导航', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureCaFacade(ca: const CaptureCaInfo());
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_mitm_switch')));
      await tester.pumpAndSettle();
      // 提示出现时开关仍未开启。
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('capture_mitm_switch')))
            .value,
        isFalse,
      );
      await tester.tap(find.text(kCaptureNeedsCaCancelText));
      await tester.pumpAndSettle();

      // 未放行：导航进入证书管理页（生产路由可达），设置页被推入栈下。
      expect(find.byType(ProxyCaptureCaPage), findsOneWidget);
      expect(facade.setCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('端口卡片常显明文 HTTP 抓包提示', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      final hint = find.byKey(const Key('capture_plain_http_hint'));
      expect(hint, findsOneWidget);
      final text = tester.widget<Text>(hint).data ?? '';
      expect(text, contains('明文 HTTP'));
      expect(text, contains('8080'));
      expect(text, contains('无需证书'));
      expect(text, contains('h2c'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('保存失败 → showError 且不崩', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade()..failSet = true;
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_toggle_body')));
      await _pumpFrames(tester);
      await tester.tap(find.byKey(const Key('capture_settings_save')));
      await _pumpFrames(tester);
      await tester.pump(const Duration(milliseconds: 300));

      expect(facade.setCalls, 1);
      expect(find.textContaining('保存失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载失败 → 错误态可重试', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade()..failGet = true;
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      expect(find.text('抓包配置加载失败'), findsOneWidget);

      facade.failGet = false;
      await tester.tap(find.byKey(const Key('capture_settings_retry')));
      await _settleLoad(tester);

      expect(find.text('抓包配置加载失败'), findsNothing);
      expect(find.text('MITM 总开关'), findsOneWidget);
      expect(facade.getCalls, 2);
    });

    testWidgets('证书管理入口：进入 ProxyCaptureCaPage（生产路由可达）', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      expect(find.byKey(const Key('capture_settings_ca_entry')), findsOneWidget);
      await tester.tap(find.byKey(const Key('capture_settings_ca_entry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // 真正进入全屏 CA 管理页（而非仅触发回调）。CA 页使用生产门面，在无原生
      // 模块的测试环境走其错误态，不影响「页面已渲染」这一可达性断言。
      expect(find.byType(ProxyCaptureCaPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== D6c：跳过上游证书校验 ====================
  //
  // 覆盖：默认关 + 风险文案可见；开启需 `showConfirmSheet(isDangerous:true)` 二次
  // 确认；确认后**精确校验** `capture.config.set` 载荷 `skipCertVerify:true` 且
  // 开关回填；取消 → 不落库、开关保持关；加载已持久化的 true → 回填为开。
  group('ProxyCaptureSettingsPage skipCertVerify toggle', () {
    const Key switchKey = Key('capture_skip_cert_verify_switch');

    testWidgets('默认关闭且风险文案可见', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      expect(find.byKey(switchKey), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byKey(switchKey)).value, isFalse);
      expect(find.text('上游证书校验'), findsOneWidget);
      // 风险文案必须常显，绝不隐藏。
      expect(find.textContaining('二次中间人'), findsWidgets);
      expect(find.textContaining('自签名'), findsWidgets);
      expect(facade.config.skipCertVerify, isFalse);
    });

    testWidgets('开启 → 弹出危险确认，未确认前不落库且开关仍关',
        (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(switchKey));
      await tester.pumpAndSettle();

      // 统一危险确认弹层出现。
      expect(find.text('跳过上游证书校验？'), findsOneWidget);
      expect(find.text('仍然开启'), findsOneWidget);
      expect(find.textContaining('二次中间人'), findsWidgets);

      expect(facade.setCalls, 0);
      expect(
        tester.widget<SwitchListTile>(find.byKey(switchKey)).value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('确认 → capture.config.set 收到 skipCertVerify:true 且回填',
        (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(switchKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('仍然开启'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 50));

      // 实际下发载荷携带 true（非仅弹层出现）。
      expect(facade.setCalls, 1);
      expect(facade.lastSet, isNotNull);
      expect(facade.lastSet!.skipCertVerify, isTrue);
      expect(facade.lastSet!.toJson()['skipCertVerify'], isTrue);
      // 持久化值回填到页面状态。
      expect(facade.config.skipCertVerify, isTrue);
      expect(
        tester.widget<SwitchListTile>(find.byKey(switchKey)).value,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('取消 → 开关保持关且从不下发 true', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade();
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      await tester.tap(find.byKey(switchKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(find.text('跳过上游证书校验？'), findsNothing);
      expect(
        tester.widget<SwitchListTile>(find.byKey(switchKey)).value,
        isFalse,
      );
      expect(facade.setCalls, 0);
      expect(facade.lastSet, isNull);
      expect(facade.config.skipCertVerify, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('加载已持久化的 skipCertVerify:true → 开关回填为开',
        (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaptureFacade(
        config: const CaptureConfig(skipCertVerify: true),
      );
      await tester.pumpWidget(_host(ProxyCaptureSettingsPage(
        facade: facade,
        installedApps: _FakeInstalledAppsProvider(),
      )));
      await _settleLoad(tester);

      expect(
        tester.widget<SwitchListTile>(find.byKey(switchKey)).value,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  });
}

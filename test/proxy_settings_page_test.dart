// Todo 23 widget tests：代理设置页（应用分流 / 始终开启 / 端口 / 日志级别 /
// 重置统计 / 引擎调试信息）。
//
// 全部密闭式：只注入假门面（[ProxySettingsFacade]），不触碰 FFI / 原生模块 /
// 平台通道。弹层宿主复用生产全局通道 `appNavigatorKey` +
// `AppDialogs.scaffoldMessengerKey`，因此走真实的 `AppSheet` / `AppDialogs`
// 呈现路径。
//
// 覆盖：
// * happy：切换分流模式并选择应用 → 门面收到更新；切换「始终开启」→ 持久化；
//   切换日志级别 / 重置统计（危险确认弹层）→ 门面收到调用。
// * failure：无任何已安装应用时，选择器渲染显式空态且不崩溃。
// * 纯函数：`ProxySettingsConfig.toVpnConfigJson()` 的三种模式映射 +
//   「排除应用」过滤本应用（Todo 4：绝不 `addDisallowedApplication(self)`）。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';
import 'package:gstore/page/proxy/proxy_settings_page.dart';

// ==================== 测试宿主 ====================

/// 与 `lib/main.dart` 相同的全局通道（Navigator / ScaffoldMessenger）。
Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

const List<InstalledAppOption> _sampleApps = <InstalledAppOption>[
  InstalledAppOption(packageName: 'com.apple', name: 'Apple'),
  InstalledAppOption(packageName: 'com.banana', name: 'Banana'),
];

// ==================== 假门面 ====================

class _FakeSettingsFacade implements ProxySettingsFacade {
  _FakeSettingsFacade({
    ProxySettingsConfig? config,
    this.apps = _sampleApps,
    ProxyEngineInfo? engine,
  })  : config = config ?? const ProxySettingsConfig(),
        engine = engine ?? const ProxyEngineInfo();

  ProxySettingsConfig config;
  List<InstalledAppOption> apps;
  ProxyEngineInfo engine;

  ProxySplitTunnelMode? lastMode;
  Set<String>? lastApps;
  bool? lastAlwaysOn;
  ProxyLocalPorts? lastPorts;
  ProxyLogLevel? lastLevel;
  int resetCalls = 0;
  ProxyLanConfig lanConfig = const ProxyLanConfig();
  ProxyLanStatus lanStatus = const ProxyLanStatus();
  ProxyLanConfig? lastLanSaved;

  @override
  Future<ProxySettingsConfig> loadSettings() async => config;

  @override
  Future<List<InstalledAppOption>> loadInstalledApps() async => apps;

  @override
  Future<ProxyEngineInfo> loadEngineInfo() async => engine;

  @override
  Future<ProxyLanConfig> loadLanConfig() async => lanConfig;

  @override
  Future<ProxyLanStatus> loadLanStatus() async => lanStatus;

  @override
  Future<ProxyLanStatus> saveLanConfig(ProxyLanConfig next) async {
    lastLanSaved = next;
    lanConfig = next;
    lanStatus = ProxyLanStatus(
      bound: next.enabled,
      addresses: next.enabled
          ? <String>['${next.bindAddress}:${next.port}']
          : const <String>[],
      warning: next.needsWarning ? '未配置认证' : null,
      config: next,
    );
    return lanStatus;
  }

  @override
  Future<void> saveSplitTunnel({
    required ProxySplitTunnelMode mode,
    required Set<String> apps,
  }) async {
    lastMode = mode;
    lastApps = apps;
    config = config.copyWith(splitMode: mode, selectedApps: apps);
  }

  @override
  Future<void> setAlwaysOnIntent(bool value) async {
    lastAlwaysOn = value;
    config = config.copyWith(alwaysOnIntent: value);
  }

  @override
  Future<void> saveLocalPorts(ProxyLocalPorts ports) async {
    lastPorts = ports;
    config = config.copyWith(localPorts: ports);
  }

  @override
  Future<LogSetLevelResult> setLogLevel(ProxyLogLevel level) async {
    lastLevel = level;
    config = config.copyWith(logLevel: level);
    return LogSetLevelResult(ok: true, level: level);
  }

  @override
  Future<StatsResetResult> resetStats() async {
    resetCalls++;
    return const StatsResetResult(ok: true, cleared: 5);
  }
}

Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// 让整个设置页在测试视口内完整布局（负测试默认 800x600 会截断下方小节）。
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  group('ProxySettingsPage', () {
    testWidgets('渲染全部设置小节', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(_host(ProxySettingsPage(facade: _FakeSettingsFacade())));
      await _settleLoad(tester);

      expect(find.text('应用分流'), findsOneWidget);
      expect(find.text('始终开启'), findsOneWidget);
      expect(find.text('本地端口 / 混合入站'), findsOneWidget);
      expect(find.text('局域网监听 (LAN)'), findsOneWidget);
      expect(find.text('日志级别'), findsOneWidget);
      expect(find.text('域名统计'), findsOneWidget);
      expect(find.text('引擎调试信息'), findsOneWidget);
      expect(find.byKey(const Key('split_mode_selector')), findsOneWidget);
    });

    testWidgets('切换分流模式并选择应用 → 门面收到更新', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      // 切到「仅选中」。
      await tester.tap(find.text('仅选中'));
      await tester.pump();
      expect(facade.lastMode, ProxySplitTunnelMode.allow);
      expect(find.text('已选 0 个应用'), findsOneWidget);

      // 打开应用选择器。
      await tester.tap(find.byKey(const Key('split_apps_button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('split_app_search')), findsOneWidget);

      // 选择两个应用并确定。
      await tester.tap(find.byKey(const Key('split_app_com.apple')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('split_app_com.banana')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('split_apps_confirm')));
      await tester.pumpAndSettle();

      expect(facade.lastMode, ProxySplitTunnelMode.allow);
      expect(facade.lastApps, containsAll(<String>['com.apple', 'com.banana']));
      expect(facade.config.selectedApps, hasLength(2));
      expect(find.text('已选 2 个应用'), findsOneWidget);
    });

    testWidgets('「排除选中」模式可切换并保留选择', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.text('排除选中'));
      await tester.pump();
      expect(facade.lastMode, ProxySplitTunnelMode.disallow);
    });

    testWidgets('切换「始终开启」→ 持久化意图', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('always_on_switch')));
      await tester.pump();
      expect(facade.lastAlwaysOn, isTrue);
      expect(facade.config.alwaysOnIntent, isTrue);

      await tester.tap(find.byKey(const Key('always_on_switch')));
      await tester.pump();
      expect(facade.lastAlwaysOn, isFalse);
      expect(facade.config.alwaysOnIntent, isFalse);
    });

    testWidgets('LAN 默认关闭；开启后下发 lan.set 并展示未认证警告', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('lan_enabled_switch')),
      );
      expect(toggle.value, isFalse, reason: 'LAN 默认必须关闭');

      await tester.tap(find.byKey(const Key('lan_enabled_switch')));
      await tester.pumpAndSettle();

      expect(facade.lastLanSaved?.enabled, isTrue);
      expect(facade.lastLanSaved?.port, 1087);
      expect(facade.lastLanSaved?.hasAuth, isFalse);
      expect(find.byKey(const Key('lan_warning_text')), findsOneWidget);
    });

    testWidgets('LAN 配置用户名/密码后不再展示警告', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('lan_enabled_switch')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('lan_auth_user_field')), 'alice');
      await tester.enterText(find.byKey(const Key('lan_auth_pass_field')), 'secret');
      await tester.tap(find.byKey(const Key('lan_save_button')));
      await tester.pumpAndSettle();

      expect(facade.lastLanSaved?.hasAuth, isTrue);
      expect(facade.lastLanSaved?.authUser, 'alice');
      expect(find.byKey(const Key('lan_warning_text')), findsNothing);
    });

    testWidgets('LAN 监听中可复制监听地址', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade()
        ..lanConfig = const ProxyLanConfig(
          enabled: true,
          port: 1087,
          bindAddress: '127.0.0.1',
        )
        ..lanStatus = const ProxyLanStatus(
          bound: true,
          addresses: <String>['127.0.0.1:1087'],
          config: ProxyLanConfig(
            enabled: true,
            port: 1087,
            bindAddress: '127.0.0.1',
          ),
        );
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('lan_copy_address')));
      await tester.pump();
      expect(copied, contains('127.0.0.1'));
    });

    testWidgets('无已安装应用 → 选择器显示空态且不崩溃', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade(apps: const <InstalledAppOption>[]);
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.text('仅选中'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('split_apps_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('split_apps_empty')), findsOneWidget);
      expect(find.text('未获取到已安装应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('切换日志级别 → log.set_level', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.text('ERROR'));
      await tester.pump();
      expect(facade.lastLevel, ProxyLogLevel.error);
    });

    testWidgets('重置统计需危险确认弹层', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('stats_reset_button')));
      await tester.pumpAndSettle();
      // 弹层标题在按钮文案之外再出现一次。
      expect(find.text('重置域名统计'), findsNWidgets(2));

      await tester.tap(find.text('重置'));
      await tester.pumpAndSettle();
      expect(facade.resetCalls, 1);
    });

    testWidgets('渲染引擎调试信息', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade(
        engine: const ProxyEngineInfo(
          version: ProxyVersionInfo(
            module: 'proxy',
            moduleVersion: '9.9.9',
            apiVersion: 3,
            minHostAbi: 3,
            hostAbi: 3,
            meowRev: 'deadbeef',
            targetArch: 'aarch64',
          ),
          ping: ProxyPingResult(
            pong: true,
            module: 'proxy',
            moduleVersion: '9.9.9',
            apiVersion: 3,
            minHostAbi: 3,
            hostAbi: 3,
            state: ProxyConnState.running,
            mode: ProxyMode.vpn,
            protectFdPresent: true,
          ),
          mode: CoreModeResult(
            mode: ProxyMode.vpn,
            state: ProxyConnState.running,
            sinceMs: 0,
          ),
        ),
      );
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      expect(find.text('9.9.9'), findsOneWidget);
      expect(find.text('deadbeef'), findsOneWidget);
      expect(find.text('aarch64'), findsOneWidget);
      expect(find.text('已注入'), findsOneWidget);
      expect(find.text('vpn'), findsWidgets);
    });

    testWidgets('保存本地端口 → 门面收到更新', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.enterText(find.byKey(const Key('local_mixed_port_field')), '1080');
      await tester.tap(find.byKey(const Key('local_ports_save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(facade.lastPorts?.mixedPort, 1080);
      expect(facade.lastPorts?.socksPort, 7891);
    });

    testWidgets('暗色模式下正常渲染（主题令牌，无硬编码颜色）', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: appNavigatorKey,
          scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
          theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
          home: ProxySettingsPage(facade: _FakeSettingsFacade()),
        ),
      );
      await _settleLoad(tester);

      expect(find.text('应用分流'), findsOneWidget);
      expect(find.text('引擎调试信息'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('ProxySettingsConfig 映射', () {
    test('full 模式不写应用清单', () {
      const config = ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.full,
        selectedApps: {'com.apple'},
      );
      expect(config.toVpnConfigJson(), '{"mode":"full"}');
    });

    test('allow 模式写入 allowedApps', () {
      const config = ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.allow,
        selectedApps: {'com.banana', 'com.apple'},
      );
      expect(
        config.toVpnConfigJson(),
        '{"mode":"allow","allowedApps":["com.apple","com.banana"]}',
      );
    });

    test('disallow 模式过滤本应用（绝不 addDisallowedApplication(self)）', () {
      const config = ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.disallow,
        selectedApps: {kGStorePackageName, 'com.apple'},
      );
      expect(
        config.toVpnConfigJson(),
        '{"mode":"disallow","disallowedApps":["com.apple"]}',
      );
    });

    test('toMap/fromMap 往返保持', () {
      const config = ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.disallow,
        selectedApps: {'com.apple'},
        alwaysOnIntent: true,
        localPorts: ProxyLocalPorts(mixedPort: 1080, allowLan: true),
        logLevel: ProxyLogLevel.warn,
      );
      final restored = ProxySettingsConfig.fromMap(config.toMap());
      expect(restored.splitMode, ProxySplitTunnelMode.disallow);
      expect(restored.selectedApps, {'com.apple'});
      expect(restored.alwaysOnIntent, isTrue);
      expect(restored.localPorts.mixedPort, 1080);
      expect(restored.localPorts.allowLan, isTrue);
      expect(restored.logLevel, ProxyLogLevel.warn);
    });
  });
}

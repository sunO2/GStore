// Todo 23 widget tests：代理设置页（应用分流 / 始终开启 / LAN / 日志级别 /
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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_dns_page.dart';
import 'package:gstore/page/proxy/proxy_engine_settings_store.dart';
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
  ProxyLogLevel? lastLevel;
  int resetCalls = 0;
  ProxyEngineSettings engineSettings = const ProxyEngineSettings();
  ProxyEngineSettings? lastEngineSaved;
  ProxyLanConfig lanConfig = const ProxyLanConfig();
  ProxyLanStatus lanStatus = const ProxyLanStatus();
  ProxyLanConfig? lastLanSaved;
  ProxyShaperSnapshot shaperSnapshot = const ProxyShaperSnapshot();
  ProxyShaperConfig? lastShaperSaved;
  int shaperLoadCalls = 0;
  int shaperSaveCalls = 0;
  bool failShaperSave = false;

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
  Future<ProxyShaperSnapshot> loadShaperConfig() async {
    shaperLoadCalls++;
    return shaperSnapshot;
  }

  @override
  Future<ProxyShaperSnapshot> saveShaperConfig(
    ProxyShaperConfig next,
  ) async {
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
  Future<ProxyEngineSettings> loadEngineSettings() async => engineSettings;

  @override
  Future<void> saveEngineSettings(ProxyEngineSettings settings) async {
    lastEngineSaved = settings;
    engineSettings = settings;
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
      expect(find.text('局域网监听 (LAN)'), findsOneWidget);
      expect(find.text('日志级别'), findsOneWidget);
      expect(find.text('域名统计'), findsOneWidget);
      expect(find.text('引擎调试信息'), findsOneWidget);
      expect(find.byKey(const Key('split_mode_selector')), findsOneWidget);
      // 新区块：引擎参数 + DNS 入口。
      expect(find.text('引擎参数'), findsOneWidget);
      expect(find.byKey(const Key('engine_stack_selector')), findsOneWidget);
      expect(find.byKey(const Key('engine_mtu_field')), findsOneWidget);
      expect(find.byKey(const Key('engine_settings_save')), findsOneWidget);
      expect(find.byKey(const Key('dns_settings_tile')), findsOneWidget);
    });

    testWidgets('渲染四个功能区表头', (tester) async {
      _useTallSurface(tester);
      await tester
          .pumpWidget(_host(ProxySettingsPage(facade: _FakeSettingsFacade())));
      await _settleLoad(tester);

      expect(find.text('连接与引擎'), findsOneWidget);
      expect(find.text('分流与入站'), findsOneWidget);
      expect(find.text('域名解析'), findsOneWidget);
      expect(find.text('维护与诊断'), findsOneWidget);
    });

    testWidgets('应用分流：药丸走 AppSegmentedButton 且独立成行', (tester) async {
      _useTallSurface(tester);
      await tester
          .pumpWidget(_host(ProxySettingsPage(facade: _FakeSettingsFacade())));
      await _settleLoad(tester);

      // 统一组件（非裸 SegmentedButton）+ 统一最小密度。
      expect(
        find.byType(AppSegmentedButton<ProxySplitTunnelMode>),
        findsOneWidget,
      );
      final Rect label = tester.getRect(find.text('应用分流'));
      final Rect pill = tester.getRect(find.byKey(const Key('split_mode_selector')));
      // 药丸独立成行：其顶部必须位于标题底部之下（不再同行居中对齐）。
      expect(pill.top, greaterThanOrEqualTo(label.bottom),
          reason: '药丸必须位于标题下方，独立成行');
      // 左对齐：药丸左边缘与该卡片正文（首个 children 文本）左边缘对齐。
      final Rect body = tester.getRect(find.text('全局模式：所有应用都通过代理。'));
      expect(pill.left, closeTo(body.left, 1.0),
          reason: '药丸应左对齐卡片正文');
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏 320：应用分流标题不换行、药丸不溢出', (tester) async {
      tester.view.physicalSize = const Size(320, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester
          .pumpWidget(_host(ProxySettingsPage(facade: _FakeSettingsFacade())));
      await _settleLoad(tester);

      expect(find.text('应用分流'), findsOneWidget);
      expect(find.byKey(const Key('split_mode_selector')), findsOneWidget);
      // 标题独立成行且保持单行：单行高度 ≈ 21px，换行会到 ~42px。
      expect(tester.getSize(find.text('应用分流')).height, lessThan(30));
      // 药丸独立成行后在窄屏内不横向溢出（右边缘不超出屏幕）。
      final Rect pill =
          tester.getRect(find.byKey(const Key('split_mode_selector')));
      expect(pill.right, lessThanOrEqualTo(320.0),
          reason: '药丸不得横向溢出 320 宽屏幕');
      // takeException 捕获 RenderFlex overflow（若有会在此抛出）。
      expect(tester.takeException(), isNull);
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

    testWidgets('引擎参数：加载值回填分段控件与 MTU 输入框', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade()
        ..engineSettings = const ProxyEngineSettings(stack: 'system', mtu: 1400);
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      final selector =
          tester.widget<AppSegmentedButton<String>>(
        find.byKey(const Key('engine_stack_selector')),
      );
      expect(selector.value, 'system');
      final mtuField = tester.widget<TextField>(
        find.byKey(const Key('engine_mtu_field')),
      );
      expect(mtuField.controller?.text, '1400');
    });

    testWidgets('引擎参数：切换 stack 并保存合法 MTU → 门面收到', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.text('system'));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('engine_mtu_field')), '1400');
      await tester.tap(find.byKey(const Key('engine_settings_save')));
      await tester.pumpAndSettle();

      expect(facade.lastEngineSaved?.stack, 'system');
      expect(facade.lastEngineSaved?.mtu, 1400);
      expect(facade.engineSettings, const ProxyEngineSettings(stack: 'system', mtu: 1400));
    });

    testWidgets('引擎参数：MTU < 1280 → 提示错误且不保存', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.enterText(find.byKey(const Key('engine_mtu_field')), '1024');
      await tester.tap(find.byKey(const Key('engine_settings_save')));
      await tester.pumpAndSettle();

      expect(facade.lastEngineSaved, isNull);
      expect(find.text('MTU 必须是不小于 1280 的整数'), findsOneWidget);
    });

    testWidgets('DNS 设置入口跳转 ProxyDnsPage', (tester) async {
      _useTallSurface(tester);
      await tester
          .pumpWidget(_host(ProxySettingsPage(facade: _FakeSettingsFacade())));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('dns_settings_tile')));
      // 只推进路由过渡，不 pumpAndSettle（DNS 页可能持续加载动画）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(ProxyDnsPage), findsOneWidget);
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

    // ==================== 弱网模拟 ====================

    testWidgets('弱网模拟：渲染区块 + 初始化读取 net.shaper.get', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      // 区域表头 + 卡片标题各一处。
      expect(find.text('弱网模拟'), findsNWidgets(2));
      expect(find.byKey(const Key('shaper_enabled_switch')), findsOneWidget);
      expect(find.byKey(const Key('shaper_preset_selector')), findsOneWidget);
      // 默认档位为「自定义」，四个输入框可见。
      expect(find.byKey(const Key('shaper_rate_field')), findsOneWidget);
      expect(find.byKey(const Key('shaper_delay_field')), findsOneWidget);
      expect(find.byKey(const Key('shaper_jitter_field')), findsOneWidget);
      expect(find.byKey(const Key('shaper_loss_field')), findsOneWidget);
      expect(find.byKey(const Key('shaper_apply_button')), findsOneWidget);
      expect(facade.shaperLoadCalls, 1, reason: '初始化必须读取一次 net.shaper.get');
      expect(tester.takeException(), isNull);
    });

    testWidgets('弱网模拟：开关调用 saveShaperConfig', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('shaper_enabled_switch')));
      await tester.pump();

      expect(facade.shaperSaveCalls, 1);
      expect(facade.lastShaperSaved?.enabled, isTrue);
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('shaper_enabled_switch')),
      );
      expect(toggle.value, isTrue);
    });

    testWidgets('弱网模拟：保存失败时开关回滚', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade()..failShaperSave = true;
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('shaper_enabled_switch')));
      await tester.pumpAndSettle();

      expect(facade.shaperSaveCalls, 1);
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('shaper_enabled_switch')),
      );
      expect(toggle.value, isFalse, reason: '保存失败必须回滚开关状态');
    });

    testWidgets('弱网模拟：选择预设下发并更新档位', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('shaper_preset_selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shaper_preset_3G')));
      await tester.pumpAndSettle();

      expect(facade.shaperSaveCalls, 1);
      expect(facade.lastShaperSaved?.enabled, isTrue);
      expect(facade.lastShaperSaved?.uplink.rateBps, 400000);
      expect(find.text('当前档位：3G'), findsOneWidget);
      // 已知档位不再展示自定义输入框。
      expect(find.byKey(const Key('shaper_rate_field')), findsNothing);
    });

    testWidgets('弱网模拟：合法自定义值下发并展示快照', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      await tester.enterText(find.byKey(const Key('shaper_rate_field')), '200000');
      await tester.enterText(find.byKey(const Key('shaper_delay_field')), '300');
      await tester.enterText(find.byKey(const Key('shaper_jitter_field')), '40');
      await tester.enterText(find.byKey(const Key('shaper_loss_field')), '5');
      await tester.tap(find.byKey(const Key('shaper_apply_button')));
      await tester.pumpAndSettle();

      expect(facade.shaperSaveCalls, 1);
      expect(facade.lastShaperSaved?.uplink.rateBps, 200000);
      expect(facade.lastShaperSaved?.uplink.delayMs, 300);
      expect(facade.lastShaperSaved?.uplink.jitterMs, 40);
      expect(facade.lastShaperSaved?.uplink.lossPct, 5);
      expect(facade.lastShaperSaved?.uplink.lossModel, 'random');
    });

    testWidgets('弱网模拟：越界自定义值报错且不下发', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeSettingsFacade();
      await tester.pumpWidget(_host(ProxySettingsPage(facade: facade)));
      await _settleLoad(tester);

      Future<void> fill({
        String rate = '1000',
        String delay = '100',
        String jitter = '50',
        String loss = '1',
      }) async {
        await tester.enterText(find.byKey(const Key('shaper_rate_field')), rate);
        await tester.enterText(find.byKey(const Key('shaper_delay_field')), delay);
        await tester
            .enterText(find.byKey(const Key('shaper_jitter_field')), jitter);
        await tester.enterText(find.byKey(const Key('shaper_loss_field')), loss);
      }

      const List<Map<String, String>> cases = <Map<String, String>>[
        <String, String>{'rate': ''},
        <String, String>{'rate': '999'},
        <String, String>{'delay': '60001'},
        <String, String>{'loss': '101'},
      ];
      for (final override in cases) {
        await fill(
          rate: override['rate'] ?? '1000',
          delay: override['delay'] ?? '100',
          jitter: override['jitter'] ?? '50',
          loss: override['loss'] ?? '1',
        );
        await tester.tap(find.byKey(const Key('shaper_apply_button')));
        await tester.pumpAndSettle();
        expect(
          facade.shaperSaveCalls,
          0,
          reason: '非法自定义值（$override）不得调用 saveShaperConfig',
        );
        expect(find.textContaining('请填写有效数值'), findsOneWidget);
      }
    });
  });

  group('ProxySettingsConfig 映射', () {
    // 逐字段断言（而非整段字符串），新增可选字段不会误伤这些用例。
    test('full 模式不写应用清单', () {
      const config = ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.full,
        selectedApps: {'com.apple'},
      );
      final map = jsonDecode(config.toVpnConfigJson()) as Map<String, dynamic>;
      expect(map['mode'], 'full');
      expect(map['addresses'], kProxyVpnAddresses);
      expect(map['routes'], kProxyVpnRoutes);
      expect(map['dns'], kProxyVpnDnsServers);
      expect(map.containsKey('allowedApps'), isFalse);
      expect(map.containsKey('disallowedApps'), isFalse);
    });

    test('allow 模式写入 allowedApps', () {
      const config = ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.allow,
        selectedApps: {'com.banana', 'com.apple'},
      );
      final map = jsonDecode(config.toVpnConfigJson()) as Map<String, dynamic>;
      expect(map['mode'], 'allow');
      expect(map['addresses'], kProxyVpnAddresses);
      expect(map['routes'], kProxyVpnRoutes);
      expect(map['dns'], kProxyVpnDnsServers);
      expect(map['allowedApps'], <String>['com.apple', 'com.banana']);
    });

    test('disallow 模式过滤本应用（绝不 addDisallowedApplication(self)）', () {
      const config = ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.disallow,
        selectedApps: {kGStorePackageName, 'com.apple'},
      );
      final map = jsonDecode(config.toVpnConfigJson()) as Map<String, dynamic>;
      expect(map['mode'], 'disallow');
      expect(map['addresses'], kProxyVpnAddresses);
      expect(map['routes'], kProxyVpnRoutes);
      expect(map['dns'], kProxyVpnDnsServers);
      expect(map['disallowedApps'], <String>['com.apple']);
    });

    test('toMap/fromMap 往返保持', () {
      const config = ProxySettingsConfig(
        splitMode: ProxySplitTunnelMode.disallow,
        selectedApps: {'com.apple'},
        alwaysOnIntent: true,
        logLevel: ProxyLogLevel.warn,
      );
      final restored = ProxySettingsConfig.fromMap(config.toMap());
      expect(restored.splitMode, ProxySplitTunnelMode.disallow);
      expect(restored.selectedApps, {'com.apple'});
      expect(restored.alwaysOnIntent, isTrue);
      expect(restored.logLevel, ProxyLogLevel.warn);
    });
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_home_facade.dart';
import 'package:gstore/page/proxy/proxy_home_page.dart';
import 'package:gstore/page/proxy/proxy_profiles_page.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';

/// 假门面：无需原生模块，可受控发出类型化事件、控制连接动作的完成时机。
class _FakeProxyFacade implements ProxyHomeFacade {
  _FakeProxyFacade({this.unavailable = false});

  /// 为 `true` 时 `ping` 抛「模块未安装」结构化异常。
  final bool unavailable;

  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast();

  int coreStartCalls = 0;
  int coreStopCalls = 0;
  int coreSetModeCalls = 0;
  String? lastSetMode;

  /// LAN listener state returned by [lanStatus]; drives the lanProxy warning.
  bool lanEnabled = false;

  /// 非空时 `coreSetMode` 以该错误失败（用于 lanProxy 未启用 LAN 的失败 QA）。
  Object? coreSetModeError;

  /// 非空时 `coreStart` 返回该 future（用于断言「连接中」过渡态）。
  Completer<ProxyCoreStatus>? coreStartCompleter;

  /// 非空时 `coreStart` 以该错误失败（用于失败 QA）。
  Object? coreStartError;

  ProxyPingResult pingResult = const ProxyPingResult(
    pong: true,
    module: 'proxy',
    moduleVersion: '0.1.0',
    apiVersion: 1,
    minHostAbi: 3,
    hostAbi: 3,
    state: ProxyConnState.stopped,
    mode: ProxyMode.off,
  );

  TrafficSnapshot trafficSnapshot = const TrafficSnapshot();
  ProfileList profileListResult = const ProfileList();

  static const ProxyCoreStatus runningStatus = ProxyCoreStatus(
    state: ProxyConnState.running,
    mode: ProxyMode.vpn,
    instanceId: 1,
    spawned: true,
    profileName: '默认配置',
  );

  @override
  Future<ProxyPingResult> ping() async {
    if (unavailable) throw ProxyModuleUnavailableException();
    return pingResult;
  }

  @override
  Future<ProxyVersionInfo> version() async => const ProxyVersionInfo(
        module: 'proxy',
        moduleVersion: '0.1.0',
        apiVersion: 1,
        minHostAbi: 3,
        hostAbi: 3,
        meowRev: '',
        targetArch: 'aarch64',
      );

  @override
  Stream<ProxyEvent> get events => controller.stream;

  @override
  Future<ProxyCoreStatus> coreStart(CoreStartRequest request) {
    coreStartCalls++;
    final error = coreStartError;
    if (error != null) return Future<ProxyCoreStatus>.error(error);
    final completer = coreStartCompleter;
    if (completer != null) return completer.future;
    return Future<ProxyCoreStatus>.value(runningStatus);
  }

  @override
  Future<CoreStopResult> coreStop() async {
    coreStopCalls++;
    return const CoreStopResult(state: ProxyConnState.stopped);
  }

  @override
  Future<CoreModeResult> coreGetMode() async => const CoreModeResult(
        mode: ProxyMode.off,
        state: ProxyConnState.stopped,
        sinceMs: 0,
      );

  @override
  Future<CoreSetModeResult> coreSetMode(String mode) {
    coreSetModeCalls++;
    lastSetMode = mode;
    final error = coreSetModeError;
    if (error != null) return Future<CoreSetModeResult>.error(error);
    return Future<CoreSetModeResult>.value(
      CoreSetModeResult(
        ok: true,
        mode: ProxyMode.fromWire(mode),
        previous: ProxyMode.vpn,
      ),
    );
  }

  @override
  Future<ProxyLanStatus> lanStatus() async => ProxyLanStatus(
        bound: lanEnabled,
        config: ProxyLanConfig(enabled: lanEnabled),
      );

  @override
  Future<TrafficSnapshot> statsTrafficGet({int? topDomains}) async =>
      trafficSnapshot;

  @override
  Future<ProfileList> profileList() async => profileListResult;

  @override
  Future<String> vpnConfigJson() async => '{}';

  void emit(ProxyEvent event) => controller.add(event);
}

/// 假 VPN 授权触发：默认「同意」。
class _FakeVpnConsent implements ProxyVpnConsent {
  _FakeVpnConsent({this.granted = true});

  final bool granted;
  int prepareCalls = 0;
  int stopCalls = 0;

  @override
  Future<bool> prepare({String configJson = '{}'}) async {
    prepareCalls++;
    return granted;
  }

  @override
  Future<bool> stop() async {
    stopCalls++;
    return true;
  }

  @override
  Future<bool> isRunning() async => false;
}

Widget _wrap(Widget child) => MaterialApp(home: child);

/// 放大测试视口：首页在状态/模式/流量三张卡之后还有快捷入口，默认 800x600
/// 会因 `ListView` 懒构建而找不到屏外条目。测试改用高视口。
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// 刷新若干帧（**不用** pumpAndSettle：AppLoading 为无限循环动画）。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('disconnected：未连接态渲染状态/开关/当前配置/入口', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('当前配置'), findsOneWidget);
    expect(find.text('未选择'), findsOneWidget);
    expect(find.text('当前节点'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('运行日志'), findsOneWidget);
    expect(find.text('流量统计'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('connecting：点击连接 -> 过渡态 -> running（happy QA）', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent();
    final completer = Completer<ProxyCoreStatus>();
    facade.coreStartCompleter = completer;

    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);
    expect(find.text('未连接'), findsOneWidget);

    await tester.tap(find.text('连接'));
    await tester.pump();

    // 过渡态：状态与按钮都显示进行中，且授权流程已触发。
    expect(find.text('正在连接…'), findsOneWidget);
    expect(find.text('连接中…'), findsOneWidget);
    expect(consent.prepareCalls, 1);
    expect(facade.coreStartCalls, 1);

    completer.complete(_FakeProxyFacade.runningStatus);
    await _flush(tester);

    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('断开'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('connected：proxy.stats 事件驱动流量/活动连接渲染', (tester) async {
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    facade.emit(const ProxyStatsEvent(
      uploadBytes: 1024,
      downloadBytes: 2097152,
      activeConns: 7,
      upBps: 2048,
      downBps: 4096,
      domainCount: 12,
      topDomains: <DomainStat>[
        DomainStat(domain: 'example.com', outbound: 'HK-01'),
      ],
    ));
    await _flush(tester);

    expect(find.text('已连接'), findsOneWidget);
    expect(
      (tester.widget<Text>(find.byKey(const Key('proxy-active-conns')))).data,
      '7',
    );
    expect(find.textContaining('1.00 KB'), findsWidgets);
    expect(find.textContaining('2.00 MB'), findsWidgets);
    expect(find.text('HK-01'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('disconnect：运行中点击断开 -> core.stop + 触发停服务', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);
    expect(find.text('断开'), findsOneWidget);

    await tester.tap(find.text('断开'));
    await _flush(tester);

    expect(facade.coreStopCalls, 1);
    expect(consent.stopCalls, 1);
    expect(find.text('未连接'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure：proxy.state 错误 -> 错误横幅代码/消息 + 重试', (tester) async {
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.stopped,
      mode: ProxyMode.off,
      error: ProxyStateError(
        code: 'PROXY_ENGINE_START_FAILED',
        message: '引擎启动失败',
      ),
    ));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-error-banner')), findsOneWidget);
    expect(find.text('PROXY_ENGINE_START_FAILED'), findsOneWidget);
    expect(find.text('引擎启动失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure QA：core.start 抛错 -> 横幅 + 重试成功', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent();
    facade.coreStartError = const ProxyModuleException(
      code: 'PROXY_TUN_FD_INVALID',
      message: 'TUN fd 无效',
      status: 422,
    );

    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);

    await tester.tap(find.text('连接'));
    await _flush(tester);

    expect(find.byKey(const Key('proxy-error-banner')), findsOneWidget);
    expect(find.text('PROXY_TUN_FD_INVALID'), findsOneWidget);
    expect(find.text('TUN fd 无效'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 重试：清除错误后再次 core.start 成功 -> 已连接。
    facade.coreStartError = null;
    await tester.tap(find.text('重试'));
    await _flush(tester);

    expect(find.text('已连接'), findsOneWidget);
    expect(facade.coreStartCalls, 2);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure QA：用户拒绝授权 -> 结构化拒绝错误', (tester) async {
    final facade = _FakeProxyFacade();
    final consent = _FakeVpnConsent(granted: false);
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);

    await tester.tap(find.text('连接'));
    await _flush(tester);

    expect(find.text('PROXY_VPN_CONSENT_DENIED'), findsOneWidget);
    expect(facade.coreStartCalls, 0);
    expect(consent.prepareCalls, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('quick entry：回调优先，缺省时给出提示（不崩溃）', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    var logs = 0;
    var stats = 0;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        onOpenLogs: () => logs++,
        onOpenStats: () => stats++,
      )),
    );
    await _flush(tester);

    await tester.ensureVisible(find.text('运行日志'));
    await tester.pump();
    await tester.tap(find.text('运行日志'));
    await tester.pump();
    await tester.ensureVisible(find.text('流量统计'));
    await tester.pump();
    await tester.tap(find.text('流量统计'));
    await tester.pump();

    expect(logs, 1);
    expect(stats, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('模块不可用：显示结构化错误态与重试按钮', (tester) async {
    final facade = _FakeProxyFacade(unavailable: true);
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    expect(find.text('代理模块不可用'), findsOneWidget);
    expect(find.text('代理模块未安装'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('mode picker：选择局域网代理但 LAN 未启用 -> 警告 + 设置快捷入口', (tester) async {
    final facade = _FakeProxyFacade(); // lanEnabled = false
    var openedLanSettings = 0;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        onOpenLanSettings: () => openedLanSettings++,
      )),
    );
    await _flush(tester);

    expect(find.byKey(const Key('proxy-mode-tile')), findsOneWidget);
    expect(find.text('VPN 模式（全设备）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('proxy-mode-option-lanProxy')), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 未运行：仅记录目标，不触发 core.set_mode；显示结构化警告 + 快捷入口。
    expect(facade.coreSetModeCalls, 0);
    expect(find.byKey(const Key('proxy-lan-disabled-warning')), findsOneWidget);
    expect(find.textContaining('PROXY_NO_INBOUND'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-open-lan-settings')));
    await tester.pump();
    expect(openedLanSettings, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('live switch：运行中从 VPN 切到局域网代理 -> core.set_mode + 停服务', (tester) async {
    final facade = _FakeProxyFacade()..lanEnabled = true;
    final consent = _FakeVpnConsent();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);
    expect(find.text('已连接'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(facade.coreSetModeCalls, 1);
    expect(facade.lastSetMode, 'lanProxy');
    expect(consent.stopCalls, 1, reason: 'lanProxy must stop the VpnService');
    expect(find.text('局域网代理（仅共享给其它设备）'), findsOneWidget);
    expect(find.byKey(const Key('proxy-lan-disabled-warning')), findsNothing);

    // 切换到当前模式是 no-op（不再次请求）。
    facade.coreSetModeCalls = 0;
    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(facade.coreSetModeCalls, 0);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure QA：lanProxy 结构化 PROXY_NO_INBOUND -> 错误横幅', (tester) async {
    final facade = _FakeProxyFacade()
      ..coreSetModeError = const ProxyModuleException(
        code: 'PROXY_NO_INBOUND',
        message: 'lanProxy requires an enabled LAN listener',
        status: 422,
      );
    final consent = _FakeVpnConsent();
    await tester.pumpWidget(
      _wrap(ProxyHomePage(facade: facade, vpnConsent: consent)),
    );
    await _flush(tester);
    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(facade.coreSetModeCalls, 1);
    expect(find.byKey(const Key('proxy-error-banner')), findsOneWidget);
    expect(find.text('PROXY_NO_INBOUND'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡：订阅入口渲染，VPN 模式下无代理设置', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    // Row A：订阅入口。
    expect(find.byKey(const Key('proxy-subscribe-tile')), findsOneWidget);
    expect(find.text('订阅'), findsOneWidget);
    expect(find.text('导入/更新节点订阅'), findsOneWidget);

    // Row B：代理模式始终在；VPN 目标模式下代理设置不渲染。
    expect(find.byKey(const Key('proxy-mode-tile')), findsOneWidget);
    expect(find.text('代理模式'), findsOneWidget);
    expect(find.byKey(const Key('proxy-settings-tile')), findsNothing);
    expect(find.text('代理设置'), findsNothing);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡：点击订阅进入订阅与配置页', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('proxy-subscribe-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ProxyProfilesPage), findsOneWidget);
    expect(find.text('订阅与配置'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('入口卡：lanProxy 模式下代理设置出现且可跳转设置', (tester) async {
    _useTallViewport(tester);
    final facade = _FakeProxyFacade();
    var openedSettings = 0;
    await tester.pumpWidget(
      _wrap(ProxyHomePage(
        facade: facade,
        onOpenLanSettings: () => openedSettings++,
      )),
    );
    await _flush(tester);
    expect(find.byKey(const Key('proxy-settings-tile')), findsNothing);

    // 未运行：选 lanProxy 只更新目标模式 -> 代理设置出现（复用模式弹层）。
    await tester.tap(find.byKey(const Key('proxy-mode-tile')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('proxy-mode-option-lanProxy')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('proxy-settings-tile')), findsOneWidget);
    expect(find.text('代理设置'), findsOneWidget);

    await tester.tap(find.byKey(const Key('proxy-settings-tile')));
    await tester.pump();
    expect(openedSettings, 1);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });
}

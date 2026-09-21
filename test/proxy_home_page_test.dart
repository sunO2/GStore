import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_home_page.dart';

/// 假门面：无需原生模块，可受控发出类型化事件。
class _FakeProxyFacade implements ProxyFacade {
  _FakeProxyFacade({this.unavailable = false});

  /// 为 `true` 时 `ping` 抛「模块未安装」结构化异常。
  final bool unavailable;

  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast();

  @override
  Future<ProxyPingResult> ping() async {
    if (unavailable) {
      throw ProxyModuleUnavailableException();
    }
    return const ProxyPingResult(
      pong: true,
      module: 'proxy',
      moduleVersion: '0.1.0',
      apiVersion: 1,
      minHostAbi: 3,
      hostAbi: 3,
      state: ProxyConnState.stopped,
      mode: ProxyMode.off,
    );
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

  void emit(ProxyEvent event) => controller.add(event);
}

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('happy：proxy.state running 更新状态文字为已连接', (tester) async {
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await tester.pump(); // 完成 ping/version

    expect(find.text('未连接'), findsOneWidget);

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.running,
      mode: ProxyMode.vpn,
    ));
    await tester.pump();

    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('模式：VPN'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('failure：proxy.state error 显示错误 UI 且不抛异常', (tester) async {
    final facade = _FakeProxyFacade();
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await tester.pump();

    facade.emit(const ProxyStateEvent(
      state: ProxyConnState.stopped,
      mode: ProxyMode.off,
      error: ProxyStateError(
        code: 'PROXY_ENGINE_START_FAILED',
        message: '引擎启动失败',
      ),
    ));
    await tester.pump();

    expect(find.text('PROXY_ENGINE_START_FAILED'), findsOneWidget);
    expect(find.text('引擎启动失败'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });

  testWidgets('模块不可用：显示结构化错误态与重试按钮', (tester) async {
    final facade = _FakeProxyFacade(unavailable: true);
    await tester.pumpWidget(_wrap(ProxyHomePage(facade: facade)));
    await tester.pump();

    expect(find.text('代理模块不可用'), findsOneWidget);
    expect(find.text('代理模块未安装'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await facade.controller.close();
  });
}

// Todo 28 widget tests：抓包 CA 安装 / 信任状态 + 指纹复制 / QR + 首页摘要。
//
// 全部密闭式：只注入假门面（`ProxyCaptureCaFacade` / `ProxyCaService` /
// `ProxyHomeFacade`），不触碰 FFI / 原生模块 / 真实平台通道。弹层宿主复用生产
// 全局通道 `appNavigatorKey` + `AppDialogs.scaffoldMessengerKey`；剪贴板经
// `SystemChannels.platform` mock 捕获。
//
// 覆盖：
// * 已生成 + 系统证书已安装 → 显示「已安装」；
// * 已生成 + 未安装 → 显示「尚未安装」（不谎报）；
// * 平台通道不可用（不支持检测）→ 显式提示，**不**谎报为未安装；
// * 未生成 → 不展示安装状态；
// * 指纹一键复制 → 剪贴板收到指纹；
// * 证书 QR → 弹层渲染二维码；
// * 首页 `HTTP+HTTPS` 摘要随 CA 生成 / 安装状态变化。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/service/proxy_ca_service.dart';
import 'package:gstore/page/proxy/proxy_capture_ca_page.dart';
import 'package:gstore/page/proxy/proxy_home_facade.dart';
import 'package:gstore/page/proxy/proxy_home_page.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _settleLoad(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 捕获 `Clipboard.setData` 文本。
List<String> _captureClipboard(WidgetTester tester) {
  final captured = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments;
        if (args is Map && args['text'] is String) {
          captured.add(args['text'] as String);
        }
      }
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
  return captured;
}

// ==================== 假实现 ====================

const String _fingerprint = 'AA:BB:CC:DD:EE:FF';
const String _pem =
    '-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----\n';
final Uint8List _der = Uint8List.fromList(<int>[1, 2, 3, 4]);

CaptureCaInfo _generatedInfo() => CaptureCaInfo(
      generated: true,
      pem: _pem,
      derBase64: base64Encode(_der),
      fingerprintSha256: _fingerprint,
    );

class _FakeCaFacade implements ProxyCaptureCaFacade {
  _FakeCaFacade({CaptureCaInfo? info}) : info = info ?? const CaptureCaInfo();

  CaptureCaInfo info;
  bool failGet = false;
  int getCalls = 0;

  @override
  Future<CaptureCaInfo> caGet() async {
    getCalls++;
    if (failGet) throw StateError('状态读取失败（测试注入）');
    return info;
  }

  @override
  Future<CaptureCaInfo> caGenerate({bool regenerate = false}) async {
    info = _generatedInfo();
    return info;
  }

  @override
  Future<CaptureCaResetResult> caReset() async {
    info = const CaptureCaInfo();
    return const CaptureCaResetResult(ok: true, cleared: true);
  }
}

/// 假 CA 服务：可返回已安装 / 未安装，或抛出「通道不可用」。
class _FakeCaService implements ProxyCaService {
  _FakeCaService({
    this.installed = false,
    this.throwUnavailable = false,
    this.throwOther = false,
  });

  bool installed;
  bool throwUnavailable;
  bool throwOther;
  int installedCalls = 0;
  String? lastPem;

  @override
  Future<CaInstallResult> installUserCa(Uint8List bytes) async =>
      const CaInstallResult(ok: true, code: 'OK', userActionRequired: true);

  @override
  Future<CaInstallResult> installSystemCa(String pem) async =>
      const CaInstallResult(ok: true, code: 'OK', installed: true);

  @override
  Future<bool> detectRoot() async => true;

  @override
  Future<bool> systemCaInstalled({String? pem}) async {
    installedCalls++;
    lastPem = pem;
    if (throwUnavailable) {
      throw const ProxyCaException(
        CaInstallResult.channelUnavailableCode,
        '平台通道不可用（非 Android 或插件未注册）',
      );
    }
    if (throwOther) {
      throw const ProxyCaException('PROBE_FAILED', '探测失败（测试注入）');
    }
    return installed;
  }
}

/// 最小 `ProxyHomeFacade` 假实现：仅满足首页只读加载 + 抓包区块。
class _FakeHomeFacade implements ProxyHomeFacade {
  final StreamController<ProxyEvent> _events =
      StreamController<ProxyEvent>.broadcast();

  CaptureConfig? captureConfig = const CaptureConfig(enabled: true);
  CaptureCaInfo captureCa = const CaptureCaInfo(generated: true);

  @override
  Stream<ProxyEvent> get events => _events.stream;

  @override
  Future<ProxyPingResult> ping() async => const ProxyPingResult(
        pong: true,
        module: 'proxy',
        moduleVersion: '0.1.0',
        apiVersion: 1,
        minHostAbi: 3,
        hostAbi: 3,
        state: ProxyConnState.stopped,
        mode: ProxyMode.off,
      );

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
  Future<ProxyCoreStatus> coreStart(CoreStartRequest request) async =>
      const ProxyCoreStatus(
        state: ProxyConnState.running,
        mode: ProxyMode.vpn,
        instanceId: 1,
        spawned: true,
      );

  @override
  Future<CoreStopResult> coreStop() async =>
      const CoreStopResult(state: ProxyConnState.stopped);

  @override
  Future<CoreModeResult> coreGetMode() async => const CoreModeResult(
        mode: ProxyMode.off,
        state: ProxyConnState.stopped,
        sinceMs: 0,
      );

  @override
  Future<CoreSetModeResult> coreSetMode(String mode) async => CoreSetModeResult(
        ok: true,
        mode: ProxyMode.fromWire(mode),
        previous: ProxyMode.vpn,
      );

  @override
  Future<RoutingModeResult> routingGetMode() async =>
      const RoutingModeResult(mode: ProxyRoutingMode.rule, engineRunning: false);

  @override
  Future<RoutingModeSetResult> routingSetMode(String mode) async =>
      RoutingModeSetResult(
        mode: ProxyRoutingMode.fromWire(mode),
        applied: true,
        engineRunning: false,
      );

  @override
  Future<ProxyLanStatus> lanStatus() async => const ProxyLanStatus();

  @override
  Future<TrafficSnapshot> statsTrafficGet({int? topDomains}) async =>
      const TrafficSnapshot();

  @override
  Future<ProfileList> profileList() async => const ProfileList();

  @override
  Future<NodeListResult> nodeList() async => const NodeListResult();

  @override
  Future<ProxyShaperSnapshot> loadShaperConfig() async =>
      const ProxyShaperSnapshot();

  @override
  Future<CaptureConfig> captureConfigGet() async {
    final config = captureConfig;
    if (config == null) throw ProxyModuleUnavailableException();
    return config;
  }

  @override
  Future<CaptureConfig> captureConfigSet(CaptureConfig config) async {
    captureConfig = config;
    return config;
  }

  @override
  Future<CaptureCaInfo> captureCaGet() async => captureCa;

  @override
  Future<String> vpnConfigJson() async => '{}';

  Future<void> close() => _events.close();
}

void main() {
  // ==================== CA 页：安装 / 信任状态 ====================

  group('ProxyCaptureCaPage 安装状态', () {
    testWidgets('已生成 + 系统证书已安装 → 显示已安装', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final service = _FakeCaService(installed: true);
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);
      await tester.pump();

      expect(service.installedCalls, 1);
      expect(service.lastPem, _pem);
      expect(
        find.byKey(const Key('capture_ca_trust_installed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('capture_ca_trust_not_installed')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('已生成 + 未安装 → 显示尚未安装（不谎报）', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final service = _FakeCaService(installed: false);
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);
      await tester.pump();

      expect(service.installedCalls, 1);
      expect(
        find.byKey(const Key('capture_ca_trust_not_installed')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('capture_ca_trust_installed')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('平台通道不可用 → 显式提示不支持，绝不谎报为未安装', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      final service = _FakeCaService(throwUnavailable: true);
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);
      await tester.pump();

      expect(
        find.byKey(const Key('capture_ca_trust_unsupported')),
        findsOneWidget,
      );
      // 不谎报：既不显示已安装，也不显示未安装。
      expect(
        find.byKey(const Key('capture_ca_trust_installed')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('capture_ca_trust_not_installed')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('未生成 → 不展示安装状态，也不探测', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade();
      final service = _FakeCaService(installed: true);
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade, caService: service)),
      );
      await _settleLoad(tester);

      expect(service.installedCalls, 0);
      expect(find.byKey(const Key('capture_ca_trust_installed')), findsNothing);
      expect(
        find.byKey(const Key('capture_ca_trust_not_installed')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('capture_ca_trust_unsupported')),
        findsNothing,
      );
      expect(find.byKey(const Key('capture_ca_status_empty')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== CA 页：指纹复制 / QR ====================

  group('ProxyCaptureCaPage 指纹分享', () {
    testWidgets('一键复制指纹 → 剪贴板收到指纹 + 成功提示', (tester) async {
      _useTallSurface(tester);
      final captured = _captureClipboard(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_copy_fingerprint')));
      await _flush(tester);

      expect(captured, <String>[_fingerprint]);
      expect(find.textContaining('指纹已复制'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('证书 QR → 弹层渲染二维码', (tester) async {
      _useTallSurface(tester);
      final facade = _FakeCaFacade(info: _generatedInfo());
      await tester.pumpWidget(
        _host(ProxyCaptureCaPage(facade: facade)),
      );
      await _settleLoad(tester);

      await tester.tap(find.byKey(const Key('capture_ca_show_qr')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('证书二维码'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // ==================== 首页：抓包摘要随状态变化 ====================

  group('ProxyHomePage 抓包摘要', () {
    Future<_FakeHomeFacade> pumpHome(
      WidgetTester tester, {
      required CaptureCaInfo ca,
      required ProxyCaService caService,
    }) async {
      _useTallSurface(tester);
      final facade = _FakeHomeFacade()
        ..captureConfig = const CaptureConfig(enabled: true)
        ..captureCa = ca;
      await tester.pumpWidget(
        _host(ProxyHomePage(facade: facade, caService: caService)),
      );
      await _flush(tester);
      await tester.pump();
      return facade;
    }

    testWidgets('已生成 + 未安装 → HTTP+HTTPS（CA 未安装）', (tester) async {
      final facade = await pumpHome(
        tester,
        ca: _generatedInfo(),
        caService: _FakeCaService(installed: false),
      );

      expect(find.text('HTTP+HTTPS（CA 未安装）'), findsOneWidget);
      expect(find.text('HTTP+HTTPS'), findsNothing);
      expect(tester.takeException(), isNull);
      await facade.close();
    });

    testWidgets('已生成 + 已安装 → HTTP+HTTPS', (tester) async {
      final facade = await pumpHome(
        tester,
        ca: _generatedInfo(),
        caService: _FakeCaService(installed: true),
      );

      expect(find.text('HTTP+HTTPS'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await facade.close();
    });

    testWidgets('未生成 → 仅 HTTP', (tester) async {
      final facade = await pumpHome(
        tester,
        ca: const CaptureCaInfo(),
        caService: _FakeCaService(installed: false),
      );

      expect(find.text('仅 HTTP'), findsOneWidget);
      expect(find.text('HTTP+HTTPS'), findsNothing);
      expect(tester.takeException(), isNull);
      await facade.close();
    });
  });
}

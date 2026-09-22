// 设备侧「隧道冒烟」集成测试（device-only integration_test harness）。
//
// ## 为什么存在（WHY）
// 本仓库 CI 没有模拟器/设备（`.github/workflows/build.yml` 关闭了 `flutter test`，
// 也没有 device job），因此「流量是否真的经代理内核转发」无法在 CI 断言。计划
// （`.omo/plans/vpn-proxy-kernel.md` §Verification）要求在**连接的真机**上，用一个
// **本地回环 mock 代理/服务器**返回**已知 marker**，让「流量确实被代理」与「域名
// 统计记录了该域名」变成无需人工判断的断言。本文件就是那个被提交的 harness。
//
// ## 怎么跑（HOW）
//   adb devices                                          # 必须有一台已授权设备
//   flutter test integration_test/proxy_tunnel_test.dart -d <deviceId>
// 或经包装脚本（无设备时以清晰信息非零退出）：
//   scripts/ci/run_proxy_tunnel_device_test.sh [deviceId]
//
// ## 覆盖范围与设备前置条款
// 本 harness 走的是**无需 VpnService 授权**的路径：开启仅绑定 `127.0.0.1` 的 LAN
// 入站（`lan.set`），以 `lanProxy` 模式 `core.start`（引擎只连接回环 mock），再用
// `HttpClient` 经该入站请求并由 `stats.domain.get` 断言。真机 `VpnService`/TUN/
// `protect`/always-on 路径**不在本文件断言**，标记为 UNVERIFIED（见
// `document/development/17-代理内核与VPN.md` §10）。**本环境无 adb 设备，故本文件
// 仅保证格式良好、可静态分析，未在设备上执行。**
//
// ## 安全
// 全程只使用本机回环地址与**合成**订阅内容；绝不使用、打印或记录任何真实订阅 URL
// 或 token。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';
import 'package:integration_test/integration_test.dart';

/// mock 代理返回的已知 marker：断言「流量确实经过隧道」的唯一凭据。
const String kTunnelFixtureMarker = 'GSTORE_TUNNEL_FIXTURE_MARKER';

/// fixture 请求目标域名（RFC 2606 保留 TLD，绝不解析到外网）。
const String kTunnelFixtureHost = 'tunnel-fixture.example.test';

/// 仅回环的 HTTP 代理 fixture：对任何**明文**请求返回 [kTunnelFixtureMarker]。
///
/// 它同时扮演计划要求的两个角色：`local mock server returning a known marker`
/// 与 `tiny HTTP fixture the tunnel can dial`（内核的 outbound 节点指向它）。
class MockHttpProxyFixture {
  MockHttpProxyFixture._(this._server, this._subscription);

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;

  int get port => _server.port;

  static Future<MockHttpProxyFixture> start() async {
    final server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: false);
    final subscription = server.listen((request) {
      _handle(request);
    });
    return MockHttpProxyFixture._(server, subscription);
  }

  static void _handle(HttpRequest request) {
    // TLS 隧道（CONNECT）超出本冒烟范围：fixture 只服务明文 HTTP。
    if (request.method == 'CONNECT') {
      request.response.statusCode = HttpStatus.notImplemented;
      request.response.close();
      return;
    }
    // 不关心请求目标，一律回 marker —— 证明请求穿过了内核到达本 fixture。
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.text
      ..write(kTunnelFixtureMarker);
    request.response.close();
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

/// 合成 Clash 订阅 fixture：单个 `http` 节点指向本地 mock fixture。
///
/// 与 `rust/gstore_mod_proxy/tests/fixtures/synthetic_provider.yaml` 同一风格：
/// 全部为自动化生成的测试值，刻意不含任何真实凭据。
String buildFixtureSubscriptionYaml({required int proxyPort}) => '''
# integration_test 合成订阅 fixture —— 仅本机回环，无真实凭据。
proxies:
  - name: tunnel-fixture-node
    type: http
    server: 127.0.0.1
    port: $proxyPort
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - tunnel-fixture-node
rules:
  - MATCH,PROXY
''';

/// 预留一个回环空闲端口（绑定后立即释放，供 LAN 入站使用）。
Future<int> _reserveLoopbackPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// 把「模块不可用 / 未授权」翻译成清晰的设备前置说明（绝不能表现为崩溃）。
String _deviceGateMessage(ProxyModuleUnavailableException error) {
  if (error.declined) {
    return 'DEVICE-ONLY：proxy 模块安装被取消（无授权/无同意）。请在已连接设备上运行并允许安装。';
  }
  return 'DEVICE-ONLY：proxy 模块不可用（无设备 / 未安装 / FFI 不可加载）。'
      '本 harness 需在 adb 连接的真机上运行：'
      'scripts/ci/run_proxy_tunnel_device_test.sh [deviceId]';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('proxy tunnel smoke (device-only)', () {
    testWidgets('经代理内核的请求返回 marker，且域名统计记录了该域名', (tester) async {
      final fixture = await MockHttpProxyFixture.start();
      final module = ProxyModule.instance;
      try {
        // 1) 设备/模块门禁：无设备或未授权 → 明确失败信息，而不是裸异常。
        try {
          final pong = await module.ping();
          expect(pong.pong, isTrue, reason: 'proxy 模块 ping 未返回 pong');
        } on ProxyModuleUnavailableException catch (error) {
          fail(_deviceGateMessage(error));
        }

        // 2) 导入**本地合成**订阅并持久化（绝不使用远程订阅 URL / token）。
        final imported = await module.profileImportText(
          text: buildFixtureSubscriptionYaml(proxyPort: fixture.port),
          name: 'integration-test-fixture',
          contentType: 'text/yaml',
        );
        expect(
          imported.nodeCount,
          greaterThan(0),
          reason: '合成订阅未解析出节点（fixture 形状可能不兼容）',
        );
        final stored =
            await module.profileCreate(ProfileCreateRequest(profile: imported));

        // 3) 开启仅绑定回环的 LAN 入站（无需 VpnService 授权）。
        final inboundPort = await _reserveLoopbackPort();
        final lanStatus = await module.invoke<ProxyLanStatus>(
          'lan.set',
          ProxyLanStatus.fromJson,
          payload: ProxyLanConfig(
            enabled: true,
            port: inboundPort,
            bindAddress: '127.0.0.1',
          ).toRequestJson(),
        );
        expect(
          lanStatus.bound,
          isTrue,
          reason: 'LAN 入站未绑定：${lanStatus.warning ?? 'unknown'}',
        );

        // 4) 连接（`lanProxy` 模式：引擎 + 仅回环入站，不触发系统 VPN 授权）。
        final status = await module.coreStart(
          CoreStartRequest(mode: 'lanProxy', profileId: stored.id),
        );
        expect(
          status.state,
          anyOf(ProxyConnState.running, ProxyConnState.starting),
          reason: 'core.start 未进入运行态：state=${status.state}',
        );

        // 5) 经隧道入站请求 fixture 域名，断言返回 marker。
        final client = HttpClient();
        client.findProxy = (uri) => 'PROXY 127.0.0.1:$inboundPort';
        String body;
        try {
          final request = await client
              .getUrl(Uri.parse('http://$kTunnelFixtureHost/marker'))
              .timeout(const Duration(seconds: 20));
          final response =
              await request.close().timeout(const Duration(seconds: 20));
          body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 20));
        } finally {
          client.close(force: true);
        }
        expect(
          body.contains(kTunnelFixtureMarker),
          isTrue,
          reason: '经隧道请求未返回 marker（body 长度=${body.length}）',
        );
        // 供包装脚本 grep 的确定性通过行（不含任何敏感信息）。
        // ignore: avoid_print
        print('[proxy-tunnel] MARKER ASSERTION PASSED: $kTunnelFixtureMarker');

        // 6) 域名统计必须记录该域名。
        final stats = await module.statsDomainGet(
          const StatsDomainGetRequest(limit: 50),
        );
        final recorded = stats.domains
            .where((d) =>
                d.domain.toLowerCase() == kTunnelFixtureHost.toLowerCase())
            .toList();
        expect(
          recorded,
          isNotEmpty,
          reason: 'stats.domain.get 未记录 $kTunnelFixtureHost'
              '（已记录：${stats.domains.map((d) => d.domain).toList()}）',
        );
        expect(recorded.first.connections, greaterThanOrEqualTo(1));
        // ignore: avoid_print
        print('[proxy-tunnel] DOMAIN STAT RECORDED: $kTunnelFixtureHost');
      } on ProxyModuleException catch (error) {
        // 结构化模块错误 → 清晰失败信息（不是崩溃）。
        fail('DEVICE-ONLY 隧道调用失败：${error.code} / ${error.message}');
      } finally {
        // 拆除：停引擎、关 LAN 入站、关 mock fixture（订单无关，全部 best-effort）。
        try {
          await module.coreStop();
        } on Object {
          // 忽略：可能从未启动。
        }
        try {
          await module.invoke<ProxyLanStatus>(
            'lan.set',
            ProxyLanStatus.fromJson,
            payload: const ProxyLanConfig(
              enabled: false,
              bindAddress: '127.0.0.1',
            ).toRequestJson(),
          );
        } on Object {
          // 忽略：可能从未绑定。
        }
        await fixture.close();
      }
    });
  });
}

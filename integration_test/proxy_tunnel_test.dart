// 设备侧「隧道冒烟 + 请求采集/导出」集成测试（device-only integration_test harness）。
//
// ## 为什么存在（WHY）
// 本仓库 CI 没有模拟器/设备（`.github/workflows/build.yml` 关闭了 `flutter test`，
// 也没有 device job），因此「流量是否真的经代理内核转发」与「请求时间线是否被采集、
// 能否一致导出」无法在 CI 断言。计划（`.omo/plans/vpn-proxy-kernel.md` §Verification、
// `.omo/plans/proxy-request-collector.md` T21）要求在**连接的真机**上，用一个
// **本地回环 mock 代理/服务器**返回**已知 marker**，让「流量确实被代理」「域名统计
// 记录了该域名」「`requests.get` 含该域名且 `dstIp` 非空」「`requests.export` 的 CSV
// 行数与 `requests.get` 一致（+1 表头）」「无载荷 `proxy.request` 脏信号到达事件流」
// 变成无需人工判断的断言。本文件就是那个被提交的 harness。
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
// `HttpClient` 经该入站请求并由 `stats.domain.get` 断言；随后断言
// `requests.get` / `requests.export` / `proxy.request` 的采集端到端契约。真机
// `VpnService`/TUN/`protect`/always-on 路径**不在本文件断言**，标记为 UNVERIFIED
// （见 `document/development/17-代理内核与VPN.md` §10）。**本环境无 adb 设备，故本
// 文件仅保证格式良好、可静态分析，未在设备上执行。**
//
// ## 已知限制（accepted limitation，务必阅读）
// 「**跨 tick 短命流不可见**」：采集走的是 500ms 采样差量法，在两次 tick 之间
// 「开又关」的短命流不会被记录。这是**已知且被接受**的覆盖缺口（见
// `document/development/17-代理内核与VPN.md` §10 与计划 Success criteria），
// **不是缺陷**。本 harness 通过让 HttpClient 保持 keep-alive、连接跨 tick 存活来
// 让流可被采样到；因此若采集断言偶发为空，首先怀疑该限制而非内核回归。
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
import 'package:integration_test/integration_test.dart';

/// mock 代理返回的已知 marker：断言「流量确实经过隧道」的唯一凭据。
const String kTunnelFixtureMarker = 'GSTORE_TUNNEL_FIXTURE_MARKER';

/// fixture 请求目标域名（RFC 2606 保留 TLD，绝不解析到外网）。
const String kTunnelFixtureHost = 'tunnel-fixture.example.test';

/// 采集/导出端到端断言通过行：包装脚本据此判定「断言真的执行了」，缺此行即失败。
const String kCollectionAssertionPassed =
    'REQUESTS COLLECTION EXPORT ASSERTION PASSED';

/// 已知限制的一句话说明，作为打印/断言说明固化，避免覆盖缺口被误读为通过。
const String kShortLivedFlowLimitationNote =
    '跨 tick 短命流不可见（accepted limitation，非缺陷）';

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
    // HTTP/1.1 默认 keep-alive：不主动关闭，让流跨采样 tick 存活（见文件头
    // 「跨 tick 短命流不可见」已知限制）。
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

/// 轮询 `requests.get`（按固定域名过滤），直到出现该域名的记录或超时。
///
/// 返回**最近一次**匹配的完整记录列表（用于与导出行数逐一对账）。使用
/// [RequestGetRequest] 的真实过滤契约（`domain` 为大小写敏感子串），不做任何
/// mock 或产品内部改写。
Future<List<RequestRecord>> _pollRequestRecords(
  ProxyModule module, {
  required String host,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  var matches = const <RequestRecord>[];
  while (DateTime.now().isBefore(deadline)) {
    final page = await module.requestsGet(
      RequestGetRequest(
        limit: 256,
        filter: RequestsFilter(domain: host),
      ),
    );
    matches = page.records
        .where((r) => r.domain.toLowerCase() == host.toLowerCase())
        .toList();
    if (matches.isNotEmpty) {
      return matches;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return matches;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('proxy tunnel smoke + request collection (device-only)', () {
    testWidgets('经隧道请求返回 marker，域名被采集、导出 CSV 行数一致、proxy.request 脏信号到达',
        (tester) async {
      final fixture = await MockHttpProxyFixture.start();
      final module = ProxyModule.instance;
      HttpClient? client;
      StreamSubscription<ProxyRequestEvent>? requestSignalSub;
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

        // 5) 先订阅事件流（广播流不缓冲，必须在产生流量的**之前**挂载），
        //    并清空上次运行的残留记录（stale_state）。
        final dirtySignals = <ProxyRequestEvent>[];
        requestSignalSub = module.events
            .where((event) => event is ProxyRequestEvent)
            .cast<ProxyRequestEvent>()
            .listen(dirtySignals.add);
        final reset = await module.requestsReset();
        expect(reset.ok, isTrue, reason: 'requests.reset 未成功');

        // 6) 经隧道入站请求 fixture 域名，断言返回 marker。
        //    保持连接（keep-alive）不在读完后立即 force-close，使流跨采样 tick 存活。
        client = HttpClient();
        client.findProxy = (uri) => 'PROXY 127.0.0.1:$inboundPort';
        String body;
        final request = await client
            .getUrl(Uri.parse('http://$kTunnelFixtureHost/marker'))
            .timeout(const Duration(seconds: 20));
        final response =
            await request.close().timeout(const Duration(seconds: 20));
        body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 20));
        expect(
          body.contains(kTunnelFixtureMarker),
          isTrue,
          reason: '经隧道请求未返回 marker（body 长度=${body.length}）',
        );
        // 供包装脚本 grep 的确定性通过行（不含任何敏感信息）。
        // ignore: avoid_print
        print('[proxy-tunnel] MARKER ASSERTION PASSED: $kTunnelFixtureMarker');

        // 7) 域名统计必须记录该域名。
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

        // 8) 采集端到端（真实交付面，无 mock 内部）：
        //    `requests.get` 必须包含该域名、且 `dstIp` 非空。
        //    已知限制说明：$kShortLivedFlowLimitationNote —— 见文件头。
        final records = await _pollRequestRecords(
          module,
          host: kTunnelFixtureHost,
        );
        expect(
          records,
          isNotEmpty,
          reason: 'requests.get 未返回 $kTunnelFixtureHost 的记录。'
              '若偶发为空，首先怀疑已知限制「$kShortLivedFlowLimitationNote」'
              '（连接未跨采样 tick 存活），而非内核采集回归。',
        );
        final firstRecord = records.first;
        expect(
          firstRecord.domain.toLowerCase(),
          kTunnelFixtureHost.toLowerCase(),
          reason: 'requests.get 记录的域名不符：${firstRecord.domain}',
        );
        expect(
          firstRecord.dstIp,
          isNotEmpty,
          reason: 'requests.get 记录 $kTunnelFixtureHost 的 dstIp 为空'
              '（契约要求非空 bare IP）',
        );
        final getRows = records.length;
        // ignore: avoid_print
        print('[proxy-requests] REQUESTS.GET RECORDED: $kTunnelFixtureHost'
            ' dstIp=${firstRecord.dstIp} rows=$getRows');

        // 9) 导出 CSV：行数必须 == `requests.get` 行数 + 1（表头）。
        //    同一 filter 保证导出集合与 get 集合一致；读取真实落盘文件逐行计数，
        //    而非仅断言「文件存在」（misleading_success 抵御）。
        final exportResult = await module.requestsExport(
          const RequestExportRequest(
            format: 'csv',
            filter: RequestsFilter(domain: kTunnelFixtureHost),
          ),
        );
        expect(
          exportResult.rows,
          getRows,
          reason: 'requests.export rows=${exportResult.rows}'
              ' 与 requests.get rows=$getRows 不一致',
        );
        expect(
          exportResult.csvPath,
          isNotNull,
          reason: 'requests.export 未返回 csvPath（format=csv）',
        );
        final csvFile = File(exportResult.csvPath!);
        expect(
          await csvFile.exists(),
          isTrue,
          reason: '导出的 CSV 文件不存在：${exportResult.csvPath}',
        );
        final csvLines = const LineSplitter()
            .convert(await csvFile.readAsString())
            .where((line) => line.isNotEmpty)
            .toList();
        expect(
          csvLines.length,
          getRows + 1,
          reason: 'CSV 行数=${csvLines.length}，期望 requests.get rows + 1'
              '（=$getRows + 1 表头）；导出与 get 不一致',
        );
        expect(
          csvLines.first.startsWith('recordId,connId,openTsMs,'),
          isTrue,
          reason: 'CSV 表头列顺序不符：${csvLines.first}',
        );
        // ignore: avoid_print
        print('[proxy-requests] EXPORT CSV ROWS OK: csvRows=${csvLines.length}'
            ' getRows=$getRows');

        // 10) 无载荷 `proxy.request` 脏信号必须到达事件流（仅由 requests::tick 发出，
        //     载荷只有 seq/count/tsMs —— 不含任何逐条请求数据）。
        final signalDeadline = DateTime.now().add(const Duration(seconds: 15));
        while (dirtySignals.isEmpty &&
            DateTime.now().isBefore(signalDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(
          dirtySignals,
          isNotEmpty,
          reason: 'proxy.request 脏信号未在事件流出现'
              '（requests::tick 未发布，或记录未跨 tick 存活：'
              '$kShortLivedFlowLimitationNote）',
        );
        expect(
          dirtySignals.first.count,
          greaterThanOrEqualTo(1),
          reason: 'proxy.request count=${dirtySignals.first.count}，期望 >= 1',
        );
        // ignore: avoid_print
        print('[proxy-requests] $kCollectionAssertionPassed: '
            'domain=$kTunnelFixtureHost getRows=$getRows csvRows=${csvLines.length}'
            ' signals=${dirtySignals.length}');
        // 已知限制固化：显式打印，避免被误读为「覆盖无缺口」。
        // ignore: avoid_print
        print('[proxy-requests] NOTE: $kShortLivedFlowLimitationNote');
      } on ProxyModuleException catch (error) {
        // 结构化模块错误 → 清晰失败信息（不是崩溃）。
        fail('DEVICE-ONLY 隧道/采集调用失败：${error.code} / ${error.message}');
      } finally {
        // 拆除：停引擎、关 LAN 入站、关 mock fixture、取消事件订阅、关 client
        // （订单无关，全部 best-effort）。
        await requestSignalSub?.cancel();
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
        client?.close(force: true);
        await fixture.close();
      }
    });
  });
}

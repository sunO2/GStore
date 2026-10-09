// Todo 30 tests：诊断面板（Clash 回环控制器）+ 日志查看器 + 规则查看器 +
// config 手动触发。
//
// 全部密闭式：门面经假网关（facade 单测）或假门面（widget 测试）注入，
// 不触碰 FFI / 原生模块。弹层宿主复用生产全局通道 `appNavigatorKey` +
// `AppDialogs.scaffoldMessengerKey`，因此走真实的 `AppSheet` / `AppDialogs`
// 呈现路径。
//
// 覆盖（Todo 30 验收）：
// * `diagnostics.clash_api.start/stop/status` 调用正确；
// * `log.get` 级别过滤 + `log.clear`；
// * `rules.get` 规则展示；
// * `config.generate` 生成触发，且结果**不渲染配置正文**（不暴露密钥）；
// * 无隧道时 `PROXY_NOT_CONFIGURED` → 友好错误。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/navigation/nav_key.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_diagnostics_facade.dart';
import 'package:gstore/page/proxy/proxy_diagnostics_page.dart';

// ==================== 测试宿主 ====================

Widget _host(Widget child) => MaterialApp(
      navigatorKey: appNavigatorKey,
      scaffoldMessengerKey: AppDialogs.scaffoldMessengerKey,
      home: child,
    );

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 放大测试视口：诊断页四个小节纵向排布，默认 800×600 会让下方小节落在
/// `ListView` 懒构建窗口之外（控件未挂载）。放大视口让全部小节同屏挂载，
/// 不改变断言语义。
void _useLargeViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

// ==================== 假网关（facade 单测） ====================

/// 假网关：受控返回信封响应并记录方法名 / 载荷；**不触碰 FFI**。
class _FakeGateway implements ProxyModuleGateway {
  _FakeGateway(this.responses);

  final Map<String, Uint8List> responses;
  final List<String> methods = <String>[];
  final Map<String, Uint8List?> payloads = <String, Uint8List?>{};

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    methods.add(method);
    payloads[method] = payload;
    final response = responses[method];
    if (response == null) {
      throw StateError('no stub for $method');
    }
    return response;
  }

  @override
  Stream<ProxyRawEvent> get events => const Stream<ProxyRawEvent>.empty();
}

Uint8List _okEnvelope(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

Map<String, dynamic> _decode(Uint8List? bytes) =>
    jsonDecode(utf8.decode(bytes!)) as Map<String, dynamic>;

// ==================== 假门面（widget 测试） ====================

/// 日志级别强弱序（用于假 `log.get` 的「≥ level」过滤）。
const List<ProxyLogLevel> _levelOrder = <ProxyLogLevel>[
  ProxyLogLevel.debug,
  ProxyLogLevel.info,
  ProxyLogLevel.warn,
  ProxyLogLevel.error,
];

class _FakeDiagnosticsFacade implements ProxyDiagnosticsFacade {
  ClashApiStatus status =
      const ClashApiStatus(enabled: false, bound: false);
  bool failClashStart = false;
  ProxyModuleException clashStartError = const ProxyModuleException(
    code: 'PROXY_NOT_CONFIGURED',
    message: 'engine not running',
  );

  int clashStartCalls = 0;
  int clashStopCalls = 0;
  int clashStatusCalls = 0;
  int? lastStartPort;
  String? lastClashErrorCode;

  List<LogRecord> logRecords = const <LogRecord>[];
  ProxyLogLevel logLevel = ProxyLogLevel.info;
  LogGetRequest? lastLogRequest;
  int logGetCalls = 0;
  int logClearCalls = 0;
  String? lastSetLevel;

  RulesSnapshot rules = const RulesSnapshot();
  int rulesGetCalls = 0;
  int rulesReloadCalls = 0;
  RulesReloadRequest? lastReloadRequest;

  GeneratedConfig generated = const GeneratedConfig(config: 'secret');
  int configGenerateCalls = 0;
  int configApplyCalls = 0;
  GenerateRequest? lastGenerateRequest;
  GenerateRequest? lastApplyRequest;

  @override
  Future<ClashApiStatus> clashApiStart({int port = 0}) async {
    clashStartCalls++;
    lastStartPort = port;
    if (failClashStart) {
      lastClashErrorCode = clashStartError.code;
      throw clashStartError;
    }
    status = ClashApiStatus(
      enabled: true,
      bound: true,
      address: '127.0.0.1:$port',
      port: port,
    );
    return status;
  }

  @override
  Future<ClashApiStopResult> clashApiStop() async {
    clashStopCalls++;
    final was = status.enabled;
    status = const ClashApiStatus(enabled: false, bound: false);
    return ClashApiStopResult(enabled: false, wasRunning: was);
  }

  @override
  Future<ClashApiStatus> clashApiStatus() async {
    clashStatusCalls++;
    return status;
  }

  @override
  Future<LogPage> logGet(LogGetRequest request) async {
    logGetCalls++;
    lastLogRequest = request;
    final records = _filterLogs(request.level);
    return LogPage(records: records, level: logLevel, retained: records.length);
  }

  List<LogRecord> _filterLogs(String? level) {
    if (level == null) return logRecords;
    final threshold = ProxyLogLevel.fromWire(level);
    final index = _levelOrder.indexOf(threshold);
    if (index < 0) return logRecords;
    return logRecords
        .where((r) => _levelOrder.indexOf(r.level) >= index)
        .toList();
  }

  @override
  Future<LogSetLevelResult> logSetLevel(String level) async {
    lastSetLevel = level;
    logLevel = ProxyLogLevel.fromWire(level);
    return LogSetLevelResult(ok: true, level: logLevel);
  }

  @override
  Future<OkResult> logClear() async {
    logClearCalls++;
    logRecords = const <LogRecord>[];
    return const OkResult(ok: true);
  }

  @override
  Future<RulesSnapshot> rulesGet() async {
    rulesGetCalls++;
    return rules;
  }

  @override
  Future<RulesSnapshot> rulesReload(RulesReloadRequest request) async {
    rulesReloadCalls++;
    lastReloadRequest = request;
    return rules;
  }

  @override
  Future<GeneratedConfig> configGenerate(GenerateRequest request) async {
    configGenerateCalls++;
    lastGenerateRequest = request;
    return generated;
  }

  @override
  Future<GeneratedConfig> configApply(GenerateRequest request) async {
    configApplyCalls++;
    lastApplyRequest = request;
    return GeneratedConfig(
      config: generated.config,
      format: generated.format,
      profileId: generated.profileId,
      hash: generated.hash,
      counts: generated.counts,
      applied: true,
      rulesCount: generated.counts.rules,
    );
  }
}

// ==================== 夹具 ====================

const LogRecord _debugRecord = LogRecord(
  cursor: 1,
  tsMs: 1700000000000,
  level: ProxyLogLevel.debug,
  kind: ProxyLogKind.message,
  message: 'debug-hello',
);
const LogRecord _warnRecord = LogRecord(
  cursor: 2,
  tsMs: 1700000000001,
  level: ProxyLogLevel.warn,
  kind: ProxyLogKind.message,
  message: 'warn-hello',
);
const LogRecord _errorRecord = LogRecord(
  cursor: 3,
  tsMs: 1700000000002,
  level: ProxyLogLevel.error,
  kind: ProxyLogKind.message,
  message: 'error-hello',
);

const RulesSnapshot _rulesFixture = RulesSnapshot(
  rules: <RuleLine>[
    RuleLine(
      index: 0,
      lineNumber: 1,
      line: 'DOMAIN-SUFFIX,example.com,PROXY',
      type: 'DOMAIN-SUFFIX',
      value: 'example.com',
      target: 'PROXY',
    ),
    RuleLine(
      index: 1,
      lineNumber: 2,
      line: 'MATCH,DIRECT',
      type: 'MATCH',
      value: '',
      target: 'DIRECT',
    ),
  ],
  finalTarget: 'DIRECT',
  count: 2,
  revision: 7,
);

// ==================== facade 单测 ====================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProxyModuleDiagnosticsFacade', () {
    test('转发 clash/log/rules/config 并按契约解码与透传请求字段', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        ProxyMethods.clashApiStart: _okEnvelope(<String, dynamic>{
          'enabled': true,
          'bound': true,
          'address': '127.0.0.1:9090',
          'loopbackOnly': true,
          'port': 9090,
        }),
        ProxyMethods.clashApiStop: _okEnvelope(<String, dynamic>{
          'enabled': false,
          'wasRunning': true,
        }),
        ProxyMethods.clashApiStatus: _okEnvelope(<String, dynamic>{
          'enabled': false,
          'bound': false,
          'loopbackOnly': true,
        }),
        ProxyMethods.logGet: _okEnvelope(<String, dynamic>{
          'records': <Map<String, dynamic>>[
            <String, dynamic>{
              'cursor': 5,
              'tsMs': 1,
              'level': 'warn',
              'kind': 'message',
              'message': 'hello',
            },
          ],
          'cursor': 5,
          'nextCursor': 5,
          'firstCursor': 1,
          'retained': 1,
          'capacity': 1000,
          'level': 'info',
        }),
        ProxyMethods.logSetLevel: _okEnvelope(<String, dynamic>{
          'ok': true,
          'level': 'debug',
        }),
        ProxyMethods.logClear: _okEnvelope(<String, dynamic>{'ok': true}),
        ProxyMethods.rulesGet: _okEnvelope(<String, dynamic>{
          'rules': <Map<String, dynamic>>[
            <String, dynamic>{
              'index': 0,
              'lineNumber': 1,
              'line': 'MATCH,DIRECT',
              'type': 'MATCH',
              'value': '',
              'target': 'DIRECT',
            },
          ],
          'final': 'DIRECT',
          'count': 1,
          'revision': 3,
        }),
        ProxyMethods.rulesReload: _okEnvelope(<String, dynamic>{
          'rules': <Map<String, dynamic>>[],
          'count': 0,
          'revision': 4,
        }),
        ProxyMethods.configGenerate: _okEnvelope(<String, dynamic>{
          'config': 'mode: rule\n',
          'format': 'clash',
          'template': 'gstore-controlled-v1',
          'profileId': 'p1',
          'hash': 'abc123',
          'counts': <String, dynamic>{'proxies': 2, 'groups': 1, 'rules': 3},
        }),
        ProxyMethods.configApply: _okEnvelope(<String, dynamic>{
          'config': 'mode: rule\n',
          'format': 'clash',
          'hash': 'abc123',
          'counts': <String, dynamic>{'proxies': 2, 'groups': 1, 'rules': 3},
          'applied': true,
          'rules': 3,
        }),
      });
      final ProxyDiagnosticsFacade facade =
          ProxyModuleDiagnosticsFacade(ProxyModule(gateway: gateway));

      final started = await facade.clashApiStart(port: 9090);
      final stopped = await facade.clashApiStop();
      final status = await facade.clashApiStatus();
      final page = await facade.logGet(
        const LogGetRequest(level: 'warn', limit: 50),
      );
      final setLevel = await facade.logSetLevel('debug');
      final cleared = await facade.logClear();
      final rules = await facade.rulesGet();
      final reloaded = await facade.rulesReload(
        const RulesReloadRequest(config: 'rules: []'),
      );
      final generated = await facade.configGenerate(
        const GenerateRequest(profileId: 'p1'),
      );
      final applied = await facade.configApply(
        const GenerateRequest(profileId: 'p1'),
      );

      expect(gateway.methods, <String>[
        ProxyMethods.clashApiStart,
        ProxyMethods.clashApiStop,
        ProxyMethods.clashApiStatus,
        ProxyMethods.logGet,
        ProxyMethods.logSetLevel,
        ProxyMethods.logClear,
        ProxyMethods.rulesGet,
        ProxyMethods.rulesReload,
        ProxyMethods.configGenerate,
        ProxyMethods.configApply,
      ]);

      // 请求字段透传到线缆。
      expect(_decode(gateway.payloads[ProxyMethods.clashApiStart])['port'], 9090);
      expect(_decode(gateway.payloads[ProxyMethods.logGet])['level'], 'warn');
      expect(_decode(gateway.payloads[ProxyMethods.logGet])['limit'], 50);
      expect(
        _decode(gateway.payloads[ProxyMethods.logSetLevel])['level'],
        'debug',
      );
      expect(gateway.payloads[ProxyMethods.logClear], isNull);
      expect(gateway.payloads[ProxyMethods.rulesGet], isNull);
      expect(
        _decode(gateway.payloads[ProxyMethods.rulesReload])['config'],
        'rules: []',
      );
      expect(
        _decode(gateway.payloads[ProxyMethods.configGenerate])['profileId'],
        'p1',
      );
      expect(
        _decode(gateway.payloads[ProxyMethods.configApply])['profileId'],
        'p1',
      );

      // 类型化解码。
      expect(started.enabled, isTrue);
      expect(started.address, '127.0.0.1:9090');
      expect(started.port, 9090);
      expect(stopped.enabled, isFalse);
      expect(stopped.wasRunning, isTrue);
      expect(status.enabled, isFalse);
      expect(page.records.single.message, 'hello');
      expect(page.records.single.level, ProxyLogLevel.warn);
      expect(setLevel.level, ProxyLogLevel.debug);
      expect(cleared.ok, isTrue);
      expect(rules.count, 1);
      expect(rules.revision, 3);
      expect(rules.finalTarget, 'DIRECT');
      expect(reloaded.revision, 4);
      expect(generated.counts.proxies, 2);
      expect(generated.counts.rules, 3);
      expect(generated.hash, 'abc123');
      expect(applied.applied, isTrue);
      expect(applied.rulesCount, 3);
    });

    test('缺字段 / 空响应不崩溃（解码为默认值）', () async {
      final gateway = _FakeGateway(<String, Uint8List>{
        ProxyMethods.clashApiStatus: _okEnvelope(const <String, dynamic>{}),
        ProxyMethods.logGet: _okEnvelope(const <String, dynamic>{}),
        ProxyMethods.rulesGet: _okEnvelope(const <String, dynamic>{}),
        ProxyMethods.configGenerate: _okEnvelope(const <String, dynamic>{}),
      });
      final ProxyDiagnosticsFacade facade =
          ProxyModuleDiagnosticsFacade(ProxyModule(gateway: gateway));

      final status = await facade.clashApiStatus();
      final page = await facade.logGet(const LogGetRequest());
      final rules = await facade.rulesGet();
      final generated =
          await facade.configGenerate(const GenerateRequest());

      expect(status.enabled, isFalse);
      expect(page.records, isEmpty);
      expect(rules.rules, isEmpty);
      expect(rules.finalTarget, 'DIRECT');
      expect(generated.config, '');
    });
  });

  // ==================== widget 测试 ====================

  Widget page(_FakeDiagnosticsFacade facade) =>
      _host(ProxyDiagnosticsPage(facade: facade));

  testWidgets('happy：Clash 诊断启停与状态刷新调用正确且标注「仅诊断」', (tester) async {
    final facade = _FakeDiagnosticsFacade();
    _useLargeViewport(tester);
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    // 打开页面即读一次状态。
    expect(facade.clashStatusCalls, 1);

    // 「仅用于诊断」必须显式标注。
    expect(find.textContaining('仅用于诊断'), findsWidgets);

    // 启动：端口留空 → 0（ephemeral）。
    await tester.tap(find.byKey(const Key('diagnostics_clash_start')));
    await _flush(tester);
    expect(facade.clashStartCalls, 1);
    expect(facade.lastStartPort, 0);
    expect(find.textContaining('127.0.0.1:0'), findsWidgets);

    // 刷新状态。
    await tester.tap(find.byKey(const Key('diagnostics_clash_refresh')));
    await _flush(tester);
    expect(facade.clashStatusCalls, greaterThanOrEqualTo(2));

    // 停止。
    await tester.tap(find.byKey(const Key('diagnostics_clash_stop')));
    await _flush(tester);
    expect(facade.clashStopCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failure：无隧道启动诊断控制器 → 友好错误提示', (tester) async {
    final facade = _FakeDiagnosticsFacade()..failClashStart = true;
    _useLargeViewport(tester);
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('diagnostics_clash_start')));
    await tester.pumpAndSettle();

    expect(facade.lastClashErrorCode, 'PROXY_NOT_CONFIGURED');
    expect(find.textContaining('隧道'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('happy：日志按级别过滤且清空调用 log.clear', (tester) async {
    final facade = _FakeDiagnosticsFacade()
      ..logRecords = const <LogRecord>[_debugRecord, _warnRecord, _errorRecord];
    _useLargeViewport(tester);
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    // 默认无级别过滤：三条都显示。
    expect(find.byKey(const Key('diagnostics_log_record_1')), findsOneWidget);
    expect(find.byKey(const Key('diagnostics_log_record_2')), findsOneWidget);
    expect(find.byKey(const Key('diagnostics_log_record_3')), findsOneWidget);

    // 选 WARN → 只保留 warn / error。
    await tester.tap(find.byKey(const Key('diagnostics_log_level_warn')));
    await _flush(tester);
    expect(facade.lastLogRequest?.level, 'warn');
    expect(find.byKey(const Key('diagnostics_log_record_1')), findsNothing);
    expect(find.byKey(const Key('diagnostics_log_record_2')), findsOneWidget);
    expect(find.byKey(const Key('diagnostics_log_record_3')), findsOneWidget);

    // 清空：危险确认弹层 → log.clear；随后空态。
    await tester.tap(find.byKey(const Key('diagnostics_log_clear')));
    await tester.pumpAndSettle();
    expect(find.text('清空日志'), findsWidgets);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(facade.logClearCalls, 1);
    expect(find.text('暂无日志'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('happy：规则查看器展示 rules 且可触发 rules.reload', (tester) async {
    final facade = _FakeDiagnosticsFacade()..rules = _rulesFixture;
    _useLargeViewport(tester);
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    expect(facade.rulesGetCalls, 1);
    expect(find.byKey(const Key('diagnostics_rule_0')), findsOneWidget);
    expect(find.byKey(const Key('diagnostics_rule_1')), findsOneWidget);
    expect(find.text('DOMAIN-SUFFIX'), findsWidgets);
    expect(find.text('example.com'), findsWidgets);
    expect(find.textContaining('最终'), findsWidgets);

    // 手动重载：弹层内粘贴内联 config → rules.reload。
    await tester.tap(find.byKey(const Key('diagnostics_rules_reload')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('diagnostics_rules_config_field')),
      'rules:\n  - MATCH,DIRECT\n',
    );
    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(facade.rulesReloadCalls, 1);
    expect(facade.lastReloadRequest?.config, contains('MATCH,DIRECT'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('happy：config.generate 触发展示摘要且不渲染配置正文（不暴露密钥）',
      (tester) async {
    final facade = _FakeDiagnosticsFacade()
      ..generated = const GeneratedConfig(
        config: 'proxies:\n  - password: super-secret-value\n',
        format: 'clash',
        template: 'gstore-controlled-v1',
        profileId: 'p1',
        hash: 'deadbeef',
        counts: ProxyConfigCounts(proxies: 2, groups: 1, rules: 3),
      );
    _useLargeViewport(tester);
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    await tester.enterText(
      find.byKey(const Key('diagnostics_config_profile')),
      'p1',
    );
    await tester.tap(find.byKey(const Key('diagnostics_config_generate')));
    await _flush(tester);

    expect(facade.configGenerateCalls, 1);
    expect(facade.lastGenerateRequest?.profileId, 'p1');
    // 摘要展示（hash / 计数）…
    expect(find.textContaining('deadbeef'), findsWidgets);
    expect(find.textContaining('2'), findsWidgets);
    // …但**绝不**渲染配置正文（其中可能含密钥）。
    expect(find.textContaining('super-secret-value'), findsNothing);
    expect(find.textContaining('配置正文已省略'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('happy：config.apply 手动触发并展示 applied 结果', (tester) async {
    final facade = _FakeDiagnosticsFacade()
      ..generated = const GeneratedConfig(
        config: 'secret',
        counts: ProxyConfigCounts(proxies: 2, groups: 1, rules: 3),
      );
    _useLargeViewport(tester);
    await tester.pumpWidget(page(facade));
    await _flush(tester);

    await tester.tap(find.byKey(const Key('diagnostics_config_apply')));
    await _flush(tester);

    expect(facade.configApplyCalls, 1);
    expect(find.textContaining('已应用'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_requests_facade.dart';

/// 假网关：受控返回信封响应；**不触碰 FFI**。
class _FakeGateway implements ProxyModuleGateway {
  _FakeGateway(this.responses);

  final Map<String, Uint8List> responses;
  final List<String> methods = <String>[];

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    methods.add(method);
    final response = responses[method];
    if (response == null) {
      throw StateError('no stub for $method');
    }
    return response;
  }

  @override
  Stream<ProxyRawEvent> get events => const Stream<ProxyRawEvent>.empty();
}

/// 成功信封 `{ok:true,data:{...}}`。
Uint8List _okEnvelope(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

/// 假门面：证明 [ProxyRequestsFacade] 可由外部实现注入（T15 widget 测试缝）。
class _FakeRequestsFacade implements ProxyRequestsFacade {
  int getCalls = 0;
  int resetCalls = 0;
  int exportCalls = 0;
  RequestGetRequest? lastGet;
  RequestExportRequest? lastExport;

  @override
  Future<RequestPage> requestsGet(RequestGetRequest request) async {
    getCalls++;
    lastGet = request;
    return const RequestPage(
      records: <RequestRecord>[
        RequestRecord(
          recordId: 42,
          connId: 'c-1',
          openTsMs: 1000,
          closeTsMs: 1200,
          durationMs: 200,
          domain: 'example.com',
          domainKnown: true,
          dstIp: '93.184.216.34',
          dstPort: 443,
          src: '10.0.0.2:5555',
          network: 'tcp',
          uid: 10123,
          packages: <String>['com.example.app'],
          uidState: ProxyUidState.known,
          rule: 'DOMAIN-SUFFIX',
          rulePayload: 'example.com',
          outbound: 'PROXY',
          uploadBytes: 10,
          downloadBytes: 2048,
          closeReason: 'closed',
        ),
      ],
      nextCursor: 42,
      firstCursor: 42,
      retained: 1,
      capacity: 4096,
      dropped: 0,
      evicted: 0,
      windowStartMs: 500,
    );
  }

  @override
  Future<void> requestsReset() async {
    resetCalls++;
  }

  @override
  Future<RequestExportResult> requestsExport(
    RequestExportRequest request,
  ) async {
    exportCalls++;
    lastExport = request;
    return const RequestExportResult(
      csvPath: '/data/proxy_requests_export_1.csv',
      jsonPath: '/data/proxy_requests_export_1.json',
      rows: 1,
      bytes: 512,
      generatedAtMs: 1700000000000,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('假实现可满足门面契约并返回类型化模型', () async {
    final ProxyRequestsFacade facade = _FakeRequestsFacade();

    final page = await facade.requestsGet(
      const RequestGetRequest(cursor: 7, limit: 50),
    );
    await facade.requestsReset();
    final export = await facade.requestsExport(
      const RequestExportRequest(format: 'csv'),
    );

    // 断言类型化值（而非仅存在性）。
    expect(page.records, hasLength(1));
    final record = page.records.single;
    expect(record.recordId, 42);
    expect(record.domain, 'example.com');
    expect(record.domainKnown, isTrue);
    expect(record.dstIp, '93.184.216.34');
    expect(record.dstPort, 443);
    expect(record.uid, 10123);
    expect(record.packages, <String>['com.example.app']);
    expect(record.uidState, ProxyUidState.known);
    expect(record.durationMs, 200);
    expect(record.downloadBytes, 2048);
    expect(record.closeReason, 'closed');
    expect(page.nextCursor, 42);
    expect(page.retained, 1);

    expect(export.csvPath, '/data/proxy_requests_export_1.csv');
    expect(export.jsonPath, '/data/proxy_requests_export_1.json');
    expect(export.rows, 1);
    expect(export.bytes, 512);

    final fake = facade as _FakeRequestsFacade;
    expect(fake.getCalls, 1);
    expect(fake.resetCalls, 1);
    expect(fake.exportCalls, 1);
    expect(fake.lastGet!.cursor, 7);
    expect(fake.lastExport!.format, 'csv');
  });

  test('ProxyModuleRequestsFacade 转发并解码类型化响应', () async {
    final gateway = _FakeGateway(<String, Uint8List>{
      ProxyMethods.requestsGet: _okEnvelope(<String, dynamic>{
        'records': <Map<String, dynamic>>[
          <String, dynamic>{
            'recordId': 9,
            'connId': 'c-9',
            'openTsMs': 100,
            'closeTsMs': 150,
            'durationMs': 50,
            'domain': '1.1.1.1',
            'domainKnown': false,
            'dstIp': '1.1.1.1',
            'dstPort': 53,
            'src': '10.0.0.2:53000',
            'network': 'tcp',
            'uid': null,
            'packages': <String>[],
            'uidState': 'unknown',
            'rule': '',
            'rulePayload': '',
            'outbound': 'DIRECT',
            'uploadBytes': 0,
            'downloadBytes': 0,
            'closeReason': 'open',
          },
        ],
        'nextCursor': 9,
        'firstCursor': 9,
        'retained': 1,
        'capacity': 4096,
        'dropped': 0,
        'evicted': 0,
        'windowStartMs': 0,
      }),
      ProxyMethods.requestsReset: _okEnvelope(<String, dynamic>{
        'ok': true,
        'cleared': 3,
      }),
      ProxyMethods.requestsExport: _okEnvelope(<String, dynamic>{
        'csvPath': '/data/exp.csv',
        'rows': 9,
        'bytes': 1024,
      }),
    });
    final ProxyRequestsFacade facade =
        ProxyModuleRequestsFacade(ProxyModule(gateway: gateway));

    final page = await facade.requestsGet(const RequestGetRequest(limit: 10));
    await facade.requestsReset();
    final export = await facade.requestsExport(
      const RequestExportRequest(format: 'both'),
    );

    expect(gateway.methods, <String>[
      ProxyMethods.requestsGet,
      ProxyMethods.requestsReset,
      ProxyMethods.requestsExport,
    ]);
    final record = page.records.single;
    expect(record.recordId, 9);
    expect(record.domainKnown, isFalse);
    expect(record.uid, isNull);
    expect(record.uidState, ProxyUidState.unknown);
    expect(record.closeReason, 'open');
    expect(page.nextCursor, 9);

    // 未请求 JSON → jsonPath 缺省为 null（不解码为伪造路径）。
    expect(export.csvPath, '/data/exp.csv');
    expect(export.jsonPath, isNull);
    expect(export.rows, 9);
    expect(export.bytes, 1024);
  });

  test('缺字段 / 空响应不崩溃（解码为默认值）', () async {
    final gateway = _FakeGateway(<String, Uint8List>{
      ProxyMethods.requestsGet: _okEnvelope(const <String, dynamic>{}),
      ProxyMethods.requestsReset: _okEnvelope(const <String, dynamic>{}),
      ProxyMethods.requestsExport: _okEnvelope(const <String, dynamic>{}),
    });
    final ProxyRequestsFacade facade =
        ProxyModuleRequestsFacade(ProxyModule(gateway: gateway));

    final page = await facade.requestsGet(const RequestGetRequest());
    await facade.requestsReset();
    final export = await facade.requestsExport(const RequestExportRequest());

    expect(page.records, isEmpty);
    expect(page.nextCursor, 0);
    expect(export.csvPath, isNull);
    expect(export.jsonPath, isNull);
    expect(export.rows, 0);
    expect(export.bytes, 0);
  });
}

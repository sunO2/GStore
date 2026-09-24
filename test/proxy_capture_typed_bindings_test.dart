// Todo 35 tests：抓包 / CA typed 绑定（经 `invoke` 信封）。
//
// 密闭式：注入假 [ProxyModuleGateway]（不触碰 FFI），记录每次调用的**精确**
// 方法名与载荷字节；断言 typed 方法经 `invoke` 信封转发，且参数编码正确。
//
// 覆盖：
// * `capture.config.*` / `capture.ca.*` / `captures.*` / `capture.rules.*` 的
//   方法名 + 载荷（反向断言，杜绝误导性成功）；
// * 模块不可用 → 结构化 [ProxyModuleUnavailableException]（不崩溃、不裸抛）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 记录型假网关：返回受控信封 + 记录 (method, payload)。
class _RecordingGateway implements ProxyModuleGateway {
  _RecordingGateway(this.responses);

  final Map<String, Uint8List> responses;
  final List<String> methods = <String>[];
  final List<Uint8List?> payloads = <Uint8List?>[];

  /// 命中即抛（模拟模块加载失败）。
  final Set<String> failingMethods = <String>{};

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    methods.add(method);
    payloads.add(payload);
    if (failingMethods.contains(method)) {
      throw StateError('module load failed: $method');
    }
    final response = responses[method];
    if (response == null) {
      throw StateError('no stub for $method');
    }
    return response;
  }

  @override
  Stream<ProxyRawEvent> get events => const Stream<ProxyRawEvent>.empty();

  /// 解出第 [index] 次调用的载荷 JSON（无载荷时为 null）。
  Map<String, dynamic>? payloadAt(int index) {
    final payload = payloads[index];
    if (payload == null) return null;
    return jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
  }
}

Uint8List _ok(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

void main() {
  test('capture.ca.generate/reset 经 invoke 信封，方法名 + 载荷精确', () async {
    final gateway = _RecordingGateway(<String, Uint8List>{
      ProxyMethods.captureCaGet: _ok(<String, dynamic>{'generated': false}),
      ProxyMethods.captureCaGenerate:
          _ok(<String, dynamic>{'generated': true, 'fingerprintSha256': 'f'}),
      ProxyMethods.captureCaReset:
          _ok(<String, dynamic>{'ok': true, 'cleared': true}),
    });
    final module = ProxyModule(gateway: gateway);

    final existing = await module.captureCaGet();
    expect(existing.generated, isFalse);
    expect(gateway.methods[0], 'capture.ca.get');
    expect(gateway.payloadAt(0), isNull, reason: 'ca.get 不发载荷');

    final generated =
        await module.captureCaGenerate(const CaptureCaGenerateRequest(regenerate: true));
    expect(generated.generated, isTrue);
    expect(generated.fingerprintSha256, 'f');
    expect(gateway.methods[1], 'capture.ca.generate');
    expect(gateway.payloadAt(1), <String, dynamic>{'regenerate': true});

    // 缺省 regenerate：仍走同一方法，载荷为空对象（不臆造键）。
    await module.captureCaGenerate();
    expect(gateway.methods[2], 'capture.ca.generate');
    expect(gateway.payloadAt(2), <String, dynamic>{});

    final reset = await module.captureCaReset();
    expect(reset.ok, isTrue);
    expect(reset.cleared, isTrue);
    expect(gateway.methods[3], 'capture.ca.reset');
    expect(gateway.payloadAt(3), isNull, reason: 'ca.reset 不发载荷');
  });

  test('captures.get/detail/reset 经 invoke 信封，方法名 + 载荷精确', () async {
    final gateway = _RecordingGateway(<String, Uint8List>{
      ProxyMethods.capturesGet: _ok(<String, dynamic>{
        'records': <Map<String, dynamic>>[
          <String, dynamic>{'recordId': 1, 'method': 'GET'},
        ],
        'nextCursor': 1,
      }),
      ProxyMethods.capturesDetail: _ok(<String, dynamic>{
        'recordId': 42,
        'method': 'POST',
        'reqBody': base64Encode(utf8.encode('full')),
      }),
      ProxyMethods.capturesReset:
          _ok(<String, dynamic>{'ok': true, 'cleared': 3}),
    });
    final module = ProxyModule(gateway: gateway);

    final page = await module.capturesGet(
      const CapturesGetRequest(
        cursor: 1,
        limit: 5,
        filter: CapturesFilter(
          host: 'a.example',
          method: 'GET',
          statusClass: 2,
          protocol: 'h2',
          requestRecordId: 7,
        ),
      ),
    );
    expect(gateway.methods[0], 'captures.get');
    expect(page.records.single.recordId, 1);
    expect(gateway.payloadAt(0), <String, dynamic>{
      'cursor': 1,
      'limit': 5,
      'filter': <String, dynamic>{
        'host': 'a.example',
        'method': 'GET',
        'statusClass': 2,
        'protocol': 'h2',
        'requestRecordId': 7,
      },
    });

    // 缺省请求：空对象载荷。
    await module.capturesGet();
    expect(gateway.methods[1], 'captures.get');
    expect(gateway.payloadAt(1), <String, dynamic>{});

    final detail = await module.capturesDetail(42);
    expect(gateway.methods[2], 'captures.detail');
    expect(gateway.payloadAt(2), <String, dynamic>{'recordId': 42});
    expect(utf8.decode(detail.reqBody), 'full');

    final reset = await module.capturesReset();
    expect(reset.cleared, 3);
    expect(gateway.methods[3], 'captures.reset');
    expect(gateway.payloadAt(3), isNull);
  });

  test('capture.config.* / capture.rules.* typed 绑定复用且方法名精确', () async {
    final gateway = _RecordingGateway(<String, Uint8List>{
      ProxyMethods.captureConfigGet:
          _ok(<String, dynamic>{'enabled': true, 'tlsPorts': <int>[443]}),
      ProxyMethods.captureConfigSet:
          _ok(<String, dynamic>{'enabled': false, 'tlsPorts': <int>[443]}),
      ProxyMethods.captureRulesGet: _ok(<String, dynamic>{
        'rules': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'r1', 'enabled': true, 'url': 'https://a/x'},
        ],
      }),
      ProxyMethods.captureRulesSet:
          _ok(<String, dynamic>{'id': 'r1', 'enabled': false, 'url': 'https://a/x'}),
      ProxyMethods.captureRulesRemove:
          _ok(<String, dynamic>{'ok': true, 'removed': true}),
    });
    final module = ProxyModule(gateway: gateway);

    final cfg = await module.captureConfigGet();
    expect(cfg.enabled, isTrue);
    expect(gateway.methods[0], 'capture.config.get');

    await module.captureConfigSet(
      const CaptureConfig(enabled: false, tlsPorts: <int>[443]),
    );
    expect(gateway.methods[1], 'capture.config.set');
    expect(gateway.payloadAt(1), <String, dynamic>{
      'enabled': false,
      'tlsPorts': <int>[443],
      'domainAllowlist': <String>[],
      'appAllowlist': <String>[],
      'appScope': 'uid',
      'captureBody': true,
      'captureWs': true,
      'captureH2': true,
      'maxBodyBytes': 1048576,
    });

    final rules = await module.captureRulesGet();
    expect(rules.single.id, 'r1');
    expect(gateway.methods[2], 'capture.rules.get');

    await module.captureRulesSet(
      const CaptureRuleSetRequest(enabled: true, url: 'https://a/x'),
    );
    expect(gateway.methods[3], 'capture.rules.set');
    expect(gateway.payloadAt(3), <String, dynamic>{
      'enabled': true,
      'url': 'https://a/x',
      'kind': 'replace',
    });

    final removed = await module.captureRulesRemove('r1');
    expect(removed.removed, isTrue);
    expect(gateway.methods[4], 'capture.rules.remove');
    expect(gateway.payloadAt(4), <String, dynamic>{'id': 'r1'});
  });

  test('模块不可用 → 结构化 ProxyModuleUnavailableException（不裸抛、不崩）',
      () async {
    final gateway = _RecordingGateway(<String, Uint8List>{})
      ..failingMethods.add(ProxyMethods.capturesGet);
    final module = ProxyModule(gateway: gateway);

    await expectLater(
      module.capturesGet(),
      throwsA(
        isA<ProxyModuleUnavailableException>().having(
          (e) => e.code,
          'code',
          'PROXY_MODULE_UNINSTALLED',
        ),
      ),
    );
  });
}

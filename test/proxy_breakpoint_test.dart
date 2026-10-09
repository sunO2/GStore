import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 假网关：只回放一个固定信封；**不触碰 FFI**。
class _StubGateway implements ProxyModuleGateway {
  _StubGateway(this.response);

  final Uint8List response;
  final List<String> methods = <String>[];

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    methods.add(method);
    return response;
  }

  @override
  Stream<ProxyRawEvent> get events => const Stream<ProxyRawEvent>.empty();
}

Uint8List _ok(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('captures.breakpoint.* 契约草图（API.md §2.20）', () {
    test('ProxyBreakpointConfig 默认关闭且有界', () {
      const cfg = ProxyBreakpointConfig();
      expect(cfg.enabled, isFalse, reason: '默认必须关闭（不改流量行为）');
      expect(cfg.timeoutMs, 15000);
      expect(cfg.scope, 'both');
      expect(cfg.urlPattern, isEmpty);
      expect(cfg.matchType, 'exact');
    });

    test('ProxyBreakpointConfig fromJson/toJson 往返保真', () {
      const fixture = <String, dynamic>{
        'enabled': true,
        'timeoutMs': 20000,
        'scope': 'response',
        'urlPattern': 'https://api.example.com/',
        'matchType': 'glob',
      };
      final cfg = ProxyBreakpointConfig.fromJson(fixture);
      expect(cfg.enabled, isTrue);
      expect(cfg.timeoutMs, 20000);
      expect(cfg.scope, 'response');
      expect(cfg.urlPattern, 'https://api.example.com/');
      expect(cfg.matchType, 'glob');

      final decoded = ProxyBreakpointConfig.fromJson(cfg.toJson());
      expect(decoded.enabled, cfg.enabled);
      expect(decoded.timeoutMs, cfg.timeoutMs);
      expect(decoded.scope, cfg.scope);
      expect(decoded.urlPattern, cfg.urlPattern);
      expect(decoded.matchType, cfg.matchType);
    });

    test('ProxyBreakpointConfig 缺省/畸形字段宽容解码', () {
      final cfg = ProxyBreakpointConfig.fromJson(const <String, dynamic>{});
      expect(cfg.enabled, isFalse);
      expect(cfg.timeoutMs, 15000);
      expect(cfg.scope, 'both');
      expect(cfg.matchType, 'exact');
    });

    test('ProxyBreakpointPending 解码全部关联字段', () {
      const fixture = <String, dynamic>{
        'handle': 'bp-1',
        'phase': 'request',
        'method': 'POST',
        'url': 'https://api.example.com/p',
        'host': 'api.example.com',
        'connId': 'uuid-1',
        'requestRecordId': 7,
        'statusCode': 0,
        'headers': 'host: api.example.com',
        'body': 'eyJvayI6dHJ1ZX0=',
        'truncated': false,
        'createdAtMs': 1700000000000,
        'expiresAtMs': 1700000015000,
      };
      final pending = ProxyBreakpointPending.fromJson(fixture);
      expect(pending.handle, 'bp-1');
      expect(pending.phase, 'request');
      expect(pending.method, 'POST');
      expect(pending.url, 'https://api.example.com/p');
      expect(pending.host, 'api.example.com');
      expect(pending.connId, 'uuid-1');
      expect(pending.requestRecordId, 7);
      expect(pending.statusCode, 0);
      expect(pending.headers, 'host: api.example.com');
      expect(pending.body, 'eyJvayI6dHJ1ZX0=');
      expect(pending.truncated, isFalse);
      expect(pending.createdAtMs, 1700000000000);
      expect(pending.expiresAtMs, 1700000015000);
    });

    test('ProxyBreakpointList 解码 pending + count', () {
      final list = ProxyBreakpointList.fromJson(const <String, dynamic>{
        'pending': <Map<String, dynamic>>[
          <String, dynamic>{'handle': 'bp-1', 'phase': 'response'},
        ],
        'count': 1,
      });
      expect(list.count, 1);
      expect(list.pending, hasLength(1));
      expect(list.pending.first.handle, 'bp-1');
      expect(list.pending.first.phase, 'response');
    });

    test('resume/cancel 请求省略未编辑字段', () {
      final resume = const ProxyBreakpointResumeRequest(handle: 'bp-1').toJson();
      expect(resume, <String, dynamic>{'handle': 'bp-1'});
      final edited = const ProxyBreakpointResumeRequest(
        handle: 'bp-1',
        method: 'PUT',
        body: 'eyJvayI6dHJ1ZX0=',
      ).toJson();
      expect(edited['method'], 'PUT');
      expect(edited['body'], 'eyJvayI6dHJ1ZX0=');
      expect(edited.containsKey('url'), isFalse);
      expect(edited.containsKey('headers'), isFalse);

      expect(
        const ProxyBreakpointCancelRequest('bp-1').toJson(),
        <String, dynamic>{'handle': 'bp-1'},
      );
    });

    test('resume/cancel 结果解码', () {
      final resumed = ProxyBreakpointResumeResult.fromJson(
        const <String, dynamic>{
          'ok': true,
          'handle': 'bp-1',
          'resumed': true,
          'phase': 'request',
        },
      );
      expect(resumed.ok, isTrue);
      expect(resumed.resumed, isTrue);
      expect(resumed.phase, 'request');

      final cancelled = ProxyBreakpointCancelResult.fromJson(
        const <String, dynamic>{
          'ok': true,
          'handle': 'bp-1',
          'cancelled': true,
          'phase': 'response',
        },
      );
      expect(cancelled.ok, isTrue);
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.phase, 'response');
    });

    test('proxy.capture.breakpoint 事件解码为类型化子类', () {
      final event = ProxyEvent.decode(ProxyRawEvent(
        eventType: 'proxy.capture.breakpoint',
        data: Uint8List.fromList(utf8.encode(jsonEncode(const <String, dynamic>{
          'handle': 'bp-1',
          'phase': 'request',
          'method': 'GET',
          'url': 'https://api.example.com/p',
        }))),
      ));
      expect(event, isA<ProxyCaptureBreakpointEvent>());
      final bp = event! as ProxyCaptureBreakpointEvent;
      expect(bp.handle, 'bp-1');
      expect(bp.phase, 'request');
      expect(bp.pending.method, 'GET');
    });

    test('门面方法经正确的方法名调用', () async {
      final gateway = _StubGateway(_ok(const <String, dynamic>{
        'enabled': false,
        'timeoutMs': 15000,
        'scope': 'both',
        'urlPattern': '',
        'matchType': 'exact',
      }));
      final facade = ProxyModule(gateway: gateway);

      final cfg = await facade.capturesBreakpointGet();
      expect(cfg.enabled, isFalse);
      expect(gateway.methods, <String>[ProxyMethods.capturesBreakpointGet]);

      final set = await facade.capturesBreakpointSet(
        const ProxyBreakpointConfig(enabled: true),
      );
      expect(set.enabled, isFalse, reason: '回放的是 stub 信封');
      expect(gateway.methods.last, ProxyMethods.capturesBreakpointSet);
    });

    test('注册表一致性：方法/事件/解码器/编码器', () {
      for (final method in const <String>[
        'captures.breakpoint.get',
        'captures.breakpoint.set',
        'captures.breakpoint.list',
        'captures.breakpoint.resume',
        'captures.breakpoint.cancel',
      ]) {
        expect(ProxyMethods.all, contains(method));
        expect(proxyResponseDecoders.containsKey(method), isTrue,
            reason: '$method 缺少解码器');
      }
      expect(ProxyEvents.all, contains('proxy.capture.breakpoint'));
      for (final method in const <String>[
        'captures.breakpoint.set',
        'captures.breakpoint.resume',
        'captures.breakpoint.cancel',
      ]) {
        expect(proxyRequestEncoders.containsKey(method), isTrue,
            reason: '$method 缺少请求编码器');
      }
    });
  });
}

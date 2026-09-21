import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 假网关：受控返回信封响应 + 可推送原始事件；**不触碰 FFI**。
class _FakeGateway implements ProxyModuleGateway {
  _FakeGateway(this.responses);

  final Map<String, Uint8List> responses;
  final StreamController<ProxyRawEvent> controller =
      StreamController<ProxyRawEvent>.broadcast();
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
  Stream<ProxyRawEvent> get events => controller.stream;
}

/// 成功信封 `{ok:true,data:{...}}`。
Uint8List _okEnvelope(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

/// 错误信封 `{status,code,message}`（无 `ok:true`）。
Uint8List _errorEnvelope(int status, String code, String message) =>
    Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{
        'status': status,
        'code': code,
        'message': message,
      })),
    );

Uint8List _eventJson(Map<String, dynamic> data) =>
    Uint8List.fromList(utf8.encode(jsonEncode(data)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ping 解码为类型化结果', () async {
    final gateway = _FakeGateway(<String, Uint8List>{
      'ping': _okEnvelope(<String, dynamic>{
        'pong': true,
        'module': 'proxy',
        'moduleVersion': '0.1.0',
        'apiVersion': 1,
        'minHostAbi': 3,
        'hostAbi': 3,
        'instanceId': 7,
        'state': 'stopped',
        'mode': 'off',
        'protectFdPresent': true,
      }),
    });
    final facade = ProxyModule(gateway: gateway);

    final ping = await facade.ping();

    expect(ping.pong, isTrue);
    expect(ping.module, 'proxy');
    expect(ping.moduleVersion, '0.1.0');
    expect(ping.apiVersion, 1);
    expect(ping.minHostAbi, 3);
    expect(ping.hostAbi, 3);
    expect(ping.instanceId, 7);
    expect(ping.state, ProxyConnState.stopped);
    expect(ping.mode, ProxyMode.off);
    expect(ping.protectFdPresent, isTrue);
    expect(ping.hostCompatible, isTrue);
    expect(gateway.methods, <String>['ping']);
  });

  test('version 解码为类型化结果', () async {
    final gateway = _FakeGateway(<String, Uint8List>{
      'version': _okEnvelope(<String, dynamic>{
        'module': 'proxy',
        'moduleVersion': '0.1.0',
        'apiVersion': 1,
        'minHostAbi': 3,
        'hostAbi': 3,
        'meowRev': 'abc123',
        'targetArch': 'aarch64',
      }),
    });
    final facade = ProxyModule(gateway: gateway);

    final version = await facade.version();

    expect(version.module, 'proxy');
    expect(version.moduleVersion, '0.1.0');
    expect(version.meowRev, 'abc123');
    expect(version.targetArch, 'aarch64');
    expect(version.hostCompatible, isTrue);
    expect(gateway.methods, <String>['version']);
  });

  test('事件流把 proxy.state 解码为 ProxyStateEvent', () async {
    final gateway = _FakeGateway(const <String, Uint8List>{});
    final facade = ProxyModule(gateway: gateway);

    final pending = facade.events.first;
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.state',
      data: _eventJson(<String, dynamic>{
        'state': 'running',
        'mode': 'vpn',
        'reason': 'user',
      }),
    ));

    final event = await pending;
    expect(event, isA<ProxyStateEvent>());
    final state = event as ProxyStateEvent;
    expect(state.eventType, 'proxy.state');
    expect(state.state, ProxyConnState.running);
    expect(state.mode, ProxyMode.vpn);
    expect(state.reason, 'user');
    expect(state.isRunning, isTrue);
    expect(state.hasError, isFalse);

    await gateway.controller.close();
  });

  test('proxy.state 携带 error 时解码为 ProxyStateError', () async {
    final gateway = _FakeGateway(const <String, Uint8List>{});
    final facade = ProxyModule(gateway: gateway);

    final pending = facade.events.first;
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.state',
      data: _eventJson(<String, dynamic>{
        'state': 'stopped',
        'mode': 'off',
        'error': {
          'code': 'PROXY_ENGINE_START_FAILED',
          'message': '引擎启动失败',
        },
      }),
    ));

    final state = await pending as ProxyStateEvent;
    expect(state.hasError, isTrue);
    expect(state.error!.code, 'PROXY_ENGINE_START_FAILED');
    expect(state.error!.message, '引擎启动失败');

    await gateway.controller.close();
  });

  test('proxy.stats / proxy.subscription.* / proxy.node.delay 解码为类型化事件', () async {
    final gateway = _FakeGateway(const <String, Uint8List>{});
    final facade = ProxyModule(gateway: gateway);
    final events = facade.events;

    final statsPending = events.firstWhere((e) => e is ProxyStatsEvent);
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.stats',
      data: _eventJson(<String, dynamic>{
        'uploadBytes': 100,
        'downloadBytes': 200,
        'activeConns': 3,
        'upBps': 1024,
        'downBps': 2048,
      }),
    ));
    final stats = await statsPending as ProxyStatsEvent;
    expect(stats.uploadBytes, 100);
    expect(stats.downloadBytes, 200);
    expect(stats.activeConns, 3);
    expect(stats.upBps, 1024);

    final updatedPending =
        events.firstWhere((e) => e is ProxySubscriptionUpdatedEvent);
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.subscription.updated',
      data: _eventJson(<String, dynamic>{
        'profileId': 'p1',
        'nodeCount': 42,
        'traffic': <String, dynamic>{'uploadBytes': 1, 'downloadBytes': 2},
        'expireAtMs': 1234,
      }),
    ));
    final updated = await updatedPending as ProxySubscriptionUpdatedEvent;
    expect(updated.profileId, 'p1');
    expect(updated.nodeCount, 42);
    expect(updated.traffic.uploadBytes, 1);
    expect(updated.traffic.downloadBytes, 2);
    expect(updated.expireAtMs, 1234);

    final addedPending =
        events.firstWhere((e) => e is ProxySubscriptionAddedEvent);
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.subscription.added',
      data: _eventJson(<String, dynamic>{'profileId': 'p2', 'name': 'sub'}),
    ));
    final added = await addedPending as ProxySubscriptionAddedEvent;
    expect(added.profileId, 'p2');
    expect(added.name, 'sub');

    final removedPending =
        events.firstWhere((e) => e is ProxySubscriptionRemovedEvent);
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.subscription.removed',
      data: _eventJson(<String, dynamic>{'profileId': 'p3'}),
    ));
    final removed = await removedPending as ProxySubscriptionRemovedEvent;
    expect(removed.profileId, 'p3');

    final delayPending = events.firstWhere((e) => e is ProxyNodeDelayEvent);
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.node.delay',
      data: _eventJson(<String, dynamic>{
        'group': 'g1',
        'node': 'n1',
        'delayMs': 88,
      }),
    ));
    final delay = await delayPending as ProxyNodeDelayEvent;
    expect(delay.group, 'g1');
    expect(delay.node, 'n1');
    expect(delay.delayMs, 88);

    await gateway.controller.close();
  });

  test('proxy.subscription.progress/updated/failed 解码为类型化事件', () async {
    final gateway = _FakeGateway(const <String, Uint8List>{});
    final facade = ProxyModule(gateway: gateway);
    final events = facade.events;

    final progressPending =
        events.firstWhere((e) => e is ProxySubscriptionProgressEvent);
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.subscription.progress',
      data: _eventJson(<String, dynamic>{
        'profileId': 'p1',
        'phase': 'fetch',
        'state': 'started',
        'attempts': 2,
      }),
    ));
    final progress = await progressPending as ProxySubscriptionProgressEvent;
    expect(progress.profileId, 'p1');
    expect(progress.phase, ProxySubscriptionPhase.fetch);
    expect(progress.state, ProxySubscriptionProgressState.started);
    expect(progress.attempts, 2);
    expect(progress.eventType, 'proxy.subscription.progress');

    final updatedPending =
        events.firstWhere((e) => e is ProxySubscriptionUpdatedEvent);
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.subscription.updated',
      data: _eventJson(<String, dynamic>{
        'profileId': 'p1',
        'nodeCount': 12,
        'traffic': <String, dynamic>{
          'uploadBytes': 10,
          'downloadBytes': 20,
          'totalBytes': 100,
          'usedBytes': 30,
        },
        'expireAtMs': 1700000000000,
        'lastUpdatedAtMs': 1690000000000,
        'intervalMs': 3600000,
        'nextRefreshAtMs': 1693600000000,
      }),
    ));
    final updated = await updatedPending as ProxySubscriptionUpdatedEvent;
    expect(updated.nodeCount, 12);
    expect(updated.traffic.uploadBytes, 10);
    expect(updated.traffic.downloadBytes, 20);
    expect(updated.traffic.totalBytes, 100);
    expect(updated.traffic.usedBytes, 30);
    expect(updated.expireAtMs, 1700000000000);
    expect(updated.lastUpdatedAtMs, 1690000000000);
    expect(updated.intervalMs, 3600000);
    expect(updated.nextRefreshAtMs, 1693600000000);

    final failedPending =
        events.firstWhere((e) => e is ProxySubscriptionFailedEvent);
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.subscription.failed',
      data: _eventJson(<String, dynamic>{
        'profileId': 'p1',
        'attempts': 3,
        'consecutiveFailures': 2,
        'lastAttemptMs': 1690000001000,
        'nextRefreshAtMs': 1690000061000,
        'error': <String, dynamic>{
          'code': 'PROXY_SUB_FETCH_FAILED',
          'message': 'connect refused',
        },
      }),
    ));
    final failed = await failedPending as ProxySubscriptionFailedEvent;
    expect(failed.profileId, 'p1');
    expect(failed.attempts, 3);
    expect(failed.consecutiveFailures, 2);
    expect(failed.nextRefreshAtMs, 1690000061000);
    expect(failed.error!.code, 'PROXY_SUB_FETCH_FAILED');
    expect(failed.error!.message, 'connect refused');

    await gateway.controller.close();
  });

  test('未知事件名被静默忽略（不入流、不抛错）', () async {
    final gateway = _FakeGateway(const <String, Uint8List>{});
    final facade = ProxyModule(gateway: gateway);

    final received = <ProxyEvent>[];
    final sub = facade.events.listen(received.add);
    await Future<void>.delayed(Duration.zero);

    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.unknown',
      data: _eventJson(<String, dynamic>{'x': 1}),
    ));
    gateway.controller.add(ProxyRawEvent(
      eventType: 'proxy.mode',
      data: _eventJson(<String, dynamic>{'mode': 'vpn', 'previous': 'off'}),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.single, isA<ProxyModeEvent>());
    expect((received.single as ProxyModeEvent).mode, ProxyMode.vpn);

    await sub.cancel();
    await gateway.controller.close();
  });

  test('信封错误映射为 ProxyModuleException（含 status/code）', () async {
    final gateway = _FakeGateway(<String, Uint8List>{
      'ping': _errorEnvelope(405, 'METHOD_NOT_FOUND', 'method not found: proxy.x'),
    });
    final facade = ProxyModule(gateway: gateway);

    await expectLater(
      facade.ping(),
      throwsA(
        isA<ProxyModuleException>()
            .having((e) => e.code, 'code', 'METHOD_NOT_FOUND')
            .having((e) => e.status, 'status', 405),
      ),
    );
  });
}

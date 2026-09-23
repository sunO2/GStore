import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/service/proxy_status_notification.dart';
import 'package:gstore/page/proxy/proxy_active_node_store.dart';
import 'package:gstore/page/proxy/proxy_active_profile_store.dart';

/// 记录通知出口调用的 spy；无需 Flutter binding / 原生插件。
class _FakeNotifier implements ProxyStatusNotifier {
  final List<String> bodies = <String>[];
  final List<String> titles = <String>[];
  String? lastSubText;
  List<String>? lastLines;
  int showCount = 0;
  int cancelCount = 0;
  int requestPermissionCount = 0;
  bool initialized = false;

  @override
  Future<void> init() async {
    initialized = true;
  }

  @override
  Future<void> requestPermission() async {
    requestPermissionCount++;
  }

  @override
  Future<void> show({
    required String title,
    required String body,
    String? subText,
    List<String>? lines,
  }) async {
    showCount++;
    titles.add(title);
    bodies.add(body);
    lastSubText = subText;
    lastLines = lines;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
  }
}

/// 可推送类型化事件 + 返回受控只读数据的假来源。
class _FakeSource implements ProxyStatusSource {
  final StreamController<ProxyEvent> controller =
      StreamController<ProxyEvent>.broadcast();

  NodeListResult nodeResult = const NodeListResult();
  ProfileList profileResult = const ProfileList();
  int nodeListCalls = 0;
  int profileListCalls = 0;

  void add(ProxyEvent event) => controller.add(event);

  @override
  Stream<ProxyEvent> get events => controller.stream;

  @override
  Future<NodeListResult> nodeList() async {
    nodeListCalls++;
    return nodeResult;
  }

  @override
  Future<ProfileList> profileList() async {
    profileListCalls++;
    return profileResult;
  }

  Future<void> close() => controller.close();
}

class _FakeProfileStore implements ProxyActiveProfileStore {
  String? id;

  @override
  Future<String?> read() async => id;

  @override
  Future<void> write(String value) async => id = value;

  @override
  Future<void> clear() async => id = null;
}

class _FakeNodeStore implements ProxyActiveNodeStore {
  ProxyActiveNode? node;

  @override
  Future<ProxyActiveNode?> read() async => node;

  @override
  Future<void> write(ProxyActiveNode selection) async => node = selection;

  @override
  Future<void> clear() async => node = null;
}

const int _kb = 1024;
const int _mb = 1024 * 1024;

ProxyStatsEvent _stats({
  int upBps = 0,
  int downBps = 0,
  int uploadBytes = 0,
  int downloadBytes = 0,
}) =>
    ProxyStatsEvent(
      uploadBytes: uploadBytes,
      downloadBytes: downloadBytes,
      activeConns: 0,
      upBps: upBps,
      downBps: downBps,
    );

void main() {
  group('formatProxySpeed', () {
    test('renders B/s, KB/s and MB/s', () {
      expect(formatProxySpeed(0), '0 B/s');
      expect(formatProxySpeed(512), '512 B/s');
      expect(formatProxySpeed(_kb), '1.00 KB/s');
      expect(formatProxySpeed(1536), '1.50 KB/s');
      expect(formatProxySpeed(2 * _mb), '2.00 MB/s');
    });

    test('clamps negative rates to zero', () {
      expect(formatProxySpeed(-1), '0 B/s');
    });
  });

  group('ProxyStatusNotificationService', () {
    late _FakeNotifier notifier;
    late _FakeSource source;
    late _FakeProfileStore profileStore;
    late _FakeNodeStore nodeStore;
    late DateTime now;
    late ProxyStatusNotificationService service;

    setUp(() {
      notifier = _FakeNotifier();
      source = _FakeSource();
      profileStore = _FakeProfileStore();
      nodeStore = _FakeNodeStore();
      now = DateTime(2026, 1, 1, 0, 0, 0);
      service = ProxyStatusNotificationService(
        notifier: notifier,
        source: source,
        profileStore: profileStore,
        nodeStore: nodeStore,
        clock: () => now,
      );
      source.nodeResult = const NodeListResult(
        engineRunning: true,
        current: NodeCurrent(group: 'PROXY', now: 'node-A'),
      );
      source.profileResult = const ProfileList(
        profiles: <ProfileSummary>[
          ProfileSummary(id: 'p1', name: '订阅A', nodeCount: 3),
        ],
      );
      profileStore.id = 'p1';
    });

    tearDown(() async {
      await service.stop();
      await source.close();
    });

    /// 让挂在事件上的异步处理器（含两次门面读取）跑完。
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('maps speed/totals/subscription/node into a 4-line inbox body',
        () async {
      await service.start();
      expect(notifier.initialized, isTrue);

      source.add(const ProxyStateEvent(
        state: ProxyConnState.running,
        mode: ProxyMode.lanProxy,
      ));
      source.add(_stats(upBps: 1536, downBps: 2 * _mb));
      // 同一时刻 stats 受 ~1s 地板限制，但首次 state 已强制展示；推进时钟后
      // 让 stats 刷新一次速率与累计。
      now = now.add(const Duration(milliseconds: 1100));
      source.add(_stats(
        upBps: 1536,
        downBps: 2 * _mb,
        uploadBytes: 5 * _mb,
        downloadBytes: 3 * _mb,
      ));
      await settle();

      expect(notifier.bodies.length, 2);
      // 折叠态正文仅实时速率（Android contentText 单行，不可含换行）。
      final collapsed = notifier.bodies.last;
      expect(collapsed, '↑ 1.50 KB/s  ↓ 2.00 MB/s');
      expect(collapsed, isNot(contains('累计')));

      // 展开态 InboxStyle：恰好 4 行。
      final lines = notifier.lastLines;
      expect(lines, isNotNull);
      expect(lines!.length, 4);
      expect(lines[0], '实时  ↑ 1.50 KB/s  ↓ 2.00 MB/s');
      expect(lines[1], '累计  ↑ 5.00 MB  ↓ 3.00 MB');
      expect(lines[2], '订阅  订阅A');
      expect(lines[3], '节点  node-A');
      expect(notifier.lastSubText, '局域网代理');
    });

    test('throttles stats-driven refreshes to the ~1s floor', () async {
      await service.start();
      source.add(const ProxyStateEvent(
        state: ProxyConnState.running,
        mode: ProxyMode.vpn,
      ));
      await settle();
      expect(notifier.bodies.length, 1);

      // 0ms / +400ms：均在地板内 → 不展示。
      source.add(_stats(upBps: 100));
      now = now.add(const Duration(milliseconds: 400));
      source.add(_stats(upBps: 200));
      await settle();
      expect(notifier.bodies.length, 1);

      // 累计 1100ms ≥ 1s → 展示一次。
      now = now.add(const Duration(milliseconds: 700));
      source.add(_stats(upBps: 300));
      await settle();
      expect(notifier.bodies.length, 2);
      expect(notifier.bodies.last, contains('300 B/s'));
    });

    test('cancels the notification when the proxy stops', () async {
      await service.start();
      source.add(const ProxyStateEvent(
        state: ProxyConnState.running,
        mode: ProxyMode.vpn,
      ));
      await settle();
      expect(notifier.bodies.length, 1);
      expect(notifier.cancelCount, 0);

      source.add(const ProxyStateEvent(
        state: ProxyConnState.stopped,
        mode: ProxyMode.off,
      ));
      await settle();
      expect(notifier.cancelCount, 1);

      // 停止后 stats 不得再展示。
      now = now.add(const Duration(seconds: 2));
      source.add(_stats(upBps: 999));
      await settle();
      expect(notifier.bodies.length, 1);
      expect(notifier.cancelCount, 1);
    });

    test('does not load the module before any engine event (no eager RPC)',
        () async {
      await service.start();
      await settle();
      expect(notifier.bodies, isEmpty);
      expect(notifier.cancelCount, 0);
      expect(source.nodeListCalls, 0);
      expect(source.profileListCalls, 0);
    });

    test('requests notification permission once when the proxy starts',
        () async {
      await service.start();
      expect(notifier.requestPermissionCount, 0);

      source.add(const ProxyStateEvent(
        state: ProxyConnState.running,
        mode: ProxyMode.vpn,
      ));
      await settle();
      expect(notifier.requestPermissionCount, 1);

      // 运行态内的后续事件不再重复请求权限。
      now = now.add(const Duration(seconds: 2));
      source.add(_stats(upBps: 100));
      await settle();
      expect(notifier.requestPermissionCount, 1);
    });

    test('does not request permission when the proxy is not running', () async {
      await service.start();
      source.add(const ProxyStateEvent(
        state: ProxyConnState.stopped,
        mode: ProxyMode.off,
      ));
      await settle();
      expect(notifier.requestPermissionCount, 0);
    });

    test('requests permission again on a second start after a stop', () async {
      await service.start();
      source.add(const ProxyStateEvent(
        state: ProxyConnState.running,
        mode: ProxyMode.vpn,
      ));
      await settle();
      expect(notifier.requestPermissionCount, 1);

      source.add(const ProxyStateEvent(
        state: ProxyConnState.stopped,
        mode: ProxyMode.off,
      ));
      await settle();

      source.add(const ProxyStateEvent(
        state: ProxyConnState.running,
        mode: ProxyMode.vpn,
      ));
      await settle();
      expect(notifier.requestPermissionCount, 2);
    });
  });
}

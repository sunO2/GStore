import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/platform/platform_channel.dart';

/// `gstore/install_events` 的 Dart 侧契约测试。
///
/// Kotlin 侧终端状态只有四种（Decision 12：installed / failed / denied / timeout），
/// `ok` 由枚举出的 `status` 派生：只有 `installed` 为真。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = EventChannel(installEventsChannelName);

  MockStreamHandlerEventSink? sink;
  var cancelled = false;

  void installStreamHandler(MockStreamHandler? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(channel, handler);
  }

  void useSink({bool trackCancel = false}) {
    sink = null;
    cancelled = false;
    installStreamHandler(
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink eventsSink) {
          sink = eventsSink;
        },
        onCancel: (Object? arguments) {
          if (trackCancel) cancelled = true;
          sink = null;
        },
      ),
    );
  }

  tearDown(() => installStreamHandler(null));

  Map<String, Object?> payload({
    String sessionId = 'task:1:1:1',
    String? packageName = 'com.example.app',
    String status = 'installed',
    String method = 'shizuku',
    String? installedVersion = '1.2.3',
    String? error,
  }) =>
      <String, Object?>{
        'sessionId': sessionId,
        'packageName': packageName,
        'ok': status == 'installed',
        'status': status,
        'method': method,
        'installedVersion': installedVersion,
        'error': error,
      };

  /// 订阅 `gstore/install_events`，推送 [events]，收齐后取消订阅。
  Future<List<InstallEvent>> collect(List<Map<String, Object?>> events) async {
    final received = <InstallEvent>[];
    final done = Completer<void>();
    final sub = channel.receiveBroadcastStream().listen((Object? event) {
      received.add(InstallEvent.fromMap(event! as Map<Object?, Object?>));
      if (received.length == events.length && !done.isCompleted) {
        done.complete();
      }
    });
    // 让 onListen 先到达（mock handler 在事件循环的下一轮被调用）。
    await Future<void>.delayed(Duration.zero);
    expect(sink, isNotNull, reason: 'onListen 必须已经触发');
    for (final event in events) {
      sink!.success(event);
    }
    await done.future.timeout(const Duration(seconds: 5));
    unawaited(sub.cancel());
    await Future<void>.delayed(Duration.zero);
    return received;
  }

  test('installed → ok=true 且字段完整', () async {
    useSink();

    final received = await collect(<Map<String, Object?>>[
      payload(status: 'installed', installedVersion: '1.2.3'),
    ]);

    expect(received, hasLength(1));
    final event = received.single;
    expect(event.status, 'installed');
    expect(event.ok, isTrue);
    expect(event.sessionId, 'task:1:1:1');
    expect(event.packageName, 'com.example.app');
    expect(event.method, 'shizuku');
    expect(event.installedVersion, '1.2.3');
    expect(event.error, isNull);
  });

  for (final status in <String>['denied', 'failed', 'timeout']) {
    test('$status → ok=false（枚举状态而非布尔）', () async {
      useSink();

      final received = await collect(<Map<String, Object?>>[
        payload(status: status, installedVersion: null, error: 'CORE_E_INSTALL'),
      ]);

      expect(received.single.status, status);
      expect(received.single.ok, isFalse);
      expect(received.single.error, 'CORE_E_INSTALL');
    });
  }

  test('重复/迟到终端事件不抛异常', () async {
    useSink(trackCancel: true);

    final received = await collect(<Map<String, Object?>>[
      payload(status: 'installed'),
      payload(status: 'installed'),
    ]);

    expect(received, hasLength(2));
    expect(received.every((e) => e.ok), isTrue);
    // 取消订阅后 Kotlin 侧 StreamHandler.onCancel 必须被触发（sink 清空）。
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, isTrue);
  });

  test('未知状态不因缺少枚举分支而崩溃', () async {
    useSink();

    final received = await collect(<Map<String, Object?>>[
      payload(status: 'pending'),
    ]);

    expect(received.single.status, 'pending');
    expect(received.single.ok, isFalse);
  });

  group('fromMap 契约', () {
    test('wire 上的 ok 与 status 冲突时以 status 为准', () {
      final event = InstallEvent.fromMap(<Object?, Object?>{
        'sessionId': 's',
        'packageName': null,
        'ok': true,
        'status': 'denied',
        'method': 'package_installer',
        'installedVersion': null,
        'error': null,
      });

      expect(event.ok, isFalse);
    });

    test('缺失键不抛异常，sessionId 缺省为空串', () {
      final event = InstallEvent.fromMap(<Object?, Object?>{});

      expect(event.sessionId, '');
      expect(event.status, '');
      expect(event.ok, isFalse);
      expect(event.packageName, isNull);
    });
  });
}

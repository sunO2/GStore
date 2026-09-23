import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/proxy_connect_intent_bridge.dart';

/// [ProxyConnectIntentBridge.handleAppResumed] 的纯逻辑单测。
///
/// 不初始化 Flutter binding、不触碰平台通道 / 原生模块：只注入两个函数接缝，
/// 直接驱动「消费 → 命中才回调」的判定与重入保护。
void main() {
  group('ProxyConnectIntentBridge.handleAppResumed', () {
    test('consume 返回 true → 回调恰好一次', () async {
      var consumes = 0;
      var connects = 0;
      final bridge = ProxyConnectIntentBridge(
        consumeRequest: () async {
          consumes++;
          return true;
        },
        onConnectRequested: () async {
          connects++;
        },
      );

      await bridge.handleAppResumed();

      expect(consumes, 1);
      expect(connects, 1);
    });

    test('consume 返回 false → 不回调', () async {
      var connects = 0;
      final bridge = ProxyConnectIntentBridge(
        consumeRequest: () async => false,
        onConnectRequested: () async {
          connects++;
        },
      );

      await bridge.handleAppResumed();

      expect(connects, 0);
    });

    test('consume 抛错 → 不回调且不崩溃', () async {
      var connects = 0;
      final bridge = ProxyConnectIntentBridge(
        consumeRequest: () async => throw StateError('consume boom'),
        onConnectRequested: () async {
          connects++;
        },
      );

      await bridge.handleAppResumed();

      expect(connects, 0);
    });

    test('onConnectRequested 抛错 → 不崩溃', () async {
      final bridge = ProxyConnectIntentBridge(
        consumeRequest: () async => true,
        onConnectRequested: () async => throw StateError('connect boom'),
      );

      await bridge.handleAppResumed();
      // 无异常冒泡即通过（失败仅记录日志）。
    });

    test('重叠 handleAppResumed → 回调只发生一次（重入保护）', () async {
      var connects = 0;
      final gate = Completer<bool>();
      final bridge = ProxyConnectIntentBridge(
        consumeRequest: () => gate.future,
        onConnectRequested: () async {
          connects++;
        },
      );

      final first = bridge.handleAppResumed();
      final second = bridge.handleAppResumed();
      gate.complete(true);
      await Future.wait(<Future<void>>[first, second]);

      expect(connects, 1);
    });

    test('冷启动单次消费：一次 handleAppResumed 恰消费一次', () async {
      var consumes = 0;
      var connects = 0;
      final bridge = ProxyConnectIntentBridge(
        consumeRequest: () async {
          consumes++;
          return true;
        },
        onConnectRequested: () async {
          connects++;
        },
      );

      await bridge.handleAppResumed();

      expect(consumes, 1);
      expect(connects, 1);
    });
  });

  // 复用同一桥类承载「磁贴长按 → 打开代理页」接缝：契约与连接桥一致——
  // 消费一次、仅命中才回调（打开代理页）。此组防回归。
  group('ProxyConnectIntentBridge（长按打开代理页复用）', () {
    test('consume 返回 true → 打开回调恰好一次', () async {
      var consumes = 0;
      var opens = 0;
      final bridge = ProxyConnectIntentBridge(
        consumeRequest: () async {
          consumes++;
          return true;
        },
        onConnectRequested: () async {
          opens++;
        },
      );

      await bridge.handleAppResumed();

      expect(consumes, 1);
      expect(opens, 1);
    });

    test('consume 返回 false → 不打开', () async {
      var opens = 0;
      final bridge = ProxyConnectIntentBridge(
        consumeRequest: () async => false,
        onConnectRequested: () async {
          opens++;
        },
      );

      await bridge.handleAppResumed();

      expect(opens, 0);
    });
  });
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:gstore/core/router/app_router.dart';
import 'package:gstore/core/routers.dart';

/// 接收其他应用/系统分享过来的 http(s) 链接，用内置浏览器打开。
///
/// Android 侧 `MainActivity` 通过 `gstore/browser_intent` EventChannel 推送
/// （ACTION_VIEW / ACTION_SEND 中的第一个链接）。
class BrowserIntents {
  BrowserIntents._();

  static const EventChannel _channel = EventChannel('gstore/browser_intent');
  static StreamSubscription<dynamic>? _subscription;

  /// 开始监听（在 runApp 之后调用一次）。
  static void start() {
    _subscription ??= _channel.receiveBroadcastStream().listen((event) {
      if (event is String) open(event);
    });
  }

  /// 用内置浏览器打开 [url]。
  static void open(String url) {
    final target = url.trim();
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      return;
    }
    // 冷启动时首帧之前 Navigator 还没挂载，延后一帧再跳转。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final host = Uri.tryParse(target)?.host ?? '';
        appRouter.push(AppRoute.webView, extra: {
          'url': target,
          'title': host.isEmpty ? '链接' : host,
        });
      } catch (_) {
        // 导航尚未就绪：忽略这次（极端竞态），不影响应用启动。
      }
    });
  }
}

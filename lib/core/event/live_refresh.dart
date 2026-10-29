/// 渠道/目录实时刷新事件的**防抖**订阅（Plan-Todo 12）。
///
/// Rust core 在渠道/目录变更时推送 `channel.changed` / `catalog.changed`
/// （Todo 10），Dart 侧映射为类型化 [AppEvent] 落到 [AppEventBus]（Todo 11）。
/// 渠道/目录 UI 必须据此重跑各自的既有 loader；但一次目录同步可能触及多行、
/// 触发**一串**事件，故一串事件必须**合并为一次** loader 重跑，绝不能逐事件
/// 冲击 loader（stale_state / storm 护栏）。
library;

import 'dart:async';

import 'package:gstore/core/event/app_event.dart';

/// 本订阅关注的两个实时刷新事件类型。
const Set<String> _liveRefreshTypes = <String>{
  AppEventTypes.channelChanged,
  AppEventTypes.catalogChanged,
};

/// 把一串 `channel.changed` / `catalog.changed` [AppEvent] 合并为一次防抖的
/// [onRefresh]。
///
/// * [onEvent]（可选）对每个被接受的事件**同步**执行（防抖前）——用于记录这串
///   事件里出现过**哪一类**变更（例如出现 `channel.changed` 才需要刷新渠道包缓存）。
/// * [shouldRefresh]（可选）收窄关注的事件；被拒绝的事件既不触发 [onEvent] 也不
///   重置计时器。缺省接受全部。
/// * [onRefresh] 每串事件只执行一次，在 [debounce] 静默期后。
/// * [events] 缺省为 [AppEventBus.instance] 的事件流（测试接缝）。
///
/// 释放时调用 [dispose]：未释放会在进程级总线上残留监听（泄漏）。
class LiveRefreshSubscription {
  LiveRefreshSubscription({
    required void Function() onRefresh,
    void Function(AppEvent event)? onEvent,
    bool Function(AppEvent event)? shouldRefresh,
    this.debounce = const Duration(milliseconds: 200),
    Stream<AppEvent>? events,
  })  : _onRefresh = onRefresh,
        _onEvent = onEvent,
        _shouldRefresh = shouldRefresh ?? _acceptAll {
    _subscription = (events ?? AppEventBus.instance.stream)
        .where((event) => _liveRefreshTypes.contains(event.type))
        .where(_shouldRefresh)
        .listen((event) {
      _onEvent?.call(event);
      _arm();
    });
  }

  static bool _acceptAll(AppEvent _) => true;

  /// 最后一个被接受事件之后的静默期，达到后 [onRefresh] 触发。
  final Duration debounce;

  final void Function() _onRefresh;
  final void Function(AppEvent event)? _onEvent;
  final bool Function(AppEvent event) _shouldRefresh;

  late final StreamSubscription<AppEvent> _subscription;
  Timer? _timer;
  bool _disposed = false;

  void _arm() {
    if (_disposed) return;
    // 重新计时：一串事件里每个都重置，只有最后一个静默满 [debounce] 才触发一次。
    _timer?.cancel();
    _timer = Timer(debounce, () {
      if (_disposed) return;
      _onRefresh();
    });
  }

  /// 取消待触发计时器与总线订阅（幂等）。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _subscription.cancel();
  }
}

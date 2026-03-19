/// 资源管理
/// 提供统一的资源释放接口，防止内存泄漏
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/exception/AppException.dart';

/// 可释放资源接口
/// 所有需要手动释放资源的类都应该实现此接口
abstract class Disposable {
  /// 释放资源
  /// 实现类应该在此方法中释放所有占用的资源
  /// 如：关闭 Stream、取消订阅、释放数据库连接等
  Future<void> dispose();

  /// 检查资源是否已释放
  bool get isDisposed;
}

/// 资源容器
/// 管理多个可释放资源，统一进行资源释放
class ResourceContainer implements Disposable {
  final Map<String, Disposable> _resources = {};
  bool _isDisposed = false;

  /// 注册资源
  void register<T extends Disposable>(String key, T resource) {
    if (_isDisposed) {
      debugPrint('ResourceContainer: 容器已释放，无法注册资源 $key');
      return;
    }
    _resources[key] = resource;
  }

  /// 获取资源
  T? getResource<T extends Disposable>(String key) {
    final resource = _resources[key];
    return resource as T?;
  }

  /// 移除资源（不释放）
  T? remove<T extends Disposable>(String key) {
    return _resources.remove(key) as T?;
  }

  /// 移除并释放资源
  Future<T?> disposeAndRemove<T extends Disposable>(String key) async {
    final resource = _resources.remove(key);
    if (resource != null) {
      await resource.dispose();
      return resource as T?;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }

    _isDisposed = true;

    // 按注册顺序逆序释放
    final keys = _resources.keys.toList().reversed;
    for (final key in keys) {
      final resource = _resources[key];
      if (resource != null) {
        try {
          await resource.dispose();
        } catch (e) {
          debugPrint('ResourceContainer: 释放资源 $key 失败 - $e');
        }
      }
    }

    _resources.clear();
  }

  @override
  bool get isDisposed => _isDisposed;

  /// 获取资源数量
  int get size => _resources.length;

  /// 检查是否有资源
  bool hasResource(String key) => _resources.containsKey(key);
}

/// StreamSubscription 包装器
/// 自动管理 StreamSubscription 的生命周期
class ManagedStreamSubscription<T> implements Disposable {
  StreamSubscription<T>? _subscription;
  bool _isDisposed = false;

  ManagedStreamSubscription(StreamSubscription<T> subscription)
      : _subscription = subscription;

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    await _subscription?.cancel();
    _subscription = null;
  }

  @override
  bool get isDisposed => _isDisposed;

  /// 获取原始订阅
  StreamSubscription<T>? get subscription => _subscription;

  /// 暂停订阅
  void pause() {
    _subscription?.pause();
  }

  /// 恢复订阅
  void resume() {
    _subscription?.resume();
  }

  /// 检查是否已暂停
  bool get isPaused => _subscription?.isPaused ?? false;
}

/// Stream 管理器
/// 管理多个 StreamSubscription，统一释放
class StreamManager implements Disposable {
  final List<ManagedStreamSubscription> _subscriptions = [];
  bool _isDisposed = false;

  /// 订阅 Stream
  StreamSubscription<T> subscribe<T>(
    Stream<T> stream,
    void Function(T) onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_isDisposed) {
      throw StateError('StreamManager 已释放，无法订阅新的 Stream');
    }

    final subscription = stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );

    final managed = ManagedStreamSubscription(subscription);
    _subscriptions.add(managed);

    return subscription;
  }

  /// 包装现有订阅
  void manage<T>(StreamSubscription<T> subscription) {
    if (_isDisposed) {
      subscription.cancel();
      return;
    }
    _subscriptions.add(ManagedStreamSubscription(subscription));
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    // 取消所有订阅
    for (final subscription in _subscriptions) {
      try {
        await subscription.dispose();
      } catch (e) {
        debugPrint('StreamManager: 取消订阅失败 - $e');
      }
    }

    _subscriptions.clear();
  }

  @override
  bool get isDisposed => _isDisposed;

  /// 获取订阅数量
  int get count => _subscriptions.length;

  /// 取消特定订阅
  Future<void> cancelAt(int index) async {
    if (index >= 0 && index < _subscriptions.length) {
      final subscription = _subscriptions.removeAt(index);
      await subscription.dispose();
    }
  }
}

/// Timer 管理器
/// 管理多个 Timer，统一释放
class TimerManager implements Disposable {
  final List<Timer> _timers = [];
  bool _isDisposed = false;

  /// 创建 Timer
  Timer createTimer(Duration duration, void Function() callback) {
    if (_isDisposed) {
      throw StateError('TimerManager 已释放，无法创建 Timer');
    }

    final timer = Timer(duration, callback);
    _timers.add(timer);
    return timer;
  }

  /// 创建周期性 Timer
  Timer createPeriodic(Duration duration, void Function(Timer) callback) {
    if (_isDisposed) {
      throw StateError('TimerManager 已释放，无法创建 Timer');
    }

    final timer = Timer.periodic(duration, callback);
    _timers.add(timer);
    return timer;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    // 取消所有 Timer
    for (final timer in _timers) {
      timer.cancel();
    }

    _timers.clear();
  }

  @override
  bool get isDisposed => _isDisposed;

  /// 获取 Timer 数量
  int get count => _timers.length;
}

/// 生命周期跟踪器
/// 跟踪对象的创建和释放，帮助检测资源泄漏
class LifecycleTracker {
  final Map<String, _LifecycleInfo> _trackedObjects = {};
  bool _enableTracking = false;

  /// 启用跟踪
  void enableTracking() {
    _enableTracking = true;
  }

  /// 禁用跟踪
  void disableTracking() {
    _enableTracking = false;
  }

  /// 跟踪对象
  void track(
    String key,
    Disposable object, {
    String? type,
    StackTrace? creationStack,
  }) {
    if (!_enableTracking) return;

    _trackedObjects[key] = _LifecycleInfo(
      key: key,
      type: type ?? object.runtimeType.toString(),
      object: object,
      createdAt: DateTime.now(),
      creationStack: creationStack,
    );

    if (kDebugMode) {
      debugPrint('LifecycleTracker: 跟踪对象 $key (${_trackedObjects[key]!.type})');
    }
  }

  /// 取消跟踪
  void untrack(String key) {
    final removed = _trackedObjects.remove(key);
    if (removed != null && kDebugMode) {
      final lifetime = DateTime.now().difference(removed.createdAt);
      debugPrint('LifecycleTracker: 取消跟踪 $key (${removed.type}), 存活时间: ${lifetime.inSeconds}s');
    }
  }

  /// 检查资源泄漏
  void checkLeaks() {
    if (!kDebugMode) return;

    if (_trackedObjects.isEmpty) {
      debugPrint('LifecycleTracker: ✓ 没有检测到资源泄漏');
      return;
    }

    debugPrint('========== 资源泄漏检测 ==========');
    debugPrint('发现 ${_trackedObjects.length} 个未释放的资源:');

    for (final entry in _trackedObjects.entries) {
      final info = entry.value;
      final lifetime = DateTime.now().difference(info.createdAt);

      debugPrint('  - ${entry.key} (${info.type})');
      debugPrint('    存活时间: ${lifetime.inSeconds}s');
      if (info.creationStack != null) {
        debugPrint('    创建位置:\n${info.creationStack}');
      }
    }

    debugPrint('==================================');
  }

  /// 获取跟踪的对象数量
  int get trackedCount => _trackedObjects.length;

  /// 清除所有跟踪
  void clear() {
    _trackedObjects.clear();
  }
}

/// 生命周期信息
class _LifecycleInfo {
  final String key;
  final String type;
  final Disposable object;
  final DateTime createdAt;
  final StackTrace? creationStack;

  _LifecycleInfo({
    required this.key,
    required this.type,
    required this.object,
    required this.createdAt,
    this.creationStack,
  });
}

/// 全局生命周期跟踪器
final lifecycleTracker = LifecycleTracker();

/// 资源管理工具函数
class ResourceManager {
  ResourceManager._internal();

  /// 安全执行并自动释放资源
  static Future<R> using<T extends Disposable, R>(
    T resource,
    Future<R> Function(T) fn,
  ) async {
    try {
      return await fn(resource);
    } finally {
      await resource.dispose();
    }
  }

  /// 创建资源容器并注册资源
  static ResourceContainer createContainer(
    Map<String, Disposable> resources,
  ) {
    final container = ResourceContainer();
    for (final entry in resources.entries) {
      container.register(entry.key, entry.value);
    }
    return container;
  }

  /// 自动释放的资源包装器
  static AutoDispose<T> autoDispose<T extends Disposable>(T resource) {
    return AutoDispose<T>(resource);
  }
}

/// 自动释放包装器
/// 在对象不再被引用时自动释放资源
class AutoDispose<T extends Disposable> {
  T _resource;
  bool _isDisposed = false;

  AutoDispose(this._resource) {
    // 注册到终结器队列（当对象被 GC 时）
    // 注意：Dart 的 GC 不保证及时调用，所以仍建议手动释放
  }

  /// 获取资源
  T get resource {
    if (_isDisposed) {
      throw StateError('资源已释放');
    }
    return _resource;
  }

  /// 释放资源
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await _resource.dispose();
  }

  /// 检查是否已释放
  bool get isDisposed => _isDisposed;
}

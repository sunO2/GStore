/// 第三方应用实时采样间隔的持久化。
///
/// 抽象 [PerfIntervalStore] 使 UI 可注入假实现，widget test 无需平台通道；
/// 生产实现 [SharedPrefsPerfIntervalStore] 经 `shared_preferences`（既有依赖）
/// 保存用户选择的采样间隔（秒），跨启动恢复。
///
/// 失败一律静默降级（`null` / 不抛），符合性能页整体容错语义。
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// 采样间隔（秒）持久化接口。
abstract class PerfIntervalStore {
  /// 读取已保存的采样间隔（秒）；无记录 / 读取失败返回 `null`。
  Future<int?> load();

  /// 保存采样间隔（秒）；失败静默（仅日志，不抛）。
  Future<void> save(int seconds);
}

/// 生产实现：`shared_preferences`。
class SharedPrefsPerfIntervalStore implements PerfIntervalStore {
  const SharedPrefsPerfIntervalStore();

  /// 存储键。
  static const String storageKey = 'perf_third_party_interval_seconds';

  @override
  Future<int?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(storageKey);
    } catch (error) {
      debugPrint('[PerfIntervalStore] 读取采样间隔失败: $error');
      return null;
    }
  }

  @override
  Future<void> save(int seconds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(storageKey, seconds);
    } catch (error) {
      debugPrint('[PerfIntervalStore] 保存采样间隔失败: $error');
    }
  }
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryPerfIntervalStore implements PerfIntervalStore {
  InMemoryPerfIntervalStore([this._seconds]);

  int? _seconds;

  @override
  Future<int?> load() async => _seconds;

  @override
  Future<void> save(int seconds) async => _seconds = seconds;
}

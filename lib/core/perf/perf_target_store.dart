/// 「上次选择的第三方应用」快捷方式持久化。
///
/// 记录用户最近一次在性能页选中的第三方应用（包名 + 展示名 + 是否系统应用），
/// 供：
/// * 「我的 → 工具 → 性能监控」入口显示副标题（如「上次: 微信」）；
/// * 打开性能页时作为预选目标（预选消费方由第三方应用区在后续接线）。
///
/// 独立于 [AppTarget] 定义轻量模型 [PerfPinnedTarget]，避免把
/// `installed_apps` / `shizuku_api` 等重依赖带入调用方（如「我的」页）。
/// 失败一律静默降级（`null` / 不抛）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

/// 固定的第三方应用目标（包名 + 展示名 + 是否系统应用）。
class PerfPinnedTarget {
  const PerfPinnedTarget({
    required this.package,
    required this.label,
    this.isSystem = false,
  });

  /// 包名。
  final String package;

  /// 展示名（缺省回退包名）。
  final String label;

  /// 是否系统应用。
  final bool isSystem;

  /// 序列化。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'package': package,
        'label': label,
        'isSystem': isSystem,
      };

  /// 宽容反序列化：缺字段用默认值。
  factory PerfPinnedTarget.fromJson(Map<String, dynamic> json) {
    final package = json['package']?.toString() ?? '';
    return PerfPinnedTarget(
      package: package,
      label: json['label']?.toString() ?? package,
      isSystem: json['isSystem'] == true,
    );
  }
}

/// 最近目标持久化接口。
abstract class PerfTargetStore {
  /// 读取最近目标；无记录 / 失败返回 `null`。
  Future<PerfPinnedTarget?> load();

  /// 保存最近目标；失败静默。
  Future<void> save(PerfPinnedTarget target);

  /// 清除最近目标；失败静默。
  Future<void> clear();
}

/// 生产实现：`shared_preferences`。
class SharedPrefsPerfTargetStore implements PerfTargetStore {
  const SharedPrefsPerfTargetStore();

  /// 存储键。
  static const String storageKey = 'perf_last_third_party_target';

  @override
  Future<PerfPinnedTarget?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return PerfPinnedTarget.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (error) {
      debugPrint('[PerfTargetStore] 读取最近目标失败: $error');
      return null;
    }
  }

  @override
  Future<void> save(PerfPinnedTarget target) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(target.toJson()));
    } catch (error) {
      debugPrint('[PerfTargetStore] 保存最近目标失败: $error');
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (error) {
      debugPrint('[PerfTargetStore] 清除最近目标失败: $error');
    }
  }
}

/// 内存实现（测试 / 无持久化环境回退）。
class InMemoryPerfTargetStore implements PerfTargetStore {
  InMemoryPerfTargetStore([this._target]);

  PerfPinnedTarget? _target;

  @override
  Future<PerfPinnedTarget?> load() async => _target;

  @override
  Future<void> save(PerfPinnedTarget target) async => _target = target;

  @override
  Future<void> clear() async => _target = null;
}

/// 更新检测缓存（时间窗持久化）
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 更新检测缓存
/// 持久化上次检测时间，用于跨重启的时间窗防重
class UpdateCache {
  UpdateCache._();

  static const String _keyLastCheckedAt = 'update_last_checked_at';

  /// 读取上次检测时间（无记录返回 null）
  static Future<DateTime?> lastCheckedAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_keyLastCheckedAt);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  /// 记录检测时间
  static Future<void> saveCheckedAt(DateTime time) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keyLastCheckedAt, time.millisecondsSinceEpoch);
    } catch (_) {
      // 持久化失败不影响内存状态
    }
  }
}

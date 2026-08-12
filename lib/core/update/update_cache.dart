/// 更新检测缓存（时间窗 + 结果列表持久化）
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_log.dart';

/// 更新检测缓存
/// - 持久化上次检测时间，用于跨重启的时间窗防重
/// - 持久化检测结果列表，应用重启后立即可展示已检测出的可更新应用
/// - 持久化上次检测日志，二次进入检测页可直接展示
class UpdateCache {
  UpdateCache._();

  static const String _keyLastCheckedAt = 'update_last_checked_at';
  static const String _keyResults = 'update_results_v1';
  static const String _keyLogs = 'update_check_logs_v1';

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

  /// 持久化检测结果列表（可更新应用）
  static Future<void> saveResults(List<AppUpdateInfo> results) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(results.map((e) => e.toCacheJson()).toList());
      await prefs.setString(_keyResults, json);
    } catch (e) {
      // 持久化失败不影响内存状态
    }
  }

  /// 读取上次检测结果列表（无记录/损坏返回空列表）
  static Future<List<AppUpdateInfo>> loadResults() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_keyResults);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => AppUpdateInfo.fromCacheJson(e as Map<String, dynamic>))
          .where((e) => e.appId.isNotEmpty && e.latestVersion.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 持久化上次检测日志（前台/后台检测同源产出，格式一致）
  static Future<void> saveLogs(List<CheckLogEntry> logs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(logs.map((e) => e.toJson()).toList());
      await prefs.setString(_keyLogs, json);
    } catch (_) {
      // 持久化失败不影响内存状态
    }
  }

  /// 读取上次检测日志（无记录/损坏返回空列表）
  static Future<List<CheckLogEntry>> loadLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_keyLogs);
      if (raw == null || raw.isEmpty) return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => CheckLogEntry.fromJson(e as Map<String, dynamic>))
          .where((e) => e.text.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }
}

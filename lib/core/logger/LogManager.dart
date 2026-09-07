import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// 全局日志管理器
/// 用于在整个应用中记录和查看日志
class LogManager {
  static LogManager? _instance;

  static LogManager get instance {
    _instance ??= LogManager._();
    return _instance!;
  }

  LogManager._();

  /// 日志条目
  final RxList<LogEntry> logs = <LogEntry>[].obs;

  /// 最大日志数量
  static const int maxLogs = 2000;

  /// 添加日志
  void log({
    required LogLevel level,
    required String message,
    Map<String, dynamic>? data,
  }) {
    final entry = LogEntry(
      level: level,
      message: message,
      data: data,
      timestamp: DateTime.now(),
    );

    // 添加到日志列表
    logs.add(entry);

    // 限制日志数量
    if (logs.length > maxLogs) {
      logs.removeAt(0);
    }

    // 同时输出到控制台
    _printToConsole(entry);
  }

  /// 便捷方法：调试日志
  void debug(String message, {Map<String, dynamic>? data}) {
    log(level: LogLevel.debug, message: message, data: data);
  }

  /// 便捷方法：信息日志
  void info(String message, {Map<String, dynamic>? data}) {
    log(level: LogLevel.info, message: message, data: data);
  }

  /// 便捷方法：警告日志
  void warning(String message, {Map<String, dynamic>? data}) {
    log(level: LogLevel.warning, message: message, data: data);
  }

  /// 便捷方法：错误日志
  void error(String message, {Map<String, dynamic>? data}) {
    log(level: LogLevel.error, message: message, data: data);
  }

  /// 清空日志
  void clear() {
    logs.clear();
    info('日志已清空');
  }

  /// 获取指定级别的日志
  List<LogEntry> getLogsByLevel(LogLevel level) {
    if (level == LogLevel.all) {
      return logs.toList();
    }
    return logs.where((log) => log.level == level).toList();
  }

  /// 导出日志为 JSON 字符串
  String exportToJson() {
    final jsonList = logs.map((log) => log.toJson()).toList();
    return const JsonEncoder.withIndent('  ').convert(jsonList);
  }

  /// 导出日志为文本
  String exportToText() {
    final buffer = StringBuffer();
    for (var log in logs) {
      buffer.writeln(log.toFormattedString());
    }
    return buffer.toString();
  }

  /// 输出到控制台
  void _printToConsole(LogEntry entry) {
    final prefix = _getLevelPrefix(entry.level);
    final timestamp = entry.timeString;

    // 直接输出到标准输出，避免递归调用 debugPrint
    if (entry.data != null) {
      print('$timestamp $prefix ${entry.message} - ${entry.data}');
    } else {
      print('$timestamp $prefix ${entry.message}');
    }
  }

  /// 获取日志级别前缀
  String _getLevelPrefix(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return '🔵 [DEBUG]';
      case LogLevel.info:
        return '🟢 [INFO]';
      case LogLevel.warning:
        return '🟡 [WARN]';
      case LogLevel.error:
        return '🔴 [ERROR]';
      default:
        return '⚪ [LOG]';
    }
  }
}

/// 日志级别
enum LogLevel {
  debug('DEBUG'),
  info('INFO'),
  warning('WARN'),
  error('ERROR'),
  all('全部'); // 用于筛选，不作为实际日志级别

  final String label;
  const LogLevel(this.label);
}

/// 日志条目
class LogEntry {
  final LogLevel level;
  final String message;
  final Map<String, dynamic>? data;
  final DateTime timestamp;

  LogEntry({
    required this.level,
    required this.message,
    this.data,
    required this.timestamp,
  });

  /// 格式化的时间字符串
  String get timeString {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  /// 格式化的日期时间字符串
  String get dateTimeString {
    return '${timestamp.month.toString().padLeft(2, '0')}-'
        '${timestamp.day.toString().padLeft(2, '0')} '
        '$timeString';
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'level': level.name,
      'message': message,
      'data': data,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  /// 格式化字符串
  String toFormattedString() {
    final buffer = StringBuffer();
    buffer.write('$dateTimeString [${level.name.toUpperCase()}] $message');
    if (data != null) {
      buffer.write(' - $data');
    }
    return buffer.toString();
  }
}

/// 全局便捷访问
final appLog = LogManager.instance;

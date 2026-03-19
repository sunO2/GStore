/// 全局错误处理器
/// 统一处理应用中的所有错误
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/exception/AppException.dart';
import 'package:gstore/core/config/AppConfig.dart';

/// 错误处理优先级
enum ErrorPriority {
  /// 低优先级：可以忽略的错误
  low,

  /// 中优先级：需要记录但不影响用户使用的错误
  medium,

  /// 高优先级：需要立即处理并可能影响用户的错误
  high,

  /// 关键错误：可能导致应用崩溃的错误
  critical,
}

/// 错误报告
class ErrorReport {
  /// 错误时间
  final DateTime timestamp;

  /// 错误优先级
  final ErrorPriority priority;

  /// 错误消息
  final String message;

  /// 错误类型
  final Type? errorType;

  /// 堆栈跟踪
  final StackTrace? stackTrace;

  /// 附加信息
  final Map<String, dynamic>? extra;

  /// 是否已处理
  bool isHandled;

  ErrorReport({
    required this.message,
    required this.priority,
    this.errorType,
    this.stackTrace,
    this.extra,
    this.isHandled = false,
  }) : timestamp = DateTime.now();

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('[$priority] $message');
    if (errorType != null) {
      buffer.write(' (type: $errorType)');
    }
    if (extra != null && extra!.isNotEmpty) {
      buffer.write('\n  附加信息: $extra');
    }
    return buffer.toString();
  }
}

/// 全局错误处理器
class ErrorHandler {
  ErrorHandler._internal();

  static final ErrorHandler _instance = ErrorHandler._internal();

  factory ErrorHandler() => _instance;

  final config = AppConfig();

  /// 错误报告列表
  final List<ErrorReport> _errorReports = [];

  /// 错误回调函数
  void Function(ErrorReport)? _onError;

  /// 是否启用错误收集
  bool _errorCollectionEnabled = true;

  /// 最大错误报告数量
  int _maxErrorReports = 100;

  /// 获取单例
  static ErrorHandler get instance => _instance;

  /// 初始化错误处理器
  void initialize({
    void Function(ErrorReport)? onError,
    bool enableErrorCollection = true,
    int maxErrorReports = 100,
  }) {
    _onError = onError;
    _errorCollectionEnabled = enableErrorCollection;
    _maxErrorReports = maxErrorReports;

    // 设置全局错误处理
    if (kDebugMode) {
      debugPrint('ErrorHandler: 初始化完成');
    }
  }

  /// 处理错误
  void handle(
    dynamic error, [
    StackTrace? stackTrace,
    ErrorPriority priority = ErrorPriority.medium,
    Map<String, dynamic>? extra,
  ]) {
    // 转换为 AppException
    final exception = error is AppException
        ? error
        : ExceptionHandler.catchException(error, stackTrace);

    // 创建错误报告
    final report = ErrorReport(
      message: exception.message,
      priority: _determinePriority(exception, priority),
      errorType: exception.runtimeType,
      stackTrace: exception.stackTrace ?? stackTrace,
      extra: {
        ...?extra,
        if (exception.code != null) 'code': exception.code,
        if (exception is NetworkException)
          'statusCode': exception.statusCode,
        if (exception is NetworkException) 'url': exception.url,
      },
    );

    // 添加到报告列表
    if (_errorCollectionEnabled) {
      _addErrorReport(report);
    }

    // 记录日志
    _logError(report);

    // 调用错误回调
    _onError?.call(report);

    // 标记为已处理
    report.isHandled = true;
  }

  /// 确定错误优先级
  ErrorPriority _determinePriority(
    AppException exception,
    ErrorPriority defaultPriority,
  ) {
    // 安全异常优先级高
    if (exception is SecurityException) {
      return ErrorPriority.high;
    }

    // 网络超时优先级低
    if (exception is NetworkException) {
      if (exception.code == 'TIMEOUT' || exception.code == 'NO_CONNECTION') {
        return ErrorPriority.low;
      }
    }

    // 配置异常优先级高
    if (exception is ConfigurationException) {
      return ErrorPriority.high;
    }

    return defaultPriority;
  }

  /// 添加错误报告
  void _addErrorReport(ErrorReport report) {
    _errorReports.add(report);

    // 保持列表大小
    if (_errorReports.length > _maxErrorReports) {
      _errorReports.removeAt(0);
    }
  }

  /// 记录错误日志
  void _logError(ErrorReport report) {
    if (!config.enableDebugLog || config.logLevel == LogLevel.none) {
      return;
    }

    // 过滤敏感信息
    String message = report.toString();
    if (config.filterSensitiveInfoInLog) {
      message = config.filterSensitiveInfo(message);
    }

    switch (report.priority) {
      case ErrorPriority.low:
        if (config.logLevel.isDebug) {
          debugPrint('🟡 [LOW] $message');
        }
        break;
      case ErrorPriority.medium:
        if (config.logLevel.isInfo) {
          debugPrint('🟠 [MEDIUM] $message');
        }
        break;
      case ErrorPriority.high:
        if (config.logLevel.isWarning) {
          debugPrint('🔴 [HIGH] $message');
        }
        break;
      case ErrorPriority.critical:
        if (config.logLevel.isError) {
          debugPrint('🚨 [CRITICAL] $message');
          if (report.stackTrace != null) {
            debugPrint(report.stackTrace.toString());
          }
        }
        break;
    }
  }

  /// 获取所有错误报告
  List<ErrorReport> getErrorReports({
    ErrorPriority? minPriority,
    DateTime? since,
  }) {
    var reports = _errorReports.toList();

    if (minPriority != null) {
      reports = reports.where((r) => r.priority.index >= minPriority.index).toList();
    }

    if (since != null) {
      reports = reports.where((r) => r.timestamp.isAfter(since)).toList();
    }

    return reports;
  }

  /// 清除错误报告
  void clearReports({ErrorPriority? maxPriority}) {
    if (maxPriority == null) {
      _errorReports.clear();
    } else {
      _errorReports.removeWhere((r) => r.priority.index <= maxPriority.index);
    }
  }

  /// 获取错误统计
  Map<String, dynamic> getErrorStats() {
    final stats = <String, dynamic>{};

    // 按类型统计
    final typeCounts = <Type, int>{};
    for (final report in _errorReports) {
      final type = report.errorType ?? dynamic;
      typeCounts[type] = (typeCounts[type] ?? 0) + 1;
    }
    stats['byType'] = typeCounts;

    // 按优先级统计
    final priorityCounts = <ErrorPriority, int>{};
    for (final report in _errorReports) {
      priorityCounts[report.priority] = (priorityCounts[report.priority] ?? 0) + 1;
    }
    stats['byPriority'] = priorityCounts;

    // 总数
    stats['total'] = _errorReports.length;

    return stats;
  }

  /// 导出错误报告为 JSON
  String exportErrorReports() {
    final reportsData = _errorReports.map((report) => {
      'timestamp': report.timestamp.toIso8601String(),
      'priority': report.priority.name,
      'message': report.message,
      'errorType': report.errorType?.toString(),
      'extra': report.extra,
    }).toList();

    return reportsData.toString();
  }

  /// 安全执行函数
  T? tryExecute<T>(
    T Function() fn, {
    T Function()? onError,
    String? context,
  }) {
    try {
      return fn();
    } catch (e, stackTrace) {
      handle(
        e,
        stackTrace,
        ErrorPriority.medium,
        context != null ? {'context': context} : null,
      );
      return onError?.call();
    }
  }

  /// 异步安全执行函数
  Future<T?> tryExecuteAsync<T>(
    Future<T> Function() fn, {
    Future<T> Function()? onError,
    String? context,
  }) async {
    try {
      return await fn();
    } catch (e, stackTrace) {
      handle(
        e,
        stackTrace,
        ErrorPriority.medium,
        context != null ? {'context': context} : null,
      );
      return onError?.call();
    }
  }
}

/// 错误处理扩展
extension ErrorHandlerExtension on Object {
  /// 安全执行实例方法
  R? safeCall<R>(
    R Function() fn, {
    R Function()? onError,
    String? context,
  }) {
    final handler = ErrorHandler();
    return handler.tryExecute(
      fn,
      onError: onError,
      context: context ?? '${runtimeType}',
    );
  }
}

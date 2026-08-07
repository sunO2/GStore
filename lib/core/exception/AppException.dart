/// 统一的应用异常体系
/// 定义所有应用级异常类型，提供清晰的错误分类和处理
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/core.dart';

/// 应用异常基类
/// 所有自定义异常都应该继承此类
abstract class AppException implements Exception {
  /// 错误消息
  final String message;

  /// 原始异常（如果有）
  final dynamic originalError;

  /// 错误代码
  final String? code;

  /// 堆栈跟踪
  final StackTrace? stackTrace;

  const AppException({
    required this.message,
    this.originalError,
    this.code,
    this.stackTrace,
  });

  @override
  String toString() {
    final buffer = StringBuffer('$runtimeType: $message');
    if (code != null) {
      buffer.write(' [code: $code]');
    }
    if (originalError != null) {
      buffer.write('\n  原因: $originalError');
    }
    return buffer.toString();
  }

  /// 记录异常信息
  void log() {
    appLog.error(toString());
    if (stackTrace != null) {
      debugPrint(stackTrace.toString());
    }
  }
}

/// 网络异常
/// 处理所有网络相关的错误
class NetworkException extends AppException {
  /// HTTP 状态码（如果有）
  final int? statusCode;

  /// 请求 URL
  final String? url;

  /// 请求方法
  final String? method;

  const NetworkException({
    required String message,
    this.statusCode,
    this.url,
    this.method,
    dynamic originalError,
    String? code,
    StackTrace? stackTrace,
  }) : super(
          message: message,
          originalError: originalError,
          code: code,
          stackTrace: stackTrace,
        );

  /// 从 Dio 错误创建
  factory NetworkException.fromDioError(
    dynamic error, {
    String? url,
    String? method,
  }) {
    String message;
    String? code;
    int? statusCode;

    if (error is Exception) {
      try {
        final dioError = error;
        // 简化处理，实际项目中可以使用 dio_error_handler 等库
        message = '网络请求失败: $error';
        statusCode = 500; // 默认值
      } catch (_) {
        message = '未知网络错误';
      }
    } else {
      message = error.toString();
    }

    return NetworkException(
      message: message,
      statusCode: statusCode,
      url: url,
      method: method,
      originalError: error,
    );
  }

  /// 从 HTTP 状态码创建
  factory NetworkException.fromStatusCode(
    int statusCode, {
    String? url,
    String? method,
  }) {
    String message;
    switch (statusCode) {
      case 400:
        message = '请求参数错误';
        break;
      case 401:
        message = '未授权，请先登录';
        break;
      case 403:
        message = '没有访问权限';
        break;
      case 404:
        message = '请求的资源不存在';
        break;
      case 500:
        message = '服务器内部错误';
        break;
      case 502:
        message = '网关错误';
        break;
      case 503:
        message = '服务暂时不可用';
        break;
      default:
        message = '网络请求失败 (状态码: $statusCode)';
    }

    return NetworkException(
      message: message,
      statusCode: statusCode,
      url: url,
      method: method,
      code: 'HTTP_$statusCode',
    );
  }

  /// 连接超时
  factory NetworkException.timeout({String? url}) {
    return NetworkException(
      message: '网络连接超时',
      url: url,
      code: 'TIMEOUT',
    );
  }

  /// 无网络连接
  factory NetworkException.noConnection({String? url}) {
    return NetworkException(
      message: '无网络连接',
      url: url,
      code: 'NO_CONNECTION',
    );
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('NetworkException: $message');
    if (statusCode != null) {
      buffer.write(' [status: $statusCode]');
    }
    if (method != null && url != null) {
      buffer.write('\n  $method $url');
    } else if (url != null) {
      buffer.write('\n  URL: $url');
    }
    if (originalError != null) {
      buffer.write('\n  原因: $originalError');
    }
    return buffer.toString();
  }
}

/// 数据解析异常
/// 处理 JSON 解析、数据转换等错误
class ParseException extends AppException {
  /// 解析的数据类型
  final String? targetType;

  /// 原始数据
  final dynamic rawData;

  const ParseException({
    required String message,
    this.targetType,
    this.rawData,
    dynamic originalError,
    String? code,
    StackTrace? stackTrace,
  }) : super(
          message: message,
          originalError: originalError,
          code: code,
          stackTrace: stackTrace,
        );

  /// JSON 解析失败
  factory ParseException.json({
    required String message,
    dynamic rawData,
    dynamic originalError,
  }) {
    return ParseException(
      message: 'JSON 解析失败: $message',
      targetType: 'JSON',
      rawData: rawData,
      originalError: originalError,
      code: 'JSON_PARSE_ERROR',
    );
  }

  /// 类型转换失败
  factory ParseException.typeConversion({
    required String targetType,
    required dynamic value,
    dynamic originalError,
  }) {
    return ParseException(
      message: '类型转换失败: 无法将 $value 转换为 $targetType',
      targetType: targetType,
      rawData: value,
      originalError: originalError,
      code: 'TYPE_CONVERSION_ERROR',
    );
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('ParseException: $message');
    if (targetType != null) {
      buffer.write(' [type: $targetType]');
    }
    return buffer.toString();
  }
}

/// 渠道异常
/// 处理渠道相关的错误
class ChannelException extends AppException {
  /// 渠道类型
  final String? channelType;

  /// 渠道操作
  final String? operation;

  const ChannelException({
    required String message,
    this.channelType,
    this.operation,
    dynamic originalError,
    String? code,
    StackTrace? stackTrace,
  }) : super(
          message: message,
          originalError: originalError,
          code: code,
          stackTrace: stackTrace,
        );

  /// 渠道未初始化
  factory ChannelException.notInitialized({
    required String channelType,
  }) {
    return ChannelException(
      message: '渠道 $channelType 未初始化',
      channelType: channelType,
      code: 'CHANNEL_NOT_INITIALIZED',
    );
  }

  /// 渠道不可用
  factory ChannelException.notAvailable({
    required String channelType,
    String? reason,
  }) {
    return ChannelException(
      message: '渠道 $channelType 不可用${reason != null ? ": $reason" : ""}',
      channelType: channelType,
      code: 'CHANNEL_NOT_AVAILABLE',
    );
  }

  /// 渠道数据解析失败
  factory ChannelException.parseError({
    required String channelType,
    required String operation,
    dynamic originalError,
  }) {
    return ChannelException(
      message: '渠道 $channelType 数据解析失败: $operation',
      channelType: channelType,
      operation: operation,
      originalError: originalError,
      code: 'CHANNEL_PARSE_ERROR',
    );
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('ChannelException: $message');
    if (channelType != null) {
      buffer.write(' [channel: $channelType]');
    }
    if (operation != null) {
      buffer.write(' [operation: $operation]');
    }
    return buffer.toString();
  }
}

/// 缓存异常
/// 处理缓存相关的错误
class CacheException extends AppException {
  /// 缓存类型
  final String? cacheType;

  /// 缓存键
  final String? key;

  const CacheException({
    required String message,
    this.cacheType,
    this.key,
    dynamic originalError,
    String? code,
    StackTrace? stackTrace,
  }) : super(
          message: message,
          originalError: originalError,
          code: code,
          stackTrace: stackTrace,
        );

  /// 缓存未命中
  factory CacheException.notFound({
    required String key,
    String? cacheType,
  }) {
    return CacheException(
      message: '缓存未命中: $key',
      cacheType: cacheType,
      key: key,
      code: 'CACHE_NOT_FOUND',
    );
  }

  /// 缓存写入失败
  factory CacheException.writeError({
    required String key,
    required dynamic error,
    String? cacheType,
  }) {
    return CacheException(
      message: '缓存写入失败: $key',
      cacheType: cacheType,
      key: key,
      originalError: error,
      code: 'CACHE_WRITE_ERROR',
    );
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('CacheException: $message');
    if (cacheType != null) {
      buffer.write(' [type: $cacheType]');
    }
    if (key != null) {
      buffer.write(' [key: $key]');
    }
    return buffer.toString();
  }
}

/// 配置异常
/// 处理配置相关的错误
class ConfigurationException extends AppException {
  /// 配置键
  final String? key;

  /// 配置文件路径
  final String? configPath;

  const ConfigurationException({
    required String message,
    this.key,
    this.configPath,
    dynamic originalError,
    String? code,
    StackTrace? stackTrace,
  }) : super(
          message: message,
          originalError: originalError,
          code: code,
          stackTrace: stackTrace,
        );

  /// 配置缺失
  factory ConfigurationException.missing({
    required String key,
    String? configPath,
  }) {
    return ConfigurationException(
      message: '配置项缺失: $key',
      key: key,
      configPath: configPath,
      code: 'CONFIG_MISSING',
    );
  }

  /// 配置无效
  factory ConfigurationException.invalid({
    required String key,
    required String reason,
    String? configPath,
  }) {
    return ConfigurationException(
      message: '配置项无效: $key - $reason',
      key: key,
      configPath: configPath,
      code: 'CONFIG_INVALID',
    );
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('ConfigurationException: $message');
    if (key != null) {
      buffer.write(' [key: $key]');
    }
    if (configPath != null) {
      buffer.write(' [path: $configPath]');
    }
    return buffer.toString();
  }
}

/// 安全异常
/// 处理安全相关的错误
class SecurityException extends AppException {
  /// 安全违规类型
  final String? violationType;

  const SecurityException({
    required String message,
    this.violationType,
    dynamic originalError,
    String? code,
    StackTrace? stackTrace,
  }) : super(
          message: message,
          originalError: originalError,
          code: code,
          stackTrace: stackTrace,
        );

  /// URL 验证失败
  factory SecurityException.invalidUrl({
    required String url,
    String? reason,
  }) {
    return SecurityException(
      message: 'URL 验证失败: $url${reason != null ? " - $reason" : ""}',
      violationType: 'INVALID_URL',
      code: 'INVALID_URL',
    );
  }

  /// 输入验证失败
  factory SecurityException.invalidInput({
    required String input,
    required String reason,
  }) {
    return SecurityException(
      message: '输入验证失败: $reason',
      violationType: 'INVALID_INPUT',
      code: 'INVALID_INPUT',
    );
  }

  /// 权限不足
  factory SecurityException.accessDenied({
    required String resource,
  }) {
    return SecurityException(
      message: '权限不足: 无法访问 $resource',
      violationType: 'ACCESS_DENIED',
      code: 'ACCESS_DENIED',
    );
  }

  @override
  String toString() {
    final buffer = StringBuffer();
    buffer.write('SecurityException: $message');
    if (violationType != null) {
      buffer.write(' [type: $violationType]');
    }
    return buffer.toString();
  }
}

/// 异常工具类
/// 提供异常处理的辅助方法
class ExceptionHandler {
  /// 捕获异常并转换为 AppException
  static AppException catchException(dynamic error, [StackTrace? stackTrace]) {
    if (error is AppException) {
      return error;
    }

    // 根据错误类型进行转换
    final message = error.toString();

    // 网络相关错误
    if (message.contains('SocketException') ||
        message.contains('HttpException') ||
        message.contains('DioException')) {
      return NetworkException(
        message: '网络错误: $message',
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    // 格式异常
    if (error is FormatException) {
      return ParseException(
        message: '数据格式错误: $message',
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    // 默认返回通用异常
    return GenericAppException(
      message: message,
      originalError: error,
      stackTrace: stackTrace,
    );
  }

  /// 安全地执行函数，捕获所有异常
  static T? tryExecute<T>(
    T Function() fn, {
    void Function(AppException)? onError,
  }) {
    try {
      return fn();
    } catch (e, stackTrace) {
      final exception = catchException(e, stackTrace);
      exception.log();
      onError?.call(exception);
      return null;
    }
  }

  /// 异步安全执行
  static Future<T?> tryExecuteAsync<T>(
    Future<T> Function() fn, {
    void Function(AppException)? onError,
  }) async {
    try {
      return await fn();
    } catch (e, stackTrace) {
      final exception = catchException(e, stackTrace);
      exception.log();
      onError?.call(exception);
      return null;
    }
  }
}

/// 通用应用异常
/// 用于没有特定类型的异常
class GenericAppException extends AppException {
  const GenericAppException({
    required String message,
    dynamic originalError,
    String? code,
    StackTrace? stackTrace,
  }) : super(
          message: message,
          originalError: originalError,
          code: code,
          stackTrace: stackTrace,
        );
}

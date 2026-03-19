import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// HTTP 条件请求结果
class ConditionalRequestResult {
  final bool isModified;
  final bool isSuccess;
  final int statusCode;
  final String? lastModified;
  final String? entityTag;

  const ConditionalRequestResult({
    required this.isModified,
    required this.isSuccess,
    required this.statusCode,
    this.lastModified,
    this.entityTag,
  });

  /// 创建 304 Not Modified 结果
  factory ConditionalRequestResult.notModified({
    String? lastModified,
    String? entityTag,
  }) {
    return ConditionalRequestResult(
      isModified: false,
      isSuccess: true,
      statusCode: 304,
      lastModified: lastModified,
      entityTag: entityTag,
    );
  }

  /// 创建成功结果
  factory ConditionalRequestResult.success({
    required int statusCode,
    String? lastModified,
    String? entityTag,
  }) {
    return ConditionalRequestResult(
      isModified: true,
      isSuccess: true,
      statusCode: statusCode,
      lastModified: lastModified,
      entityTag: entityTag,
    );
  }

  /// 创建失败结果
  factory ConditionalRequestResult.failure({
    required int statusCode,
    String? errorMessage,
  }) {
    return ConditionalRequestResult(
      isModified: false,
      isSuccess: false,
      statusCode: statusCode,
    );
  }

  /// 是否缓存有效（服务器返回 304）
  bool get isNotModified => !isModified && isSuccess;

  @override
  String toString() {
    if (isNotModified) {
      return 'ConditionalRequestResult(304 Not Modified)';
    } else if (isSuccess) {
      return 'ConditionalRequestResult($statusCode Success)';
    } else {
      return 'ConditionalRequestResult($statusCode Failed)';
    }
  }
}

/// HTTP 条件请求增强
/// 支持 If-Modified-Since 和 If-None-Match 头
class ConditionalHttpClient {
  final Dio _dio;

  ConditionalHttpClient(this._dio);

  /// 条件 GET 请求
  ///
  /// 如果服务器返回 304 Not Modified，说明数据未修改，可以使用缓存
  ///
  /// 参数：
  /// - [url]: 请求 URL
  /// - [lastModified]: 上次的 Last-Modified 值
  /// - [entityTag]: 上次的 ETag 值
  /// - [authentication]: 认证头
  Future<ConditionalRequestResult> get(
    String url, {
    String? lastModified,
    String? entityTag,
    String? authentication,
  }) async {
    try {
      final options = Options();

      // 添加条件请求头
      final headers = <String, dynamic>{};

      if (lastModified != null && lastModified.isNotEmpty) {
        headers['If-Modified-Since'] = lastModified;
      }

      if (entityTag != null && entityTag.isNotEmpty) {
        headers['If-None-Match'] = entityTag;
      }

      if (authentication != null && authentication.isNotEmpty) {
        headers['Authorization'] = authentication;
      }

      options.headers = headers;

      debugPrint('ConditionalHttpClient: 请求 $url');
      debugPrint('  If-Modified-Since: $lastModified');
      debugPrint('  If-None-Match: $entityTag');

      final response = await _dio.get(url, options: options);

      // 处理 304 Not Modified
      if (response.statusCode == 304) {
        debugPrint('ConditionalHttpClient: 304 Not Modified - 使用缓存');

        // 从响应头获取新的元数据（如果有）
        final newLastModified = response.headers['Last-Modified']?.first;
        final newEntityTag = response.headers['ETag']?.first;

        return ConditionalRequestResult.notModified(
          lastModified: newLastModified ?? lastModified,
          entityTag: newEntityTag ?? entityTag,
        );
      }

      // 处理成功响应
      if (response.statusCode == 200) {
        debugPrint('ConditionalHttpClient: ${response.statusCode} Success - 数据已更新');

        final newLastModified = response.headers['Last-Modified']?.first;
        final newEntityTag = response.headers['ETag']?.first;

        return ConditionalRequestResult.success(
          statusCode: response.statusCode!,
          lastModified: newLastModified,
          entityTag: newEntityTag,
        );
      }

      // 处理其他状态码
      debugPrint('ConditionalHttpClient: ${response.statusCode} - $url');

      return ConditionalRequestResult.failure(
        statusCode: response.statusCode!,
      );
    } catch (e) {
      debugPrint('ConditionalHttpClient: 请求失败 - $e');
      return ConditionalRequestResult.failure(
        statusCode: 0,
        errorMessage: e.toString(),
      );
    }
  }

  /// 流式下载（带条件请求）
  Future<Response> download(
    String url, {
    String? lastModified,
    String? entityTag,
    String? authentication,
    ProgressCallback? onProgress,
  }) async {
    final options = Options(
      responseType: ResponseType.stream,
    );

    // 添加条件请求头
    final headers = <String, dynamic>{};

    if (lastModified != null && lastModified.isNotEmpty) {
      headers['If-Modified-Since'] = lastModified;
    }

    if (entityTag != null && entityTag.isNotEmpty) {
      headers['If-None-Match'] = entityTag;
    }

    if (authentication != null && authentication.isNotEmpty) {
      headers['Authorization'] = authentication;
    }

    options.headers = headers;

    debugPrint('ConditionalHttpClient: 流式下载 $url');

    final response = await _dio.get(
      url,
      options: options,
      onReceiveProgress: onProgress,
    );

    // 检查是否是 304
    if (response.statusCode == 304) {
      debugPrint('ConditionalHttpClient: 304 Not Modified - 使用缓存');
      throw Exception('304 Not Modified - Content not modified');
    }

    return response;
  }
}

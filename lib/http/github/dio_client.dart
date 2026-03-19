import "dart:io";
import "package:dio/dio.dart";
import "package:dio/io.dart";
import "package:gstore/core/core.dart";
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

/// 重试拦截器
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final int retries;
  final List<Duration> retryDelays;

  RetryInterceptor({
    required this.dio,
    required this.retries,
    required this.retryDelays,
  });

  @override
  Future onError(DioException err, ErrorInterceptorHandler handler) async {
    if (_shouldRetry(err)) {
      final retryCount = err.requestOptions.extra['retryCount'] ?? 0;
      if (retryCount < retries) {
        await Future.delayed(retryDelays[retryCount]);
        err.requestOptions.extra['retryCount'] = retryCount + 1;
        try {
          return handler.resolve(await dio.request(
            err.requestOptions.path,
            data: err.requestOptions.data,
            options: Options(
              method: err.requestOptions.method,
              headers: err.requestOptions.headers,
              extra: err.requestOptions.extra,
            ),
          ));
        } catch (e) {
          return handler.next(err);
        }
      }
    }
    return handler.next(err);
  }

  bool _shouldRetry(DioException err) {
    return err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.response?.statusCode == 502 ||
        err.response?.statusCode == 503 ||
        err.response?.statusCode == 504;
  }
}

/// GitHub API 配置常量
class GitHubConfig {
  static const String apiVersion = "2022-11-28";
  static const String acceptHeader = "application/vnd.github+json";
  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration receiveTimeout = Duration(seconds: 30);
}

/// GitHub API HTTP客户端
/// 使用Dio实现，支持自定义证书验证和授权设置
/// 包含请求日志、超时设置、重试机制等功能
class DioClient {
  /// 工厂构造函数，返回单例实例
  factory DioClient() => _getInstance();

  /// 获取单例实例
  static DioClient get instance => _getInstance();

  /// 静态私有成员，单例实例
  static DioClient? _instance;

  /// Dio实例
  static late Dio _dio;

  /// 私有构造函数，初始化Dio配置
  /// 设置GitHub API请求头和证书验证
  DioClient._internal() {
    BaseOptions options = BaseOptions(
      connectTimeout: GitHubConfig.connectTimeout,
      receiveTimeout: GitHubConfig.receiveTimeout,
      headers: {
        "Accept": GitHubConfig.acceptHeader,
        "X-GitHub-Api-Version": GitHubConfig.apiVersion
      },
    );

    _dio = Dio(options);

    // 添加日志拦截器
    _dio.interceptors.add(dioLoggerInterceptor);

    // 添加重试拦截器
    _dio.interceptors.add(RetryInterceptor(
      dio: _dio,
      retries: 3,
      retryDelays: const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 3),
      ],
    ));

    // 配置HTTPS证书验证
    (_dio.httpClientAdapter as IOHttpClientAdapter).onHttpClientCreate =
        (HttpClient client) {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
      return client;
    };
  }

  /// 日志拦截器
  final Interceptor dioLoggerInterceptor = PrettyDioLogger(
    requestHeader: true,
    requestBody: true,
    responseHeader: true,
    responseBody: true,
    error: true,
    compact: true,
    // 过滤 F-Droid v2 索引文件和大文件下载的日志
    filter: (options, args) {
      final requestPath = options.uri.path;
      final requestUrl = options.uri.toString();

      // 过滤 F-Droid 索引文件 (index-v1.json, index-v2.json 等)
      if (requestPath.contains('index-v') || requestUrl.contains('index-v')) {
        return false;
      }

      // 过滤 F-Droid 增量文件 (index-v2-*.json)
      if (RegExp(r'index-v\d+-\d+\.json').hasMatch(requestPath)) {
        return false;
      }

      // 过滤 F-Droid entry 文件
      if (requestPath.contains('entry.json') || requestPath.contains('entry.jar')) {
        return false;
      }

      // 过滤 APK 文件下载
      if (requestPath.endsWith('.apk')) {
        return false;
      }

      // 过滤大型响应 (检查请求是否是大型文件)
      // 如果是 F-Droid 仓库的请求，很可能是大文件
      if (requestUrl.contains('f-droid.org/repo') &&
          (requestPath.contains('.json') || requestPath.contains('.jar'))) {
        return false;
      }

      return true;
    },
  );

  /// 获取Dio实例
  Dio get() => _dio;

  /// 设置授权token
  /// [authorization] GitHub个人访问令牌
  set authorization(String? authorization) {
    if (authorization?.isNotEmpty ?? false) {
      _dio.options.headers["Authorization"] = "Bearer $authorization";
    }
  }

  /// 获取单例实例，如果不存在则创建
  static DioClient _getInstance() {
    _instance ??= DioClient._internal();
    return _instance!;
  }
}

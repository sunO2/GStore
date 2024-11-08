import "package:dio/dio.dart" show BaseOptions, Dio;

class DioClient {
  factory DioClient() => _getInstance();

  static DioClient get instance => _getInstance();

  // 静态私有成员，没有初始化
  static DioClient? _instance;

  static late Dio _dio;

  // 私有构造函数
  DioClient._internal() {
    BaseOptions options = BaseOptions();
    options.headers = {
      "Accept": "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28"
    };
    // 初始化
    _dio = Dio(options);
  }

  Dio get() => _dio;

  void setAuthorization(String? authorization) {
    if (authorization?.isNotEmpty ?? false) {
      _dio.options.headers["Authorization"] = "Bearer $authorization";
    }
  }

  static DioClient _getInstance() {
    _instance ??= DioClient._internal();
    return _instance!;
  }
}

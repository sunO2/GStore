import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart';
import 'dart:convert';

/// Rhttp HttpClientAdapter for Dio
/// 使用 rhttp 作为底层 HTTP 客户端来提升网络请求性能
class RhttpAdapter implements HttpClientAdapter {
  late final RhttpCompatibleClient _client;
  bool _initialized = false;

  /// 工厂构造函数
  factory RhttpAdapter({bool allowBadCertificate = true}) {
    return RhttpAdapter._internal(allowBadCertificate);
  }

  /// 私有命名构造函数 - 异步初始化
  RhttpAdapter._internal(bool allowBadCertificate) {
    _initClient(allowBadCertificate);
  }

  /// 异步初始化 rhttp 客户端
  void _initClient(bool allowBadCertificate) async {
    try {
      _client = await RhttpCompatibleClient.create(
        settings: const ClientSettings(
          // 配置 TLS 设置，是否验证证书
          tlsSettings: TlsSettings(
            trustRootCertificates: true,
            trustedRootCertificates: [],
            verifyCertificates: false, // 允许自签名证书
            sni: true,
          ),
        ),
      );
      _initialized = true;
    } catch (e) {
      // 如果 rhttp 初始化失败，使用默认的 IOHttpClientAdapter
      _initialized = false;
    }
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // 如果 rhttp 未初始化，使用默认的 IOHttpClientAdapter
    if (!_initialized) {
      return _fetchWithDefaultAdapter(options, requestStream, cancelFuture);
    }

    try {
      // 构建 http 请求
      final request = http.StreamedRequest(
        options.method,
        options.uri,
      );

      // 设置请求头
      options.headers.forEach((key, value) {
        if (value != null) {
          request.headers[key] = value.toString();
        }
      });

      // 设置请求体
      if (options.data != null) {
        if (options.data is String) {
          request.sink.add(options.data.codeUnits);
        } else if (options.data is List) {
          request.sink.add(options.data);
        } else if (options.data is Map) {
          // 检查 Content-Type 来决定如何编码 Map
          final contentType = options.headers['Content-Type'] ??
                              options.headers['content-type'] ??
                              request.headers['Content-Type'];

          if (contentType != null &&
              contentType.toString().contains('x-www-form-urlencoded')) {
            // 表单编码格式 (application/x-www-form-urlencoded)
            final formData = options.data as Map;
            final bodyParts = <String>[];
            formData.forEach((key, value) {
              if (value != null) {
                // 使用正确的 URL 编码
                bodyParts.add('${Uri.encodeQueryComponent(key.toString())}=${Uri.encodeQueryComponent(value.toString())}');
              }
            });
            final bodyString = bodyParts.join('&');
            request.sink.add(utf8.encode(bodyString));
          } else {
            // 默认 JSON 编码
            request.headers['Content-Type'] =
                'application/json; charset=UTF-8';
            final jsonString = options.data.toString();
            request.sink.add(jsonString.codeUnits);
          }
        }
      }
      request.sink.close();

      // 使用 rhttp 发送请求
      final http.StreamedResponse response = await _client.send(request);

      // 将 ByteStream (Stream<List<int>>) 转换为 Stream<Uint8List>
      final responseBodyStream = response.stream.map((data) {
        return data is Uint8List ? data : Uint8List.fromList(data);
      });

      // 构建响应头
      final headers = <String, List<String>>{};
      response.headers.forEach((key, values) {
        headers[key] = values.split(',');
      });

      return ResponseBody(
        responseBodyStream,
        response.statusCode,
        headers: headers,
        statusMessage: response.reasonPhrase,
        isRedirect: response.isRedirect,
      );
    } catch (e) {
      throw DioException(
        requestOptions: options,
        error: e,
        type: _getErrorType(e),
      );
    }
  }

  /// 使用默认的 IOHttpClientAdapter 发送请求
  Future<ResponseBody> _fetchWithDefaultAdapter(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final defaultAdapter = IOHttpClientAdapter();
    return defaultAdapter.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    if (_initialized) {
      _client.close();
    }
  }

  /// 根据错误类型获取 DioExceptionType
  DioExceptionType _getErrorType(dynamic error) {
    if (error.toString().contains('timeout')) {
      return DioExceptionType.connectionTimeout;
    }
    if (error.toString().contains('certificate')) {
      return DioExceptionType.badCertificate;
    }
    if (error.toString().contains('connection')) {
      return DioExceptionType.connectionError;
    }
    return DioExceptionType.unknown;
  }
}

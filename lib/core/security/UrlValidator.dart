/// URL 安全验证器
/// 验证 URL 的安全性和有效性
library;

import 'package:gstore/core/config/AppConfig.dart';
import 'package:gstore/core/exception/AppException.dart';

/// URL 验证器
class UrlValidator {
  UrlValidator._internal();

  static final UrlValidator _instance = UrlValidator._internal();

  factory UrlValidator() => _instance;

  final config = AppConfig();

  /// 验证 URL
  ///
  /// 返回验证结果，包含是否有效和错误信息
  ValidationResult validate(String url) {
    // 检查是否为空
    if (url.isEmpty) {
      return ValidationResult.failure('URL 不能为空');
    }

    // 检查是否为有效的 URI 格式
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (e) {
      return ValidationResult.failure('URL 格式无效: $e');
    }

    // 检查协议
    if (!AppConfig.allowedProtocols.contains(uri.scheme)) {
      return ValidationResult.failure(
        '不支持的协议: ${uri.scheme}，仅支持: ${AppConfig.allowedProtocols.join(", ")}',
      );
    }

    // 检查主机名
    if (uri.host.isEmpty) {
      return ValidationResult.failure('URL 缺少主机名');
    }

    // HTTPS 安全检查
    if (uri.scheme == 'http') {
      // 检查是否在白名单中允许 HTTP
      final allowsHttp = AppConfig.urlWhitelist.any((whitelist) =>
          url.startsWith('http://$whitelist'));

      if (!allowsHttp && config.enableUrlValidation) {
        return ValidationResult.failure(
          '不安全的 HTTP 连接，请使用 HTTPS',
        );
      }
    }

    // 检查白名单
    if (config.enableUrlValidation) {
      final isWhitelisted = AppConfig.urlWhitelist.any((whitelist) {
        return url.startsWith(whitelist) ||
               (uri != null && (uri.host.contains(whitelist) ||
               uri.host == whitelist.replaceFirst('https://', '').replaceFirst('http://', '')));
      });

      if (!isWhitelisted) {
        return ValidationResult.failure(
          'URL 不在白名单中: ${uri?.host ?? "未知"}',
        );
      }
    }

    // 检查端口（不允许非标准端口）
    if (uri.hasPort && uri.port != 80 && uri.port != 443) {
      return ValidationResult.failure(
        '不允许使用非标准端口: ${uri.port}',
      );
    }

    // 检查本地地址
    if (_isLocalAddress(uri)) {
      return ValidationResult.failure(
        '不允许访问本地地址',
      );
    }

    return ValidationResult.success();
  }

  /// 快速验证 URL，失败则抛出异常
  void validateOrThrow(String url) {
    final result = validate(url);
    if (!result.isValid) {
      throw SecurityException.invalidUrl(
        url: url,
        reason: result.errorMessage,
      );
    }
  }

  /// 批量验证 URL
  List<ValidationResult> validateMultiple(List<String> urls) {
    return urls.map((url) => validate(url)).toList();
  }

  /// 检查是否为本地地址
  bool _isLocalAddress(Uri uri) {
    final host = uri.host.toLowerCase();

    // 检查 localhost
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return true;
    }

    // 检查本地网络
    if (host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        host.startsWith('172.16.') ||
        host.startsWith('127.')) {
      return true;
    }

    return false;
  }

  /// 检查是否为 GitHub URL
  bool isGitHubUrl(String url) {
    return url.startsWith(AppConfig.githubApiBaseUrl) ||
           url.startsWith(AppConfig.githubWebBaseUrl);
  }

  /// 检查是否为 vivo URL
  bool isVivoUrl(String url) {
    return url.startsWith(AppConfig.vivoApiBaseUrl);
  }

  /// 检查是否为 F-Droid URL
  bool isFdroidUrl(String url) {
    return AppConfig.fdroidMirrorRepos.any((repo) => url.startsWith(repo));
  }

  /// 获取 URL 的域名
  String? getDomain(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (e) {
      return null;
    }
  }

  /// 构建安全的 URL（添加基础路径）
  String buildSafeUrl(String baseUrl, String path) {
    // 验证基础 URL
    validateOrThrow(baseUrl);

    // 标准化路径
    String normalizedPath = path;
    if (!path.startsWith('/')) {
      normalizedPath = '/$path';
    }

    return baseUrl + normalizedPath;
  }

  /// 构建查询参数 URL
  String buildUrlWithQuery(
    String baseUrl,
    Map<String, dynamic> params,
  ) {
    validateOrThrow(baseUrl);

    final uri = Uri.parse(baseUrl);
    final queryParameters = Map<String, dynamic>.from(uri.queryParameters)
      ..addAll(params);

    return uri.replace(queryParameters: queryParameters).toString();
  }
}

/// 验证结果
class ValidationResult {
  /// 是否验证通过
  final bool isValid;

  /// 错误消息（验证失败时）
  final String? errorMessage;

  const ValidationResult._({
    required this.isValid,
    this.errorMessage,
  });

  /// 创建成功结果
  const ValidationResult.success() : isValid = true, errorMessage = null;

  /// 创建失败结果
  const ValidationResult.failure(this.errorMessage)
      : isValid = false;

  @override
  String toString() {
    if (isValid) {
      return 'ValidationResult.success';
    }
    return 'ValidationResult.failure: $errorMessage';
  }
}

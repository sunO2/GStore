// 与 lib/core/rust/ 既有桥接文件命名约定一致（PascalCase）。
// ignore_for_file: file_names

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'package:gstore/http/rhttp_adapter.dart';
import 'package:gstore/core/rust/ModuleDownloader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';

/// 复用 app 既有 Dio(rhttp/curl) 传输栈的模块字节下载器。
///
/// 与 [ModuleDownloader] 的差异**仅在传输层**：本类走 `RhttpAdapter`
/// （基于 curl，HTTP/2），用于 `dart:io HttpClient` 在部分网络/代理组合下
/// 「连接被中途掐断（Connection closed while receiving data）」的场景——
/// app 的普通下载正是走这条栈。
///
/// 安全语义与 [ModuleDownloader] 一致：
/// * 代理**仅**在原 URL host 通过资产域白名单后作为固定前缀施加；
/// * 代理返回的字节一律不可信，由调用方按清单 sha256 复核；
/// * 大小上限、失败返回 null、绝不抛异常。
class DioModuleFetcher implements ModuleFetcher {
  DioModuleFetcher({
    Dio? dio,
    Set<String>? allowedHosts,
    String Function()? proxyProvider,
    Duration timeout = const Duration(seconds: 60),
    int maxAttempts = 3,
  })  : _dio = dio ?? Dio(),
        _allowedHosts = allowedHosts ?? ModuleDownloader.defaultAssetHosts,
        _proxyProvider = proxyProvider ?? ModuleDownloader.configuredProxy,
        _timeout = timeout,
        _maxAttempts = maxAttempts < 1 ? 1 : maxAttempts;

  /// 生产入口：构造带 `RhttpAdapter` 的独立 Dio（不共享 GitHub API 实例，
  /// 避免其 `RetryInterceptor`/API 头影响大文件下载语义）。
  factory DioModuleFetcher.rhttp({
    String Function()? proxyProvider,
    Duration timeout = const Duration(seconds: 60),
    int maxAttempts = 3,
  }) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: timeout,
        sendTimeout: const Duration(seconds: 30),
      ),
    )..httpClientAdapter = RhttpAdapter(allowBadCertificate: true);
    return DioModuleFetcher(
      dio: dio,
      proxyProvider: proxyProvider,
      timeout: timeout,
      maxAttempts: maxAttempts,
    );
  }

  final Dio _dio;
  final Set<String> _allowedHosts;
  final String Function() _proxyProvider;
  final Duration _timeout;
  final int _maxAttempts;

  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) async {
    final target = _buildTarget(url);
    if (target == null) return null;

    final limit = (maxBytes == null || maxBytes <= 0)
        ? ModuleDownloader.defaultMaxBytes
        : maxBytes;
    final proxy = _proxyProvider().trim();
    debugPrint(
        'DioModuleFetcher: 代理="${proxy.isEmpty ? '(直连)' : proxy}" <- $url');

    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        final resp = await _dio.get<List<int>>(
          target,
          options: Options(
            responseType: ResponseType.bytes,
            receiveTimeout: _timeout,
            sendTimeout: _timeout,
            headers: const {'User-Agent': 'GStore-App/1.0'},
            validateStatus: (code) => code != null && code >= 200 && code < 300,
          ),
        );
        final data = resp.data;
        if (data == null) {
          debugPrint('DioModuleFetcher: 空响应体');
          return null;
        }
        if (data.length > limit) {
          debugPrint('DioModuleFetcher: 超出大小上限 ${data.length} > $limit');
          return null;
        }
        debugPrint('DioModuleFetcher: 成功 ${data.length} 字节');
        return data is Uint8List ? data : Uint8List.fromList(data);
      } catch (e) {
        debugPrint('DioModuleFetcher: 第 $attempt 次失败 - $e');
      }
    }
    debugPrint('DioModuleFetcher: 下载失败 url=$url（$_maxAttempts 次尝试）');
    return null;
  }

  String? _buildTarget(String url) {
    final original = Uri.tryParse(url);
    if (original == null || !_isAllowed(original)) {
      debugPrint('DioModuleFetcher: 原始 URL host 不在白名单，拒绝 - $url');
      return null;
    }

    final proxy = _proxyProvider().trim();
    if (proxy.isEmpty) return url;

    final proxyUri = Uri.tryParse(proxy);
    if (proxyUri == null ||
        !(proxyUri.scheme == 'http' || proxyUri.scheme == 'https') ||
        proxyUri.host.isEmpty) {
      debugPrint('DioModuleFetcher: 代理前缀格式非法，拒绝 - $proxy');
      return null;
    }
    final normalized = proxy.endsWith('/') ? proxy : '$proxy/';
    return '$normalized$url';
  }

  bool _isAllowed(Uri uri) {
    if (uri.host.isEmpty) return false;
    if (uri.scheme == 'https') return _isAllowedHost(uri.host);
    if (uri.scheme == 'http' && _isLoopbackHost(uri.host)) {
      return _isAllowedHost(uri.host);
    }
    return false;
  }

  bool _isAllowedHost(String host) {
    final normalized = host.toLowerCase();
    for (final allowed in _allowedHosts) {
      final w = allowed.toLowerCase();
      if (normalized == w || normalized.endsWith('.$w')) return true;
    }
    return false;
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == '127.0.0.1' ||
        normalized == 'localhost' ||
        normalized == '::1' ||
        normalized == '[::1]';
  }
}

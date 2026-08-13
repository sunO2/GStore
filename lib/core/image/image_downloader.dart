import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 图片字节下载器
///
/// 用浏览器 UA 请求图片地址，返回原始字节（[Uint8List]）。
/// 供需要把图片字节落盘/上传的场景使用（如 WebDAV 备份图标）。
class ImageDownloader {
  ImageDownloader._internal({http.Client? client})
      : _client = client ?? http.Client();

  static final ImageDownloader instance = ImageDownloader._internal();

  http.Client _client;

  /// 测试注入：替换 HTTP 客户端（如 MockClient）
  @visibleForTesting
  set debugClient(http.Client client) => _client = client;

  /// 浏览器 UA：部分图片 CDN 拒绝非浏览器请求
  static const String browserUserAgent =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Mobile Safari/537.36';

  static const Duration _timeout = Duration(seconds: 15);

  /// 下载图片字节
  ///
  /// - 非 200 状态码 → 抛 [http.ClientException]（含状态码信息）
  /// - 空 body → 抛 [http.ClientException]
  /// - 网络异常 / 超时 → 向上传播
  Future<Uint8List> fetchBytes(String url) async {
    final resp = await _client
        .get(Uri.parse(url), headers: {'User-Agent': browserUserAgent})
        .timeout(_timeout);

    if (resp.statusCode != 200) {
      throw http.ClientException(
        'ImageDownloader: 下载失败 ${resp.statusCode} - $url',
        Uri.parse(url),
      );
    }
    if (resp.bodyBytes.isEmpty) {
      throw http.ClientException('ImageDownloader: 空响应体 - $url');
    }
    return resp.bodyBytes;
  }
}

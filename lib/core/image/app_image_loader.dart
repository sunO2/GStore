import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'image_byte_cache.dart';
import 'image_downloader.dart';
import 'image_type_detector.dart';

/// 加载完成的图片：原始字节 + 判型结果。
class LoadedImage {
  LoadedImage({required this.url, required this.bytes, required this.format});

  /// 图片 URL。
  final String url;

  /// 图片原始字节。
  final Uint8List bytes;

  /// 判型结果。
  final ImageFormat format;
}

/// 图片加载编排器。
///
/// 组合 [ImageDownloader] 与 [ImageByteCache]：先查内存缓存（LRU），未命中
/// 时下载并写入缓存。下载异常 / 判型异常直接向上传播，不吞错。
class AppImageLoader {
  AppImageLoader._internal();

  static final AppImageLoader instance = AppImageLoader._internal();

  final ImageByteCache _cache = ImageByteCache();

  final ImageDownloader _downloader = ImageDownloader.instance;

  /// 测试注入：替换底层 HTTP 客户端。
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  set debugClient(http.Client c) => _downloader.debugClient = c;

  /// 测试辅助：清空内存缓存。
  @visibleForTesting
  void clearCache() => _cache.clear();

  /// 加载 [url] 图片：命中缓存直接返回，否则下载、判型并写入缓存。
  Future<LoadedImage> load(String url) async {
    final cached = _cache.get(url);
    if (cached != null) {
      return LoadedImage(
        url: url,
        bytes: cached,
        format: detectImageType(bytes: cached),
      );
    }

    final bytes = await _downloader.fetchBytes(url);
    final format = detectImageType(bytes: bytes);
    _cache.put(url, bytes);
    return LoadedImage(url: url, bytes: bytes, format: format);
  }
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'image_byte_cache.dart';
import 'image_disk_cache.dart';
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
/// 组合 [ImageDownloader]、[ImageByteCache] 与 [ImageDiskCache] 三级缓存：
/// 先查内存缓存（LRU），未命中查磁盘缓存（命中则写回内存），仍未命中才下载
/// 并写入两级缓存。下载异常 / 判型异常直接向上传播，不吞错；磁盘读写异常
/// 静默降级，不影响主流程。
class AppImageLoader {
  AppImageLoader._internal();

  static final AppImageLoader instance = AppImageLoader._internal();

  final ImageByteCache _cache = ImageByteCache();

  final ImageDownloader _downloader = ImageDownloader.instance;

  ImageDiskCache _disk = ImageDiskCache.instance;

  /// 测试注入：替换底层 HTTP 客户端。
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  set debugClient(http.Client c) => _downloader.debugClient = c;

  /// 测试注入：替换磁盘缓存目录（重建磁盘缓存实例）。
  @visibleForTesting
  set diskDirectory(Directory d) => _disk = ImageDiskCache(directory: d);

  /// 测试辅助：清空内存缓存（磁盘保留，符合"重启复用"语义）。
  @visibleForTesting
  void clearCache() => _cache.clear();

  /// 测试辅助：清空磁盘缓存。
  @visibleForTesting
  Future<void> clearDiskCache() => _disk.clear();

  /// 加载 [url] 图片：内存 → 磁盘 → 网络三级，命中缓存直接返回，
  /// 否则下载、判型并写入两级缓存。
  Future<LoadedImage> load(String url) async {
    final cached = _cache.get(url);
    if (cached != null) {
      return LoadedImage(
        url: url,
        bytes: cached,
        format: detectImageType(bytes: cached),
      );
    }

    final disk = await _disk.get(url);
    if (disk != null) {
      _cache.put(url, disk);
      return LoadedImage(
        url: url,
        bytes: disk,
        format: detectImageType(bytes: disk),
      );
    }

    final bytes = await _downloader.fetchBytes(url);
    final format = detectImageType(bytes: bytes);
    _cache.put(url, bytes);
    try {
      await _disk.put(url, bytes);
    } catch (_) {
      // 写盘失败不影响主流程。
    }
    return LoadedImage(url: url, bytes: bytes, format: format);
  }
}

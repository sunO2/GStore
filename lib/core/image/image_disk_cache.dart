import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 图片字节磁盘缓存（内存 → 磁盘 → 网络三级中的磁盘层）。
///
/// 以 URL 的 base64url 编码为文件名（安全字符、可逆、去 padding），按 [ttl]
/// 判断过期；读写/清理异常一律静默降级，不影响主流程。
///
/// 默认目录为 `getTemporaryDirectory()/gstore_image_cache`：Android 上即
/// `cacheDir`（应用私有缓存目录），可写且无需存储权限。内部使用异步 I/O，
/// 不阻塞 UI isolate。`getTemporaryDirectory` 为平台通道调用，在 widget 测试
/// 的 FakeAsync 区下不会完成，因此默认单例在测试环境被禁用。
///
/// 测试通过 [directory] 注入临时目录（注入时恒启用，走普通异步 I/O，无需
/// 平台通道）；未注入时在测试环境（flutter test 会设置 `FLUTTER_TEST` 环境
/// 变量）下禁用磁盘缓存（get 恒 null / put 与 clear 无操作），避免共享默认
/// 目录在用例间相互污染、以及平台通道在 FakeAsync 下挂起加载流程。
class ImageDiskCache {
  ImageDiskCache({Directory? directory, this.ttl = const Duration(days: 7)})
      : _directory = directory;

  /// 默认目录单例（懒解析）。
  static final ImageDiskCache instance = ImageDiskCache();

  /// 测试环境标记：`flutter test` 会在测试进程环境变量中设置 `FLUTTER_TEST`。
  static final bool _isTestEnv = Platform.environment.containsKey('FLUTTER_TEST');

  /// 缓存有效期；写入后超过该时长未读的条目视为过期。
  final Duration ttl;

  final Directory? _directory;

  /// 懒解析结果的 memoize 槽位（仅解析一次）。
  Future<Directory>? _resolvedFuture;

  /// 是否启用：注入目录时恒启用；未注入时生产环境启用、测试环境禁用。
  bool get _enabled => _directory != null || !_isTestEnv;

  /// 懒解析缓存目录：优先注入目录，否则
  /// `getTemporaryDirectory()/gstore_image_cache`（应用私有缓存目录）。
  ///
  /// 平台通道异常会让返回的 Future 失败，由 get/put/clear 的 catch 捕获（静默）。
  Future<Directory> _resolveDirectory() {
    return _resolvedFuture ??= () async {
      final injected = _directory;
      if (injected != null) return injected;
      final temp = await getTemporaryDirectory();
      return Directory('${temp.path}/gstore_image_cache');
    }();
  }

  /// URL → 文件名：base64url 编码（安全字符、可逆），去掉 padding。
  static String _fileNameFor(String url) =>
      base64Url.encode(utf8.encode(url)).replaceAll('=', '');

  /// 读取 [url] 缓存字节。
  ///
  /// 未命中 / 超过 [ttl] 过期（过期文件会被删除）/ IO 异常 / 未启用 → null（静默）。
  Future<Uint8List?> get(String url) async {
    if (!_enabled) return null;
    try {
      final dir = await _resolveDirectory();
      final file = File('${dir.path}/${_fileNameFor(url)}');
      if (!await file.exists()) return null;
      final stat = await file.stat();
      if (DateTime.now().difference(stat.modified) > ttl) {
        await file.delete();
        return null;
      }
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  /// 写入 [url] 字节（覆盖）；IO 异常 / 未启用 → 忽略（缓存失败不影响主流程）。
  Future<void> put(String url, Uint8List bytes) async {
    if (!_enabled) return;
    try {
      final dir = await _resolveDirectory();
      await dir.create(recursive: true);
      final file = File('${dir.path}/${_fileNameFor(url)}');
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // 缓存失败不影响主流程。
    }
  }

  /// 清空磁盘缓存（删除整个缓存目录）；异常 / 未启用 → 忽略。
  Future<void> clear() async {
    if (!_enabled) return;
    try {
      final dir = await _resolveDirectory();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // 清理失败不影响主流程。
    }
  }
}

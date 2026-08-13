import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// README 磁盘缓存条目。
class ReadmeCacheEntry {
  const ReadmeCacheEntry({required this.etag, required this.readme});

  /// 服务端 ETag（条件请求 If-None-Match 用）。
  final String etag;

  /// README 内容（图片已绝对化的 markdown 文本）。
  final String readme;
}

/// README ETag 条件缓存（GitHub contents API 304 复用 / 200 刷新）。
///
/// 存储结构（固定文件名，避免 ETag 非法字符/堆积）：
/// ```text
/// {baseDir}/readme_cache/{owner}_{repo}/readme.md   # 内容（绝对化后文本）
/// {baseDir}/readme_cache/{owner}_{repo}/etag        # ETag 纯文本
/// ```
///
/// 默认目录为 `getTemporaryDirectory()/readme_cache`：Android 上即 `cacheDir`
/// （应用私有缓存目录），可写且无需存储权限。内部使用异步 I/O，不阻塞 UI
/// isolate。`getTemporaryDirectory` 为平台通道调用，在 widget 测试的
/// FakeAsync 区下不会完成，因此默认单例在测试环境被禁用。
///
/// 测试通过 [directory] 注入临时目录（注入时恒启用，走普通异步 I/O，无需
/// 平台通道）；未注入时在测试环境（flutter test 会设置 `FLUTTER_TEST` 环境
/// 变量）下禁用磁盘缓存（get 恒 null / put 与 clear 无操作），避免共享默认
/// 目录在用例间相互污染、以及平台通道在 FakeAsync 下挂起加载流程。
///
/// GitHubChannel 集成测试通过 [instanceForTest] 替换默认单例为注入临时目录
/// 的实例。
class ReadmeCache {
  ReadmeCache({Directory? directory}) : _directory = directory;

  /// 默认目录单例（懒解析）。
  static ReadmeCache instance = ReadmeCache();

  /// 测试实例替换入口：GitHubChannel 集成测试注入临时目录缓存实例，
  /// 测试结束应重置回 `ReadmeCache()`（否则默认单例指向测试目录）。
  @visibleForTesting
  static set instanceForTest(ReadmeCache c) => instance = c;

  /// 测试环境标记：`flutter test` 会在测试进程环境变量中设置 `FLUTTER_TEST`。
  static final bool _isTestEnv =
      Platform.environment.containsKey('FLUTTER_TEST');

  final Directory? _directory;

  /// 懒解析结果的 memoize 槽位（仅解析一次）。
  Future<Directory>? _resolvedFuture;

  /// 是否启用：注入目录时恒启用；未注入时生产环境启用、测试环境禁用。
  bool get _enabled => _directory != null || !_isTestEnv;

  /// 懒解析缓存目录：优先注入目录，否则
  /// `getTemporaryDirectory()/readme_cache`（应用私有缓存目录）。
  ///
  /// 平台通道异常会让返回的 Future 失败，由 get/put/clear 的 catch 捕获（静默）。
  Future<Directory> _resolveDirectory() {
    return _resolvedFuture ??= () async {
      final injected = _directory;
      if (injected != null) return injected;
      final temp = await getTemporaryDirectory();
      return Directory('${temp.path}/readme_cache');
    }();
  }

  /// owner/repo → 目录名：GitHub 用户名/仓库名仅含字母数字与 `-`/`_`，
  /// 用 `_` 连接避免歧义（`$owner\_$repo`）。
  static String _dirNameFor(String owner, String repo) => '${owner}_$repo';

  /// 读取 [owner]/[repo] 缓存条目。
  ///
  /// 任一文件缺失 / IO 异常 / 未启用 → null（静默）。
  Future<ReadmeCacheEntry?> get(String owner, String repo) async {
    if (!_enabled) return null;
    try {
      final base = await _resolveDirectory();
      final dir = Directory('${base.path}/${_dirNameFor(owner, repo)}');
      final etagFile = File('${dir.path}/etag');
      final readmeFile = File('${dir.path}/readme.md');
      if (!await etagFile.exists() || !await readmeFile.exists()) return null;
      final etag = await etagFile.readAsString();
      final readme = await readmeFile.readAsString();
      return ReadmeCacheEntry(etag: etag, readme: readme);
    } catch (_) {
      return null;
    }
  }

  /// 覆盖写 [owner]/[repo] 缓存条目（create recursive + 覆盖写两文件）；
  /// IO 异常 / 未启用 → 忽略（缓存失败不影响主流程）。
  Future<void> put(String owner, String repo,
      {required String etag, required String readme}) async {
    if (!_enabled) return;
    try {
      final base = await _resolveDirectory();
      final dir = Directory('${base.path}/${_dirNameFor(owner, repo)}');
      await dir.create(recursive: true);
      await File('${dir.path}/etag').writeAsString(etag, flush: true);
      await File('${dir.path}/readme.md').writeAsString(readme, flush: true);
    } catch (_) {
      // 缓存失败不影响主流程。
    }
  }

  /// 清空磁盘缓存（删除整个 readme_cache 目录）；异常 / 未启用 → 忽略。
  Future<void> clear() async {
    if (!_enabled) return;
    try {
      final base = await _resolveDirectory();
      if (await base.exists()) {
        await base.delete(recursive: true);
      }
    } catch (_) {
      // 清理失败不影响主流程。
    }
  }
}

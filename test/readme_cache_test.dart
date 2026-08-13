import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/cache/ReadmeCache.dart';

/// ReadmeCache 磁盘缓存单元测试
///
/// 注入临时目录（注入时恒启用，走普通异步 IO），覆盖：
/// - put 后 get 命中（etag/readme 正确）
/// - 未 put / 仅单文件存在 → null
/// - 同目录新实例跨实例命中（磁盘持久化）
/// - clear → null
/// - 目录不存在 / 损坏 → null 不抛
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('readme_cache_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  ReadmeCache newCache() => ReadmeCache(directory: tempDir);

  group('ReadmeCache', () {
    test('put 后 get 命中（etag/readme 正确）', () async {
      final cache = newCache();
      await cache.put('owner', 'repo', etag: '"etag1"', readme: '# Termux\n使用手册');

      final entry = await cache.get('owner', 'repo');
      expect(entry, isNotNull);
      expect(entry!.etag, '"etag1"');
      expect(entry.readme, '# Termux\n使用手册');
    });

    test('未 put → null', () async {
      final cache = newCache();
      expect(await cache.get('owner', 'repo'), isNull);
    });

    test('仅 readme.md 存在（无 etag 文件）→ null', () async {
      final cache = newCache();
      await cache.put('owner', 'repo', etag: 'e1', readme: 'x');
      // 注入目录即缓存根目录（模式同 ImageDiskCache）
      final dir = Directory('${tempDir.path}/owner_repo');
      await File('${dir.path}/etag').delete();

      expect(await cache.get('owner', 'repo'), isNull);
    });

    test('仅 etag 存在 → null', () async {
      final cache = newCache();
      await cache.put('owner', 'repo', etag: 'e1', readme: 'x');
      final dir = Directory('${tempDir.path}/owner_repo');
      await File('${dir.path}/readme.md').delete();

      expect(await cache.get('owner', 'repo'), isNull);
    });

    test('同目录新 ReadmeCache 实例 → 命中（磁盘持久化）', () async {
      final cache1 = newCache();
      await cache1.put('owner', 'repo', etag: 'e1', readme: 'persisted');

      final cache2 = newCache();
      final entry = await cache2.get('owner', 'repo');
      expect(entry, isNotNull);
      expect(entry!.etag, 'e1');
      expect(entry.readme, 'persisted');
    });

    test('clear → null', () async {
      final cache = newCache();
      await cache.put('owner', 'repo', etag: 'e1', readme: 'x');
      await cache.clear();

      expect(await cache.get('owner', 'repo'), isNull);
    });

    test('目录不存在 → get null 不抛', () async {
      final cache = ReadmeCache(directory: Directory('${tempDir.path}/nope'));
      expect(await cache.get('owner', 'repo'), isNull);
    });

    test('损坏（readme.md 被替换为目录）→ get null 不抛', () async {
      final dir = Directory('${tempDir.path}/owner_repo');
      await dir.create(recursive: true);
      await File('${dir.path}/etag').writeAsString('e1');
      await File('${dir.path}/readme.md').writeAsString('x');
      // 损坏：readme.md 从普通文件变成目录 → readAsString 抛 IO 异常 → null
      await File('${dir.path}/readme.md').delete();
      await Directory('${dir.path}/readme.md').create();

      expect(await newCache().get('owner', 'repo'), isNull);
    });
  });
}

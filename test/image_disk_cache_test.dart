import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/image/image_disk_cache.dart';

void main() {
  late Directory dir;
  late ImageDiskCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('imgcache');
    cache = ImageDiskCache(directory: dir);
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  const urlA = 'https://example.com/a.png';
  const urlB = 'https://example.com/b.png';
  final bytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);

  test('put 后 get 命中（同实例）', () async {
    await cache.put(urlA, bytes);

    final result = await cache.get(urlA);

    expect(result, bytes);
  });

  test('同目录新建实例 → get 仍命中（跨实例磁盘持久化）', () async {
    await cache.put(urlA, bytes);

    final another = ImageDiskCache(directory: dir);
    final result = await another.get(urlA);

    expect(result, bytes);
  });

  test('未 put 的 key → null', () async {
    final result = await cache.get(urlA);

    expect(result, isNull);
  });

  test('TTL 过期（ttl: Duration.zero）→ null', () async {
    final zeroCache = ImageDiskCache(directory: dir, ttl: Duration.zero);
    await zeroCache.put(urlA, bytes);

    final result = await zeroCache.get(urlA);

    expect(result, isNull);
  });

  test('TTL 过期（手动改文件 mtime 到过去）→ null 且文件被删', () async {
    await cache.put(urlA, bytes);
    final file = dir.listSync().whereType<File>().single;
    await file.setLastModified(
      DateTime.now().subtract(const Duration(days: 8)),
    );

    final result = await cache.get(urlA);

    expect(result, isNull);
    expect(file.existsSync(), isFalse, reason: '过期文件应被删除');
  });

  test('clear → 全空', () async {
    await cache.put(urlA, bytes);
    await cache.put(urlB, bytes);

    await cache.clear();

    expect(await cache.get(urlA), isNull);
    expect(await cache.get(urlB), isNull);
  });

  test('目录不存在（已删除）→ get null 不抛异常', () async {
    await dir.delete(recursive: true);

    final result = await cache.get(urlA);

    expect(result, isNull);
  });
}

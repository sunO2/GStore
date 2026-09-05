import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/cache_manage/logic.dart';
import 'package:gstore/page/cache_manage/state.dart';

void main() {
  group('CacheManageLogic', () {
    late Directory cacheDir;
    late CacheManageLogic logic;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('cache_manage_test');
      logic = CacheManageLogic()..debugCacheDir = cacheDir;
    });

    tearDown(() async {
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    });

    test('reload 统计目录缓存大小并正确分组', () async {
      // 造数据：CachedNetworkImage 目录 + readme 目录 + 普通残留
      final imgDir = Directory('${cacheDir.path}/libCachedImageData')
        ..createSync(recursive: true);
      File('${imgDir.path}/a.png').writeAsBytesSync(List.filled(100, 1));

      final readmeDir = Directory('${cacheDir.path}/readme_cache')
        ..createSync(recursive: true);
      File('${readmeDir.path}/x.md').writeAsBytesSync(List.filled(50, 2));

      File('${cacheDir.path}/random.tmp').writeAsBytesSync(List.filled(30, 3));

      await logic.reload();

      final state = logic.state;
      expect(state.groups, isNotEmpty);
      expect(state.totalSize.value, 180);

      // 图片缓存组应包含 libCachedImageData 项（100B）
      CacheItem? imgItem;
      CacheItem? readmeItem;
      for (final group in state.groups) {
        for (final item in group.items) {
          if (item.id == 'cached_network_image') imgItem = item;
          if (item.id == 'readme_cache') readmeItem = item;
        }
      }
      expect(imgItem, isNotNull);
      expect(imgItem!.size, 100);
      expect(readmeItem, isNotNull);
      expect(readmeItem!.size, 50);
    });

    test('单项清理目录缓存', () async {
      final imgDir = Directory('${cacheDir.path}/libCachedImageData')
        ..createSync(recursive: true);
      File('${imgDir.path}/a.png').writeAsBytesSync(List.filled(100, 1));

      await logic.reload();
      final ok = await logic.clearOne('cached_network_image');
      expect(ok, isTrue);
      expect(await imgDir.exists(), isFalse);
      expect(logic.state.totalSize.value, 0);
    });

    test('清理临时文件时保留下载分片与专项目录', () async {
      // 正在下载的 .part 分片
      File('${cacheDir.path}/down.apk.part0').writeAsBytesSync(List.filled(10, 1));
      // 专项缓存目录（应跳过）
      final imgDir = Directory('${cacheDir.path}/libCachedImageData')
        ..createSync(recursive: true);
      File('${imgDir.path}/a.png').writeAsBytesSync(List.filled(20, 1));
      // 普通残留
      File('${cacheDir.path}/random.tmp').writeAsBytesSync(List.filled(30, 1));

      final ok = await logic.clearOne('temp_files');
      expect(ok, isTrue);

      // 分片保留
      expect(await File('${cacheDir.path}/down.apk.part0').exists(), isTrue);
      // 专项目录保留
      expect(await imgDir.exists(), isTrue);
      // 普通残留被清理
      expect(await File('${cacheDir.path}/random.tmp').exists(), isFalse);
    });
  });

  group('CacheManageLogic 已下载文件清理', () {
    late Directory cacheDir;
    late Directory downloadsDir;
    late CacheManageLogic logic;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('cache_dl_test');
      downloadsDir =
          await Directory.systemTemp.createTemp('cache_dl_downloads');
      logic = CacheManageLogic()
        ..debugCacheDir = cacheDir
        ..debugDownloadsDir = downloadsDir;
    });

    tearDown(() async {
      if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
      if (await downloadsDir.exists()) {
        await downloadsDir.delete(recursive: true);
      }
    });

    test('loadDownloads 列出下载目录全部文件并汇总大小', () async {
      File('${downloadsDir.path}/a.apk').writeAsBytesSync(List.filled(200, 1));
      File('${downloadsDir.path}/b.apk').writeAsBytesSync(List.filled(300, 1));

      await logic.loadDownloads();

      expect(logic.state.downloads.length, 2);
      expect(logic.state.downloadTotalSize.value, 500);
      // 文件名正确
      final names =
          logic.state.downloads.map((e) => e.fileName).toSet();
      expect(names, contains('a.apk'));
      expect(names, contains('b.apk'));
    });

    test('loadDownloads 跳过下载残留分片', () async {
      File('${downloadsDir.path}/a.apk').writeAsBytesSync(List.filled(200, 1));
      File('${downloadsDir.path}/b.apk.part0')
          .writeAsBytesSync(List.filled(100, 1));
      File('${downloadsDir.path}/c.apk.temp')
          .writeAsBytesSync(List.filled(50, 1));

      await logic.loadDownloads();

      expect(logic.state.downloads.length, 1);
      expect(logic.state.downloads.first.fileName, 'a.apk');
      expect(logic.state.downloadTotalSize.value, 200);
    });

    test('deleteDownloads 按路径删除文件', () async {
      final f1 = File('${downloadsDir.path}/a.apk')
        ..writeAsBytesSync(List.filled(100, 1));
      final f2 = File('${downloadsDir.path}/b.apk')
        ..writeAsBytesSync(List.filled(200, 1));

      await logic.loadDownloads();
      expect(logic.state.downloads.length, 2);

      // 删除一个文件
      final success = await logic.deleteDownloads([f1.path]);
      expect(success, 1);
      expect(await f1.exists(), isFalse);
      expect(await f2.exists(), isTrue);
      // 列表刷新后只剩一个
      expect(logic.state.downloads.length, 1);
    });

    test('deleteDownloads 文件不存在视为成功', () async {
      final ok = await logic.deleteDownloads(['${downloadsDir.path}/nope.apk']);
      expect(ok, 1);
    });
  });
}

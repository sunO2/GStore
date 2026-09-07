import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/page/cache_manage/cache_service.dart';
import 'package:gstore/page/cache_manage/logic.dart';
import 'package:gstore/page/cache_manage/state.dart';

void main() {
  group('CacheManageService 缓存扫描与清理', () {
    late Directory cacheDir;
    late CacheManageService service;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('cache_manage_test');
      service = CacheManageService()..debugCacheDir = cacheDir;
    });

    tearDown(() async {
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    });

    test('scanCacheGroups 统计目录缓存大小并正确分组', () async {
      // 造数据：CachedNetworkImage 目录 + readme 目录 + 普通残留
      final imgDir = Directory('${cacheDir.path}/libCachedImageData')
        ..createSync(recursive: true);
      File('${imgDir.path}/a.png').writeAsBytesSync(List.filled(100, 1));

      final readmeDir = Directory('${cacheDir.path}/readme_cache')
        ..createSync(recursive: true);
      File('${readmeDir.path}/x.md').writeAsBytesSync(List.filled(50, 2));

      File('${cacheDir.path}/random.tmp').writeAsBytesSync(List.filled(30, 3));

      final (groups, total) = await service.scanCacheGroups();

      expect(groups, isNotEmpty);
      expect(total, 180);

      // 图片缓存组应包含 libCachedImageData 项（100B）
      CacheItem? imgItem;
      CacheItem? readmeItem;
      for (final group in groups) {
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

      final ok = await service.clearOne('cached_network_image');
      expect(ok, isTrue);
      expect(await imgDir.exists(), isFalse);

      // 清理后统计归零
      final (_, total) = await service.scanCacheGroups();
      expect(total, 0);
    });

    test('清理临时文件时保留下载分片与专项目录', () async {
      // 正在下载的 .part 分片
      File('${cacheDir.path}/down.apk.part0')
          .writeAsBytesSync(List.filled(10, 1));
      // 专项缓存目录（应跳过）
      final imgDir = Directory('${cacheDir.path}/libCachedImageData')
        ..createSync(recursive: true);
      File('${imgDir.path}/a.png').writeAsBytesSync(List.filled(20, 1));
      // 普通残留
      File('${cacheDir.path}/random.tmp').writeAsBytesSync(List.filled(30, 1));

      final ok = await service.clearOne('temp_files');
      expect(ok, isTrue);

      // 分片保留
      expect(await File('${cacheDir.path}/down.apk.part0').exists(), isTrue);
      // 专项目录保留
      expect(await imgDir.exists(), isTrue);
      // 普通残留被清理
      expect(await File('${cacheDir.path}/random.tmp').exists(), isFalse);
    });

    test('按展示名批量清理（clearByNames，供 Agent 复用）', () async {
      final imgDir = Directory('${cacheDir.path}/libCachedImageData')
        ..createSync(recursive: true);
      File('${imgDir.path}/a.png').writeAsBytesSync(List.filled(100, 1));

      final ok = await service.clearByNames(['网络图片缓存', '不存在的项']);
      expect(ok, 1);
      expect(await imgDir.exists(), isFalse);
    });
  });

  group('CacheManageService 已下载文件清理', () {
    late Directory cacheDir;
    late Directory downloadsDir;
    late CacheManageService service;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('cache_dl_test');
      downloadsDir =
          await Directory.systemTemp.createTemp('cache_dl_downloads');
      service = CacheManageService()
        ..debugCacheDir = cacheDir
        ..debugDownloadsDir = downloadsDir;
    });

    tearDown(() async {
      if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
      if (await downloadsDir.exists()) {
        await downloadsDir.delete(recursive: true);
      }
    });

    test('scanDownloads 列出下载目录全部文件并汇总大小', () async {
      File('${downloadsDir.path}/a.apk').writeAsBytesSync(List.filled(200, 1));
      File('${downloadsDir.path}/b.apk').writeAsBytesSync(List.filled(300, 1));

      final (items, total) = await service.scanDownloads();

      expect(items.length, 2);
      expect(total, 500);
      // 文件名正确
      final names = items.map((e) => e.fileName).toSet();
      expect(names, contains('a.apk'));
      expect(names, contains('b.apk'));
    });

    test('scanDownloads 跳过下载残留分片', () async {
      File('${downloadsDir.path}/a.apk').writeAsBytesSync(List.filled(200, 1));
      File('${downloadsDir.path}/b.apk.part0')
          .writeAsBytesSync(List.filled(100, 1));
      File('${downloadsDir.path}/c.apk.temp')
          .writeAsBytesSync(List.filled(50, 1));

      final (items, total) = await service.scanDownloads();

      expect(items.length, 1);
      expect(items.first.fileName, 'a.apk');
      expect(total, 200);
    });

    test('deleteDownloads 按路径删除文件', () async {
      final f1 = File('${downloadsDir.path}/a.apk')
        ..writeAsBytesSync(List.filled(100, 1));
      final f2 = File('${downloadsDir.path}/b.apk')
        ..writeAsBytesSync(List.filled(200, 1));

      final success = await service.deleteDownloads([f1.path]);
      expect(success, 1);
      expect(await f1.exists(), isFalse);
      expect(await f2.exists(), isTrue);
    });

    test('deleteDownloads 文件不存在视为成功', () async {
      final ok = await service.deleteDownloads(['${downloadsDir.path}/nope.apk']);
      expect(ok, 1);
    });
  });

  group('CacheManageNotifier（Riverpod 状态流转）', () {
    late Directory cacheDir;
    late Directory downloadsDir;
    late ProviderContainer container;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('cache_notifier_test');
      downloadsDir =
          await Directory.systemTemp.createTemp('cache_notifier_downloads');
      final service = CacheManageService()
        ..debugCacheDir = cacheDir
        ..debugDownloadsDir = downloadsDir;
      final notifier = CacheManageNotifier()..debugService = service;
      container = ProviderContainer(overrides: [
        cacheManageProvider.overrideWith(() => notifier),
      ]);
      // 建立 element（触发 Notifier.build）
      container.read(cacheManageProvider);
    });

    tearDown(() async {
      container.dispose();
      if (await cacheDir.exists()) await cacheDir.delete(recursive: true);
      if (await downloadsDir.exists()) {
        await downloadsDir.delete(recursive: true);
      }
    });

    test('reload 更新 groups/totalSize/loading', () async {
      await pumpEventQueue(); // 等 build 的自动加载完成，避免并发覆盖
      final imgDir = Directory('${cacheDir.path}/libCachedImageData')
        ..createSync(recursive: true);
      File('${imgDir.path}/a.png').writeAsBytesSync(List.filled(100, 1));

      await container.read(cacheManageProvider.notifier).reload();
      // 等 microtask 链完成（reload 内部无额外 microtask，但 build 已触发过）
      final state = container.read(cacheManageProvider);
      expect(state.groups, isNotEmpty);
      expect(state.totalSize, 100);
      expect(state.loading, isFalse);
    });

    test('clearOne 清理后刷新状态', () async {
      await pumpEventQueue(); // 等 build 的自动加载完成
      final imgDir = Directory('${cacheDir.path}/libCachedImageData')
        ..createSync(recursive: true);
      File('${imgDir.path}/a.png').writeAsBytesSync(List.filled(100, 1));

      final notifier = container.read(cacheManageProvider.notifier);
      await notifier.reload();
      expect(container.read(cacheManageProvider).totalSize, 100);

      final ok = await notifier.clearOne('cached_network_image');
      expect(ok, isTrue);
      expect(await imgDir.exists(), isFalse);
      expect(container.read(cacheManageProvider).totalSize, 0);
      expect(container.read(cacheManageProvider).clearing, '');
    });

    test('loadDownloads 更新下载列表状态', () async {
      await pumpEventQueue(); // 等 build 的自动加载完成
      File('${downloadsDir.path}/a.apk').writeAsBytesSync(List.filled(200, 1));
      final notifier = container.read(cacheManageProvider.notifier);
      await notifier.loadDownloads();

      final state = container.read(cacheManageProvider);
      expect(state.downloads.length, 1);
      expect(state.downloadTotalSize, 200);
      expect(state.downloadsLoading, isFalse);
    });

    test('deleteDownloads 删除并刷新列表', () async {
      await pumpEventQueue(); // 等 build 的自动加载完成，避免旧扫描结果覆盖
      final f1 = File('${downloadsDir.path}/a.apk')
        ..writeAsBytesSync(List.filled(200, 1));
      final notifier = container.read(cacheManageProvider.notifier);
      await notifier.loadDownloads();
      expect(container.read(cacheManageProvider).downloads.length, 1);

      final success = await notifier.deleteDownloads([f1.path]);
      expect(success, 1);
      expect(await f1.exists(), isFalse);
      expect(container.read(cacheManageProvider).downloads, isEmpty);
      expect(container.read(cacheManageProvider).deletingIds, isEmpty);
    });
  });
}

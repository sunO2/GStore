import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/it_tools_service.dart';
import 'package:gstore/page/cache_manage/cache_service.dart';
import 'package:gstore/page/cache_manage/logic.dart';
import 'package:gstore/page/cache_manage/state.dart';

/// 在测试内构造离线包 zip（不联网、不依赖 `assets/it_tools/it-tools.zip`）。
Uint8List _buildAssetZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final data = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// 可控扫描时序的服务：让第一次 [scanDownloads] 在拿到「目录快照」后挂起，
/// 用于确定性地复现「旧扫描（文件写入前）晚落盘覆盖新结果」的竞态。
class _HoldFirstScanService extends CacheManageService {
  /// 第一次扫描已捕获目录快照（并即将挂起）。
  final Completer<void> firstScanCaptured = Completer<void>();

  Completer<void>? _releaseFirstScan;
  bool _first = true;

  void holdFirstScan() => _releaseFirstScan = Completer<void>();

  void releaseFirstScan() => _releaseFirstScan?.complete();

  @override
  Future<(List<DownloadedFileItem>, int)> scanDownloads() async {
    final snapshot = await super.scanDownloads();
    if (_first) {
      _first = false;
      if (!firstScanCaptured.isCompleted) firstScanCaptured.complete();
      final release = _releaseFirstScan;
      if (release != null) await release.future;
    }
    return snapshot;
  }
}

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
      // 真实屏障是下面 loadDownloads() 返回的 future：刷新已串行化，
      // await 返回即代表本次扫描结果已写入状态（pumpEventQueue 仅让首帧加载先跑）。
      await pumpEventQueue();
      File('${downloadsDir.path}/a.apk').writeAsBytesSync(List.filled(200, 1));
      final notifier = container.read(cacheManageProvider.notifier);
      await notifier.loadDownloads();

      final state = container.read(cacheManageProvider);
      expect(state.downloads.length, 1);
      expect(state.downloadTotalSize, 200);
      expect(state.downloadsLoading, isFalse);
    });

    test('竞态：先发起的旧扫描晚落盘不得覆盖新结果', () async {
      // 旧扫描 = provider build 的自动加载：先让它拿到「空目录」快照并挂起。
      final raceService = _HoldFirstScanService()
        ..debugCacheDir = cacheDir
        ..debugDownloadsDir = downloadsDir;
      final raceNotifier = CacheManageNotifier()..debugService = raceService;
      final raceContainer = ProviderContainer(overrides: [
        cacheManageProvider.overrideWith(() => raceNotifier),
      ]);
      addTearDown(raceContainer.dispose);

      raceService.holdFirstScan();
      raceContainer.read(cacheManageProvider); // 触发 build 的自动加载
      // 等旧扫描完成目录快照（此刻目录为空）并挂起
      await raceService.firstScanCaptured.future;

      // 新文件写入后再发起一次刷新（新扫描）
      File('${downloadsDir.path}/a.apk').writeAsBytesSync(List.filled(200, 1));
      final refresh = raceNotifier.loadDownloads();

      // 释放旧扫描：其空结果此刻才落盘，绝不能覆盖随后完成的新扫描
      raceService.releaseFirstScan();
      await refresh;

      expect(
        raceContainer.read(cacheManageProvider).downloads.length,
        1,
        reason: '新扫描必须获胜，旧扫描不得用过期空快照覆盖',
      );
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

  group('开发者工具箱离线资源（缓存管理入口）', () {
    late Directory docs;
    late Directory currentDir;
    late Directory prevDir;
    late Directory stagingDir;
    late CacheManageService service;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('it_tools_cache_test');
      ItToolsService.debugDocsDir = docs;
      // 同步返回路径不联网；后台自动更新也关闭，避免用例外呼。
      ItToolsService.debugDisableAutoUpdate = true;
      currentDir = Directory('${docs.path}/it_tools');
      prevDir = Directory('${docs.path}/${ItToolsService.previousDirName}');
      stagingDir = Directory('${docs.path}/${ItToolsService.stagingDirName}');
      service = CacheManageService()..debugCacheDir = docs;
    });

    tearDown(() async {
      // 完整复位注入：debugCacheDir/debugDownloadsDir/liveness 若残留会污染后续用例
      ItToolsService.debugReset();
      service.debugCacheDir = null;
      service.debugDownloadsDir = null;
      if (await docs.exists()) {
        await docs.delete(recursive: true);
      }
    });

    CacheItem itToolsItem(List<CacheGroup> groups) => groups
        .firstWhere((g) => g.title == '应用资源')
        .items
        .firstWhere((i) => i.id == 'it_tools_bundle');

    test('大小覆盖当前目录 + .prev + .new，且计入目录内标记文件', () async {
      currentDir.createSync(recursive: true);
      File('${currentDir.path}/index.html').writeAsBytesSync(List.filled(100, 1));
      // 标记文件位于当前目录内，必须计入占用
      File('${currentDir.path}/${ItToolsService.markerFileName}')
          .writeAsBytesSync(List.filled(10, 2));

      prevDir.createSync(recursive: true);
      File('${prevDir.path}/index.html').writeAsBytesSync(List.filled(50, 3));

      stagingDir.createSync(recursive: true);
      File('${stagingDir.path}/index.html').writeAsBytesSync(List.filled(25, 4));

      final (groups, _) = await service.scanCacheGroups();
      final item = itToolsItem(groups);

      expect(item.id, 'it_tools_bundle');
      expect(item.name, '开发者工具箱资源');
      expect(
        item.size,
        185,
        reason: 'current(100+10) + prev(50) + new(25)，漏掉任一目录都会小于该值',
      );
    });

    test('清理后当前目录、.prev、.new 与标记都不存在，大小归零', () async {
      currentDir.createSync(recursive: true);
      File('${currentDir.path}/index.html').writeAsStringSync('<html/>');
      File('${currentDir.path}/${ItToolsService.markerFileName}')
          .writeAsStringSync('{"contentHash":"x","source":"asset"}');

      prevDir.createSync(recursive: true);
      File('${prevDir.path}/index.html').writeAsStringSync('<html>prev</html>');

      stagingDir.createSync(recursive: true);
      File('${stagingDir.path}/index.html').writeAsStringSync('<html>new</html>');

      expect(await service.clearOne('it_tools_bundle'), isTrue);

      for (final dir in [currentDir, prevDir, stagingDir]) {
        expect(await dir.exists(), isFalse, reason: '目录未清除：${dir.path}');
      }
      expect(
        await File('${currentDir.path}/${ItToolsService.markerFileName}').exists(),
        isFalse,
        reason: '标记随当前目录一并删除，下次进入必然重新解析',
      );

      final (groups, _) = await service.scanCacheGroups();
      expect(itToolsItem(groups).size, 0);
    });

    test('存活保护：页面使用中不删除当前目录，且 clearOne 如实返回 false', () async {
      currentDir.createSync(recursive: true);
      File('${currentDir.path}/index.html').writeAsStringSync('<html/>');
      File('${currentDir.path}/${ItToolsService.markerFileName}')
          .writeAsStringSync('{"contentHash":"x","source":"asset"}');

      // 模拟 WebView/页面存活
      ItToolsService.beginUse();

      // 清理被延迟：不抛异常，但必须如实返回 false（不得误报成功）
      expect(await service.clearOne('it_tools_bundle'), isFalse);
      expect(
        await currentDir.exists(),
        isTrue,
        reason: 'WebView 存活期间绝不能删除正在使用的当前目录',
      );
      expect(
        await File('${currentDir.path}/${ItToolsService.markerFileName}').exists(),
        isTrue,
      );

      // 页面退出 → 兑现延迟清理
      await ItToolsService.endUse();
      expect(await currentDir.exists(), isFalse);
    });

    test('存活保护可重入：多个使用者全部退出后才兑现延迟清理', () async {
      currentDir.createSync(recursive: true);
      File('${currentDir.path}/index.html').writeAsStringSync('<html/>');

      ItToolsService.beginUse();
      ItToolsService.beginUse();
      expect(ItToolsService.isInUse, isTrue);

      expect(await service.clearOne('it_tools_bundle'), isFalse);
      expect(await currentDir.exists(), isTrue);

      // 只退出一个使用者：仍存活，不得清理
      await ItToolsService.endUse();
      expect(ItToolsService.isInUse, isTrue);
      expect(await currentDir.exists(), isTrue);

      // 最后一个退出：兑现延迟清理
      await ItToolsService.endUse();
      expect(ItToolsService.isInUse, isFalse);
      expect(await currentDir.exists(), isFalse);
    });

    test('竞态：延迟清理窗口内新页面进入时必须重新延迟，绝不删除活动目录', () async {
      currentDir.createSync(recursive: true);
      File('${currentDir.path}/index.html').writeAsStringSync('<html/>');
      File('${currentDir.path}/${ItToolsService.markerFileName}')
          .writeAsStringSync('{"contentHash":"x","source":"asset"}');

      // 第一个使用者进入 → 清理被延迟
      ItToolsService.beginUse();
      expect(await service.clearOne('it_tools_bundle'), isFalse);
      expect(ItToolsService.isInUse, isTrue);

      // 在 endUse#1 的「目录解析后、最终校验前」窗口注入新页面进入
      ItToolsService.debugBeforeClearDelete = () {
        ItToolsService.debugBeforeClearDelete = null; // 只触发一次
        ItToolsService.beginUse();
      };

      await ItToolsService.endUse(); // #1：新页面在窗口内进入
      expect(ItToolsService.isInUse, isTrue, reason: '新页面已进入');
      expect(
        await currentDir.exists(),
        isTrue,
        reason: '延迟清理不得删除窗口内新进入页面正在使用的目录（修复 TOCTOU）',
      );
      expect(
        await File('${currentDir.path}/${ItToolsService.markerFileName}').exists(),
        isTrue,
      );

      // 新页面退出 → 延迟清理兑现
      await ItToolsService.endUse(); // #2
      expect(ItToolsService.isInUse, isFalse);
      expect(await currentDir.exists(), isFalse);
    });

    test('并发/重复清理不崩溃且不误删活动目录', () async {
      currentDir.createSync(recursive: true);
      File('${currentDir.path}/index.html').writeAsStringSync('<html/>');

      // 两个并发清理：同一隔离区，不得抛异常；至少一个真正清理
      final results = await Future.wait([
        ItToolsService.clearManagedDirs(),
        ItToolsService.clearManagedDirs(),
      ]);

      expect(await currentDir.exists(), isFalse);
      expect(results, contains(ItToolsClearOutcome.cleared));
      expect(
        results.every((r) => r != ItToolsClearOutcome.deferred),
        isTrue,
      );
    });

    test('清理后 ensureExtracted 重新解析并回退随包资产', () async {
      currentDir.createSync(recursive: true);
      File('${currentDir.path}/index.html').writeAsStringSync('<html>remote</html>');
      File('${currentDir.path}/${ItToolsService.markerFileName}')
          .writeAsStringSync('{"contentHash":"x","source":"remote"}');

      final assetZip = _buildAssetZip({
        'index.html': '<html>asset-after-clean</html>',
        'assets/app.js': 'x',
      });
      ItToolsService.debugAssetLoader = () async => assetZip;

      expect(await service.clearOne('it_tools_bundle'), isTrue);
      expect(await currentDir.exists(), isFalse);

      // 无当前、无 .prev → 回退随包资产并落 source=asset 标记
      final dir = await ItToolsService.ensureExtracted();
      expect(
        await File('${dir.path}/index.html').readAsString(),
        '<html>asset-after-clean</html>',
      );
      final marker = await ItToolsService.readCurrentMarker();
      expect(marker, isNotNull);
      expect(marker!.source, ItToolsService.sourceAsset);
      expect(await prevDir.exists(), isFalse);
      expect(await stagingDir.exists(), isFalse);
    });
  });
}

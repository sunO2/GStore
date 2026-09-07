import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/page/cache_manage/cache_service.dart';
import 'package:gstore/page/cache_manage/download_clean_page.dart';
import 'package:gstore/page/cache_manage/logic.dart';
import 'package:gstore/page/cache_manage/view.dart';
import 'package:gstore/page/database_manage/logic.dart';
import 'package:gstore/page/database_manage/view.dart';
import 'package:gstore/page/licenses/licenses_page.dart';
import 'package:gstore/page/log_viewer/view.dart';
import 'package:gstore/page/webdav_config/view.dart';

/// 新页面的挂载冒烟测试。
///
/// 注意：testWidgets 运行在 FakeAsync 时间区，dart:io / 平台通道的真实异步
/// 不会自行推进，因此只验证「页面可构建 + 标题正确」，不等待真实 IO。
void main() {
  group('管理页冒烟', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('manage_page_smoke');
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    testWidgets('缓存管理页可挂载并展示标题（Riverpod）', (tester) async {
      final downloadsDir = Directory('${tmpDir.path}/downloads')
        ..createSync();
      final service = CacheManageService()
        ..debugCacheDir = tmpDir
        ..debugDownloadsDir = downloadsDir;
      final notifier = CacheManageNotifier()..debugService = service;
      final container = ProviderContainer(overrides: [
        cacheManageProvider.overrideWith(() => notifier),
      ]);
      addTearDown(container.dispose);
      // 触发 build 建立 element
      container.read(cacheManageProvider);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CacheManagePage()),
        ),
      );
      await tester.pump();

      expect(find.text('缓存管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已下载文件清理页可挂载（Riverpod ConsumerState）', (tester) async {
      final downloadsDir = Directory('${tmpDir.path}/downloads2')
        ..createSync();
      final service = CacheManageService()
        ..debugCacheDir = tmpDir
        ..debugDownloadsDir = downloadsDir;
      final notifier = CacheManageNotifier()..debugService = service;
      final container = ProviderContainer(overrides: [
        cacheManageProvider.overrideWith(() => notifier),
      ]);
      addTearDown(container.dispose);
      container.read(cacheManageProvider);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: DownloadCleanPage()),
        ),
      );
      await tester.pump();

      expect(find.text('已下载文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('数据库管理页可挂载并展示标题（Riverpod）', (tester) async {
      final docsDir = Directory('${tmpDir.path}/docs')..createSync();
      final dbDir = Directory('${tmpDir.path}/dbs')..createSync();
      final notifier = DatabaseManageNotifier()
        ..debugDocsDir = docsDir
        ..debugDatabasesDir = dbDir;
      final container = ProviderContainer(overrides: [
        databaseManageProvider.overrideWith(() => notifier),
      ]);
      addTearDown(container.dispose);
      // 触发 build 建立 element
      container.read(databaseManageProvider);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: DatabaseManagePage()),
        ),
      );
      await tester.pump();

      expect(find.text('数据库管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('日志查看页可挂载并展示标题（Riverpod）', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: LogViewerPage())),
      );
      await tester.pump();

      expect(find.text('应用日志'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('日志查看页打开时展示已存在的日志（种子流回归）', (tester) async {
      // 预置一条已存在日志（模拟进入页面时 LogManager 已有内容）。
      // RxList.stream 是 broadcast：新订阅者拿不到历史值，改造前此处列表为空。
      final logManager = LogManager.instance;
      logManager.logs.clear();
      logManager.log(level: LogLevel.info, message: '历史日志应可见');

      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: LogViewerPage())),
      );
      // StreamProvider 种子事件经 microtask 到达
      await tester.pump();
      await tester.pump();

      expect(find.text('历史日志应可见'), findsOneWidget,
          reason: '进入页面时应立即显示已存在的日志');
      expect(tester.takeException(), isNull);
    });

    testWidgets('WebDAV 配置页可挂载并展示标题（Riverpod）', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: WebDavConfigPage())),
      );
      await tester.pump();

      expect(find.text('WebDAV 配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('开源许可页可挂载并列出依赖', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LicensesPage()));
      await tester.pump();

      expect(find.text('开源许可'), findsOneWidget);
      expect(find.textContaining('本项目依赖以下开源软件'), findsOneWidget);
    });
  });
}

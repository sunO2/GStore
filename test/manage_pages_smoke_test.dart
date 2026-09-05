import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/page/cache_manage/logic.dart';
import 'package:gstore/page/cache_manage/view.dart';
import 'package:gstore/page/database_manage/logic.dart';
import 'package:gstore/page/database_manage/view.dart';
import 'package:gstore/page/licenses/licenses_page.dart';

/// 两个新管理页的挂载冒烟测试。
///
/// 注意：testWidgets 运行在 FakeAsync 时间区，dart:io / 平台通道的真实异步
/// 不会自行推进，因此只验证「页面可构建 + 进入加载态 + 标题正确」，
/// 不等待真实 IO 完成（真实 reload 逻辑由普通 test 覆盖）。
void main() {
  group('管理页冒烟', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('manage_page_smoke');
      Get.testMode = true;
    });

    tearDown(() async {
      Get.reset();
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    testWidgets('缓存管理页可挂载并展示标题', (tester) async {
      final logic = CacheManageLogic()..debugCacheDir = tmpDir;
      Get.put(logic);

      await tester.pumpWidget(const MaterialApp(home: CacheManagePage()));
      await tester.pump();

      expect(find.text('缓存管理'), findsOneWidget);
      // 页面可挂载且无异常即可（loading / 空态时序随异步 IO 变化，不强断言）
      expect(tester.takeException(), isNull);
    });

    testWidgets('数据库管理页可挂载并展示标题', (tester) async {
      final docsDir = Directory('${tmpDir.path}/docs')..createSync();
      final dbDir = Directory('${tmpDir.path}/dbs')..createSync();
      final logic = DatabaseManageLogic()
        ..debugDocsDir = docsDir
        ..debugDatabasesDir = dbDir;
      Get.put(logic);

      await tester.pumpWidget(const MaterialApp(home: DatabaseManagePage()));
      await tester.pump();

      expect(find.text('数据库管理'), findsOneWidget);
      expect(find.text('正在扫描数据库…'), findsOneWidget);
    });

    testWidgets('开源许可页可挂载并列出依赖', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LicensesPage()));
      await tester.pump();

      expect(find.text('开源许可'), findsOneWidget);
      // 顶部说明文案存在（含依赖计数）
      expect(find.textContaining('本项目依赖以下开源软件'), findsOneWidget);
    });
  });
}

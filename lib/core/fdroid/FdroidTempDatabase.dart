import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/fdroid/FdroidRepoDatabase.dart';

/// 临时数据库 - 用于存储解析过程中的应用数据
/// 类似 Neo-Store 的 IndexContentMerger
///
/// 使用临时数据库的好处：
/// 1. 内存控制 - 解析完的应用立即存入数据库，不占用内存
/// 2. 快速查询 - SQLite 比内存中的 List 查询更快
/// 3. 事务安全 - 解析失败可以回滚，不影响正式数据库
class FdroidTempDatabase {
  final File dbFile;
  Database? _database;

  FdroidTempDatabase(this.dbFile);

  /// 打开临时数据库
  Future<Database> get database async {
    if (_database != null) return _database!;

    _database = await openDatabase(
      dbFile.path,
      version: 1,
      onCreate: (db, version) async {
        // 创建应用临时表
        await db.execute('''
          CREATE TABLE temp_product (
            package_name TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            summary TEXT,
            icon TEXT,
            author_name TEXT,
            license TEXT,
            source_code TEXT,
            web_site TEXT,
            category TEXT,
            added INTEGER,
            last_updated INTEGER,
            metadata_json TEXT NOT NULL
          )
        ''');

        // 创建包临时表
        await db.execute('''
          CREATE TABLE temp_package (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            package_name TEXT NOT NULL,
            apk_name TEXT NOT NULL,
            version_name TEXT,
            version_code INTEGER,
            size INTEGER,
            hash TEXT,
            sig TEXT,
            permissions_json TEXT,
            nativecode TEXT,
            min_sdk INTEGER,
            target_sdk INTEGER,
            FOREIGN KEY (package_name) REFERENCES temp_product(package_name)
          )
        ''');

        // 创建索引
        await db.execute('CREATE INDEX idx_temp_package_name ON temp_package(package_name)');

        // 开启事务
        await db.execute('BEGIN TRANSACTION');
      },
    );

    return _database!;
  }

  /// 添加应用到临时数据库
  Future<void> addProducts(List<FdroidApp> apps) async {
    final db = await database;

    final batch = db.batch();

    for (final app in apps) {
      // 存储 metadata 为 JSON（支持复杂字段）
      final metadataJson = {
        'added': app.added?.millisecondsSinceEpoch,
        'lastUpdated': app.lastUpdated?.millisecondsSinceEpoch,
        'categories': app.categories,
      };

      batch.insert('temp_product', {
        'package_name': app.packageName,
        'name': app.name,
        'summary': app.summary,
        'icon': app.icon,
        'author_name': app.authorName,
        'license': app.license,
        'source_code': app.sourceCode,
        'web_site': app.webSite,
        'category': (app.categories != null && app.categories!.isNotEmpty)
            ? app.categories!.first
            : '',
        'added': app.added?.millisecondsSinceEpoch ?? 0,
        'last_updated': app.lastUpdated?.millisecondsSinceEpoch ?? 0,
        'metadata_json': metadataJson,
      });

      // Note: Packages are stored separately, not in FdroidApp
      // We'll need to pass packages separately or get them from another source
    }

    await batch.commit(noResult: true);
  }

  /// 窗口化查询应用（每次只查询指定数量）
  /// 类似 Neo-Store 的 forEach 方法
  Future<void> forEach(
    int repositoryId,
    int windowSize,
    Future<void> Function(List<FdroidApp>, int totalCount) callback,
  ) async {
    final db = await database;

    // 先获取总数
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count FROM temp_product
    ''');
    final totalCount = Sqflite.firstIntValue(result) ?? 0;

    int offset = 0;

    while (offset < totalCount) {
      // 查询一批数据
      final result = await db.rawQuery('''
        SELECT
          tp.package_name,
          tp.name,
          tp.summary,
          tp.icon,
          tp.author_name,
          tp.license,
          tp.source_code,
          tp.web_site,
          tp.category,
          tp.added,
          tp.last_updated
        FROM temp_product tp
        ORDER BY tp.name ASC
        LIMIT ? OFFSET ?
      ''', [windowSize, offset]);

      // 构建应用对象
      final apps = <FdroidApp>[];
      for (final row in result) {
        final packageName = row['package_name'] as String;

        // Note: 不再查询包信息，因为 FdroidApp 不包含 packages 字段
        // 如果需要包信息，应该通过数据库的 dao.getPackages() 方法单独查询

        apps.add(FdroidApp(
          packageName: packageName,
          name: row['name'] as String,
          summary: row['summary'] as String? ?? '',
          icon: row['icon'] as String? ?? '$packageName.png',
          authorName: row['author_name'] as String?,
          license: row['license'] as String?,
          sourceCode: row['source_code'] as String?,
          webSite: row['web_site'] as String?,
          categories: row['category'] == null ? [] : [row['category'] as String],
          added: row['added'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(row['added'] as int),
          lastUpdated: row['last_updated'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(row['last_updated'] as int),
        ));
      }

      // 回调处理
      await callback(apps, totalCount);

      offset += windowSize;
    }
  }

  /// 从临时数据库复制到正式数据库
  Future<void> copyToDatabase(FdroidRepoDatabase targetDatabase) async {
    final db = await database;

    // 开�启事务
    await db.execute('BEGIN TRANSACTION');

    try {
      // 获取所有应用
      final result = await db.rawQuery('''
        SELECT * FROM temp_product ORDER BY name ASC
      ''');

      final apps = <FdroidApp>[];
      for (final row in result) {
        final packageName = row['package_name'] as String;

        // Note: FdroidApp 不再包含 packages 字段
        // 包信息应该通过其他方式处理
        apps.add(FdroidApp(
          packageName: packageName,
          name: row['name'] as String,
          summary: row['summary'] as String? ?? '',
          icon: row['icon'] as String? ?? '$packageName.png',
          authorName: row['author_name'] as String?,
          license: row['license'] as String?,
          sourceCode: row['source_code'] as String?,
          webSite: row['web_site'] as String?,
          categories: row['category'] == null ? [] : [row['category'] as String],
          added: row['added'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(row['added'] as int),
          lastUpdated: row['last_updated'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(row['last_updated'] as int),
        ));
      }

      // 写入目标数据库
      await targetDatabase.dao.upsertApps(apps);

      // 提交事务
      await db.execute('COMMIT');

      debugPrint('FdroidTempDatabase: 已复制 ${apps.length} 个应用到正式数据库');
    } catch (e) {
      await db.execute('ROLLBACK');
      debugPrint('FdroidTempDatabase: 复制失败，已回滚 - $e');
      rethrow;
    }
  }

  /// 清空临时数据库
  Future<void> clear() async {
    final db = await database;

    await db.execute('DROP TABLE IF EXISTS temp_package');
    await db.execute('DROP TABLE IF EXISTS temp_product');

    await close();

    debugPrint('FdroidTempDatabase: 临时数据库已清空');
  }

  /// 关闭数据库
  Future<void> close() async {
    await _database?.close();
    _database = null;

    // 删除临时文件
    if (await dbFile.exists()) {
      await dbFile.delete();
    }
  }
}

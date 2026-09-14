import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';

/// 应用快照持久化存储。
///
/// 为什么用裸 sqflite 而不是 Floor：快照载荷是一整块 JSON（不参与关系查询），
/// 查询只有「按应用查历史」「按时间倒序」两类，裸 sqflite 更直接、
/// 且不引入代码生成步骤；这与仓内 `CacheManager` / `FdroidTempDatabase` 的既有做法一致。
class AppSnapshotStore {
  AppSnapshotStore._();

  static final AppSnapshotStore instance = AppSnapshotStore._();

  static const String _dbName = 'app_snapshot.db';
  static const int _dbVersion = 1;
  static const String _table = 'app_snapshot';

  Database? _db;
  Future<Database>? _opening;

  /// 测试用：覆盖库文件路径（null 恢复默认）
  @visibleForTesting
  static String? debugDbPath;

  Future<Database> get _database async {
    final existing = _db;
    if (existing != null) return existing;
    // 并发调用复用同一个正在打开的 future，避免重复建连
    return _opening ??= _open().then((db) {
      _db = db;
      _opening = null;
      return db;
    });
  }

  Future<Database> _open() async {
    final path = debugDbPath ??
        p.join((await getApplicationDocumentsDirectory()).path, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $_table (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            packageName TEXT NOT NULL,
            appLabel TEXT NOT NULL DEFAULT '',
            versionName TEXT NOT NULL DEFAULT '',
            versionCode TEXT NOT NULL DEFAULT '',
            createdAt INTEGER NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            payloadVersion INTEGER NOT NULL DEFAULT 0,
            summary TEXT NOT NULL DEFAULT '{}',
            payload TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_snapshot_app_time '
          'ON $_table (packageName, createdAt DESC)',
        );
        appLog.info('AppSnapshotStore: 创建快照表，版本 $version');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // v1 为初始版本；后续字段/索引变更在此按 oldVersion 逐级迁移
        appLog.info('AppSnapshotStore: 升级 $oldVersion → $newVersion');
      },
    );
  }

  /// 插入一条快照，返回自增 id（失败返回 null）
  Future<int?> insert(SnapshotRecord record) async {
    try {
      final db = await _database;
      return await db.insert(_table, {
        'packageName': record.packageName,
        'appLabel': record.appLabel,
        'versionName': record.versionName,
        'versionCode': record.versionCode,
        'createdAt': record.createdAt,
        'note': record.note,
        'payloadVersion': record.payloadVersion,
        'summary': jsonEncode(record.summary.toJson()),
        'payload': record.payload.encode(),
      });
    } catch (e) {
      appLog.error('AppSnapshotStore: 写入快照失败 - $e');
      return null;
    }
  }

  /// 某应用的全部快照（时间倒序，最新在前）
  Future<List<SnapshotRecord>> listByApp(String packageName) async {
    try {
      final db = await _database;
      final rows = await db.query(
        _table,
        where: 'packageName = ?',
        whereArgs: [packageName],
        orderBy: 'createdAt DESC, id DESC',
      );
      return _rowsToRecords(rows);
    } catch (e) {
      appLog.error('AppSnapshotStore: 查询快照失败 - $e');
      return const [];
    }
  }

  /// 全部快照（跨应用，时间倒序）
  Future<List<SnapshotRecord>> listAll({int limit = 500}) async {
    try {
      final db = await _database;
      final rows = await db.query(
        _table,
        orderBy: 'createdAt DESC, id DESC',
        limit: limit,
      );
      return _rowsToRecords(rows);
    } catch (e) {
      appLog.error('AppSnapshotStore: 查询全部快照失败 - $e');
      return const [];
    }
  }

  /// 按 id 取单条
  Future<SnapshotRecord?> getById(int id) async {
    try {
      final db = await _database;
      final rows = await db.query(_table, where: 'id = ?', whereArgs: [id]);
      final records = _rowsToRecords(rows);
      return records.isEmpty ? null : records.first;
    } catch (e) {
      appLog.error('AppSnapshotStore: 查询快照 $id 失败 - $e');
      return null;
    }
  }

  Future<int> countByApp(String packageName) async {
    try {
      final db = await _database;
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM $_table WHERE packageName = ?',
        [packageName],
      );
      return (rows.first['c'] as num?)?.toInt() ?? 0;
    } catch (e) {
      appLog.error('AppSnapshotStore: 统计快照失败 - $e');
      return 0;
    }
  }

  /// 删除单条快照
  Future<bool> delete(int id) async {
    try {
      final db = await _database;
      final n = await db.delete(_table, where: 'id = ?', whereArgs: [id]);
      return n > 0;
    } catch (e) {
      appLog.error('AppSnapshotStore: 删除快照失败 - $e');
      return false;
    }
  }

  /// 删除某应用的全部快照
  Future<int> deleteByApp(String packageName) async {
    try {
      final db = await _database;
      return await db
          .delete(_table, where: 'packageName = ?', whereArgs: [packageName]);
    } catch (e) {
      appLog.error('AppSnapshotStore: 删除应用快照失败 - $e');
      return 0;
    }
  }

  /// 测试用：关闭连接并清空缓存（下次访问重新打开）
  @visibleForTesting
  Future<void> closeForTest() async {
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
    _opening = null;
  }

  List<SnapshotRecord> _rowsToRecords(List<Map<String, Object?>> rows) {
    final out = <SnapshotRecord>[];
    for (final row in rows) {
      final payload = SnapshotPayload.decode(row['payload'] as String? ?? '');
      if (payload == null) {
        // 载荷损坏：跳过该条而不是让整表查询失败
        appLog.warning('AppSnapshotStore: 快照 ${row['id']} 载荷解析失败，已跳过');
        continue;
      }
      out.add(
        SnapshotRecord(
          id: (row['id'] as num?)?.toInt(),
          packageName: row['packageName'] as String? ?? '',
          appLabel: row['appLabel'] as String? ?? '',
          versionName: row['versionName'] as String? ?? '',
          versionCode: row['versionCode'] as String? ?? '',
          createdAt: (row['createdAt'] as num?)?.toInt() ?? 0,
          note: row['note'] as String? ?? '',
          payloadVersion: (row['payloadVersion'] as num?)?.toInt() ?? 0,
          summary: SnapshotSummary.decode(row['summary'] as String? ?? '{}'),
          payload: payload,
        ),
      );
    }
    return out;
  }
}

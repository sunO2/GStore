import 'dart:async';
import 'dart:io';
import 'package:floor/floor.dart';
import 'package:gstore/core/fdroid/FdroidRepoDao.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;

part 'FdroidRepoDatabase.g.dart';

/// F-Droid 仓库数据库
///
/// 使用 Floor ORM 管理本地缓存的 F-Droid 应用数据
/// 支持多源、增量更新、流式解析
@Database(version: 1, entities: [
  FdroidApp,
  FdroidPackage,
  FdroidVersionInfo,
])
abstract class FdroidRepoDatabase extends FloorDatabase {
  /// 获取 DAO
  FdroidRepoDao get dao;

  /// 数据库版本迁移
  static final migration1to2 = Migration(1, 2, (database) async {
    // 未来版本迁移逻辑
  });
}

/// 获取数据库路径
Future<String> getDatabasePath() async {
  final databasesPath = await sqflite.getDatabasesPath();
  return p.join(databasesPath, 'fdroid_repo.db');
}

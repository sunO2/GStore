import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'package:gstore/core/core.dart';

import 'state.dart';

/// 删除判定结果。
class _DeleteGuard {
  const _DeleteGuard.allowed([this.hint])
      : allowed = true,
        blockedReason = null;

  const _DeleteGuard.blocked(this.blockedReason)
      : allowed = false,
        hint = null;

  final bool allowed;

  /// 允许删除时的提示语（可为空）。
  final String? hint;

  /// 拒绝删除的原因（allowed=false 时）。
  final String? blockedReason;
}

/// 数据库管理逻辑：枚举各 SQLite 库、浏览表与行、行级删除。
///
/// 库发现范围：应用文档目录（Documents）+ sqflite 默认库目录（databases），
/// 排除备份/渠道包等非库目录。删除前对受管库/表做保护判定。
class DatabaseManageLogic extends GetxController {
  final DatabaseManageState state = DatabaseManageState();

  @override
  void onInit() {
    super.onInit();
    reload();
  }

  // ---------- 目录注入（测试） ----------

  /// 测试注入：应用文档目录替身。
  @visibleForTesting
  Directory? debugDocsDir;

  /// 测试注入：sqflite databases 目录替身。
  @visibleForTesting
  Directory? debugDatabasesDir;

  Future<Directory> _docsDir() async {
    if (debugDocsDir != null) return debugDocsDir!;
    return getApplicationDocumentsDirectory();
  }

  Future<Directory> _sqfliteDir() async {
    if (debugDatabasesDir != null) return debugDatabasesDir!;
    final base = await sqflite.getDatabasesPath();
    return Directory(base);
  }

  // ---------- 库发现 ----------

  /// 已知库的展示元数据（fileName → 展示名/描述/是否受管）。
  static const _knownDb = <String, (String, String, bool)>{
    'apps.db': ('应用目录库', 'GStore 应用商店种子目录（支持在线更新）', true),
    'added_apps.db': ('我的应用', '已添加应用引用 + 标签', false),
    'channel_apps.db': ('渠道收藏', '各渠道添加的应用记录', false),
    'download_task.db': ('下载任务', '下载队列/进度/历史记录', true),
    'fdroid_repo.db': ('F-Droid 仓库', 'F-Droid 源与索引缓存', false),
    'workflow.db': ('工作流', '工作流引擎运行时数据', false),
  };

  /// 展示用表中文名（表名 → 中文）。
  static const _knownTable = <String, String>{
    'apps': '应用',
    'config': '配置版本',
    'category': '分类',
    'apps_fts': '全文搜索索引',
    'added_apps': '已添加应用',
    'added_app_tags': '应用标签',
    'channel_added_app': '渠道已添加应用',
    'DownloadTaskEntity': '下载任务',
    'workflow': '工作流',
  };

  /// 受管只读主表：不允许行级删除（属 App 运行时管理的数据）。
  static const _readonlyTables = <String, String>{
    'apps': '应用目录主表受版本管理，删除会导致列表异常，请用「数据库更新」整库刷新',
    'workflow': '工作流数据受引擎管理，不建议手动删除',
  };

  /// 刷新数据库列表。
  Future<void> reload() async {
    state.loading.value = true;
    try {
      final found = <DbEntry>[];
      final seen = <String>{};

      // 1. 应用文档目录（apps.db 在 gstore/ 子目录，added/channel 在根目录）
      final docs = await _docsDir();
      await _scanDir(docs, found, seen);
      final gstoreDir = Directory(p.join(docs.path, 'gstore'));
      if (await gstoreDir.exists()) {
        await _scanDir(gstoreDir, found, seen);
      }

      // 2. sqflite 默认库目录（download_task.db / workflow.db 等）
      final dbDir = await _sqfliteDir();
      if (!p.equals(dbDir.path, docs.path)) {
        await _scanDir(dbDir, found, seen);
      }

      found.sort((a, b) => a.fileName.compareTo(b.fileName));
      state.dbs.value = found;
    } catch (e) {
      appLog.error('DatabaseManage: 枚举数据库失败 - $e');
      state.dbs.value = [];
    } finally {
      state.loading.value = false;
    }
  }

  Future<void> _scanDir(
    Directory dir,
    List<DbEntry> out,
    Set<String> seen,
  ) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      // 仅 *.db，排除 sqlite 附属文件
      if (!name.endsWith('.db') ||
          name.endsWith('-wal') ||
          name.endsWith('-shm') ||
          name.endsWith('-journal')) {
        continue;
      }
      final key = entity.path;
      if (!seen.add(key)) continue;
      out.add(await _describe(entity));
    }
  }

  Future<DbEntry> _describe(File file) async {
    final name = file.path.split(Platform.pathSeparator).last;
    final meta = _knownDb[name];
    int version = 0;
    try {
      // singleInstance: false → 独立连接，避免拿到 Floor 常驻连接后 close 误关应用连接
      final db = await sqflite.openDatabase(file.path,
          readOnly: true, singleInstance: false);
      final rows = await db.rawQuery('PRAGMA user_version');
      version = sqflite.Sqflite.firstIntValue(rows) ?? 0;
      await db.close();
    } catch (e) {
      appLog.warning('DatabaseManage: 读取 $name 版本失败 - $e');
    }
    var size = 0;
    try {
      size = await file.length();
    } catch (_) {}
    return DbEntry(
      filePath: file.path,
      fileName: name,
      displayName: meta?.$1 ?? name,
      description: meta?.$2 ?? 'SQLite 数据库',
      managed: meta?.$3 ?? false,
      size: size,
      version: version,
    );
  }

  /// 只读打开独立连接（singleInstance: false），close 不影响 Floor/其它持有者。
  Future<sqflite.Database> _openReadOnly(String path) {
    return sqflite.openDatabase(path,
        readOnly: true, singleInstance: false);
  }

  /// 可写打开独立连接（用于删除行），close 不影响 Floor 常驻连接。
  Future<sqflite.Database> _openWritable(String path) {
    return sqflite.openDatabase(path, singleInstance: false);
  }

  // ---------- 表浏览 ----------

  /// 加载选中库的表列表。
  Future<void> loadTables(DbEntry db) async {
    state.selectedDb.value = db;
    state.tablesLoading.value = true;
    state.tables.value = [];
    state.browsingPath.value = '';
    state.browsingTable.value = '';
    state.selectedRowIndex.value = -1;
    try {
      final conn = await _openReadOnly(db.filePath);
      try {
        final tableRows = await conn.rawQuery(
          "SELECT name FROM sqlite_master "
          "WHERE type='table' AND name NOT LIKE 'sqlite_%' "
          "ORDER BY name",
        );
        final tables = <DbTable>[];
        for (final row in tableRows) {
          final name = row['name'] as String? ?? '';
          if (name.isEmpty) continue;
          final isVirtual = await _isVirtualTable(conn, name);
          if (isVirtual) continue; // 跳过 FTS 等虚拟表
          final countRow = await conn.rawQuery(
            'SELECT COUNT(*) AS c FROM "${_quoteIdent(name)}"',
          );
          final count = sqflite.Sqflite.firstIntValue(countRow) ?? 0;
          tables.add(DbTable(
            name: name,
            count: count,
            displayName: _knownTable[name],
            readonly: _readonlyTables.containsKey(name),
          ));
        }
        state.tables.value = tables;
      } finally {
        await conn.close();
      }
    } catch (e) {
      appLog.error('DatabaseManage: 读取表失败 - $e');
    } finally {
      state.tablesLoading.value = false;
    }
  }

  Future<bool> _isVirtualTable(sqflite.Database conn, String name) async {
    try {
      final rows = await conn.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name = ?",
        [name],
      );
      if (rows.isEmpty) return true;
      final sql = rows.first['sql'] as String? ?? '';
      return sql.trimLeft().toUpperCase().contains('VIRTUAL TABLE');
    } catch (_) {
      return true;
    }
  }

  // ---------- 行浏览 ----------

  /// 加载某表的一页数据。
  Future<void> loadRows(String table, {int page = 0}) async {
    final dbPath = state.selectedDb.value?.filePath;
    if (dbPath == null) return;
    state.rowsLoading.value = true;
    state.browsingTable.value = table;
    state.page.value = page;
    state.selectedRowIndex.value = -1;
    try {
      final conn = await _openReadOnly(dbPath);
      try {
        final countRow = await conn.rawQuery(
          'SELECT COUNT(*) AS c FROM "${_quoteIdent(table)}"',
        );
        state.tableTotal.value = sqflite.Sqflite.firstIntValue(countRow) ?? 0;

        final ident = _quoteIdent(table);
        final rows = await conn.rawQuery(
          'SELECT rowid AS _rowid_, * FROM $ident '
          'ORDER BY _rowid_ DESC '
          'LIMIT ${state.pageSize} OFFSET ${page * state.pageSize}',
        );
        if (rows.isEmpty) {
          state.columns.value = [];
          state.rows.value = [];
          return;
        }
        state.columns.value = rows.first.keys.toList();
        state.rows.value = rows;
      } finally {
        await conn.close();
      }
    } catch (e) {
      appLog.error('DatabaseManage: 读取行失败 - $e');
      state.rows.value = [];
      state.columns.value = [];
    } finally {
      state.rowsLoading.value = false;
    }
  }

  Future<void> nextPage() async {
    final table = state.browsingTable.value;
    if (table.isEmpty) return;
    final maxPage = (state.tableTotal.value / state.pageSize).ceil() - 1;
    if (state.page.value >= maxPage) return;
    await loadRows(table, page: state.page.value + 1);
  }

  Future<void> prevPage() async {
    final table = state.browsingTable.value;
    if (table.isEmpty) return;
    if (state.page.value <= 0) return;
    await loadRows(table, page: state.page.value - 1);
  }

  // ---------- 行级删除 ----------

  /// 删除前守卫：返回是否允许 + 提示。
  Future<_DeleteGuard> _guardDelete(String table, Map<String, Object?> row) async {
    // 受管只读主表
    final readonlyReason = _readonlyTables[table];
    if (readonlyReason != null) {
      return _DeleteGuard.blocked(readonlyReason);
    }
    // 下载任务表：仅允许删除终态（非 queued/downloading/paused 由下载管理器持有）
    if (table == 'DownloadTaskEntity' || table == 'download_task') {
      final status = row['status'];
      // status 0=queued 1=downloading 2=completed 3=failed 4=paused 5=cancelled
      if (status is int && (status == 0 || status == 1)) {
        return const _DeleteGuard.blocked('进行中的下载任务不能删除，请先取消或等待完成');
      }
      if (status is int && status == 4) {
        return const _DeleteGuard.blocked('已暂停的下载任务请先删除下载中心的任务或恢复后再处理');
      }
      final filePath = row['filePath'] as String?;
      if (filePath != null && filePath.isNotEmpty) {
        final f = File(filePath);
        if (await f.exists()) {
          return const _DeleteGuard.allowed('删除记录后，已下载的 APK 文件将保留在下载目录，可手动清理');
        }
      }
      return const _DeleteGuard.allowed();
    }
    // 其余普通表允许
    return const _DeleteGuard.allowed();
  }

  /// 删除一行。row 需含 _rowid_（来自 loadRows）。
  Future<bool> deleteRow(String table, Map<String, Object?> row) async {
    final dbPath = state.selectedDb.value?.filePath;
    final rowid = row['_rowid_'];
    if (dbPath == null || rowid == null) return false;
    if (state.busy.value) return false;
    state.busy.value = true;
    try {
      final conn = await _openWritable(dbPath);
      try {
        final guard = await _guardDelete(table, row);
        if (!guard.allowed) {
          await AppDialogs.showWarningDialog(
            title: '无法删除',
            message: guard.blockedReason ?? '该记录受保护',
          );
          return false;
        }
        final reason = guard.hint;
        final ok = await AppDialogs.showConfirmDialog(
          title: '删除记录',
          message: '确定删除「$table」中的这条记录吗？\n${reason ?? ''}',
          isDangerous: true,
        );
        if (ok != true) return false;

        await conn.delete(
          table,
          where: 'rowid = ?',
          whereArgs: [rowid],
        );
        return true;
      } finally {
        await conn.close();
      }
    } catch (e) {
      appLog.error('DatabaseManage: 删除行失败 - $e');
      await AppDialogs.showErrorDialog(
        title: '删除失败',
        message: '数据库繁忙或已被占用，请稍后重试。\n$e',
      );
      return false;
    } finally {
      state.busy.value = false;
    }
  }

  /// 删除后的联动：刷新当前页行数据 + 通知聚合列表刷新。
  Future<void> afterDelete(String table) async {
    final page = state.page.value;
    // 当前页删空后回退一页
    final targetPage = state.rows.length <= 1 && page > 0 ? page - 1 : page;
    await loadRows(table, page: targetPage);

    // 通知“我的应用/发现页”刷新（聚合器订阅了事件总线全量刷新）
    final isUserAppTable = table == 'added_apps' ||
        table == 'channel_added_app' ||
        table == 'added_app_tags';
    if (isUserAppTable) {
      try {
        DatabaseEventBus.instance
            .send(const DatabaseChangeEvent(type: DatabaseChangeType.appDeleted));
      } catch (e) {
        appLog.warning('DatabaseManage: 事件总线发送失败 - $e');
      }
    }
  }

  /// 对标识符做双引号转义。
  String _quoteIdent(String ident) => ident.replaceAll('"', '""');

  /// 格式化字节数。
  String formatSize(int bytes) => byteSize(bytes);
}

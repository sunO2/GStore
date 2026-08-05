import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/step_model.dart';
import 'step_executors.dart';

/// 数据库执行器基类
abstract class DatabaseExecutor extends StepExecutor {
  /// 获取数据库路径
  Future<String> _getDatabasePath(StepContext context) async {
    final dbPath = context.variables['__db_path__'] as String? ??
        join(await getDatabasesPath(), 'workflow.db');
    return dbPath;
  }

  /// 获取数据库连接
  Future<Database> _getDatabase(StepContext context) async {
    final dbPath = await _getDatabasePath(context);
    return openDatabase(dbPath);
  }

  /// 执行数据库查询
  Future<List<Map<String, dynamic>>> _executeQuery(
    Database db,
    String sql, [
    List<dynamic>? arguments,
  ]) async {
    return db.rawQuery(sql, arguments);
  }

  /// 获取表的字段信息
  Future<List<Map<String, dynamic>>> _getTableColumns(Database db, String tableName) async {
    return db.rawQuery('PRAGMA table_info("$tableName")');
  }

  /// 获取所有表名
  Future<List<String>> _getTableNames(Database db) async {
    final result = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return result.map((r) => r['name'] as String).toList();
  }

  /// 生成表不存在时创建表的 SQL
  Future<void> _ensureTableExists(Database db, String tableName, List<Map<String, dynamic>> columns) async {
    // 检查表是否存在
    final tables = await _getTableNames(db);
    if (tables.contains(tableName)) return;

    // 生成建表 SQL
    final columnDefs = <String>[];
    for (final col in columns) {
      final name = col['name'] as String;
      final type = col['type'] as String? ?? 'TEXT';
      final nullable = col['nullable'] as bool? ?? true;
      final primaryKey = col['primaryKey'] as bool? ?? false;
      final autoIncrement = col['autoIncrement'] as bool? ?? false;
      final defaultValue = col['defaultValue'] as String?;

      var colDef = '"$name" $type';
      if (!nullable && !primaryKey) {
        colDef += ' NOT NULL';
      }
      if (primaryKey && autoIncrement) {
        colDef += ' PRIMARY KEY AUTOINCREMENT';
      } else if (primaryKey) {
        colDef += ' PRIMARY KEY';
      }
      if (defaultValue != null && defaultValue.isNotEmpty) {
        if (type == 'TEXT') {
          colDef += " DEFAULT '$defaultValue'";
        } else {
          colDef += ' DEFAULT $defaultValue';
        }
      }
      columnDefs.add(colDef);
    }

    if (columnDefs.isEmpty) {
      columnDefs.add('id INTEGER PRIMARY KEY AUTOINCREMENT');
      columnDefs.add('data TEXT');
      columnDefs.add('created_at DATETIME DEFAULT CURRENT_TIMESTAMP');
    }

    final sql = 'CREATE TABLE "$tableName" (${columnDefs.join(', ')})';
    await db.execute(sql);
  }

  /// 将 dynamic Map 安全转换为 Map<String, dynamic>
  Map<String, dynamic> _toStringKeyMap(dynamic map) {
    if (map == null) return {};
    if (map is Map<String, dynamic>) return map;
    // 处理 _Map<dynamic, dynamic> 或其他 map 类型
    return Map<String, dynamic>.fromEntries(
      (map as Map).entries.map((e) => MapEntry(e.key.toString(), e.value)),
    );
  }

  /// 安全获取 Map 中的值
  dynamic _getMapValue(dynamic map, String key) {
    if (map == null) return null;
    if (map is! Map) return null;
    // 尝试直接用字符串 key 获取
    if (map.containsKey(key)) {
      return map[key];
    }
    // 尝试用动态 key 匹配
    for (final k in map.keys) {
      if (k.toString() == key) {
        return map[k];
      }
    }
    return null;
  }
}

/// 数据库读取执行器
class DatabaseReadExecutor extends DatabaseExecutor {
  @override
  String get type => 'database_read';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final tableName = options['tableName'] as String? ?? '';
    final tableAlias = options['tableAlias'] as String? ?? tableName;
    final columns = options['columns'] as List<dynamic>? ?? [];
    final whereClause = options['whereClause'] as String? ?? '';
    final whereParams = options['whereParams'] as Map<String, dynamic>? ?? {};
    final orderBy = options['orderBy'] as String? ?? '';
    final limit = options['limit'] as int? ?? 100;

    if (tableName.isEmpty) {
      return StepOutput.failure(context.config.id, '表名不能为空');
    }

    try {
      final db = await _getDatabase(context);

      // 如果没有指定列，获取所有列
      List<String> columnList;
      if (columns.isEmpty) {
        final tableInfo = await _getTableColumns(db, tableName);
        columnList = tableInfo.map((c) => c['name'] as String).toList();
      } else {
        columnList = columns.map((c) {
          if (c is Map) return _getMapValue(c, 'name') as String? ?? c.toString();
          return c.toString();
        }).toList();
      }

      // 构建 SQL
      final sqlColumns = columnList.map((c) => '"$c"').join(', ');
      var sql = 'SELECT $sqlColumns FROM "$tableName"';
      final args = <dynamic>[];

      if (whereClause.isNotEmpty) {
        sql += ' WHERE $whereClause';
        if (whereParams.isNotEmpty) {
          // 安全处理 whereParams
          for (final entry in whereParams.entries) {
            args.add(entry.value);
          }
        }
      }

      if (orderBy.isNotEmpty) {
        sql += ' ORDER BY $orderBy';
      }

      sql += ' LIMIT $limit';

      // 执行查询
      final results = await _executeQuery(db, sql, args.isNotEmpty ? args : null);

      // 关闭数据库
      await db.close();

      // 构建输出数据
      final outputData = {
        'rows': results,
        'count': results.length,
        'columns': columnList,
        'tableName': tableName,
        'tableAlias': tableAlias,
      };

      return StepOutput.success(
        context.config.id,
        outputData,
        metadata: {
          'tableName': tableName,
          'tableAlias': tableAlias,
          'rowCount': results.length,
        },
      );
    } catch (e) {
      return StepOutput.failure(context.config.id, '数据库读取失败: $e');
    }
  }
}

/// 数据库写入执行器
class DatabaseWriteExecutor extends DatabaseExecutor {
  @override
  String get type => 'database_write';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final tableName = options['tableName'] as String? ?? '';
    final tableAlias = options['tableAlias'] as String? ?? tableName;
    final operation = options['operation'] as String? ?? 'insert';
    final columns = options['columns'] as List<dynamic>? ?? [];
    final valuesSource = options['valuesSource'] as String? ?? 'input';
    final staticValues = options['staticValues'] as Map<String, dynamic>? ?? {};
    final onConflict = options['onConflict'] as String? ?? 'abort';
    final conflictTarget = options['conflictTarget'] as String? ?? '';
    final whereClause = options['whereClause'] as String? ?? '';

    if (tableName.isEmpty) {
      return StepOutput.failure(context.config.id, '表名不能为空');
    }

    try {
      final db = await _getDatabase(context);

      // 如果有列定义，确保表存在
      if (columns.isNotEmpty) {
        await _ensureTableExists(db, tableName, columns.cast<Map<String, dynamic>>());
      }

      // 获取输入数据
      dynamic inputData = context.inputData;

      // 如果指定了数据源步骤，从该步骤的输出获取数据
      final inputSourceStepId = options['inputSourceStepId'] as String?;
      if (inputSourceStepId != null && inputSourceStepId.isNotEmpty && inputSourceStepId != '__INPUT__') {
        if (context.results.containsKey(inputSourceStepId)) {
          inputData = context.results[inputSourceStepId]?.data;
        }
      }

      List<Map<String, dynamic>>? rows;

      if (inputData is List) {
        rows = inputData.map((item) {
          if (item is Map<String, dynamic>) return item;
          if (item is Map) return _toStringKeyMap(item);
          return <String, dynamic>{};
        }).toList();
      } else if (inputData is Map) {
        // 先转换为 String key map
        final mapData = inputData is Map<String, dynamic>
            ? inputData
            : _toStringKeyMap(inputData);
        // 检查是否是包含 rows 的结构
        if (mapData.containsKey('rows') && mapData['rows'] is List) {
          rows = (mapData['rows'] as List).map((item) {
            if (item is Map<String, dynamic>) return item;
            if (item is Map) return _toStringKeyMap(item);
            return <String, dynamic>{};
          }).toList();
        } else {
          rows = [mapData];
        }
      }

      if (rows == null || rows.isEmpty) {
        return StepOutput.failure(context.config.id, '没有可写入的数据');
      }

      int totalAffected = 0;
      final results = <Map<String, dynamic>>[];

      // 获取表的所有列名
      List<String> tableColumns = [];
      try {
        final tableInfo = await _getTableColumns(db, tableName);
        tableColumns = tableInfo.map((c) => c['name'] as String).toList();
      } catch (_) {}

      for (final row in rows) {
        // 构建写入的值
        final Map<String, dynamic> values;

        if (valuesSource == 'static') {
          values = Map<String, dynamic>.from(staticValues);
        } else {
          // 从输入数据映射
          values = {};
          for (final col in columns) {
            if (col is Map) {
              final colName = col['name'] as String;
              final sourcePath = col['sourcePath'] as String?;
              if (sourcePath != null && sourcePath.isNotEmpty) {
                values[colName] = _extractPath(row, sourcePath);
              } else if (row.containsKey(colName)) {
                values[colName] = row[colName];
              }
            }
          }
          // 添加不在定义中的其他字段
          for (final key in row.keys) {
            if (!values.containsKey(key) && tableColumns.contains(key)) {
              values[key] = row[key];
            }
          }
        }

        int affected = 0;

        switch (operation) {
          case 'insert':
            if (values.isEmpty) break;

            final columnNames = values.keys.map((k) => '"$k"').join(', ');
            final placeholders = values.keys.map((_) => '?').join(', ');
            final sql = 'INSERT${_getConflictClause(onConflict)} INTO "$tableName" ($columnNames) VALUES ($placeholders)';

            affected = await db.rawInsert(sql, values.values.toList());
            break;

          case 'update':
            if (values.isEmpty || whereClause.isEmpty) break;

            final setClause = values.keys.map((k) => '"$k" = ?').join(', ');
            final sql = 'UPDATE "$tableName" SET $setClause WHERE $whereClause';

            affected = await db.rawUpdate(sql, values.values.toList());
            break;

          case 'upsert':
            if (values.isEmpty) break;

            // 如果没有指定冲突目标列，不执行 upsert
            final targetColumn = conflictTarget.isNotEmpty ? conflictTarget : 'id';
            if (targetColumn.isEmpty) {
              return StepOutput.failure(context.config.id, 'Upsert 操作需要指定冲突目标列 (conflictTarget)');
            }

            // 验证目标列是否存在
            final tableColumns = await _getTableColumns(db, tableName);
            final columnNames = tableColumns.map((c) => c['name'] as String).toList();
            if (!columnNames.contains(targetColumn)) {
              return StepOutput.failure(
                context.config.id,
                'Upsert 操作指定的冲突目标列 "$targetColumn" 不存在于表 "$tableName" 中',
              );
            }

            final columnNames2 = values.keys.map((k) => '"$k"').join(', ');
            final placeholders = values.keys.map((_) => '?').join(', ');
            final setClause = values.keys.map((k) => '"$k" = excluded."$k"').join(', ');

            final sql = 'INSERT${_getConflictClause(onConflict)} INTO "$tableName" ($columnNames2) VALUES ($placeholders) ON CONFLICT($targetColumn) DO UPDATE SET $setClause';

            affected = await db.rawInsert(sql, values.values.toList());
            break;
        }

        totalAffected += affected;
        results.add({'row': row, 'affected': affected});
      }

      // 关闭数据库
      await db.close();

      return StepOutput.success(
        context.config.id,
        {
          'affectedRows': totalAffected,
          'results': results,
          'tableName': tableName,
          'tableAlias': tableAlias,
        },
        metadata: {
          'tableName': tableName,
          'tableAlias': tableAlias,
          'operation': operation,
          'affectedRows': totalAffected,
        },
      );
    } catch (e) {
      return StepOutput.failure(context.config.id, '数据库写入失败: $e');
    }
  }

  String _getConflictClause(String onConflict) {
    switch (onConflict) {
      case 'ignore':
        return ' OR IGNORE';
      case 'replace':
        return ' OR REPLACE';
      default:
        return '';
    }
  }

  dynamic _extractPath(Map<String, dynamic> data, String path) {
    final parts = path.split('.');
    dynamic current = data;

    for (final part in parts) {
      if (current == null) return null;

      // 处理数组索引，如 items[0]
      final arrayMatch = RegExp(r'^(\w+)\[(\d+)\]$').firstMatch(part);
      if (arrayMatch != null) {
        final key = arrayMatch.group(1)!;
        final index = int.parse(arrayMatch.group(2)!);
        current = current[key] as List?;
        if (current is List && index < current.length) {
          current = current[index];
        } else {
          return null;
        }
      } else {
        current = current[part];
      }
    }

    return current;
  }
}

/// 数据库创建执行器
class DatabaseCreateExecutor extends DatabaseExecutor {
  @override
  String get type => 'database_create';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final tableName = options['tableName'] as String? ?? '';
    final ifNotExists = options['ifNotExists'] as bool? ?? true;
    final replaceExisting = options['replaceExisting'] as bool? ?? false;
    final columns = options['columns'] as List<dynamic>? ?? [];

    if (tableName.isEmpty) {
      return StepOutput.failure(context.config.id, '表名不能为空');
    }

    try {
      final db = await _getDatabase(context);

      // 检查表是否已存在
      final tables = await _getTableNames(db);
      final tableExists = tables.contains(tableName);

      if (tableExists) {
        if (replaceExisting) {
          // 删除旧表
          await db.execute('DROP TABLE IF EXISTS "$tableName"');
        } else {
          // 表已存在，不创建
          await db.close();
          return StepOutput.success(
            context.config.id,
            {
              'created': false,
              'skipped': true,
              'reason': '表已存在',
              'tableName': tableName,
            },
            metadata: {
              'tableName': tableName,
              'created': false,
              'skipped': true,
            },
          );
        }
      }

      // 构建建表 SQL
      final columnDefs = <String>[];
      for (final col in columns) {
        if (col is! Map) continue;
        final colMap = _toStringKeyMap(col);

        final name = colMap['name'] as String? ?? '';
        if (name.isEmpty) continue;

        final type = colMap['type'] as String? ?? 'TEXT';
        final nullable = colMap['nullable'] as bool? ?? true;
        final primaryKey = colMap['primaryKey'] as bool? ?? false;
        final autoIncrement = colMap['autoIncrement'] as bool? ?? false;
        final defaultValue = colMap['defaultValue'] as String?;

        var colDef = '"$name" $type';
        if (!nullable && !primaryKey) {
          colDef += ' NOT NULL';
        }
        if (primaryKey && autoIncrement) {
          colDef += ' PRIMARY KEY AUTOINCREMENT';
        } else if (primaryKey) {
          colDef += ' PRIMARY KEY';
        }
        if (defaultValue != null && defaultValue.isNotEmpty) {
          if (type.toUpperCase() == 'TEXT') {
            colDef += " DEFAULT '$defaultValue'";
          } else {
            colDef += ' DEFAULT $defaultValue';
          }
        }
        columnDefs.add(colDef);
      }

      // 如果没有定义列，添加默认列
      if (columnDefs.isEmpty) {
        columnDefs.add('id INTEGER PRIMARY KEY AUTOINCREMENT');
        columnDefs.add('data TEXT');
        columnDefs.add('created_at DATETIME DEFAULT CURRENT_TIMESTAMP');
      }

      // 生成并执行 SQL
      final sql = ifNotExists
          ? 'CREATE TABLE IF NOT EXISTS "$tableName" (${columnDefs.join(', ')})'
          : 'CREATE TABLE "$tableName" (${columnDefs.join(', ')})';

      await db.execute(sql);
      await db.close();

      return StepOutput.success(
        context.config.id,
        {
          'created': true,
          'tableName': tableName,
          'columns': columnDefs.length,
          'sql': sql,
        },
        metadata: {
          'tableName': tableName,
          'created': true,
          'columnCount': columnDefs.length,
        },
      );
    } catch (e) {
      return StepOutput.failure(context.config.id, '建表失败: $e');
    }
  }
}

/// WHERE 子句构建（辅助方法，用于 update 操作）
String buildWhereClause(String condition, Map<String, dynamic> params) {
  return condition;
}

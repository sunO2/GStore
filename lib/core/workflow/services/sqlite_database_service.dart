import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// SQLite 数据库服务
/// 用于表结构读取和数据库操作
class SqliteDatabaseService {
  static final SqliteDatabaseService _instance = SqliteDatabaseService._internal();
  factory SqliteDatabaseService() => _instance;
  SqliteDatabaseService._internal();

  Database? _database;
  String? _currentPath;

  /// 获取或打开数据库
  Future<Database> getDatabase([String? dbPath]) async {
    final path = dbPath ?? _currentPath ?? join(await getDatabasesPath(), 'workflow.db');

    if (_database != null && _currentPath == path) {
      return _database!;
    }

    _currentPath = path;
    _database = await openDatabase(path);
    return _database!;
  }

  /// 关闭数据库连接
  Future<void> close() async {
    await _database?.close();
    _database = null;
    _currentPath = null;
  }

  /// 获取所有表名
  Future<List<String>> getTableNames() async {
    final db = await getDatabase();
    final result = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return result.map((r) => r['name'] as String).toList();
  }

  /// 获取表的所有列信息
  Future<List<ColumnInfo>> getTableColumns(String tableName) async {
    final db = await getDatabase();
    final result = await db.rawQuery('PRAGMA table_info("$tableName")');

    return result.map((r) => ColumnInfo(
      name: r['name'] as String,
      type: r['type'] as String? ?? 'TEXT',
      nullable: r['notnull'] == 0,
      primaryKey: r['pk'] == 1,
      defaultValue: r['dflt_value'] as String?,
    )).toList();
  }

  /// 获取表结构的完整描述（用于显示）
  Future<TableSchemaInfo> getTableSchema(String tableName) async {
    final db = await getDatabase();
    final columns = await getTableColumns(tableName);
    final countResult = await db.rawQuery('SELECT COUNT(*) as count FROM "$tableName"');
    final rowCount = countResult.first['count'] as int? ?? 0;

    return TableSchemaInfo(
      name: tableName,
      columns: columns,
      rowCount: rowCount,
    );
  }

  /// 获取所有表及其列的完整结构
  Future<Map<String, TableSchemaInfo>> getAllTableSchemas() async {
    final tableNames = await getTableNames();
    final schemas = <String, TableSchemaInfo>{};

    for (final name in tableNames) {
      schemas[name] = await getTableSchema(name);
    }

    return schemas;
  }

  /// 执行 SQL 查询（用于测试连接）
  Future<List<Map<String, dynamic>>> query(String sql, [List<dynamic>? arguments]) async {
    final db = await getDatabase();
    return db.rawQuery(sql, arguments);
  }

  /// 检查表是否存在
  Future<bool> tableExists(String tableName) async {
    final tables = await getTableNames();
    return tables.contains(tableName);
  }

  /// 创建表
  Future<void> createTable(String tableName, List<ColumnDefinition> columns) async {
    final db = await getDatabase();
    final columnDefs = columns.map((c) => c.toSql()).join(', ');
    final sql = 'CREATE TABLE IF NOT EXISTS "$tableName" ($columnDefs)';
    await db.execute(sql);
  }
}

/// 列信息
class ColumnInfo {
  final String name;
  final String type;
  final bool nullable;
  final bool primaryKey;
  final String? defaultValue;

  ColumnInfo({
    required this.name,
    required this.type,
    required this.nullable,
    required this.primaryKey,
    this.defaultValue,
  });

  String get displayType => primaryKey ? '$type (PK)' : type;
}

/// 表结构信息
class TableSchemaInfo {
  final String name;
  final List<ColumnInfo> columns;
  final int rowCount;

  TableSchemaInfo({
    required this.name,
    required this.columns,
    required this.rowCount,
  });

  List<String> get columnNames => columns.map((c) => c.name).toList();

  String get displayInfo => '$name (${columns.length} 列, $rowCount 行)';
}

/// 列定义（用于创建表）
class ColumnDefinition {
  final String name;
  final String type;
  final int? length;
  final bool nullable;
  final bool primaryKey;
  final bool autoIncrement;
  final String? defaultValue;

  ColumnDefinition({
    required this.name,
    required this.type,
    this.length,
    this.nullable = true,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.defaultValue,
  });

  String toSql() {
    final parts = <String>['"$name"'];

    if (length != null && type.toUpperCase() == 'TEXT') {
      parts.add('$type($length)');
    } else {
      parts.add(type);
    }

    if (!nullable && !primaryKey) {
      parts.add('NOT NULL');
    }

    if (primaryKey && autoIncrement) {
      parts.add('PRIMARY KEY AUTOINCREMENT');
    } else if (primaryKey) {
      parts.add('PRIMARY KEY');
    }

    if (defaultValue != null && defaultValue!.isNotEmpty) {
      if (type.toUpperCase() == 'TEXT') {
        parts.add("DEFAULT '$defaultValue'");
      } else {
        parts.add('DEFAULT $defaultValue');
      }
    }

    return parts.join(' ');
  }
}

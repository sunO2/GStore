/// 数据库字段类型枚举
enum DbColumnType {
  text('TEXT', '文本'),
  integer('INTEGER', '整数'),
  real('REAL', '实数'),
  boolean('BOOLEAN', '布尔'),
  blob('BLOB', '二进制'),
  datetime('DATETIME', '日期时间');

  final String sqlType;
  final String label;

  const DbColumnType(this.sqlType, this.label);
}

/// 字段定义
class ColumnSchema {
  final String name;
  final DbColumnType type;
  final int? length;
  final bool nullable;
  final bool primaryKey;
  final bool autoIncrement;
  final String? defaultValue;
  final bool isIndex;

  ColumnSchema({
    required this.name,
    this.type = DbColumnType.text,
    this.length,
    this.nullable = true,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.defaultValue,
    this.isIndex = false,
  });

  ColumnSchema copyWith({
    String? name,
    DbColumnType? type,
    int? length,
    bool? nullable,
    bool? primaryKey,
    bool? autoIncrement,
    String? defaultValue,
    bool? isIndex,
    bool clearLength = false,
    bool clearDefaultValue = false,
  }) {
    return ColumnSchema(
      name: name ?? this.name,
      type: type ?? this.type,
      length: clearLength ? null : (length ?? this.length),
      nullable: nullable ?? this.nullable,
      primaryKey: primaryKey ?? this.primaryKey,
      autoIncrement: autoIncrement ?? this.autoIncrement,
      defaultValue: clearDefaultValue ? null : (defaultValue ?? this.defaultValue),
      isIndex: isIndex ?? this.isIndex,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type.name,
      if (length != null) 'length': length,
      'nullable': nullable,
      'primaryKey': primaryKey,
      'autoIncrement': autoIncrement,
      if (defaultValue != null) 'defaultValue': defaultValue,
      'isIndex': isIndex,
    };
  }

  factory ColumnSchema.fromJson(Map<String, dynamic> json) {
    return ColumnSchema(
      name: json['name'] as String,
      type: DbColumnType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => DbColumnType.text,
      ),
      length: json['length'] as int?,
      nullable: json['nullable'] as bool? ?? true,
      primaryKey: json['primaryKey'] as bool? ?? false,
      autoIncrement: json['autoIncrement'] as bool? ?? false,
      defaultValue: json['defaultValue'] as String?,
      isIndex: json['isIndex'] as bool? ?? false,
    );
  }

  /// 生成建表 SQL 片段
  String toSql() {
    final parts = <String>[];
    parts.add('"$name" ${type.sqlType}');
    if (length != null && type == DbColumnType.text) {
      parts.add('($length)');
    }
    if (!nullable) {
      parts.add('NOT NULL');
    }
    if (primaryKey) {
      parts.add('PRIMARY KEY');
    }
    if (autoIncrement && type == DbColumnType.integer) {
      parts.add('AUTOINCREMENT');
    }
    if (defaultValue != null) {
      if (type == DbColumnType.text) {
        parts.add("DEFAULT '$defaultValue'");
      } else {
        parts.add('DEFAULT $defaultValue');
      }
    }
    return parts.join(' ');
  }
}

/// 表定义
class TableSchema {
  final String name;
  final String? alias;
  final List<ColumnSchema> columns;

  TableSchema({
    required this.name,
    this.alias,
    required this.columns,
  });

  TableSchema copyWith({
    String? name,
    String? alias,
    List<ColumnSchema>? columns,
  }) {
    return TableSchema(
      name: name ?? this.name,
      alias: alias ?? this.alias,
      columns: columns ?? this.columns,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      if (alias != null) 'alias': alias,
      'columns': columns.map((c) => c.toJson()).toList(),
    };
  }

  factory TableSchema.fromJson(Map<String, dynamic> json) {
    return TableSchema(
      name: json['name'] as String,
      alias: json['alias'] as String?,
      columns: (json['columns'] as List<dynamic>)
          .map((c) => ColumnSchema.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 数据库连接配置
class DatabaseConnection {
  final String id;
  final String name;
  final String databasePath;
  final bool isDefault;

  DatabaseConnection({
    required this.id,
    required this.name,
    required this.databasePath,
    this.isDefault = false,
  });

  DatabaseConnection copyWith({
    String? id,
    String? name,
    String? databasePath,
    bool? isDefault,
  }) {
    return DatabaseConnection(
      id: id ?? this.id,
      name: name ?? this.name,
      databasePath: databasePath ?? this.databasePath,
      isDefault: isDefault ?? this.isDefault,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'databasePath': databasePath,
      'isDefault': isDefault,
    };
  }

  factory DatabaseConnection.fromJson(Map<String, dynamic> json) {
    return DatabaseConnection(
      id: json['id'] as String,
      name: json['name'] as String,
      databasePath: json['databasePath'] as String,
      isDefault: json['isDefault'] as bool? ?? false,
    );
  }
}

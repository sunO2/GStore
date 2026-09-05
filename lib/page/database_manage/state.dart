/// 数据库管理页模型与 UI 状态（Riverpod 不可变 state）。
library;

/// 单个数据库文件的信息。
class DbEntry {
  const DbEntry({
    required this.filePath,
    required this.fileName,
    required this.displayName,
    required this.description,
    required this.size,
    required this.version,
    this.managed = false,
    this.totalRows,
  });

  final String filePath;
  final String fileName;

  /// 展示名（如"应用目录库""我的应用"）。
  final String displayName;

  /// 用途说明。
  final String description;

  /// 文件字节数。
  final int size;

  /// PRAGMA user_version。
  final int version;

  /// 是否受 App 运行态管理（删除行可能影响运行状态，需额外提示/限制）。
  final bool managed;

  /// 行数（懒加载）。
  final int? totalRows;
}

/// 单个表的信息。
class DbTable {
  const DbTable({
    required this.name,
    required this.count,
    this.displayName,
    this.readonly = false,
  });

  final String name;

  /// 行数。
  final int count;

  /// 展示用中文名（已知表）。
  final String? displayName;

  /// 是否只读（受管主表，不允许行级删除）。
  final bool readonly;
}

/// 数据库管理页 UI 状态。
class DatabaseManageState {
  final bool loading;
  final List<DbEntry> dbs;
  final DbEntry? selectedDb;
  final List<DbTable> tables;
  final bool tablesLoading;
  final String browsingTable;
  final List<Map<String, Object?>> rows;
  final List<String> columns;
  final int tableTotal;
  final int page;
  final int selectedRowIndex;
  final bool rowsLoading;
  final bool busy;

  /// 每页行数。
  final int pageSize;

  const DatabaseManageState({
    this.loading = false,
    this.dbs = const [],
    this.selectedDb,
    this.tables = const [],
    this.tablesLoading = false,
    this.browsingTable = '',
    this.rows = const [],
    this.columns = const [],
    this.tableTotal = 0,
    this.page = 0,
    this.selectedRowIndex = -1,
    this.rowsLoading = false,
    this.busy = false,
    this.pageSize = 50,
  });

  DatabaseManageState copyWith({
    bool? loading,
    List<DbEntry>? dbs,
    DbEntry? selectedDb,
    bool clearSelectedDb = false,
    List<DbTable>? tables,
    bool? tablesLoading,
    String? browsingTable,
    List<Map<String, Object?>>? rows,
    List<String>? columns,
    int? tableTotal,
    int? page,
    int? selectedRowIndex,
    bool? rowsLoading,
    bool? busy,
  }) {
    return DatabaseManageState(
      loading: loading ?? this.loading,
      dbs: dbs ?? this.dbs,
      selectedDb:
          clearSelectedDb ? null : (selectedDb ?? this.selectedDb),
      tables: tables ?? this.tables,
      tablesLoading: tablesLoading ?? this.tablesLoading,
      browsingTable: browsingTable ?? this.browsingTable,
      rows: rows ?? this.rows,
      columns: columns ?? this.columns,
      tableTotal: tableTotal ?? this.tableTotal,
      page: page ?? this.page,
      selectedRowIndex: selectedRowIndex ?? this.selectedRowIndex,
      rowsLoading: rowsLoading ?? this.rowsLoading,
      busy: busy ?? this.busy,
      pageSize: pageSize,
    );
  }
}

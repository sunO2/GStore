import 'package:get/get.dart';

/// 单个数据库文件的信息。
class DbEntry {
  DbEntry({
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

  /// 展示名（如“应用目录库”“我的应用”）。
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
  int? totalRows;

  DbEntry copyWith({
    int? size,
    int? version,
    int? totalRows,
  }) {
    return DbEntry(
      filePath: filePath,
      fileName: fileName,
      displayName: displayName,
      description: description,
      size: size ?? this.size,
      version: version ?? this.version,
      managed: managed,
      totalRows: totalRows ?? this.totalRows,
    );
  }
}

/// 单个表的信息。
class DbTable {
  DbTable({
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

/// 数据库管理页状态。
class DatabaseManageState {
  /// 首页加载中。
  final RxBool loading = false.obs;

  /// 发现的数据库列表。
  final RxList<DbEntry> dbs = <DbEntry>[].obs;

  /// 当前选中的库（进入库详情时设置）。
  final Rxn<DbEntry> selectedDb = Rxn<DbEntry>();

  /// 当前库的表列表。
  final RxList<DbTable> tables = <DbTable>[].obs;

  /// 表加载中。
  final RxBool tablesLoading = false.obs;

  /// 当前浏览的库文件路径。
  final RxString browsingPath = ''.obs;

  /// 当前浏览的表名。
  final RxString browsingTable = ''.obs;

  /// 当前表行数据。
  final RxList<Map<String, Object?>> rows = <Map<String, Object?>>[].obs;

  /// 当前表列名。
  final RxList<String> columns = <String>[].obs;

  /// 当前表总行数。
  final RxInt tableTotal = 0.obs;

  /// 当前页（从 0 开始）。
  final RxInt page = 0.obs;

  /// 选中行的行内索引（-1 表示未选中，用于高亮与详情定位）。
  final RxInt selectedRowIndex = (-1).obs;

  /// 每页行数。
  final int pageSize = 50;

  /// 行浏览加载中。
  final RxBool rowsLoading = false.obs;

  /// 操作进行中（删除等）。
  final RxBool busy = false.obs;
}

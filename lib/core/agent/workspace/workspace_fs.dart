/// AI 文件工作区后端抽象。
///
/// 目前只有应用私有目录实现（[InternalWorkspaceFs]）；后续可增加 SAF
/// (`content://`) 实现，而无需改动 file* 工具与审批逻辑。
library;

/// 工作区硬限制。
class WorkspaceLimits {
  WorkspaceLimits._();

  static const int maxWriteBytes = 512 * 1024;
  static const int maxReadBytes = 256 * 1024;
  static const int maxTotalBytes = 5 * 1024 * 1024;
  static const int maxFiles = 200;
}

/// 工作区操作失败（可直接展示给模型/用户）。
class AgentWorkspaceException implements Exception {
  const AgentWorkspaceException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum WorkspaceNodeType { file, directory, other }

/// 路径解析结果（后端无关）。
class WorkspaceResolved {
  const WorkspaceResolved({
    required this.relative,
    required this.type,
    required this.exists,
  });

  final String relative;
  final WorkspaceNodeType type;
  final bool exists;
}

class WorkspaceStat {
  const WorkspaceStat({
    required this.relative,
    required this.type,
    required this.bytes,
    required this.modifiedAt,
  });

  final String relative;
  final WorkspaceNodeType type;
  final int bytes;
  final DateTime modifiedAt;
}

class AgentWorkspaceEntry {
  const AgentWorkspaceEntry({
    required this.path,
    required this.isDirectory,
    required this.bytes,
    required this.modifiedAt,
  });

  /// 相对工作区根目录的路径（统一使用 `/`）
  final String path;
  final bool isDirectory;
  final int bytes;
  final DateTime modifiedAt;
}

class AgentWorkspaceStats {
  const AgentWorkspaceStats({
    required this.files,
    required this.bytes,
    required this.maxFiles,
    required this.maxBytes,
  });

  final int files;
  final int bytes;
  final int maxFiles;
  final int maxBytes;

  double get ratio => maxBytes <= 0 ? 0 : (bytes / maxBytes).clamp(0.0, 1.0);
}

class AgentWorkspaceReadResult {
  const AgentWorkspaceReadResult({
    required this.path,
    required this.bytes,
    required this.truncated,
    required this.binary,
    this.text,
  });

  final String path;
  final int bytes;
  final bool truncated;
  final bool binary;
  final String? text;
}

/// 工作区文件后端。
///
/// 所有路径均为**工作区相对路径**；后端负责路径沙箱与真实 IO。
abstract interface class WorkspaceFs {
  /// 是否按应用工作区的 5MB / 200 文件总量限制校验。
  ///
  /// 外部用户目录（SAF）通常已有大量文件，不应被应用配额限制。
  bool get enforceWorkspaceQuota;

  /// 是否为外部用户目录（SAF）。
  bool get isExternal;

  /// 工作区根目录（内部实现返回真实路径；SAF 实现可返回显示名/空串）。
  Future<String> get rootPath;

  /// 规范化并校验路径；不实际创建/写入。
  Future<WorkspaceResolved> resolve(String path, {bool forWrite = false});

  Future<WorkspaceStat> stat(String path);

  /// 列目录；[recursive] 为 true 时返回全部后代。
  Future<List<AgentWorkspaceEntry>> list(
    String path, {
    bool recursive = false,
    int limit = 500,
  });

  /// 读取文本（超过 [maxBytes] 截断；二进制返回 metadata）。
  Future<AgentWorkspaceReadResult> read(
    String path, {
    int maxBytes = WorkspaceLimits.maxReadBytes,
  });

  /// 读取原始字节（编辑/导出用）。
  Future<List<int>> readBytes(String path);

  /// 原子写入（内部实现使用临时文件 + rename）。
  Future<void> writeBytes(
    String path,
    List<int> bytes, {
    bool create = false,
  });

  Future<void> delete(String path);

  Future<void> move(String source, String target);

  Future<void> mkdir(String path);

  Future<AgentWorkspaceStats> stats();

  Future<void> clear();

  /// 内部后端的真实路径；SAF 等外部后端返回 null。
  Future<String?> localPathFor(String relative);
}

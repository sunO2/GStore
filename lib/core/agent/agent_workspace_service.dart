import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'workspace/internal_workspace_fs.dart';
import 'workspace/saf_workspace_fs.dart';
import 'workspace/workspace_fs.dart';

export 'workspace/workspace_fs.dart';
export 'workspace/saf_workspace_fs.dart';

class AgentWorkspaceApproval {
  const AgentWorkspaceApproval({
    required this.id,
    required this.action,
    required this.path,
    required this.bytes,
    required this.expiresAt,
  });

  final String id;
  final String action;
  final String path;
  final int bytes;
  final DateTime expiresAt;
}

enum AgentWorkspaceType { internal, saf }

class AgentWorkspaceInfo {
  const AgentWorkspaceInfo({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.type = AgentWorkspaceType.internal,
    this.uri,
  });

  final String id;
  final String name;
  final int createdAt;
  final int updatedAt;
  final AgentWorkspaceType type;

  /// SAF tree URI（仅 type=saf）
  final String? uri;

  bool get isExternal => type == AgentWorkspaceType.saf;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'type': type.name,
        if (uri != null) 'uri': uri,
      };

  factory AgentWorkspaceInfo.fromJson(Map<String, dynamic> json) {
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return AgentWorkspaceInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      createdAt: asInt(json['createdAt']),
      updatedAt: asInt(json['updatedAt']),
      type: json['type']?.toString() == AgentWorkspaceType.saf.name
          ? AgentWorkspaceType.saf
          : AgentWorkspaceType.internal,
      uri: json['uri']?.toString(),
    );
  }

  AgentWorkspaceInfo copyWith({String? name, int? updatedAt}) =>
      AgentWorkspaceInfo(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        type: type,
        uri: uri,
      );
}

class AgentWorkspaceAuditEntry {
  const AgentWorkspaceAuditEntry({
    required this.time,
    required this.action,
    required this.path,
    required this.bytes,
    required this.ok,
    this.message,
    this.workspaceId = '',
  });

  final DateTime time;
  final String action;
  final String path;
  final int bytes;
  final bool ok;
  final String? message;

  /// Workspace that produced this entry.
  ///
  /// Entries written before multi-workspace support have an empty id and are
  /// treated as the [AgentWorkspaceService.defaultWorkspaceId] workspace.
  final String workspaceId;

  Map<String, dynamic> toJson() => {
        'time': time.millisecondsSinceEpoch,
        'action': action,
        'path': path,
        'bytes': bytes,
        'ok': ok,
        if (message != null && message!.isNotEmpty) 'message': message,
        if (workspaceId.isNotEmpty) 'workspaceId': workspaceId,
      };

  factory AgentWorkspaceAuditEntry.fromJson(Map<String, dynamic> json) {
    return AgentWorkspaceAuditEntry(
      time: DateTime.fromMillisecondsSinceEpoch(
        (json['time'] as num?)?.toInt() ?? 0,
      ),
      action: json['action']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      ok: json['ok'] == true,
      message: json['message']?.toString(),
      workspaceId: json['workspaceId']?.toString() ?? '',
    );
  }
}

class _PendingApproval {
  _PendingApproval({
    required this.action,
    required this.path,
    required this.contentHash,
    required this.bytes,
    required this.expiresAt,
    this.target,
  });

  final String action;
  final String path;
  final String contentHash;
  final int bytes;
  final DateTime expiresAt;
  final String? target;
}

/// AI 文件工作区：应用私有目录 + 路径沙箱 + 审批 token。
///
/// 只负责文件系统与安全校验，不涉及 UI；确认卡片由 AgentService 负责。
class AgentWorkspaceService {
  AgentWorkspaceService({
    Directory? workspaceRoot,
    Directory? supportRoot,
  })  : _workspaceRootOverride = workspaceRoot,
        _supportRootOverride = supportRoot;

  static const int maxWriteBytes = WorkspaceLimits.maxWriteBytes;
  static const int maxReadBytes = WorkspaceLimits.maxReadBytes;
  static const int maxTotalBytes = WorkspaceLimits.maxTotalBytes;
  static const int maxFiles = WorkspaceLimits.maxFiles;
  static const int maxApprovals = 16;
  static const Duration approvalTtl = Duration(minutes: 5);

  static const String defaultWorkspaceId = 'default';
  static const String _registryKey = 'agent_workspaces_v1';

  final Directory? _workspaceRootOverride;
  final Directory? _supportRootOverride;

  String _workspaceId = defaultWorkspaceId;
  WorkspaceFs? _fs;
  final Map<String, _PendingApproval> _approvals = {};

  /// 当前工作区 ID（默认 default）。
  String get workspaceId => _workspaceId;

  Future<Directory> _supportDir() async {
    final override = _supportRootOverride;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }
    return getApplicationSupportDirectory();
  }

  Future<Directory> _workspaceBaseDir() async {
    final dir = Directory(
      p.join((await _supportDir()).path, 'agent_workspaces'),
    );
    await dir.create(recursive: true);

    // 旧版本全局工作区迁移到 default 工作区。
    final legacy = Directory(
      p.join((await _supportDir()).path, 'agent_workspace'),
    );
    final defaultDir = Directory(p.join(dir.path, defaultWorkspaceId));
    if (await legacy.exists() && !await defaultDir.exists()) {
      try {
        await legacy.rename(defaultDir.path);
      } catch (_) {
        // 迁移失败不影响新工作区使用
      }
    }
    await defaultDir.create(recursive: true);
    return dir;
  }

  Future<Directory> _workspaceDir(String id) async {
    final base = await _workspaceBaseDir();
    final dir = Directory(p.join(base.path, id));
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<AgentWorkspaceInfo>> workspaces() => _loadRegistry();

  Future<AgentWorkspaceInfo> currentWorkspace() async {
    final list = await _loadRegistry();
    for (final item in list) {
      if (item.id == _workspaceId) return item;
    }
    return list.first;
  }

  /// 切换当前工作区；返回工作区信息（不存在时回退 default）。
  Future<AgentWorkspaceInfo> selectWorkspace(String id) async {
    final list = await _loadRegistry();
    final info = list.firstWhere(
      (item) => item.id == id,
      orElse: () => list.first,
    );
    _workspaceId = info.id;
    _fs = null;
    // 审批 token 绑定的是相对路径，切换工作区后必须失效。
    _approvals.clear();
    return info;
  }

  /// 新建工作区（自动命名，默认选中）。
  Future<AgentWorkspaceInfo> createWorkspace({String? name}) async {
    final list = await _loadRegistry();
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = 'ws-$now';
    final info = AgentWorkspaceInfo(
      id: id,
      name: (name?.trim().isNotEmpty ?? false)
          ? name!.trim()
          : '工作区 ${list.length}',
      createdAt: now,
      updatedAt: now,
    );
    list.add(info);
    await _saveRegistry(list);
    if (_workspaceRootOverride == null) {
      await _workspaceDir(id);
    }
    return info;
  }

  /// 添加一个外部 SAF 目录工作区（用户通过系统目录选择器授权）。
  Future<AgentWorkspaceInfo> addSafWorkspace({
    required String uri,
    String? name,
  }) async {
    if (uri.trim().isEmpty) {
      throw const AgentWorkspaceException('SAF URI 不能为空');
    }
    if (!await SafWorkspaceFs.hasPermission(uri)) {
      throw const AgentWorkspaceException('没有该目录的持久化读写权限');
    }
    final list = await _loadRegistry();
    for (final item in list) {
      if (item.uri == uri) return item;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final info = AgentWorkspaceInfo(
      id: 'saf-$now',
      name: (name?.trim().isNotEmpty ?? false) ? name!.trim() : '外部目录',
      createdAt: now,
      updatedAt: now,
      type: AgentWorkspaceType.saf,
      uri: uri,
    );
    list.add(info);
    await _saveRegistry(list);
    return info;
  }

  /// Removes a workspace from the registry.
  ///
  /// * The default workspace can never be removed (use [clear] for its files).
  /// * An app-private workspace has its private directory deleted best-effort.
  /// * An external SAF workspace only loses the registry entry: the user's
  ///   directory and its files are never touched.
  /// * If the removed workspace is current, the first remaining workspace
  ///   (always the default) becomes current.
  Future<void> removeWorkspace(String id) async {
    final list = await _loadRegistry();
    final index = list.indexWhere((item) => item.id == id);
    if (index < 0) {
      throw const AgentWorkspaceException('工作区不存在');
    }
    final info = list[index];
    if (info.id == defaultWorkspaceId) {
      throw const AgentWorkspaceException('默认工作区不可移除，只能清空文件');
    }
    list.removeAt(index);
    await _saveRegistry(list);

    // Internal workspaces own an app-private directory; delete it so a removed
    // workspace cannot leave invisible files behind. External SAF directories
    // are user-owned and must not be deleted.
    if (!info.isExternal && _workspaceRootOverride == null) {
      try {
        final base = await _workspaceBaseDir();
        final dir = Directory(p.join(base.path, info.id));
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (_) {
        // Best-effort: the registry entry is gone; a locked file must not undo it.
      }
    }

    if (_workspaceId == id) {
      _workspaceId = list.isNotEmpty ? list.first.id : defaultWorkspaceId;
      _fs = null;
      _approvals.clear();
    }
  }

  Future<List<AgentWorkspaceInfo>> _loadRegistry() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_registryKey);
    final list = <AgentWorkspaceInfo>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final info = AgentWorkspaceInfo.fromJson(
                Map<String, dynamic>.from(item),
              );
              if (info.id.isNotEmpty) list.add(info);
            }
          }
        }
      } catch (_) {}
    }
    if (!list.any((item) => item.id == defaultWorkspaceId)) {
      final now = DateTime.now().millisecondsSinceEpoch;
      list.insert(
        0,
        AgentWorkspaceInfo(
          id: defaultWorkspaceId,
          name: '默认工作区',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await _saveRegistry(list);
    }
    return list;
  }

  Future<void> _saveRegistry(List<AgentWorkspaceInfo> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _registryKey,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<WorkspaceFs> _fsInstance() async {
    final cached = _fs;
    if (cached != null) return cached;

    final override = _workspaceRootOverride;
    if (override != null) {
      final fs = InternalWorkspaceFs(override);
      _fs = fs;
      return fs;
    }

    final info = await currentWorkspace();
    if (info.isExternal) {
      final uri = info.uri;
      if (uri == null || uri.isEmpty) {
        throw const AgentWorkspaceException('外部工作区缺少 SAF URI');
      }
      final permitted = await SafWorkspaceFs.hasPermission(uri);
      if (!permitted) {
        throw const AgentWorkspaceException(
          '外部工作区授权已失效，请重新选择目录',
        );
      }
      final fs = SafWorkspaceFs(uri);
      _fs = fs;
      return fs;
    }

    final fs = InternalWorkspaceFs(await _workspaceDir(_workspaceId));
    _fs = fs;
    return fs;
  }

  /// 工作区根目录（内部后端为真实路径）。
  Future<String> get rootPath async => (await _fsInstance()).rootPath;

  /// 工作区真实路径（仅内部后端；STAF 等外部后端返回 null）。
  Future<String?> localPathFor(String relative) async =>
      (await _fsInstance()).localPathFor(relative);

  Future<List<int>> readBytes(String path) async =>
      (await _fsInstance()).readBytes(path);

  Future<List<AgentWorkspaceEntry>> list({String? dir}) async {
    final fs = await _fsInstance();
    return fs.list(dir ?? '', limit: maxFiles);
  }

  Future<List<AgentWorkspaceEntry>> listAll({int limit = 500}) async {
    final fs = await _fsInstance();
    return fs.list('', recursive: true, limit: limit);
  }

  Future<AgentWorkspaceReadResult> read(String path) async {
    final fs = await _fsInstance();
    return fs.read(path, maxBytes: maxReadBytes);
  }

  Future<int> validateWrite({
    required String action,
    required String path,
    required String content,
  }) async {
    if (action != 'write' && action != 'create') {
      throw const AgentWorkspaceException('仅支持 write/create');
    }
    final bytes = utf8.encode(content);
    if (bytes.length > maxWriteBytes) {
      throw const AgentWorkspaceException('文件超过 512KB 限制');
    }
    final fs = await _fsInstance();
    final resolved = await fs.resolve(path, forWrite: true);
    if (resolved.type == WorkspaceNodeType.directory) {
      throw const AgentWorkspaceException('目标是目录');
    }
    if (action == 'create' && resolved.exists) {
      throw const AgentWorkspaceException('文件已存在，请使用 write 覆盖');
    }
    if (fs.enforceWorkspaceQuota) {
      final stats = await fs.stats();
      final existingBytes =
          resolved.exists ? (await fs.stat(resolved.relative)).bytes : 0;
      final fileCount = stats.files + (resolved.exists ? 0 : 1);
      if (fileCount > maxFiles) {
        throw const AgentWorkspaceException('工作区文件数量已达上限');
      }
      if (stats.bytes - existingBytes + bytes.length > maxTotalBytes) {
        throw const AgentWorkspaceException('工作区容量已达上限（5MB）');
      }
    }
    return bytes.length;
  }

  Future<({String relative, int bytes})> validateDelete(String path) async {
    final fs = await _fsInstance();
    final resolved = await fs.resolve(path);
    if (!resolved.exists) {
      throw const AgentWorkspaceException('文件或目录不存在');
    }
    if (resolved.type == WorkspaceNodeType.directory) {
      final children = await fs.list(resolved.relative, limit: 1);
      if (children.isNotEmpty) {
        throw const AgentWorkspaceException('目录不为空，无法删除');
      }
      return (relative: resolved.relative, bytes: 0);
    }
    final stat = await fs.stat(resolved.relative);
    return (relative: resolved.relative, bytes: stat.bytes);
  }

  Future<({String source, String target, int bytes})> validateMove(
    String path,
    String target,
  ) async {
    if (target.trim().isEmpty) {
      throw const AgentWorkspaceException('move 需要 target');
    }
    final fs = await _fsInstance();
    final source = await fs.resolve(path);
    if (!source.exists) {
      throw const AgentWorkspaceException('源文件不存在');
    }
    final targetResolved = await fs.resolve(target, forWrite: true);
    if (source.relative == targetResolved.relative) {
      throw const AgentWorkspaceException('源和目标相同');
    }
    if (targetResolved.exists) {
      throw const AgentWorkspaceException('目标已存在');
    }
    final bytes = source.type == WorkspaceNodeType.file
        ? (await fs.stat(source.relative)).bytes
        : 0;
    return (
      source: source.relative,
      target: targetResolved.relative,
      bytes: bytes,
    );
  }

  Future<({int oldBytes, int newBytes, int matches, String newContent})>
      validateEdit({
    required String path,
    required String oldText,
    required String newText,
    bool replaceAll = false,
  }) async {
    if (oldText.isEmpty) {
      throw const AgentWorkspaceException('oldText 不能为空');
    }
    final fs = await _fsInstance();
    final resolved = await fs.resolve(path);
    if (!resolved.exists || resolved.type != WorkspaceNodeType.file) {
      throw const AgentWorkspaceException('文件不存在');
    }
    final length = (await fs.stat(resolved.relative)).bytes;
    if (length > maxWriteBytes) {
      throw const AgentWorkspaceException('文件超过 512KB，暂不支持编辑');
    }
    final raw = await fs.readBytes(resolved.relative);
    if (raw.contains(0) || _looksBinary(raw)) {
      throw const AgentWorkspaceException('仅支持 UTF-8 文本文件');
    }
    final text = utf8.decode(raw, allowMalformed: false);
    final matches = oldText.allMatches(text).length;
    if (matches == 0) {
      throw const AgentWorkspaceException('未找到 oldText，请先 fileRead 确认内容');
    }
    if (matches > 1 && !replaceAll) {
      throw AgentWorkspaceException(
        'oldText 匹配到 $matches 处，请提供更精确的 oldText 或 replaceAll=true',
      );
    }
    final newContent = replaceAll
        ? text.replaceAll(oldText, newText)
        : text.replaceFirst(oldText, newText);
    final newBytes = utf8.encode(newContent).length;
    if (newBytes > maxWriteBytes) {
      throw const AgentWorkspaceException('修改后文件超过 512KB 限制');
    }
    if (fs.enforceWorkspaceQuota) {
      final stats = await fs.stats();
      if (stats.bytes - length + newBytes > maxTotalBytes) {
        throw const AgentWorkspaceException('工作区容量已达上限（5MB）');
      }
    }
    return (
      oldBytes: length,
      newBytes: newBytes,
      matches: matches,
      newContent: newContent,
    );
  }

  Future<AgentWorkspaceApproval> createApproval({
    required String action,
    required String path,
    String content = '',
    String? target,
    String oldText = '',
    String newText = '',
    bool replaceAll = false,
  }) async {
    String normalizedPath;
    String? normalizedTarget;
    var bytes = 0;
    var hashContent = content;
    final fs = await _fsInstance();

    switch (action) {
      case 'write':
      case 'create':
        bytes = await validateWrite(action: action, path: path, content: content);
        normalizedPath = (await fs.resolve(path, forWrite: true)).relative;
      case 'delete':
        final result = await validateDelete(path);
        bytes = result.bytes;
        normalizedPath = result.relative;
      case 'move':
        final result = await validateMove(path, target ?? '');
        bytes = result.bytes;
        normalizedPath = result.source;
        normalizedTarget = result.target;
      case 'edit':
        final result = await validateEdit(
          path: path,
          oldText: oldText,
          newText: newText,
          replaceAll: replaceAll,
        );
        bytes = result.newBytes;
        normalizedPath = (await fs.resolve(path, forWrite: true)).relative;
        hashContent = _editApprovalPayload(oldText, newText, replaceAll);
      default:
        throw const AgentWorkspaceException('不支持的审批动作');
    }

    _cleanupApprovals();
    final id = _newApprovalId();
    final approval = _PendingApproval(
      action: action,
      path: normalizedPath,
      target: normalizedTarget,
      contentHash: _contentHash(
        action,
        normalizedPath,
        hashContent,
        normalizedTarget,
      ),
      bytes: bytes,
      expiresAt: DateTime.now().add(approvalTtl),
    );
    _approvals[id] = approval;
    while (_approvals.length > maxApprovals) {
      _approvals.remove(_approvals.keys.first);
    }
    return AgentWorkspaceApproval(
      id: id,
      action: approval.action,
      path: approval.path,
      bytes: approval.bytes,
      expiresAt: approval.expiresAt,
    );
  }

  Future<AgentWorkspaceWriteResult> write({
    required String approvalId,
    required String path,
    required String content,
  }) async {
    final approval = _approvals[approvalId];
    if (approval == null || approval.expiresAt.isBefore(DateTime.now())) {
      _approvals.remove(approvalId);
      throw const AgentWorkspaceException('审批已失效，请重新调用 fileApprove');
    }
    if (approval.action != 'write' && approval.action != 'create') {
      throw const AgentWorkspaceException('审批动作不是写入');
    }
    final fs = await _fsInstance();
    final resolved = await fs.resolve(path, forWrite: true);
    if (approval.path != resolved.relative ||
        approval.target != null ||
        approval.contentHash !=
            _contentHash(approval.action, resolved.relative, content, null)) {
      throw const AgentWorkspaceException('写入内容与审批不一致，请重新审批');
    }
    if (approval.action == 'create' && resolved.exists) {
      throw const AgentWorkspaceException('文件已存在，请使用 write 覆盖');
    }

    final bytes = utf8.encode(content);
    // 审批后再次校验配额，避免期间其它写入把工作区撑满。
    if (fs.enforceWorkspaceQuota) {
      final stats = await fs.stats();
      final existingBytes =
          resolved.exists ? (await fs.stat(resolved.relative)).bytes : 0;
      if (stats.bytes - existingBytes + bytes.length > maxTotalBytes) {
        throw const AgentWorkspaceException('工作区容量已达上限（5MB）');
      }
    }
    try {
      await fs.writeBytes(
        resolved.relative,
        bytes,
        create: approval.action == 'create',
      );
    } catch (error) {
      await _audit(
        action: approval.action,
        path: resolved.relative,
        bytes: bytes.length,
        ok: false,
        message: '$error',
      );
      throw AgentWorkspaceException('写入失败：$error');
    }

    _approvals.remove(approvalId);
    await _audit(
      action: approval.action,
      path: resolved.relative,
      bytes: bytes.length,
      ok: true,
    );
    return AgentWorkspaceWriteResult(path: resolved.relative, bytes: bytes.length);
  }

  /// 精确文本替换（需要 approvalId，供 fileEdit 工具使用）。
  Future<AgentWorkspaceWriteResult> editWithApproval({
    required String approvalId,
    required String path,
    required String oldText,
    required String newText,
    bool replaceAll = false,
  }) async {
    final fs = await _fsInstance();
    final resolved = await fs.resolve(path, forWrite: true);
    final payload = _editApprovalPayload(oldText, newText, replaceAll);
    _requireApproval(
      approvalId,
      action: 'edit',
      path: resolved.relative,
      content: payload,
      target: null,
    );
    final result = await validateEdit(
      path: resolved.relative,
      oldText: oldText,
      newText: newText,
      replaceAll: replaceAll,
    );
    final bytes = utf8.encode(result.newContent);
    await fs.writeBytes(resolved.relative, bytes);
    _approvals.remove(approvalId);
    await _audit(
      action: 'edit',
      path: resolved.relative,
      bytes: bytes.length,
      ok: true,
      message: 'matches=${result.matches} replaceAll=$replaceAll',
    );
    return AgentWorkspaceWriteResult(
      path: resolved.relative,
      bytes: bytes.length,
    );
  }

  /// 删除（需要 approvalId，供 fileDelete 工具使用）。
  Future<void> deleteWithApproval({
    required String approvalId,
    required String path,
  }) async {
    final fs = await _fsInstance();
    final resolved = await fs.resolve(path, forWrite: true);
    _requireApproval(
      approvalId,
      action: 'delete',
      path: resolved.relative,
      target: null,
    );
    await deleteFile(resolved.relative);
    _approvals.remove(approvalId);
  }

  /// 移动/重命名（需要 approvalId，供 fileMove 工具使用）。
  Future<void> moveWithApproval({
    required String approvalId,
    required String path,
    required String target,
  }) async {
    final fs = await _fsInstance();
    final source = await fs.resolve(path, forWrite: true);
    final targetResolved = await fs.resolve(target, forWrite: true);
    _requireApproval(
      approvalId,
      action: 'move',
      path: source.relative,
      target: targetResolved.relative,
    );
    await moveFile(source.relative, targetResolved.relative);
    _approvals.remove(approvalId);
  }

  /// 直接删除文件/空目录（工作区页面手动操作，不经 AI）。
  Future<void> deleteFile(String path) async {
    final result = await validateDelete(path);
    final fs = await _fsInstance();
    await fs.delete(result.relative);
    await _audit(
      action: 'delete',
      path: result.relative,
      bytes: result.bytes,
      ok: true,
    );
  }

  /// 直接移动/重命名（工作区页面手动操作，不经 AI）。
  Future<void> moveFile(String path, String target) async {
    final result = await validateMove(path, target);
    final fs = await _fsInstance();
    await fs.move(result.source, result.target);
    await _audit(
      action: 'move',
      path: result.target,
      bytes: result.bytes,
      ok: true,
      message: 'from ${result.source}',
    );
  }

  /// 直接写入文本（工作区页面手动编辑，不经 AI 审批）。
  ///
  /// 仍复用 [validateWrite] 的配额/大小/路径校验，并写入审计日志。
  Future<AgentWorkspaceWriteResult> writeTextDirect({
    required String path,
    required String content,
  }) async {
    await validateWrite(action: 'write', path: path, content: content);
    final fs = await _fsInstance();
    final resolved = await fs.resolve(path, forWrite: true);
    final bytes = utf8.encode(content);
    try {
      await fs.writeBytes(
        resolved.relative,
        bytes,
        create: !resolved.exists,
      );
    } catch (error) {
      await _audit(
        action: 'write',
        path: resolved.relative,
        bytes: bytes.length,
        ok: false,
        message: '$error',
      );
      throw AgentWorkspaceException('写入失败：$error');
    }
    await _audit(
      action: 'write',
      path: resolved.relative,
      bytes: bytes.length,
      ok: true,
      message: 'manual editor',
    );
    return AgentWorkspaceWriteResult(
      path: resolved.relative,
      bytes: bytes.length,
    );
  }

  /// 创建工作区目录（低风险，无需审批）。
  Future<void> mkdir(String path) async {
    if (path.trim().isEmpty) {
      throw const AgentWorkspaceException('mkdir 需要 path');
    }
    final fs = await _fsInstance();
    await fs.mkdir(path);
    final resolved = await fs.resolve(path);
    await _audit(
      action: 'mkdir',
      path: resolved.relative,
      bytes: 0,
      ok: true,
    );
  }

  /// 从外部文件导入到工作区（工作区页面 SAF 导入，用户主动选择）。
  Future<AgentWorkspaceWriteResult> importFile(
    String sourcePath, {
    String? asPath,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const AgentWorkspaceException('来源文件不存在');
    }
    final bytes = await source.readAsBytes();
    if (bytes.length > maxWriteBytes) {
      throw const AgentWorkspaceException('文件超过 512KB 限制');
    }
    final relative = asPath?.trim().isNotEmpty == true
        ? asPath!
        : p.basename(sourcePath);
    final fs = await _fsInstance();
    final resolved = await fs.resolve(relative, forWrite: true);
    if (resolved.exists) {
      throw const AgentWorkspaceException('目标已存在');
    }
    if (fs.enforceWorkspaceQuota) {
      final stats = await fs.stats();
      if (stats.files + 1 > maxFiles) {
        throw const AgentWorkspaceException('工作区文件数量已达上限');
      }
      if (stats.bytes + bytes.length > maxTotalBytes) {
        throw const AgentWorkspaceException('工作区容量已达上限（5MB）');
      }
    }
    try {
      await fs.writeBytes(resolved.relative, bytes, create: true);
    } catch (error) {
      throw AgentWorkspaceException('导入失败：$error');
    }
    await _audit(
      action: 'import',
      path: resolved.relative,
      bytes: bytes.length,
      ok: true,
    );
    return AgentWorkspaceWriteResult(path: resolved.relative, bytes: bytes.length);
  }

  /// 导出工作区文件字节（工作区页面 SAF 导出，用户主动选择）。
  Future<List<int>> exportBytes(String path) async {
    final fs = await _fsInstance();
    return fs.readBytes(path);
  }

  _PendingApproval _requireApproval(
    String id, {
    required String action,
    required String path,
    String content = '',
    String? target,
  }) {
    final approval = _approvals[id];
    if (approval == null || approval.expiresAt.isBefore(DateTime.now())) {
      _approvals.remove(id);
      throw const AgentWorkspaceException('审批已失效，请重新调用 fileApprove');
    }
    if (approval.action != action ||
        approval.path != path ||
        approval.target != target ||
        approval.contentHash != _contentHash(action, path, content, target)) {
      throw const AgentWorkspaceException('操作与审批不一致，请重新审批');
    }
    return approval;
  }

  Future<AgentWorkspaceStats> stats() async {
    final fs = await _fsInstance();
    return fs.stats();
  }

  Future<void> clear() async {
    final fs = await _fsInstance();
    await fs.clear();
    _approvals.clear();
    await _audit(action: 'clear', path: '.', bytes: 0, ok: true);
  }

  /// Recent audit entries for one workspace (defaults to the current one).
  ///
  /// Entries written before multi-workspace support carry no workspace id and
  /// are attributed to [defaultWorkspaceId]; they are deliberately hidden while
  /// another workspace is selected so the page never mixes histories.
  Future<List<AgentWorkspaceAuditEntry>> audit({
    int limit = 20,
    String? workspaceId,
  }) async {
    final target = workspaceId ?? _workspaceId;
    try {
      final file =
          File(p.join((await _supportDir()).path, 'agent_file_audit.jsonl'));
      if (!await file.exists()) return const [];
      final lines = await file.readAsLines();
      final out = <AgentWorkspaceAuditEntry>[];
      for (var i = lines.length - 1; i >= 0 && out.length < limit; i--) {
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        try {
          final entry = AgentWorkspaceAuditEntry.fromJson(
            Map<String, dynamic>.from(jsonDecode(line) as Map),
          );
          final entryWorkspace = entry.workspaceId.isEmpty
              ? defaultWorkspaceId
              : entry.workspaceId;
          if (entryWorkspace == target) out.add(entry);
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _audit({
    required String action,
    required String path,
    required int bytes,
    required bool ok,
    String? message,
  }) async {
    try {
      final dir = await _supportDir();
      final file = File(p.join(dir.path, 'agent_file_audit.jsonl'));
      await file.parent.create(recursive: true);
      final line = jsonEncode(AgentWorkspaceAuditEntry(
        time: DateTime.now(),
        action: action,
        path: path,
        bytes: bytes,
        ok: ok,
        message: message,
        workspaceId: _workspaceId,
      ).toJson());
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
      if (await file.length() > 256 * 1024) {
        final lines = await file.readAsLines();
        await file.writeAsString(
          '${lines.skip(max(0, lines.length - 100)).join('\n')}\n',
          flush: true,
        );
      }
    } catch (_) {
      // 审计失败不影响文件操作
    }
  }

  void _cleanupApprovals() {
    final now = DateTime.now();
    _approvals.removeWhere((_, value) => value.expiresAt.isBefore(now));
  }

  String _newApprovalId() {
    final random = Random.secure();
    final suffix = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'appr-${DateTime.now().microsecondsSinceEpoch}-$suffix';
  }

  String _editApprovalPayload(
    String oldText,
    String newText,
    bool replaceAll,
  ) =>
      '${replaceAll ? 1 : 0}\n$oldText\n$newText';

  bool _looksBinary(List<int> bytes) {
    if (bytes.isEmpty) return false;
    var control = 0;
    for (final b in bytes) {
      if (b == 9 || b == 10 || b == 13) continue;
      if (b < 32) control++;
    }
    return control > bytes.length * 0.1;
  }

  String _contentHash(
    String action,
    String path,
    String content,
    String? target,
  ) {
    return sha256
        .convert(utf8.encode('$action\n$path\n${target ?? ''}\n$content'))
        .toString();
  }

  /// 测试接缝：清理过期审批。
  void debugCleanupApprovals() => _cleanupApprovals();

  /// 测试接缝：当前有效审批数量。
  int get debugApprovalCount => _approvals.length;
}

class AgentWorkspaceWriteResult {
  const AgentWorkspaceWriteResult({required this.path, required this.bytes});

  final String path;
  final int bytes;
}

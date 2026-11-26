import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace_fs.dart';

/// 应用私有目录实现：真实路径 + 路径沙箱 + 原子写。
class InternalWorkspaceFs implements WorkspaceFs {
  InternalWorkspaceFs(Directory root) : _root = root;

  final Directory _root;
  String? _rootPathCache;

  @override
  bool get enforceWorkspaceQuota => true;

  @override
  bool get isExternal => false;

  Future<String> _rootPath() async {
    final cached = _rootPathCache;
    if (cached != null) return cached;
    await _root.create(recursive: true);
    final resolved = await _root.resolveSymbolicLinks();
    _rootPathCache = resolved;
    return resolved;
  }

  @override
  Future<String> get rootPath => _rootPath();

  Future<WorkspaceResolved> _resolve(
    String raw, {
    bool allowRoot = false,
    bool forWrite = false,
  }) async {
    final root = await _rootPath();
    final trimmed = raw.trim().replaceAll('\\', '/');
    if (trimmed.contains('\u0000')) {
      throw const AgentWorkspaceException('路径包含非法字符');
    }
    if (trimmed.isEmpty) {
      if (!allowRoot) throw const AgentWorkspaceException('路径不能为空');
      return const WorkspaceResolved(
        relative: '.',
        type: WorkspaceNodeType.directory,
        exists: true,
      );
    }
    if (p.isAbsolute(trimmed)) {
      throw const AgentWorkspaceException('只允许工作区相对路径');
    }
    final normalized = p.normalize(trimmed);
    if (normalized == '..' || normalized.startsWith('../')) {
      throw const AgentWorkspaceException('路径不能跳出工作区');
    }
    if (!allowRoot && (normalized == '.' || normalized.isEmpty)) {
      throw const AgentWorkspaceException('路径不能为空');
    }

    var full = p.join(root, normalized);
    if (!p.isWithin(root, full) && full != root) {
      throw const AgentWorkspaceException('路径不能跳出工作区');
    }
    if (full == root) {
      if (!allowRoot) throw const AgentWorkspaceException('路径不能是工作区根目录');
      return const WorkspaceResolved(
        relative: '.',
        type: WorkspaceNodeType.directory,
        exists: true,
      );
    }

    if (await FileSystemEntity.isLink(full)) {
      throw const AgentWorkspaceException('不允许访问符号链接');
    }

    if (forWrite) {
      // 目标可能不存在：从最近存在的父目录开始解析，防止 symlink 绕过。
      var probe = Directory(p.dirname(full));
      while (!await probe.exists()) {
        final parent = probe.parent;
        if (parent.path == probe.path) break;
        probe = parent;
      }
      final resolvedParent = await probe.resolveSymbolicLinks();
      if (!p.isWithin(root, resolvedParent) && resolvedParent != root) {
        throw const AgentWorkspaceException('目标目录不在工作区内');
      }
      full = p.join(resolvedParent, p.relative(full, from: probe.path));
    } else {
      final type = await FileSystemEntity.type(full, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        final resolved = type == FileSystemEntityType.directory
            ? await Directory(full).resolveSymbolicLinks()
            : await File(full).resolveSymbolicLinks();
        if (!p.isWithin(root, resolved) && resolved != root) {
          throw const AgentWorkspaceException('路径不在工作区内');
        }
        full = resolved;
      }
    }

    final relative = p.relative(full, from: root).replaceAll('\\', '/');
    if (relative == '..' || relative.startsWith('../')) {
      throw const AgentWorkspaceException('路径不能跳出工作区');
    }
    final type = await FileSystemEntity.type(full, followLinks: false);
    return WorkspaceResolved(
      relative: relative,
      type: _nodeType(type),
      exists: type != FileSystemEntityType.notFound,
    );
  }

  WorkspaceNodeType _nodeType(FileSystemEntityType type) {
    switch (type) {
      case FileSystemEntityType.file:
        return WorkspaceNodeType.file;
      case FileSystemEntityType.directory:
        return WorkspaceNodeType.directory;
      default:
        return WorkspaceNodeType.other;
    }
  }

  @override
  Future<WorkspaceResolved> resolve(String path, {bool forWrite = false}) =>
      _resolve(path, forWrite: forWrite);

  @override
  Future<WorkspaceStat> stat(String path) async {
    final resolved = await _resolve(path);
    final type = await FileSystemEntity.type(
      (await _fullPath(resolved.relative)),
      followLinks: false,
    );
    final full = await _fullPath(resolved.relative);
    final entityStat = await FileSystemEntity.type(full, followLinks: false) ==
            FileSystemEntityType.notFound
        ? null
        : await (type == FileSystemEntityType.directory
            ? Directory(full).stat()
            : File(full).stat());
    return WorkspaceStat(
      relative: resolved.relative,
      type: _nodeType(type),
      bytes: type == FileSystemEntityType.file
          ? await File(full).length()
          : 0,
      modifiedAt: entityStat?.modified ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  Future<String> _fullPath(String relative) async {
    final root = await _rootPath();
    return relative == '.' ? root : p.join(root, relative);
  }

  @override
  Future<List<AgentWorkspaceEntry>> list(
    String path, {
    bool recursive = false,
    int limit = 500,
  }) async {
    final resolved = await _resolve(path, allowRoot: true);
    final root = await _rootPath();
    final directory = Directory(resolved.relative == '.'
        ? root
        : p.join(root, resolved.relative));
    if (!await directory.exists()) {
      throw const AgentWorkspaceException('目录不存在');
    }
    final entries = <AgentWorkspaceEntry>[];
    await for (final entity in directory.list(
      followLinks: false,
      recursive: recursive,
    )) {
      if (entries.length >= limit) break;
      if (entity is Link) continue;
      final stat = await entity.stat();
      final relative = p.relative(entity.path, from: root).replaceAll('\\', '/');
      entries.add(AgentWorkspaceEntry(
        path: relative,
        isDirectory: entity is Directory,
        bytes: entity is File ? stat.size : 0,
        modifiedAt: stat.modified,
      ));
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });
    return entries;
  }

  @override
  Future<AgentWorkspaceReadResult> read(
    String path, {
    int maxBytes = WorkspaceLimits.maxReadBytes,
  }) async {
    final resolved = await _resolve(path);
    final full = await _fullPath(resolved.relative);
    final file = File(full);
    if (!await file.exists()) {
      throw const AgentWorkspaceException('文件不存在');
    }
    final length = await file.length();
    final limit = length > maxBytes ? maxBytes : length;
    final raf = await file.open();
    List<int> bytes;
    try {
      bytes = await raf.read(limit);
    } finally {
      await raf.close();
    }
    final truncated = length > limit;
    final binary = bytes.contains(0) || _looksBinary(bytes);
    String? text;
    if (!binary) {
      try {
        text = utf8.decode(bytes, allowMalformed: truncated);
      } catch (_) {
        text = null;
      }
    }
    return AgentWorkspaceReadResult(
      path: resolved.relative,
      bytes: length,
      truncated: truncated,
      binary: binary || text == null,
      text: text,
    );
  }

  @override
  Future<List<int>> readBytes(String path) async {
    final resolved = await _resolve(path);
    final file = File(await _fullPath(resolved.relative));
    if (!await file.exists()) {
      throw const AgentWorkspaceException('文件不存在');
    }
    return file.readAsBytes();
  }

  @override
  Future<void> writeBytes(
    String path,
    List<int> bytes, {
    bool create = false,
  }) async {
    final resolved = await _resolve(path, forWrite: true);
    final parent = Directory(p.dirname(await _fullPath(resolved.relative)));
    await parent.create(recursive: true);
    // 二次校验父目录真实路径，防止审批后目录被替换成 symlink。
    final root = await _rootPath();
    final parentResolved = await parent.resolveSymbolicLinks();
    if (!p.isWithin(root, parentResolved) && parentResolved != root) {
      throw const AgentWorkspaceException('目标目录不在工作区内');
    }
    final target = File(p.join(parentResolved, p.basename(resolved.relative)));
    if (create &&
        await FileSystemEntity.type(target.path, followLinks: false) ==
            FileSystemEntityType.file) {
      throw const AgentWorkspaceException('文件已存在，请使用 write 覆盖');
    }
    final tmp = File('${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> delete(String path) async {
    final resolved = await _resolve(path);
    final full = await _fullPath(resolved.relative);
    final type = await FileSystemEntity.type(full, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(full).delete(recursive: false);
    } else if (type == FileSystemEntityType.file) {
      await File(full).delete();
    } else {
      throw const AgentWorkspaceException('文件或目录不存在');
    }
  }

  @override
  Future<void> move(String source, String target) async {
    final src = await _resolve(source);
    final dst = await _resolve(target, forWrite: true);
    final srcFull = await _fullPath(src.relative);
    final dstFull = await _fullPath(dst.relative);
    if (await FileSystemEntity.type(dstFull, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const AgentWorkspaceException('目标已存在');
    }
    await Directory(p.dirname(dstFull)).create(recursive: true);
    final type = await FileSystemEntity.type(srcFull, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(srcFull).rename(dstFull);
    } else if (type == FileSystemEntityType.file) {
      await File(srcFull).rename(dstFull);
    } else {
      throw const AgentWorkspaceException('源文件不存在');
    }
  }

  @override
  Future<void> mkdir(String path) async {
    if (path.trim().isEmpty) {
      throw const AgentWorkspaceException('mkdir 需要 path');
    }
    final resolved = await _resolve(path, forWrite: true);
    final full = await _fullPath(resolved.relative);
    final type = await FileSystemEntity.type(full, followLinks: false);
    if (type == FileSystemEntityType.directory) return;
    if (type != FileSystemEntityType.notFound) {
      throw const AgentWorkspaceException('同名文件已存在');
    }
    await Directory(full).create(recursive: true);
  }

  @override
  Future<AgentWorkspaceStats> stats() async {
    final root = await _rootPath();
    var files = 0;
    var bytes = 0;
    await for (final entity
        in Directory(root).list(recursive: true, followLinks: false)) {
      if (entity is Link) continue;
      if (entity is File) {
        files++;
        bytes += await entity.length();
      }
    }
    return AgentWorkspaceStats(
      files: files,
      bytes: bytes,
      maxFiles: WorkspaceLimits.maxFiles,
      maxBytes: WorkspaceLimits.maxTotalBytes,
    );
  }

  @override
  Future<void> clear() async {
    final root = await _rootPath();
    final dir = Directory(root);
    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is Link) {
          await entity.delete();
        } else {
          await entity.delete(recursive: true);
        }
      }
    }
  }

  @override
  Future<String?> localPathFor(String relative) async {
    final resolved = await _resolve(relative);
    return _fullPath(resolved.relative);
  }

  bool _looksBinary(List<int> bytes) {
    if (bytes.isEmpty) return false;
    var control = 0;
    for (final b in bytes) {
      if (b == 9 || b == 10 || b == 13) continue;
      if (b < 32) control++;
    }
    return control > bytes.length * 0.1;
  }
}

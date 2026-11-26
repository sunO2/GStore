import 'dart:convert';

import 'package:flutter/services.dart';

import 'workspace_fs.dart';

/// Android SAF（`content://` 目录树）工作区后端。
///
/// 文件操作全部经 MethodChannel 转到 Android `ContentResolver` /
/// `DocumentsContract`；不把 content URI 当普通路径。
class SafWorkspaceFs implements WorkspaceFs {
  SafWorkspaceFs(this.treeUri);

  static const MethodChannel _channel =
      MethodChannel('gstore/saf_workspace');

  final String treeUri;

  @override
  bool get enforceWorkspaceQuota => false;

  @override
  bool get isExternal => true;

  @override
  Future<String> get rootPath async => treeUri;

  /// 打开系统目录选择器并持久化读写权限；取消返回 null。
  static Future<({String uri, String name})?> pickDirectory() async {
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'pickDirectory',
    );
    if (raw == null) return null;
    final uri = raw['uri']?.toString() ?? '';
    if (uri.isEmpty) return null;
    return (uri: uri, name: raw['name']?.toString() ?? '外部目录');
  }

  static Future<bool> hasPermission(String treeUri) async {
    return await _channel.invokeMethod<bool>(
          'hasPermission',
          {'uri': treeUri},
        ) ??
        false;
  }

  @override
  Future<WorkspaceResolved> resolve(
    String path, {
    bool forWrite = false,
  }) async {
    final raw = await _invokeMap('resolve', {
      'uri': treeUri,
      'path': path,
      'forWrite': forWrite,
    });
    return WorkspaceResolved(
      relative: raw['relative']?.toString() ?? path,
      type: _type(raw['type']?.toString()),
      exists: raw['exists'] == true,
    );
  }

  @override
  Future<WorkspaceStat> stat(String path) async {
    final raw = await _invokeMap('stat', {'uri': treeUri, 'path': path});
    return WorkspaceStat(
      relative: raw['relative']?.toString() ?? path,
      type: _type(raw['type']?.toString()),
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        (raw['modifiedAt'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  @override
  Future<List<AgentWorkspaceEntry>> list(
    String path, {
    bool recursive = false,
    int limit = 500,
  }) async {
    final raw = await _channel.invokeListMethod<dynamic>(
      'list',
      {
        'uri': treeUri,
        'path': path,
        'recursive': recursive,
        'limit': limit,
      },
    );
    return [
      for (final item in raw ?? const [])
        if (item is Map)
          AgentWorkspaceEntry(
            path: item['path']?.toString() ?? '',
            isDirectory: item['type']?.toString() == 'directory',
            bytes: (item['bytes'] as num?)?.toInt() ?? 0,
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(
              (item['modifiedAt'] as num?)?.toInt() ?? 0,
            ),
          ),
    ];
  }

  @override
  Future<AgentWorkspaceReadResult> read(
    String path, {
    int maxBytes = WorkspaceLimits.maxReadBytes,
  }) async {
    final raw = await _invokeMap('read', {
      'uri': treeUri,
      'path': path,
      'maxBytes': maxBytes,
    });
    final bytes = _bytes(raw['bytes']);
    final binary = bytes.contains(0);
    String? text;
    if (!binary) {
      try {
        text = utf8.decode(
          bytes,
          allowMalformed: raw['truncated'] == true,
        );
      } catch (_) {
        text = null;
      }
    }
    return AgentWorkspaceReadResult(
      path: raw['path']?.toString() ?? path,
      bytes: (raw['size'] as num?)?.toInt() ?? bytes.length,
      truncated: raw['truncated'] == true,
      binary: binary || text == null,
      text: text,
    );
  }

  @override
  Future<List<int>> readBytes(String path) async {
    final bytes = await _channel.invokeMethod<Uint8List>(
      'readBytes',
      {'uri': treeUri, 'path': path},
    );
    return bytes ?? const [];
  }

  @override
  Future<void> writeBytes(
    String path,
    List<int> bytes, {
    bool create = false,
  }) async {
    await _channel.invokeMethod<void>('writeBytes', {
      'uri': treeUri,
      'path': path,
      'bytes': Uint8List.fromList(bytes),
      'create': create,
    });
  }

  @override
  Future<void> delete(String path) async {
    await _channel.invokeMethod<void>(
      'delete',
      {'uri': treeUri, 'path': path},
    );
  }

  @override
  Future<void> move(String source, String target) async {
    await _channel.invokeMethod<void>('move', {
      'uri': treeUri,
      'source': source,
      'target': target,
    });
  }

  @override
  Future<void> mkdir(String path) async {
    await _channel.invokeMethod<void>(
      'mkdir',
      {'uri': treeUri, 'path': path},
    );
  }

  @override
  Future<AgentWorkspaceStats> stats() async {
    final raw = await _invokeMap('stats', {'uri': treeUri});
    return AgentWorkspaceStats(
      files: (raw['files'] as num?)?.toInt() ?? 0,
      bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
      maxFiles: WorkspaceLimits.maxFiles,
      maxBytes: WorkspaceLimits.maxTotalBytes,
    );
  }

  @override
  Future<void> clear() async {
    await _channel.invokeMethod<void>('clear', {'uri': treeUri});
  }

  @override
  Future<String?> localPathFor(String relative) async => null;

  Future<Map<String, dynamic>> _invokeMap(
    String method,
    Map<String, dynamic> args,
  ) async {
    final map = await _channel.invokeMapMethod<String, dynamic>(method, args);
    if (map == null) {
      throw const AgentWorkspaceException('SAF 返回空结果');
    }
    return map;
  }

  List<int> _bytes(Object? raw) {
    if (raw is Uint8List) return raw;
    if (raw is List) return raw.cast<int>();
    return const [];
  }

  WorkspaceNodeType _type(String? type) {
    switch (type) {
      case 'file':
        return WorkspaceNodeType.file;
      case 'directory':
        return WorkspaceNodeType.directory;
      default:
        return WorkspaceNodeType.other;
    }
  }
}

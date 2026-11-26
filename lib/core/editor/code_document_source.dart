import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:gstore/core/agent/agent_workspace_service.dart';

/// 文本文件加载失败（可直接展示给用户）。
class CodeDocumentException implements Exception {
  const CodeDocumentException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 已加载的文本文档。
class CodeDocument {
  const CodeDocument({
    required this.title,
    required this.text,
    required this.bytes,
    required this.editable,
    this.filePath,
    this.truncated = false,
    this.save,
  });

  /// 页面标题（文件名/路径）。
  final String title;

  /// 用于推断语法高亮的路径。
  final String? filePath;

  /// 文本内容。
  final String text;

  /// 文件字节数（截断时为已读取字节数）。
  final int bytes;

  /// 是否因超过预览上限被截断。
  final bool truncated;

  /// 是否允许编辑；截断/二进制/非法 UTF-8/只读来源为 false。
  final bool editable;

  /// 保存回调；null 表示只读（或由页面返回编辑结果）。
  final Future<void> Function(String text)? save;
}

/// 文本来源：内存文本、本地文件、URI、AI 工作区文件。
abstract class CodeDocumentSource {
  const CodeDocumentSource();

  factory CodeDocumentSource.text(
    String text, {
    String? title,
    String? filePath,
  }) = _TextSource;

  factory CodeDocumentSource.file(
    File file, {
    String? title,
  }) = _FileSource;

  factory CodeDocumentSource.filePath(
    String path, {
    String? title,
  }) = _FileSource.path;

  factory CodeDocumentSource.uri(
    Uri uri, {
    String? title,
  }) = _UriSource;

  factory CodeDocumentSource.workspace(
    AgentWorkspaceService service,
    String path,
  ) = _WorkspaceSource;

  String get title;

  String? get filePath;

  Future<CodeDocument> load({int maxBytes = 256 * 1024});
}

class _TextSource extends CodeDocumentSource {
  _TextSource(
    this._text, {
    String? title,
    String? filePath,
  })  : _title = title,
        _filePath = filePath;

  final String _text;
  final String? _title;
  final String? _filePath;

  @override
  String get title => _title ?? '文本';

  @override
  String? get filePath => _filePath;

  @override
  Future<CodeDocument> load({int maxBytes = 256 * 1024}) async {
    return CodeDocument(
      title: title,
      filePath: _filePath,
      text: _text,
      bytes: utf8.encode(_text).length,
      editable: true,
    );
  }
}

class _FileSource extends CodeDocumentSource {
  _FileSource(
    this._file, {
    String? title,
  }) : _title = title;

  _FileSource.path(
    String path, {
    String? title,
  })  : _file = File(path),
        _title = title;

  final File _file;
  final String? _title;

  @override
  String get title => _title ?? p.basename(_file.path);

  @override
  String? get filePath => _file.path;

  @override
  Future<CodeDocument> load({int maxBytes = 256 * 1024}) async {
    if (!await _file.exists()) {
      throw const CodeDocumentException('文件不存在');
    }
    final length = await _file.length();
    final truncated = length > maxBytes;
    final bytes = await _readFirstBytes(_file, truncated ? maxBytes : length);
    final decoded = _decode(bytes);
    final editable = !truncated && !decoded.malformed;

    return CodeDocument(
      title: title,
      filePath: _file.path,
      text: decoded.text,
      bytes: truncated ? bytes.length : length,
      truncated: truncated,
      editable: editable,
      save: editable
          ? (text) async {
              await _file.writeAsString(text, flush: true);
            }
          : null,
    );
  }
}

class _UriSource extends CodeDocumentSource {
  _UriSource(
    this._uri, {
    String? title,
  }) : _title = title;

  final Uri _uri;
  final String? _title;

  @override
  String get title {
    final custom = _title?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    final last = _uri.pathSegments.isEmpty ? '' : _uri.pathSegments.last;
    return last.isNotEmpty ? last : _uri.toString();
  }

  @override
  String? get filePath => switch (_uri.scheme) {
        '' || 'file' => _uri.path,
        _ => _uri.path.isEmpty ? null : _uri.path,
      };

  @override
  Future<CodeDocument> load({int maxBytes = 256 * 1024}) async {
    final scheme = _uri.scheme.toLowerCase();
    switch (scheme) {
      case '':
        return _FileSource(File(_uri.path), title: title)
            .load(maxBytes: maxBytes);
      case 'file':
        return _FileSource(File.fromUri(_uri), title: title)
            .load(maxBytes: maxBytes);
      case 'http':
      case 'https':
        final response = await http.get(_uri);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw CodeDocumentException('请求失败：HTTP ${response.statusCode}');
        }
        return _fromBytes(
          response.bodyBytes,
          maxBytes: maxBytes,
          editable: false,
          save: null,
        );
      case 'data':
        final data = _uri.data;
        if (data == null) {
          throw const CodeDocumentException('data URI 缺少内容');
        }
        return _fromBytes(
          data.contentAsBytes(),
          maxBytes: maxBytes,
          editable: false,
          save: null,
        );
      case 'content':
        throw const CodeDocumentException(
          '暂不支持 content:// URI，请通过文件工作区打开',
        );
      default:
        throw CodeDocumentException('不支持的 URI 协议：$scheme');
    }
  }

  CodeDocument _fromBytes(
    List<int> bytes, {
    required int maxBytes,
    required bool editable,
    required Future<void> Function(String text)? save,
  }) {
    final truncated = bytes.length > maxBytes;
    final visible = truncated ? bytes.sublist(0, maxBytes) : bytes;
    final decoded = _decode(visible);
    return CodeDocument(
      title: title,
      filePath: filePath,
      text: decoded.text,
      bytes: visible.length,
      truncated: truncated,
      editable: editable && !truncated && !decoded.malformed,
      save: save,
    );
  }
}

class _WorkspaceSource extends CodeDocumentSource {
  _WorkspaceSource(this._service, this._path);

  final AgentWorkspaceService _service;
  final String _path;

  @override
  String get title => _path;

  @override
  String? get filePath => _path;

  @override
  Future<CodeDocument> load({int maxBytes = 256 * 1024}) async {
    final result = await _service.read(_path);
    if (result.binary || result.text == null) {
      throw CodeDocumentException(
        '二进制文件（${_formatBytes(result.bytes)}），暂不支持文本预览',
      );
    }
    final editable = !result.truncated;
    return CodeDocument(
      title: _path,
      filePath: _path,
      text: result.text!,
      bytes: result.bytes,
      truncated: result.truncated,
      editable: editable,
      save: editable
          ? (text) async {
              await _service.writeTextDirect(path: _path, content: text);
            }
          : null,
    );
  }
}

Future<List<int>> _readFirstBytes(File file, int length) async {
  if (length <= 0) return const [];
  final raf = await file.open();
  try {
    return await raf.read(length);
  } finally {
    await raf.close();
  }
}

({String text, bool malformed}) _decode(List<int> bytes) {
  if (bytes.contains(0)) {
    throw const CodeDocumentException('二进制文件，暂不支持文本预览');
  }
  try {
    return (text: utf8.decode(bytes), malformed: false);
  } on FormatException {
    return (text: utf8.decode(bytes, allowMalformed: true), malformed: true);
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)}KB';
  }
  return '$bytes B';
}

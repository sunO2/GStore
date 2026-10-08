/// 「请求调试」请求体编码的 IO 辅助（薄层）。
///
/// 把纯编码器 [body_encoder.dart] 需要的**文件字节**在这里读入：仅此文件触碰
/// `dart:io`，纯编码器保持可测。读取失败（文件不存在 / 无权限）向上抛
/// [FileSystemException]，由编辑器归一化为用户可见错误。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'body_encoder.dart';
import 'debug_models.dart';

/// 读取本地文件为字节。
Future<List<int>> readBodyFile(String path) => File(path).readAsBytes();

/// 把结构化 multipart 字段解析为 [BodyPart] 列表（文件项读取字节）。
///
/// 跳过 `enabled == false` 或空名项；文件项文件名取 `fileName`，
/// 缺省取路径 basename。
Future<List<BodyPart>> resolveMultipartFields(
  List<DebugMultipartField> fields, {
  Future<List<int>> Function(String path) readFile = readBodyFile,
}) async {
  final parts = <BodyPart>[];
  for (final field in fields) {
    final name = field.name.trim();
    if (!field.enabled || name.isEmpty) continue;
    if (field.isFile) {
      final path = field.filePath!;
      final bytes = await readFile(path);
      parts.add(BodyPart(
        name: name,
        fileName: field.fileName ?? p.basename(path),
        contentType: field.contentType,
        fileBytes: bytes,
      ));
    } else {
      parts.add(BodyPart(
        name: name,
        value: field.value,
        contentType: field.contentType,
      ));
    }
  }
  return parts;
}

/// 解析 binary 输入为字节：`raw`/`hex`/`base64` 走纯解码；`file` 读取文件。
///
/// 非法 hex/base64 返回空列表（编辑器据此提示）；[DebugBinarySource.file] 但
/// 未提供路径时返回空列表。
Future<List<int>> resolveBinaryBytes(
  String text,
  DebugBinarySource source, {
  String? filePath,
  Future<List<int>> Function(String path) readFile = readBodyFile,
}) async {
  if (source == DebugBinarySource.file) {
    if (filePath == null || filePath.isEmpty) return const <int>[];
    return readFile(filePath);
  }
  return decodeBinaryText(text, source) ?? const <int>[];
}

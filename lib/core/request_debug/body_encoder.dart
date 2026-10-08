/// 「请求调试」请求体编码器（纯逻辑，无 IO / UI）。
///
/// 目标（plan todo 3）：让编辑器里选择的 `bodyKind` **真正决定线缆上的字节与
/// Content-Type**，而不是一律把 textarea 文本按 UTF-8 发出。
///
/// 设计：
/// - [encodeBody] 是唯一入口，给定 [BodyEncodeInput]（分类 + 已解析数据）返回
///   [BodyEncodeResult]（字节 + 建议 Content-Type）；
/// - **纯函数**：文件字节由调用方（IO 辅助 `body_encoder_io.dart`）预先读入后
///   放进 [BodyPart.fileBytes] / [BodyEncodeInput.binaryBytes]；
/// - hex / base64 / raw 的解码是纯的，见 [decodeBinaryText]；
/// - `json` / `text` 自动给出默认 Content-Type；`multipart` 生成 boundary；
///   无显式 Content-Type 时由编辑器补上（结果里的 `contentType` 仅"建议"）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'debug_models.dart';

/// multipart 的一个 part。
///
/// [fileName] 非空表示**文件 part**（此时 [fileBytes] 必须已由调用方读入）；
/// 否则为普通文本 part（[value]）。
class BodyPart {
  const BodyPart({
    required this.name,
    this.value = '',
    this.fileName,
    this.contentType,
    this.fileBytes,
  });

  final String name;
  final String value;

  /// 文件 part 的文件名（`null` = 文本 part）。
  final String? fileName;

  /// 可选的 part 级 Content-Type。
  final String? contentType;

  /// 文件 part 的字节（已解析）。
  final List<int>? fileBytes;

  bool get isFile => fileName != null;
}

/// 编码输入。
class BodyEncodeInput {
  const BodyEncodeInput({
    required this.kind,
    this.text = '',
    this.contentType,
    this.parts = const <BodyPart>[],
    this.binaryBytes,
    this.boundary,
  });

  /// 请求体类型。
  final DebugBodyKind kind;

  /// textarea 原始文本（json/text/form_urlencoded 直接使用）。
  final String text;

  /// 已显式存在的 Content-Type（仅用于信息；补头由调用方决定）。
  final String? contentType;

  /// multipart 的 part（文本 / 文件均已解析）。
  final List<BodyPart> parts;

  /// binary 的已解析字节。
  final List<int>? binaryBytes;

  /// 显式 boundary（测试确定性用；为 `null` 时自动生成）。
  final String? boundary;
}

/// 编码结果。
class BodyEncodeResult {
  const BodyEncodeResult({required this.bytes, this.contentType});

  /// 线缆字节。
  final List<int> bytes;

  /// 建议的 Content-Type（`null` = 不自动补）。
  final String? contentType;

  bool get hasBody => bytes.isNotEmpty;
}

int _boundarySeq = 0;

/// 生成一个 multipart boundary（尽量唯一）。
String generateMultipartBoundary() =>
    '----GStoreBoundary${DateTime.now().microsecondsSinceEpoch}${_boundarySeq++}';

/// 主入口：把 [input] 编码为线缆字节 + 建议 Content-Type（纯函数）。
BodyEncodeResult encodeBody(BodyEncodeInput input) {
  switch (input.kind) {
    case DebugBodyKind.none:
      return const BodyEncodeResult(bytes: <int>[]);
    case DebugBodyKind.json:
      return BodyEncodeResult(
        bytes: input.text.isEmpty ? const <int>[] : utf8.encode(input.text),
        contentType: 'application/json',
      );
    case DebugBodyKind.text:
      return BodyEncodeResult(
        bytes: input.text.isEmpty ? const <int>[] : utf8.encode(input.text),
        contentType: 'text/plain; charset=utf-8',
      );
    case DebugBodyKind.formUrlEncoded:
      final encoded = encodeFormUrlEncoded(input.text);
      return BodyEncodeResult(
        bytes: encoded.isEmpty ? const <int>[] : utf8.encode(encoded),
        contentType: 'application/x-www-form-urlencoded',
      );
    case DebugBodyKind.multipart:
      final boundary = input.boundary ?? generateMultipartBoundary();
      return BodyEncodeResult(
        bytes: _encodeMultipart(input.parts, boundary),
        contentType: 'multipart/form-data; boundary=$boundary',
      );
    case DebugBodyKind.binary:
      return BodyEncodeResult(bytes: input.binaryBytes ?? const <int>[]);
  }
}

/// 把 `a=1&b=2` 形式的文本重新 URL 编码（`application/x-www-form-urlencoded`）。
///
/// 每个 `name` / `value` 用 [Uri.encodeQueryComponent]（空格→`+`，`+`→`%2B`，
/// 非 ASCII 按 UTF-8 百分号编码）；无 `=` 的片段视为空值字段。
String encodeFormUrlEncoded(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  final pairs = <String>[];
  for (final rawPair in trimmed.split('&')) {
    if (rawPair.isEmpty) continue;
    final eq = rawPair.indexOf('=');
    final name = eq < 0 ? rawPair : rawPair.substring(0, eq);
    final value = eq < 0 ? '' : rawPair.substring(eq + 1);
    pairs.add(
      '${Uri.encodeQueryComponent(name)}=${Uri.encodeQueryComponent(value)}',
    );
  }
  return pairs.join('&');
}

/// 从 textarea 文本解析 multipart **文本** part（每行 `name=value`）。
///
/// 文件 part 由结构化模型 [DebugMultipartField] + IO 辅助提供。
List<BodyPart> parseMultipartText(String text) {
  final parts = <BodyPart>[];
  for (final line in const LineSplitter().convert(text)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final eq = trimmed.indexOf('=');
    final name = eq < 0 ? trimmed : trimmed.substring(0, eq);
    final value = eq < 0 ? '' : trimmed.substring(eq + 1);
    if (name.isEmpty) continue;
    parts.add(BodyPart(name: name, value: value));
  }
  return parts;
}

/// 解码 binary 的文本输入为字节（纯）。
///
/// [DebugBinarySource.file] 不在此处理（IO 由 `body_encoder_io.dart` 负责），
/// 返回 `null`。hex/base64 非法时返回 `null`（调用方据此提示错误）。
List<int>? decodeBinaryText(String text, DebugBinarySource source) {
  switch (source) {
    case DebugBinarySource.raw:
      return utf8.encode(text);
    case DebugBinarySource.hex:
      final cleaned = text.replaceAll(RegExp(r'[\s:,\-]'), '');
      if (cleaned.isEmpty) return const <int>[];
      if (cleaned.length.isOdd) return null;
      final out = <int>[];
      for (var i = 0; i < cleaned.length; i += 2) {
        final byte = int.tryParse(cleaned.substring(i, i + 2), radix: 16);
        if (byte == null) return null;
        out.add(byte);
      }
      return out;
    case DebugBinarySource.base64:
      try {
        return base64Decode(text.replaceAll(RegExp(r'\s'), ''));
      } on FormatException {
        return null;
      }
    case DebugBinarySource.file:
      return null;
  }
}

/// 从 Content-Type 头提取 multipart boundary（非 multipart 或无 boundary → null）。
String? multipartBoundaryOf(String? contentType) {
  if (contentType == null) return null;
  if (!contentType.toLowerCase().trimLeft().startsWith('multipart/')) {
    return null;
  }
  final match = RegExp(r'boundary="?([^";]+)"?').firstMatch(contentType);
  final boundary = match?.group(1)?.trim();
  return (boundary == null || boundary.isEmpty) ? null : boundary;
}

// ==================== 私有 ====================

Uint8List _encodeMultipart(List<BodyPart> parts, String boundary) {
  final builder = BytesBuilder(copy: false);
  void writeAscii(String value) => builder.add(utf8.encode(value));

  for (final part in parts) {
    writeAscii('--$boundary\r\n');
    final disposition = StringBuffer(
      'Content-Disposition: form-data; name="${_escapeQuoted(part.name)}"',
    );
    if (part.isFile) {
      disposition.write('; filename="${_escapeQuoted(part.fileName!)}"');
    }
    writeAscii('$disposition\r\n');
    if (part.contentType != null && part.contentType!.isNotEmpty) {
      writeAscii('Content-Type: ${part.contentType}\r\n');
    }
    writeAscii('\r\n');
    if (part.isFile) {
      builder.add(part.fileBytes ?? const <int>[]);
    } else {
      builder.add(utf8.encode(part.value));
    }
    writeAscii('\r\n');
  }
  writeAscii('--$boundary--\r\n');
  return builder.takeBytes();
}

String _escapeQuoted(String value) =>
    value.replaceAll('"', '%22').replaceAll(RegExp(r'[\r\n]'), '');

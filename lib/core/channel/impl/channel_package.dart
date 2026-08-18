import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// zip 渠道包：解析校验 `channels/<key>.zip`，提取 entry.js / detail.js / meta.json。
///
/// ## 渠道包规范
/// ```
/// channels/<key>.zip
/// ├── entry.js    （必须：发现页脚本，main 分发器：getAllApps/searchApps/getAppInfo 等）
/// ├── detail.js   （可选：详情页脚本，main 分发器：getAppDetail/versionOptions/switchVersion/buildHistory/detailMenu 等）
/// └── meta.json   （可选：{ "name": "...", "description": "...", "icon": "..." }）
/// ```
///
/// channelKey = `'js_' + zip 文件名（无 .zip）`。
///
/// ## 安全设计（防 zip 路径穿越）
/// 本解析器**只取根目录直接文件**，且**不落盘任何解压内容**（仅读入内存字符串）：
/// - 条目名含 `/`、`\` 或 `..`（如 `../evil.js`、`sub/entry.js`）→ **整包拒绝**（返回 null）
/// - 目录条目直接跳过
/// 配合 [ChannelLoader] 的 channelKey 标识符白名单，杜绝包内路径逃逸。
class ChannelPackage {
  /// 发现页脚本（entry.js，必须；缺失 → 包无效）
  final String entryScript;

  /// 详情页脚本（detail.js，可选；缺失 → 详情走 JsChannel 原路径/降级）
  final String? detailScript;

  /// 渠道元信息（meta.json，可选：name/description/icon）
  final Map<String, dynamic>? meta;

  const ChannelPackage({
    required this.entryScript,
    this.detailScript,
    this.meta,
  });

  /// 从 zip 字节解码渠道包；包无效 → 返回 null（调用方跳过 + 日志）。
  ///
  /// 校验规则：
  /// - 非 zip / 损坏 / 空包 → null
  /// - **entry.js（根目录）必须**，缺失 → null
  /// - detail.js / meta.json → 可选（根目录）
  /// - meta.json 非 JSON 对象 / 损坏 → 忽略该文件（不视为包无效）
  /// - **路径穿越防护**：任何条目名含 `/`、`\` 或 `..` → 整包拒绝（null）
  static ChannelPackage? decode(Uint8List zipBytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (_) {
      // 非 zip / 损坏 → 无效包
      return null;
    }
    if (archive.isEmpty) return null;

    String? entry;
    String? detail;
    String? metaRaw;
    for (final file in archive.files) {
      if (!file.isFile) continue; // 目录条目跳过
      final name = file.name;
      // 路径穿越防护：只取根目录直接文件，任何分隔符/穿越标记 → 整包拒绝
      if (name.contains('/') || name.contains('\\') || name.contains('..')) {
        return null;
      }
      if (name == 'entry.js') {
        entry = _contentToString(file);
      } else if (name == 'detail.js') {
        detail = _contentToString(file);
      } else if (name == 'meta.json') {
        metaRaw = _contentToString(file);
      }
    }

    // entry.js 必须：缺失 → 包无效
    if (entry == null) return null;

    return ChannelPackage(
      entryScript: entry,
      detailScript: detail,
      meta: _parseMeta(metaRaw),
    );
  }

  /// 文件内容 → 字符串（UTF-8 宽松解码；内容缺失 → null）
  static String? _contentToString(ArchiveFile file) {
    final content = file.content;
    if (content == null) return null;
    return utf8.decode(content, allowMalformed: true);
  }

  /// meta.json → Map；非 JSON 对象 / 损坏 → null（不视为包无效）
  static Map<String, dynamic>? _parseMeta(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {
      // 损坏 meta.json：忽略
    }
    return null;
  }
}

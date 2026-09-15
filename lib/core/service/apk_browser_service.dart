import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/AnalyzerRustDecoder.dart';
import 'package:gstore/core/rust/contract/ModuleTypes.dart';

/// APK 内容浏览服务：目录列举 + 条目导出（宿主侧薄封装）
///
/// 架构（见 `document/development/11-APK文件浏览器.md`）：
/// **解压与嵌套容器解析全部在 Rust（唯一出口）**，本服务只负责
/// ① 把调用参数整理成契约编码；② 管理导出落地用的缓存目录与文件名。
/// 原始字节不跨 FFI 回传——导出结果直接落到缓存文件，UI 用文件消费。
class ApkBrowserService {
  ApkBrowserService._();

  static final ApkBrowserService instance = ApkBrowserService._();

  /// 导出落地目录（首次使用时创建）
  String? _cacheDir;

  /// 列一层目录。
  ///
  /// [containerChain] 为嵌套容器链（用 [AnalyzerRustDecoder.chainSep] 连接，
  /// 空串 = APK 根），[dir] 为当前容器内目录前缀。
  /// 返回 null = 分析模块不可用（UI 应提示，而不是显示空目录）。
  Future<ApkBrowseListing?> list(
    String apkPath, {
    String containerChain = '',
    String dir = '',
  }) {
    return AnalyzerRustDecoder.browseApkEntries(
      apkPath,
      containerChain: containerChain,
      dir: dir,
    );
  }

  /// 把条目导出到缓存文件，返回**落地绝对路径**（失败返回 null）。
  ///
  /// [entryPath] 是当前容器内的条目路径；嵌套内容用 [containerChain] 定位。
  Future<String?> exportToCache(
    String apkPath, {
    required String entryPath,
    String containerChain = '',
  }) async {
    final dir = await _ensureCacheDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final outPath = '$dir/${stamp}_${_safeFileName(entryPath)}';
    final result = await AnalyzerRustDecoder.exportApkEntry(
      apkPath,
      entryPath: entryPath,
      containerChain: containerChain,
      outPath: outPath,
    );
    if (result == null) {
      appLog.warning('ApkBrowserService: 导出失败 - $entryPath');
      return null;
    }
    return result.outPath;
  }

  /// 导出并同时返回元数据（预览器用它做 CRC 校验与类型判断）
  Future<ApkExportedEntry?> exportEntry(
    String apkPath, {
    required String entryPath,
    String containerChain = '',
  }) async {
    final dir = await _ensureCacheDir();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final outPath = '$dir/${stamp}_${_safeFileName(entryPath)}';
    return AnalyzerRustDecoder.exportApkEntry(
      apkPath,
      entryPath: entryPath,
      containerChain: containerChain,
      outPath: outPath,
    );
  }

  /// 导出并读取为**文本预览**（Agent 读取内容用）。
  ///
  /// 文本类直接解码；二进制回退为十六进制摘要（头 512 字节），
  /// 避免把不可读字节塞进模型上下文。
  Future<String?> readEntryText(
    String apkPath, {
    required String entryPath,
    String containerChain = '',
    int maxBytes = 64 * 1024,
  }) async {
    final result = await exportEntry(
      apkPath,
      entryPath: entryPath,
      containerChain: containerChain,
    );
    if (result == null) return null;
    final file = File(result.outPath);
    final len = await file.length();
    final want = len < maxBytes ? len : maxBytes;
    final raf = await file.open();
    Uint8List bytes;
    try {
      bytes = await raf.read(want);
    } finally {
      await raf.close();
    }
    final head = '路径: ${result.path}\n'
        '大小: $len 字节${len > want ? '（仅读取前 $want 字节）' : ''}\n\n';
    if (_looksBinary(bytes)) {
      return '$head（二进制内容，十六进制摘要）\n${hexDump(bytes, limit: 512)}';
    }
    return head + utf8.decode(bytes, allowMalformed: true);
  }

  /// 清空导出缓存（浏览器页退出时可调用）
  Future<void> clearCache() async {
    final dir = _cacheDir;
    if (dir == null) return;
    try {
      final d = Directory(dir);
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    } catch (e) {
      appLog.warning('ApkBrowserService: 清理缓存失败 - $e');
    }
    _cacheDir = null;
  }

  Future<String> _ensureCacheDir() async {
    final cached = _cacheDir;
    if (cached != null) return cached;
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}/apk_browser');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir.path;
    return _cacheDir!;
  }

  /// 只用条目**文件名**做落地名，并剔除路径分隔与特殊字符。
  ///
  /// 落盘名不采用条目原路径 → 不可能借条目名做目录穿越（zip slip）。
  static String _safeFileName(String entryPath) {
    final name = entryPath.split('/').last;
    final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'entry.bin' : cleaned;
  }
}

/// 条目类型 → 中文标签（UI 与 Agent 共用同一份，避免两处漂移）
///
/// [kind] 取值与 Rust `browser::classify` 一致。
String apkEntryKindLabel(String kind, {bool isDir = false}) {
  if (isDir) return '目录';
  return switch (kind) {
    'zip' => 'ZIP 压缩包',
    'apk' => 'APK 包',
    'jar' => 'JAR 包',
    'aar' => 'AAR 包',
    'dex' => 'DEX 字节码',
    'so' => '原生库',
    'arsc' => '资源表',
    'manifest' => '清单文件',
    'image' => '图片',
    'json' => 'JSON',
    'text' => '文本',
    'font' => '字体',
    'cert' => '证书',
    'video' => '视频',
    'audio' => '音频',
    _ => '二进制',
  };
}

/// 粗略判断是否为二进制内容（不可打印字节占比过高）
bool _looksBinary(Uint8List bytes) {
  if (bytes.isEmpty) return false;
  var control = 0;
  for (final b in bytes) {
    // 允许 \t \n \r 与可打印 ASCII
    if (b == 0x09 || b == 0x0a || b == 0x0d) continue;
    if (b < 0x20) control++;
  }
  return control * 10 > bytes.length; // >10% 控制字符
}

/// 16 字节/行：偏移 + 十六进制 + ASCII（预览与 Agent 摘要共用）
String hexDump(Uint8List bytes, {int limit = 4096}) {
  final view = bytes.length > limit ? bytes.sublist(0, limit) : bytes;
  final buf = StringBuffer();
  for (var offset = 0; offset < view.length; offset += 16) {
    final end = (offset + 16 > view.length) ? view.length : offset + 16;
    final hex = StringBuffer();
    final ascii = StringBuffer();
    for (var i = offset; i < offset + 16; i++) {
      if (i < end) {
        hex.write(view[i].toRadixString(16).padLeft(2, '0'));
        final c = view[i];
        ascii.write(c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '.');
      } else {
        hex.write('  ');
      }
      hex.write(' ');
      if (i % 8 == 7) hex.write(' ');
    }
    buf.writeln('${offset.toRadixString(16).padLeft(8, '0')}  $hex $ascii');
  }
  return buf.toString();
}

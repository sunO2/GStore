import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// zip 中央目录里的一条记录（**不解压**即可获得）
class ApkZipEntry {
  const ApkZipEntry({
    required this.name,
    required this.size,
    required this.compressedSize,
    required this.crc32,
    required this.method,
    required this.localHeaderOffset,
  });

  final String name;

  /// 解压后字节数
  final int size;
  final int compressedSize;
  final int crc32;

  /// 0 = STORED（未压缩），8 = DEFLATED
  final int method;
  final int localHeaderOffset;

  bool get isStored => method == 0;
}

/// APK（zip）中央目录索引：**只解析中央目录，不解压条目**。
///
/// 用途：Dart 侧兜底路径（Rust 模块不可用时）原先用
/// `File(path).readAsBytesSync()` + `ZipDecoder().decodeBytes()` ——
/// 整包读进内存 + 全量解压，只为拿条目名与大小。`archive` 3.x 又没有流式解码接口，
/// 所以这里直接读中央目录：内存占用与解压开销都降到最低。
///
/// 需要条目**内容**时用 [readEntryBytes]，它只解压指定条目（STORED 直取，
/// DEFLATED 用 raw inflate）。
class ApkZipIndex {
  ApkZipIndex._(this.path, this.fileSize, this.entries);

  final String path;
  final int fileSize;
  final List<ApkZipEntry> entries;

  static const int _eocdSignature = 0x06054b50;
  static const int _centralSignature = 0x02014b50;
  static const int _localSignature = 0x04034b50;
  static const int _eocdMinSize = 22;
  static const int _maxCommentSize = 65535;

  /// 仅文件（排除目录条目）
  List<ApkZipEntry> get files =>
      [for (final e in entries) if (!e.name.endsWith('/')) e];

  /// 读取中央目录；失败（非 zip / zip64 / 损坏）返回 null，由调用方降级
  static ApkZipIndex? read(String apkPath) {
    RandomAccessFile? raf;
    try {
      final fileLen = File(apkPath).lengthSync();
      if (fileLen < _eocdMinSize) return null;
      raf = File(apkPath).openSync();

      // 1) 尾部找 EOCD
      final tailLen = math.min(fileLen, _eocdMinSize + _maxCommentSize);
      raf.setPositionSync(fileLen - tailLen);
      final tail = raf.readSync(tailLen);
      final eocd = _findEocd(tail);
      if (eocd == null) return null;

      final cdOffset = _u32(tail, eocd + 16);
      final cdSize = _u32(tail, eocd + 12);
      final totalEntries = _u16(tail, eocd + 10);
      // zip64：APK 场景基本不出现；不猜，交调用方降级
      if (cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF || totalEntries == 0xFFFF) {
        return null;
      }
      if (cdOffset + cdSize > fileLen) return null;

      // 2) 读中央目录并逐条解析
      raf.setPositionSync(cdOffset);
      final cd = raf.readSync(cdSize);
      final parsed = <ApkZipEntry>[];
      var p = 0;
      while (p + 46 <= cd.length) {
        if (_u32(cd, p) != _centralSignature) break;
        final nameLen = _u16(cd, p + 28);
        final extraLen = _u16(cd, p + 30);
        final commentLen = _u16(cd, p + 32);
        if (p + 46 + nameLen > cd.length) break;
        parsed.add(
          ApkZipEntry(
            name: utf8.decode(
              cd.sublist(p + 46, p + 46 + nameLen),
              allowMalformed: true,
            ),
            size: _u32(cd, p + 24),
            compressedSize: _u32(cd, p + 20),
            crc32: _u32(cd, p + 16),
            method: _u16(cd, p + 10),
            localHeaderOffset: _u32(cd, p + 42),
          ),
        );
        p += 46 + nameLen + extraLen + commentLen;
      }
      return ApkZipIndex._(apkPath, fileLen, parsed);
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// 按名称查条目（重名取第一条）
  ApkZipEntry? entryNamed(String name) {
    for (final e in entries) {
      if (e.name == name) return e;
    }
    return null;
  }

  /// 解压单个条目内容；不存在或方法不支持返回 null
  Uint8List? readEntryBytes(String name) {
    final entry = entryNamed(name);
    if (entry == null) return null;
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync();
      // 本地头：30 字节固定 + 文件名 + 扩展区，之后才是数据
      raf.setPositionSync(entry.localHeaderOffset);
      final local = raf.readSync(30);
      if (local.length < 30 || _u32(local, 0) != _localSignature) return null;
      final nameLen = _u16(local, 26);
      final extraLen = _u16(local, 28);
      raf.setPositionSync(entry.localHeaderOffset + 30 + nameLen + extraLen);
      final raw = raf.readSync(entry.compressedSize);
      if (entry.isStored) return Uint8List.fromList(raw);
      if (entry.method == 8) {
        // zip 内的 deflate 是 raw deflate（无 zlib 头）
        final filter = RawZLibFilter.inflateFilter(raw: true);
        filter.process(raw, 0, raw.length);
        return Uint8List.fromList(filter.processed() ?? const <int>[]);
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }

  /// 从尾部缓冲区里定位 EOCD（注释长度须与剩余字节数一致）
  static int? _findEocd(Uint8List tail) {
    if (tail.length < _eocdMinSize) return null;
    for (var offset = tail.length - _eocdMinSize; offset >= 0; offset--) {
      if (_u32(tail, offset) != _eocdSignature) continue;
      final commentLen = _u16(tail, offset + 20);
      if (offset + _eocdMinSize + commentLen == tail.length) return offset;
    }
    return null;
  }

  static int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

  static int _u32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
}

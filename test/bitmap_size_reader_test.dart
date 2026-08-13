import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/image/bitmap_size_reader.dart';

// ---- fixture ----

/// 1×1 透明 PNG（标准魔数 + 有效 CRC + zlib 流，可被 ImageDescriptor 解析）。
final Uint8List kPngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

/// 1×1 JPEG（完整合法文件，SOI + APP0 + DQT + SOF0 等齐全）。
final Uint8List kJpegBytes = base64Decode(
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==',
);

/// 垃圾字节（不匹配任何格式）。
final Uint8List kGarbageBytes = Uint8List.fromList(
  List<int>.generate(64, (i) => (i * 7 + 3) % 256),
);

/// SVG 文本（非位图，ImageDescriptor 无法解析）。
final Uint8List kSvgBytes = utf8.encode(
  '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="20">'
  '<rect width="100" height="20" fill="red"/></svg>',
);

void main() {
  group('readBitmapSize', () {
    test('有效 1×1 PNG → (1,1)', () async {
      final size = await readBitmapSize(kPngBytes);
      expect(size, isNotNull);
      expect(size!.width, 1);
      expect(size.height, 1);
    });

    test('有效 1×1 JPEG → (1,1)', () async {
      final size = await readBitmapSize(kJpegBytes);
      expect(size, isNotNull);
      expect(size!.width, 1);
      expect(size.height, 1);
    });

    test('垃圾 bytes → null', () async {
      expect(await readBitmapSize(kGarbageBytes), isNull);
    });

    test('SVG 文本 bytes → null', () async {
      expect(await readBitmapSize(kSvgBytes), isNull);
    });

    test('空 bytes → null', () async {
      expect(await readBitmapSize(Uint8List(0)), isNull);
    });
  });
}

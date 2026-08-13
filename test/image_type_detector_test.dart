import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/image/image_type_detector.dart';

// ---- 内联 fixture：1×1 有效图片字节 ----

/// 1×1 透明 PNG（标准魔数 89 50 4E 47 0D 0A 1A 0A）。
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

/// 1×1 JPEG（SOI + JFIF APP0 头）。
final Uint8List kJpegBytes = Uint8List.fromList(const [
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, //
  0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, //
  0x00, 0x01, 0x00, 0x00,
]);

/// 1×1 GIF89a。
final Uint8List kGifBytes = Uint8List.fromList(const [
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, //
  0x01, 0x00, 0x01, 0x00, //
  0x80, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, //
  0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, //
  0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, //
  0x02, 0x02, 0x44, 0x01, 0x00, //
  0x3B,
]);

/// 1×1 WebP（RIFF….WEBP….VP8L 无损）。
final Uint8List kWebpBytes = Uint8List.fromList(const [
  0x52, 0x49, 0x46, 0x46, 0x1E, 0x00, 0x00, 0x00, //
  0x57, 0x45, 0x42, 0x50, //
  0x56, 0x50, 0x38, 0x4C, 0x12, 0x00, 0x00, 0x00, //
  0x2F, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0B, 0x00, //
  0x00, 0x00, 0x00, 0x00,
]);

/// 1×1 24 位 BMP（42 4D 开头）。
final Uint8List kBmpBytes = Uint8List.fromList(const [
  0x42, 0x4D, 0x3E, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x36, 0x00, 0x00, 0x00, 0x28, 0x00, //
  0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, //
  0x00, 0x00, 0x01, 0x00, 0x18, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x13, 0x0B, //
  0x00, 0x00, 0x13, 0x0B, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,
]);

/// 1×1 SVG 文本（utf8 编码）。
final Uint8List kSvgBytes = utf8.encode(
  '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1">'
  '<rect width="1" height="1" fill="red"/></svg>',
);

/// 未知字节序列。
final Uint8List kUnknownBytes = Uint8List.fromList(const [0x00, 0x01, 0x02, 0x03]);

void main() {
  group('detectImageType magic bytes 检测', () {
    test('PNG 魔数 → png', () {
      expect(detectImageType(bytes: kPngBytes), ImageFormat.png);
    });

    test('JPEG 魔数 → jpeg', () {
      expect(detectImageType(bytes: kJpegBytes), ImageFormat.jpeg);
    });

    test('GIF 魔数 → gif', () {
      expect(detectImageType(bytes: kGifBytes), ImageFormat.gif);
    });

    test('WebP 魔数（RIFF+WEBP）→ webp', () {
      expect(detectImageType(bytes: kWebpBytes), ImageFormat.webp);
    });

    test('BMP 魔数 → bmp', () {
      expect(detectImageType(bytes: kBmpBytes), ImageFormat.bmp);
    });

    test('SVG 文本（无 content-type）→ svg', () {
      expect(detectImageType(bytes: kSvgBytes), ImageFormat.svg);
    });

    test('未知字节 → unknown', () {
      expect(detectImageType(bytes: kUnknownBytes), ImageFormat.unknown);
    });
  });

  group('detectImageType Content-Type 优先', () {
    test('content-type=image/png 但 bytes 是 SVG 文本 → png', () {
      expect(
        detectImageType(contentType: 'image/png', bytes: kSvgBytes),
        ImageFormat.png,
      );
    });

    test('content-type=image/jpeg 但 bytes 是 PNG → jpeg', () {
      expect(
        detectImageType(contentType: 'image/jpeg', bytes: kPngBytes),
        ImageFormat.jpeg,
      );
    });

    test('content-type=image/svg+xml 但 bytes 是 PNG → svg', () {
      expect(
        detectImageType(contentType: 'image/svg+xml', bytes: kPngBytes),
        ImageFormat.svg,
      );
    });

    test('content-type 大小写不敏感（IMAGE/PNG）→ png', () {
      expect(
        detectImageType(contentType: 'IMAGE/PNG', bytes: kSvgBytes),
        ImageFormat.png,
      );
    });

    test('content-type 带参数（image/svg+xml;charset=utf-8）→ svg', () {
      expect(
        detectImageType(
          contentType: 'image/svg+xml;charset=utf-8',
          bytes: kPngBytes,
        ),
        ImageFormat.svg,
      );
    });

    test('content-type 带参数与空格（image/png ; charset=utf-8）→ png', () {
      expect(
        detectImageType(
          contentType: 'image/png ; charset=utf-8',
          bytes: kSvgBytes,
        ),
        ImageFormat.png,
      );
    });

    test('content-type 未知（application/octet-stream）→ 回退魔数 → png', () {
      expect(
        detectImageType(
          contentType: 'application/octet-stream',
          bytes: kPngBytes,
        ),
        ImageFormat.png,
      );
    });
  });

  group('detectImageType SVG 文本嗅探', () {
    test('带 UTF-8 BOM 的 SVG → svg', () {
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...kSvgBytes]);
      expect(detectImageType(bytes: bytes), ImageFormat.svg);
    });

    test('前导空白 + SVG → svg', () {
      final bytes = utf8.encode('  \n\t<svg xmlns="http://www.w3.org/2000/svg"/>');
      expect(detectImageType(bytes: bytes), ImageFormat.svg);
    });

    test('BOM + 前导空白 + SVG → svg', () {
      final bytes =
          Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('  <svg/>')]);
      expect(detectImageType(bytes: bytes), ImageFormat.svg);
    });

    test('<?xml 声明开头且含 <svg → svg', () {
      final bytes = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>',
      );
      expect(detectImageType(bytes: bytes), ImageFormat.svg);
    });

    test('<?xml 声明开头且含 <!DOCTYPE svg → svg', () {
      final bytes = utf8.encode(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" '
        '"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\n'
        '<svg xmlns="http://www.w3.org/2000/svg"/>',
      );
      expect(detectImageType(bytes: bytes), ImageFormat.svg);
    });

    test('非 SVG 文本（<html>）→ unknown', () {
      final bytes = utf8.encode('<html><body>hello</body></html>');
      expect(detectImageType(bytes: bytes), ImageFormat.unknown);
    });
  });

  group('detectImageType 边界', () {
    test('空 bytes → unknown', () {
      expect(detectImageType(bytes: Uint8List(0)), ImageFormat.unknown);
    });

    test('空 bytes 即使有 content-type → unknown', () {
      expect(
        detectImageType(contentType: 'image/png', bytes: Uint8List(0)),
        ImageFormat.unknown,
      );
    });

    test('bytes 过短（单字节）→ unknown', () {
      expect(
        detectImageType(bytes: Uint8List.fromList(const [0x89])),
        ImageFormat.unknown,
      );
    });

    test('PNG 魔数不完整（前 4 字节）→ unknown', () {
      expect(
        detectImageType(bytes: Uint8List.fromList(const [0x89, 0x50, 0x4E, 0x47])),
        ImageFormat.unknown,
      );
    });

    test('WebP 不足 12 字节（仅 RIFF 头）→ unknown', () {
      expect(
        detectImageType(
          bytes: Uint8List.fromList(const [
            0x52, 0x49, 0x46, 0x46, //
            0x1E, 0x00, 0x00, 0x00,
          ]),
        ),
        ImageFormat.unknown,
      );
    });

    test('WebP 不足 12 字节（RIFF+部分 WEB）→ unknown', () {
      expect(
        detectImageType(
          bytes: Uint8List.fromList(const [
            0x52, 0x49, 0x46, 0x46, //
            0x1E, 0x00, 0x00, 0x00, //
            0x57, 0x45, 0x42,
          ]),
        ),
        ImageFormat.unknown,
      );
    });

    test('GIF 魔数不完整（仅 GIF）→ unknown', () {
      expect(
        detectImageType(bytes: Uint8List.fromList(const [0x47, 0x49, 0x46])),
        ImageFormat.unknown,
      );
    });
  });
}

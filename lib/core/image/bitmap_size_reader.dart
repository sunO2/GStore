import 'dart:typed_data';
import 'dart:ui' as ui;

/// 从位图字节读取固有尺寸（PNG/JPEG/GIF/WebP/BMP 等 ImageDescriptor 支持格式）。
///
/// 任何失败（SVG 文本/损坏/不支持格式）→ null，由调用方自然回退。
Future<({double width, double height})?> readBitmapSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (
      width: descriptor.width.toDouble(),
      height: descriptor.height.toDouble(),
    );
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

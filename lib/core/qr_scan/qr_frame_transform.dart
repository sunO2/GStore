import 'dart:typed_data';

/// QR 帧方向变换：把 CameraImage 的传感器方向灰度/RGBA 转到预览方向。
///
/// 纯函数，无相机/平台依赖，便于单测与扫码组件复用。
class QrFrameTransform {
  QrFrameTransform._();

  /// 将紧凑像素帧按【顺时针 quarterTurns 次 90°】旋转，再可选水平镜像。
  ///
  /// [w]/[h] 为输入宽高、[bytesPerPixel] 每像素字节数（灰度 1 / RGBA 4）。
  /// 返回 `<像素数据, 旋转后宽, 旋转后高>`。
  static (Uint8List, int, int) rotateToPreview(
    Uint8List luma,
    int w,
    int h, {
    required int quarterTurns,
    bool mirrorX = false,
    int bytesPerPixel = 1,
  }) {
    Uint8List out = luma.buffer.asUint8List(
      luma.offsetInBytes,
      luma.lengthInBytes,
    );
    var cw = w, ch = h;
    final bpp = bytesPerPixel;
    for (var t = 0; t < quarterTurns % 4; t++) {
      // 顺时针 90°：目标 (r, c) ← 源 (ch-1-c, r)；目标宽=源高、目标高=源宽
      final dst = Uint8List(ch * cw * bpp);
      for (var r = 0; r < cw; r++) {
        for (var c = 0; c < ch; c++) {
          final s = ((ch - 1 - c) * cw + r) * bpp;
          final d = (r * ch + c) * bpp;
          for (var b = 0; b < bpp; b++) {
            dst[d + b] = out[s + b];
          }
        }
      }
      final tmp = cw;
      cw = ch;
      ch = tmp;
      out = dst;
    }
    if (mirrorX) {
      // 水平镜像：目标 (r, c) ← 源 (r, cw-1-c)
      final dst = Uint8List(cw * ch * bpp);
      for (var r = 0; r < ch; r++) {
        for (var c = 0; c < cw; c++) {
          final s = (r * cw + c) * bpp;
          final d = (r * cw + (cw - 1 - c)) * bpp;
          for (var b = 0; b < bpp; b++) {
            dst[d + b] = out[s + b];
          }
        }
      }
      out = dst;
    }
    return (out, cw, ch);
  }
}

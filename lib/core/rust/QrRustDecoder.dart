import 'dart:typed_data';

import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show QrDecoder;
import 'package:gstore/core/rust/generated/qr_decode.dart' show QrDecodeResult;

/// 二维码解码器（zxing-cpp，经 rust-flutter-bridge）
///
/// 单例懒初始化 FRB bridge；解码一帧灰度 ROI（紧凑布局）。
/// 返回 null = 完全未检测到；text 为空但 points 非空 = 检测到候选但解析失败
/// （供扫码页的码眼引导/自动变焦使用）。
class QrRustDecoder {
  QrRustDecoder._();

  static QrDecoder? _decoder;

  /// 解码一帧灰度图（宽度 × 高度字节，紧凑布局）
  static Future<QrDecodeResult?> decodeLuma(
    Uint8List luma,
    int width,
    int height,
  ) async {
    final decoder = await _instance();
    return decoder.decodeLuma(luma: luma, width: width, height: height);
  }

  static Future<QrDecoder> _instance() async {
    if (_decoder == null) {
      await RustBridge.ensureInitialized();
      _decoder = await QrDecoder.newInstance();
    }
    return _decoder!;
  }
}

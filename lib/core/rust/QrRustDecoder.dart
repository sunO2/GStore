import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/Contract.dart' show decodeQrDecodeResult;
import 'package:gstore/core/rust/contract/GStoreException.dart'
    show GStoreException;
import 'package:gstore/core/rust/contract/ModuleTypes.dart' show QrDecodeResult;
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;

/// 二维码解码器（zxing-cpp）
///
/// 优先走模块化路径（P2：按需下载 libgstore_mod_qr.so → 宿主 dlopen 挂载 →
/// 模块实例调用），模块不可用时降级到宿主内置 QrDecoder（旧路径）。
/// 返回 null = 完全未检测到；text 为空但 points 非空 = 检测到候选但解析失败。
class QrRustDecoder {
  QrRustDecoder._();

  static ModuleHandle? _moduleHandle;
  static RustModuleInstance? _moduleInstance;

  /// 解码一帧灰度图（宽度 × 高度字节，紧凑布局）
  static Future<QrDecodeResult?> decodeLuma(
    Uint8List luma,
    int width,
    int height,
  ) async {
    // 模块化路径（宿主已删内置实现，仅模块可用）
    return _decodeViaModule(luma, width, height);
  }

  static bool _moduleAvailable = false;
  static bool _moduleTried = false;

  /// 确保模块挂载（下载 + dlopen + create 实例）
  static Future<bool> _ensureModule() async {
    if (_moduleTried) return _moduleAvailable;
    _moduleTried = true;
    try {
      final ok = await RustModuleLoader.instance.ensureModule('qr');
      if (!ok) return false;

      _moduleHandle = await RustModuleManager.instance.loadModule('qr');
      if (_moduleHandle == null) return false;

      _moduleInstance = await RustModuleInstance.createWithContext('qr', _moduleHandle!);
      _moduleAvailable = _moduleInstance != null;
      return _moduleAvailable;
    } catch (e) {
      appLog.error('QrRustDecoder: 模块初始化失败 - $e');
      return false;
    }
  }

  /// 经模块实例调用 decode_luma
  /// payload 布局与模块约定: [width:i32][height:i32][luma...]
  static Future<QrDecodeResult?> _decodeViaModule(
    Uint8List luma,
    int width,
    int height,
  ) async {
    if (kIsWeb) return null; // 桌面/Web 无模块 .so
    if (!await _ensureModule()) return null;
    try {
      final payload = BytesBuilder(copy: false)
        ..add(_i32le(width))
        ..add(_i32le(height))
        ..add(luma);
      // 统一信封入口（proto 编解码 + 异常模型）
      final resp = await _moduleInstance!.callModule('decode_luma', payload.takeBytes());
      if (resp.isEmpty) return null;
      final text = utf8.decode(resp, allowMalformed: true);
      if (text == 'null') return null;
      return _parseModuleResponse(text);
    } on GStoreException catch (e) {
      appLog.warning('QrRustDecoder: 模块调用失败(信封) - ${e.status.name} ${e.errorCode}：${e.message}');
      return null;
    } catch (e) {
      appLog.error('QrRustDecoder: 模块调用失败 - $e');
      return null;
    }
  }

  static Uint8List _i32le(int v) {
    final b = ByteData(4)..setInt32(0, v, Endian.little);
    return b.buffer.asUint8List();
  }

  /// 解析模块返回的 JSON 为 QrDecodeResult（复用契约层统一解析，避免字段两边漂移）
  static QrDecodeResult? _parseModuleResponse(String json) {
    try {
      return decodeQrDecodeResult(jsonDecode(json));
    } catch (e) {
      appLog.error('QrRustDecoder: 模块响应解析失败 - $e');
      return null;
    }
  }
}

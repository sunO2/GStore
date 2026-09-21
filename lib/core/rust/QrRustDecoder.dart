import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/Contract.dart' show decodeQrDecodeResult;
import 'package:gstore/core/rust/contract/GStoreException.dart'
    show GStoreException;
import 'package:gstore/core/rust/contract/ModuleTypes.dart' show QrDecodeResult;

/// 二维码解码器（zxing-cpp）
///
/// 走统一模块自举门 [ModuleBootstrap]（按需下载 libgstore_mod_qr.so → 宿主
/// dlopen 挂载 → 模块实例调用）。模块不可用/安装期间返回 null，由调用方
/// （相机逐帧循环）自然丢弃该帧、下一帧重试。
/// 返回 null = 完全未检测到；text 为空但 points 非空 = 检测到候选但解析失败。
class QrRustDecoder {
  QrRustDecoder._();

  /// `qr` 模块阶段订阅（懒创建，应用生命周期内长存；只监听 `qr`）。
  static StreamSubscription<ModuleBootstrapState>? _phaseSub;

  /// `qr` 模块最近一次已知阶段（由 [_phaseSub] 持续更新）。
  static ModuleBootstrapPhase _phase = ModuleBootstrapPhase.absent;

  /// 首次调用是否已同步过门的缓存阶段（见 [decodeLuma]）。
  static bool _phaseSynced = false;

  /// 解码一帧灰度图（宽度 × 高度字节，紧凑布局）
  ///
  /// **相机循环安全**：本方法绝不 await 安装。首个非就绪帧只「即发即忘」触发
  /// 门的安装确保 / 实例创建并立即返回 null；安装期间（downloading /
  /// initializing）后续帧直接返回 null、不重复触发；失败（failed）**不粘滞**，
  /// 后续帧可再次触发重试；就绪（ready）后经门缓存实例解码。
  ///
  /// 「帧合并为最新」而非排队：实时相机流本身就是天然的“已保存任务”——每帧
  /// 都是更新的画面，安装期间积压旧帧没有意义，故直接丢弃、待就绪后解码下一帧
  /// 最新画面。
  static Future<QrDecodeResult?> decodeLuma(
    Uint8List luma,
    int width,
    int height,
  ) async {
    if (kIsWeb) return null; // 桌面/Web 无模块 .so

    _ensurePhaseSubscription();
    if (!_phaseSynced) {
      // `watch` 的首个（缓存）事件是异步投递的：首次调用让渡一次事件循环，
      // 读取门已缓存的最新阶段，避免对已就绪模块误触发一次安装。
      await Future<void>.delayed(Duration.zero);
      _phaseSynced = true;
    }

    final gate = ModuleBootstrap.instance;
    switch (_phase) {
      case ModuleBootstrapPhase.ready:
        return _decodeReady(gate, luma, width, height);
      case ModuleBootstrapPhase.downloading:
      case ModuleBootstrapPhase.initializing:
        // 安装/挂载进行中：不阻塞、不重复触发（帧合并为最新）。
        return null;
      case ModuleBootstrapPhase.absent:
      case ModuleBootstrapPhase.failed:
        // 首次使用或上次失败：即发即忘触发安装确保 + 实例创建，立即返回。
        // `acquire` 会 join `ensureStarted` 已启动的单飞 ensure，不会重复下载；
        // 失败结果不缓存，下一帧会再次进入本分支重试。
        gate.ensureStarted('qr');
        gate.acquire('qr').ignore();
        return null;
    }
  }

  /// 预热 `qr` 模块：进页面/切到识别时提前点火下载与挂载，与相机初始化并行。
  ///
  /// **为什么要预热**：模块的下载与挂载有真实网络/IO 延迟。若只等相机首帧解码时
  /// 才触发，用户会在相机已就绪后继续盯着「准备中」等待下载；把这段本可重叠的
  /// 延迟**藏进相机预热窗口**，扫码几乎无感。
  ///
  /// **幂等**：重复调用与帧循环里的 `ensureStarted`/`acquire` 合流（两级单飞），
  /// 不会重复下载；故可安全地「进页面 + 切模式」多次调用。
  ///
  /// **已安装短路**：若门已缓存 `qr` 实例，产物必然就绪，本方法直接返回、**不**
  /// 触发 `ensureStarted`。否则对已安装模块，loader 的 `_isLoaded` 会让一次
  /// ensure 成功却没有终态，把已 ready 的可观测阶段翻回 downloading 并冻结
  /// （重入扫码页卡在「下载中」）。
  static void prewarm() {
    if (kIsWeb) return; // 桌面/Web 无模块 .so
    _ensurePhaseSubscription();
    final gate = ModuleBootstrap.instance;
    if (gate.hasInstance('qr')) return;
    gate.ensureStarted('qr');
    gate.acquire('qr').ignore();
  }

  /// 模块就绪：经门取缓存实例并调用 `decode_luma`。
  static Future<QrDecodeResult?> _decodeReady(
    ModuleBootstrap gate,
    Uint8List luma,
    int width,
    int height,
  ) async {
    try {
      final instance = await gate.acquire('qr');
      // payload 布局与模块约定: [width:i32][height:i32][luma...]
      final payload = BytesBuilder(copy: false)
        ..add(_i32le(width))
        ..add(_i32le(height))
        ..add(luma);
      // 统一信封入口（proto 编解码 + 异常模型）
      final resp = await instance.callModule('decode_luma', payload.takeBytes());
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

  /// 懒创建 `qr` 阶段订阅（幂等）。
  static void _ensurePhaseSubscription() {
    _phaseSub ??= ModuleBootstrap.instance.watch('qr').listen((state) {
      _phase = state.phase;
    });
  }

  /// 测试专用：取消阶段订阅并复位缓存阶段（生产不调用）。
  @visibleForTesting
  static void debugReset() {
    _phaseSub?.cancel();
    _phaseSub = null;
    _phase = ModuleBootstrapPhase.absent;
    _phaseSynced = false;
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

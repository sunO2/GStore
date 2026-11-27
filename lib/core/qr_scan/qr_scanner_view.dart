import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/qr_scan/zoom_controller.dart';
import 'package:gstore/core/rust/QrRustDecoder.dart';

import 'qr_frame_transform.dart';

/// 可嵌入任意页面的二维码实时预览 + 识别组件。
///
/// 只负责相机预览、逐帧解码和识别框 UI；不写历史、不碰输入框。
/// 识别结果通过 [onResult] 回调交给宿主页面。
///
/// 默认尺寸 240×240，宿主可放在任意有界容器中；组件自身负责：
/// - 相机权限/初始化/释放
/// - 预览 cover 裁剪
/// - YUV 帧旋转/镜像与多 ROI 解码
/// - 码眼叠加、失败引导、重新扫描
class QrScannerView extends StatefulWidget {
  const QrScannerView({
    super.key,
    required this.onResult,
    this.onError,
    this.availableCameras,
    this.dimension = 240,
    this.scanBoxRatio = 0.75,
    this.autoStart = true,
    this.stopOnResult = true,
    this.showOverlay = true,
  });

  /// 识别成功回调（已保证非空文本）。
  final ValueChanged<String> onResult;

  /// 相机/解码错误回调；组件内也会显示错误占位。
  final ValueChanged<String>? onError;

  /// 测试/宿主注入：枚举相机（null = 走真实 availableCameras）。
  final Future<List<CameraDescription>> Function()? availableCameras;

  /// 预览区边长；组件按正方形渲染。
  final double dimension;

  /// 识别框边长占预览区比例（默认 0.75）。
  final double scanBoxRatio;

  /// 挂载后自动启动相机。
  final bool autoStart;

  /// 识别成功是否停止图像流（默认 true；连续扫码可设 false）。
  final bool stopOnResult;

  /// 是否绘制默认识别框/提示/码眼。
  final bool showOverlay;

  @override
  State<QrScannerView> createState() => _QrScannerViewState();
}

class _QrScannerViewState extends State<QrScannerView>
    with WidgetsBindingObserver {
  CameraController? _camera;
  Future<List<CameraDescription>>? _camerasFuture;

  bool _initializing = false;
  String? _error;
  bool _stopped = false;

  final List<Offset> _eyePoints = <Offset>[];
  final List<Offset> _mappedEyePoints = <Offset>[];
  int _lastFrameW = 0;
  int _lastFrameH = 0;

  CameraImage? _pendingFrame;
  bool _drainRunning = false;

  String _hint = '将二维码对准框内';

  ui.Image? _capturedFrame;

  double _minZoomLevel = 1;
  double _maxZoomLevel = 1;
  double _currentZoom = 0;
  QrZoomController? _zoomController;
  String? _zoomControllerCamera;

  double _minExposureOffset = 0;
  double _maxExposureOffset = 0;
  double _currentExposureOffset = 0;
  DateTime _lastExposureAdjustAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _overExposureStreak = 0;
  int _underExposureStreak = 0;
  String? _exposureHint;

  double _lastRoiSharpness = 0;
  int _consecutiveDecodeFailures = 0;
  bool _lastChecksumError = false;
  String? _zoomBoundaryHint;

  DateTime _lastAutoFocusAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastZoomLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastZoomLogAction = '';
  Timer? _focusLockTimer;

  static const double _sharpnessGoodThreshold = 6.0;

  Size? _previewBoxSize;
  Size? _previewContentSize;

  int _previewQuarterTurns = 0;
  bool _previewMirrorX = false;

  static const List<double> _roiFractions = <double>[0.75, 0.45, 0.95];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_start());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_releaseCamera());
    } else if (state == AppLifecycleState.resumed &&
        mounted &&
        _camera == null &&
        !_initializing) {
      unawaited(_start());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusLockTimer?.cancel();
    _capturedFrame?.dispose();
    _capturedFrame = null;
    unawaited(_releaseCamera());
    super.dispose();
  }

  Future<List<CameraDescription>> _loadCameras() {
    final custom = widget.availableCameras;
    if (custom != null) return custom();
    return _camerasFuture ??= availableCameras();
  }

  Future<void> _start() async {
    if (_camera != null || _initializing) return;
    setState(() {
      _initializing = true;
      _error = null;
      _stopped = false;
      _hint = '将二维码对准框内';
      _capturedFrame?.dispose();
      _capturedFrame = null;
    });
    _eyePoints.clear();
    _mappedEyePoints.clear();
    _zoomBoundaryHint = null;
    _exposureHint = null;
    _lastChecksumError = false;
    // 相机初始化与 qr 原生模块预热并行；幂等，页面/组件重复调用安全。
    QrRustDecoder.prewarm();
    try {
      final cameras = await _loadCameras();
      if (!mounted) return;
      CameraDescription? back;
      for (final c in cameras) {
        if (c.lensDirection == CameraLensDirection.back) {
          back = c;
          break;
        }
      }
      final desc = back ?? (cameras.isNotEmpty ? cameras.first : null);
      if (desc == null) {
        throw CameraException('noCamera', '未检测到可用相机');
      }
      _previewQuarterTurns = defaultTargetPlatform == TargetPlatform.android
          ? (desc.sensorOrientation ~/ 90) % 4
          : 0;
      _previewMirrorX = desc.lensDirection == CameraLensDirection.front;

      final controller = CameraController(
        desc,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      // 预览优先：先挂载 CameraPreview，再做对焦/图像流配置。
      setState(() {
        _camera = controller;
        _initializing = false;
      });
      unawaited(_configure(controller));
    } catch (e) {
      appLog.error('QrScannerView: 相机初始化失败 - $e');
      _camerasFuture = null;
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = '相机不可用';
      });
      widget.onError?.call('无法启动相机，请检查相机权限');
    }
  }

  Future<void> _configure(CameraController controller) async {
    bool current() => mounted && identical(_camera, controller);
    if (!current()) return;
    try {
      try {
        _minZoomLevel = await controller.getMinZoomLevel();
        _maxZoomLevel = await controller.getMaxZoomLevel();
      } catch (e) {
        appLog.error('QrScannerView: 读取变焦范围失败 - $e');
      }
      if (!current()) return;

      final cameraKey = controller.description.name;
      final existing = _zoomController;
      if (existing == null || _zoomControllerCamera != cameraKey) {
        _zoomController = QrZoomController(
          minZoom: _minZoomLevel,
          maxZoom: _maxZoomLevel,
          learning: QrZoomLearning.of(cameraKey),
        );
        _zoomControllerCamera = cameraKey;
      } else {
        existing.updateZoomRange(_minZoomLevel, _maxZoomLevel);
      }
      _lastChecksumError = false;

      try {
        _minExposureOffset = await controller.getMinExposureOffset();
        _maxExposureOffset = await controller.getMaxExposureOffset();
      } catch (e) {
        _minExposureOffset = 0;
        _maxExposureOffset = 0;
      }
      if (!current()) return;
      _currentExposureOffset = 0;
      _overExposureStreak = 0;
      _underExposureStreak = 0;
      _consecutiveDecodeFailures = 0;
      _lastRoiSharpness = 0;
      _exposureHint = null;
      _currentZoom = _minZoomLevel;
      final startZoom = _zoomController!.preferredStartZoom;

      // 预览已挂载；启动图像流让识别尽早开始。
      await controller.startImageStream(_onFrame);
      if (!current()) return;

      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        await controller.setFocusPoint(const Offset(0.5, 0.5));
      } catch (_) {}
      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (_) {}
      try {
        await controller.setExposurePoint(const Offset(0.5, 0.5));
      } catch (_) {}
      if (!current()) return;
      if ((startZoom - _currentZoom).abs() >= 0.1) {
        await _applyZoom(startZoom);
      }
    } catch (e) {
      appLog.error('QrScannerView: 相机配置/图像流失败 - $e');
      if (!current()) return;
      setState(() => _error = '相机已启动，但扫描流不可用');
      widget.onError?.call('相机已启动，但扫描流不可用');
    }
  }

  Future<void> _releaseCamera() async {
    final controller = _camera;
    _camera = null;
    _pendingFrame = null;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  /// 外部可调用：释放相机（例如宿主页面进入后台/切页）。
  Future<void> stop() => _releaseCamera();

  /// 外部可调用：重新启动相机。
  Future<void> start() => _start();

  /// 重新扫描：保留相机，只重置识别状态并恢复图像流。
  Future<void> restart() async {
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized) {
      await _start();
      return;
    }
    setState(() {
      _stopped = false;
      _hint = '将二维码对准框内';
      _capturedFrame?.dispose();
      _capturedFrame = null;
    });
    _eyePoints.clear();
    _mappedEyePoints.clear();
    _zoomController?.resetTransient();
    _zoomBoundaryHint = null;
    _pendingFrame = null;
    _consecutiveDecodeFailures = 0;
    _overExposureStreak = 0;
    _underExposureStreak = 0;
    _exposureHint = null;
    _lastRoiSharpness = 0;
    _lastAutoFocusAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastExposureAdjustAt = DateTime.fromMillisecondsSinceEpoch(0);
    _focusLockTimer?.cancel();
    try {
      await controller.setFocusMode(FocusMode.auto);
    } catch (_) {}
    final startZoom = _zoomController?.preferredStartZoom ?? _minZoomLevel;
    if ((_currentZoom - startZoom).abs() > 0.1) {
      await _applyZoom(startZoom);
    } else {
      _currentZoom = startZoom;
    }
    if (!controller.value.isStreamingImages) {
      try {
        await controller.startImageStream(_onFrame);
      } catch (e) {
        appLog.error('QrScannerView: 重新扫描失败 - $e');
      }
    }
  }

  void _onFrame(CameraImage image) {
    if (_stopped) return;
    _lastFrameW = image.width;
    _lastFrameH = image.height;
    _pendingFrame = image;
    if (_drainRunning) return;
    unawaited(_drainFrames());
  }

  Future<void> _drainFrames() async {
    _drainRunning = true;
    try {
      while (!_stopped) {
        final image = _pendingFrame;
        if (image == null) break;
        _pendingFrame = null;
        _maybeAutoRefocus();
        final text = await _decodeQr(image);
        if (_stopped) break;
        if (text != null && text.isNotEmpty) {
          _consecutiveDecodeFailures = 0;
          await _onScanSuccess(text, image);
          break;
        }
        _consecutiveDecodeFailures++;
        if (_eyePoints.isNotEmpty) {
          await _adjustZoomToEyes();
        }
        _updateHint();
        _syncEyePointsOverlay();
      }
    } catch (e) {
      appLog.error('QrScannerView: 帧调度异常 - $e');
    } finally {
      _drainRunning = false;
    }
  }

  Future<void> _onScanSuccess(String text, CameraImage image) async {
    if (_stopped) return;
    _stopped = true;
    _zoomController?.onDecoded(_currentZoom, _symbolRatio());
    _logZoomBuckets();
    _captureFreezeFrame(image);
    final controller = _camera;
    if (widget.stopOnResult && controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (e) {
        appLog.error('QrScannerView: 停止图像流失败 - $e');
      }
    }
    if (mounted) setState(() => _hint = '已识别');
    HapticFeedback.mediumImpact();
    widget.onResult(text);
    if (!widget.stopOnResult) {
      _stopped = false;
      _capturedFrame?.dispose();
      _capturedFrame = null;
      if (mounted) setState(() => _hint = '将二维码对准框内');
    }
  }

  Future<String?> _decodeQr(CameraImage image) async {
    if (image.planes.isEmpty) return null;
    final (data, w, h) = _extractLumaRotated(image);
    if (w <= 0 || h <= 0 || data.length < w * h) return null;
    final shortSide = w < h ? w : h;
    final refSide = (shortSide * _roiFractions.first).round();
    if (refSide <= 0) return null;
    final refLeft = (w - refSide) ~/ 2;
    final refTop = (h - refSide) ~/ 2;
    _eyePoints.clear();
    _lastChecksumError = false;

    for (final fraction in _roiFractions) {
      final side = (shortSide * fraction).round();
      if (side <= 0 || side > w || side > h) continue;
      final left = (w - side) ~/ 2;
      final top = (h - side) ~/ 2;
      final roi = Uint8List(side * side);
      for (var y = 0; y < side; y++) {
        roi.setRange(y * side, (y + 1) * side, data, (top + y) * w + left);
      }
      if (side == refSide) {
        _updateExposureFeedback(roi);
        _lastRoiSharpness = _computeSharpness(roi, side);
      }

      final result = await QrRustDecoder.decodeLuma(roi, side, side);
      if (result == null) continue;
      final pts = result.points;
      final corners = <Offset>[];
      if (pts.length >= 8) {
        final dx = (left - refLeft).toDouble();
        final dy = (top - refTop).toDouble();
        corners.addAll([
          Offset(pts[0] + dx, pts[1] + dy),
          Offset(pts[2] + dx, pts[3] + dy),
          Offset(pts[4] + dx, pts[5] + dy),
          Offset(pts[6] + dx, pts[7] + dy),
        ]);
      }
      final decoded =
          result.isValid || (result.error.isEmpty && result.text.isNotEmpty);
      if (decoded) {
        _eyePoints
          ..clear()
          ..addAll(corners);
        return result.text;
      }
      _lastChecksumError = _lastChecksumError || result.isChecksumFailure;
      if (_eyePoints.isEmpty) _eyePoints.addAll(corners);
    }
    return null;
  }

  (Uint8List, int, int) _extractLumaRotated(CameraImage image) {
    final plane = image.planes[0];
    final w = image.width;
    final h = image.height;
    final rowStride = plane.bytesPerRow;
    final bytes = plane.bytes;
    final src = Int8List(w * h);
    if (rowStride == w) {
      src.setAll(0, bytes);
    } else {
      for (var y = 0; y < h; y++) {
        src.setRange(y * w, (y + 1) * w, bytes, y * rowStride);
      }
    }
    return QrFrameTransform.rotateToPreview(
      src.buffer.asUint8List(src.offsetInBytes, src.lengthInBytes),
      w,
      h,
      quarterTurns: _previewQuarterTurns,
      mirrorX: _previewMirrorX,
    );
  }

  void _updateHint() {
    final hint = _zoomBoundaryHint ??
        _exposureHint ??
        (_eyePoints.isNotEmpty ? '检测到二维码，请移近/对准框内' : '未检测到，请将二维码对准框内');
    if (mounted && hint != _hint) setState(() => _hint = hint);
  }

  void _syncEyePointsOverlay() {
    if (!mounted) return;
    final mapped = _computeMappedEyePoints(_lastFrameW, _lastFrameH);
    if (listEquals(mapped, _mappedEyePoints)) return;
    setState(() {
      _mappedEyePoints
        ..clear()
        ..addAll(mapped);
    });
  }

  double _symbolRatio() {
    if (_eyePoints.isEmpty) return 0;
    final shortSide = _lastFrameW < _lastFrameH ? _lastFrameW : _lastFrameH;
    final side = (shortSide * _roiFractions.first).round();
    if (side <= 0) return 0;
    var minX = double.infinity, minY = double.infinity;
    var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
    for (final p in _eyePoints) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    if (!minX.isFinite || !minY.isFinite) return 0;
    final area = (maxX - minX) * (maxY - minY);
    return (area / (side * side)).clamp(0.0, 1.0);
  }

  Future<void> _adjustZoomToEyes() async {
    final controller = _camera;
    final zc = _zoomController;
    if (controller == null || !controller.value.isInitialized || zc == null) {
      return;
    }
    final observation = ZoomObservation(
      ratio: _symbolRatio(),
      zoom: _currentZoom,
      detected: _eyePoints.isNotEmpty,
      checksumError: _lastChecksumError,
      sharpness: _lastRoiSharpness,
    );
    final decision = zc.update(observation);
    switch (decision.action) {
      case ZoomAction.zoomIn:
      case ZoomAction.zoomOut:
        _zoomBoundaryHint = null;
        final applied = await _applyZoom(decision.targetZoom!);
        if (applied) {
          _lastAutoFocusAt = DateTime.fromMillisecondsSinceEpoch(0);
        }
        _logZoomDecision(observation, decision, applied);
      case ZoomAction.tooFar:
        _setBoundaryHint('请靠近一点');
        _logZoomDecision(observation, decision, false);
      case ZoomAction.tooClose:
        _setBoundaryHint('请拿远一点，让二维码完整入框');
        _logZoomDecision(observation, decision, false);
      case ZoomAction.none:
        if (observation.detected &&
            !zc.isOutOfBand(zc.smoothedRatio) &&
            _zoomBoundaryHint != null) {
          _zoomBoundaryHint = null;
          if (mounted) setState(() {});
        }
    }
  }

  Future<bool> _applyZoom(double target) async {
    if ((target - _currentZoom).abs() < 0.1) return false;
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized) return false;
    try {
      await controller.setZoomLevel(target);
      _currentZoom = target;
      return true;
    } catch (e) {
      appLog.error('QrScannerView: 设置变焦失败 - $e');
      return false;
    }
  }

  void _logZoomDecision(ZoomObservation o, ZoomDecision d, bool applied) {
    final now = DateTime.now();
    final changed = d.action.name != _lastZoomLogAction;
    if (!changed &&
        now.difference(_lastZoomLogAt) < const Duration(seconds: 1)) {
      return;
    }
    _lastZoomLogAction = d.action.name;
    _lastZoomLogAt = now;
    final zc = _zoomController;
    appLog.debug('QR_ZOOM', data: {
      'zoom': double.parse(o.zoom.toStringAsFixed(2)),
      'ratio': double.parse(o.ratio.toStringAsFixed(3)),
      'emaRatio': double.parse((zc?.smoothedRatio ?? 0).toStringAsFixed(3)),
      'detected': o.detected,
      'checksumError': o.checksumError,
      'sharpness': double.parse(o.sharpness.toStringAsFixed(2)),
      'action': d.action.name,
      'target': d.targetZoom == null
          ? null
          : double.parse(d.targetZoom!.toStringAsFixed(2)),
      'applied': applied,
      'zoomIneffective': zc?.zoomIneffective ?? false,
      'levelGood': zc?.currentLevelProvenGood ?? false,
    });
  }

  void _logZoomBuckets() {
    final zc = _zoomController;
    if (zc == null) return;
    appLog.info('QR_ZOOM_STATS', data: {
      'buckets': {
        for (final e in zc.buckets.entries)
          (e.key / 4).toStringAsFixed(2): e.value.toJson(),
      },
    });
  }

  void _setBoundaryHint(String hint) {
    if (_zoomBoundaryHint == hint) return;
    _zoomBoundaryHint = hint;
    _setScanHint(hint);
  }

  void _setScanHint(String hint) {
    if (!mounted || hint == _hint) return;
    setState(() => _hint = hint);
  }

  void _updateExposureFeedback(Uint8List roi) {
    if (roi.isEmpty) return;
    var sum = 0;
    var saturated = 0;
    var n = 0;
    for (var i = 0; i < roi.length; i += 4) {
      final v = roi[i];
      sum += v;
      if (v >= 250) saturated++;
      n++;
    }
    if (n == 0) return;
    final mean = sum / n;
    final satRatio = saturated / n;
    _overExposureStreak =
        (satRatio > 0.06 || mean > 190) ? _overExposureStreak + 1 : 0;
    _underExposureStreak = mean < 55 ? _underExposureStreak + 1 : 0;
    _maybeAdjustExposure();
    if (_overExposureStreak == 0 &&
        _underExposureStreak == 0 &&
        _exposureHint != null) {
      _exposureHint = null;
      _updateHint();
    }
  }

  void _maybeAdjustExposure() {
    if (_minExposureOffset == 0 && _maxExposureOffset == 0) return;
    final now = DateTime.now();
    if (now.difference(_lastExposureAdjustAt).inMilliseconds < 400) return;
    if (_overExposureStreak >= 3) {
      _overExposureStreak = 0;
      _lastExposureAdjustAt = now;
      final next = (_currentExposureOffset - 0.5)
          .clamp(_minExposureOffset, _maxExposureOffset);
      if ((next - _currentExposureOffset).abs() < 0.01) {
        _setExposureHint('光线过曝，请调低屏幕亮度或避开反光');
      } else {
        unawaited(_applyExposureOffset(next));
      }
    } else if (_underExposureStreak >= 6) {
      _underExposureStreak = 0;
      _lastExposureAdjustAt = now;
      final next = (_currentExposureOffset + 0.5)
          .clamp(_minExposureOffset, _maxExposureOffset);
      if ((next - _currentExposureOffset).abs() < 0.01) {
        _setExposureHint('光线太暗，请移到明亮处');
      } else {
        unawaited(_applyExposureOffset(next));
      }
    }
  }

  Future<void> _applyExposureOffset(double value) async {
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized) return;
    if ((value - _currentExposureOffset).abs() < 0.01) return;
    try {
      await controller.setExposureOffset(value);
      _currentExposureOffset = value;
      if (_exposureHint != null) {
        _exposureHint = null;
        _updateHint();
      }
    } catch (e) {
      appLog.error('QrScannerView: 调整曝光补偿失败 - $e');
    }
  }

  void _setExposureHint(String hint) {
    if (_exposureHint == hint) return;
    _exposureHint = hint;
    _updateHint();
  }

  double _computeSharpness(Uint8List luma, int side) {
    if (side < 8) return 0;
    var sum = 0.0;
    var n = 0;
    for (var y = 1; y < side - 1; y += 3) {
      final row = y * side;
      for (var x = 1; x < side - 1; x += 3) {
        final i = row + x;
        final dx = (luma[i + 1] - luma[i - 1]).abs();
        final dy = (luma[i + side] - luma[i - side]).abs();
        sum += (dx + dy).toDouble();
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  void _maybeAutoRefocus() {
    if (_stopped) return;
    final now = DateTime.now();
    if (now.difference(_lastAutoFocusAt).inMilliseconds < 1000) return;
    final blurry =
        _lastRoiSharpness > 0 && _lastRoiSharpness < _sharpnessGoodThreshold;
    final failing = _consecutiveDecodeFailures >= 8;
    if (!blurry && !failing) return;
    _lastAutoFocusAt = now;
    final target = _eyePointsCenterInPreview();
    unawaited(_refocusAt(
        target ?? Offset(widget.dimension / 2, widget.dimension / 2)));
  }

  Offset? _eyePointsCenterInPreview() {
    if (_eyePoints.isEmpty) return null;
    final shortSide = _lastFrameW < _lastFrameH ? _lastFrameW : _lastFrameH;
    final side = (shortSide * _roiFractions.first).round();
    if (side <= 0) return null;
    final boxSize = widget.dimension * widget.scanBoxRatio;
    final boxOffset = (widget.dimension - boxSize) / 2;
    final scale = boxSize / side;
    var cx = 0.0, cy = 0.0;
    for (final p in _eyePoints) {
      cx += p.dx;
      cy += p.dy;
    }
    return Offset(
      boxOffset + (cx / _eyePoints.length) * scale,
      boxOffset + (cy / _eyePoints.length) * scale,
    );
  }

  Future<void> _refocusAt(Offset local) async {
    final controller = _camera;
    final box = _previewBoxSize;
    final content = _previewContentSize;
    if (controller == null ||
        !controller.value.isInitialized ||
        box == null ||
        content == null ||
        content.isEmpty) {
      return;
    }
    final originX = (box.width - content.width) / 2;
    final originY = (box.height - content.height) / 2;
    var u = (local.dx - originX) / content.width;
    final v = (local.dy - originY) / content.height;
    if (_previewMirrorX) u = 1 - u;
    final point = Offset(u.clamp(0.0, 1.0), v.clamp(0.0, 1.0));
    try {
      await controller.setFocusPoint(point);
      await controller.setExposurePoint(point);
    } catch (e) {
      appLog.error('QrScannerView: 对焦失败 - $e');
    }
  }

  void _lockFocusBriefly() {
    final controller = _camera;
    if (controller == null) return;
    _focusLockTimer?.cancel();
    unawaited(() async {
      try {
        await controller.setFocusMode(FocusMode.locked);
      } catch (_) {}
    }());
    _focusLockTimer = Timer(const Duration(seconds: 2), () {
      unawaited(() async {
        final c = _camera;
        if (c == null || !c.value.isInitialized) return;
        try {
          await c.setFocusMode(FocusMode.auto);
        } catch (_) {}
      }());
    });
  }

  void _captureFreezeFrame(CameraImage image) {
    if (image.planes.length < 3) {
      _captureFreezeFrameGrayscale(image);
      return;
    }
    final w = image.width, h = image.height;
    final yPlane = image.planes[0],
        uPlane = image.planes[1],
        vPlane = image.planes[2];
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final yi =
            yPlane.bytesPerRow == w ? y * w + x : y * yPlane.bytesPerRow + x;
        final ui = uPlane.bytesPerRow == (w / 2).ceil()
            ? (y ~/ 2) * (w ~/ 2) + x ~/ 2
            : (y ~/ 2) * uPlane.bytesPerRow + x ~/ 2;
        final vi = vPlane.bytesPerRow == (w / 2).ceil()
            ? (y ~/ 2) * (w ~/ 2) + x ~/ 2
            : (y ~/ 2) * vPlane.bytesPerRow + x ~/ 2;
        final yv = yPlane.bytes[yi];
        final u = uPlane.bytes[ui] - 128;
        final v = vPlane.bytes[vi] - 128;
        final r = yv + (1.402 * v).round();
        final g = yv - (0.344 * u).round() - (0.714 * v).round();
        final b = yv + (1.772 * u).round();
        final di = (y * w + x) * 4;
        rgba[di] = r.clamp(0, 255);
        rgba[di + 1] = g.clamp(0, 255);
        rgba[di + 2] = b.clamp(0, 255);
        rgba[di + 3] = 0xFF;
      }
    }
    final (rotated, rw, rh) = _rotateRgbaToPreview(rgba, w, h);
    _decodeFreezeFrame(rotated, rw, rh);
  }

  void _captureFreezeFrameGrayscale(CameraImage image) {
    final plane = image.planes.isEmpty ? null : image.planes[0];
    if (plane == null) return;
    final w = image.width, h = image.height;
    final rowStride = plane.bytesPerRow;
    final bytes = plane.bytes;
    if (rowStride < w) return;
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final srcRow = y * rowStride;
      final dstRow = y * w * 4;
      for (var x = 0; x < w; x++) {
        final yv = bytes[srcRow + x];
        final di = dstRow + x * 4;
        rgba[di] = yv;
        rgba[di + 1] = yv;
        rgba[di + 2] = yv;
        rgba[di + 3] = 0xFF;
      }
    }
    final (rotated, rw, rh) = _rotateRgbaToPreview(rgba, w, h);
    _decodeFreezeFrame(rotated, rw, rh);
  }

  (Uint8List, int, int) _rotateRgbaToPreview(Uint8List src, int w, int h) {
    return QrFrameTransform.rotateToPreview(
      src,
      w,
      h,
      quarterTurns: _previewQuarterTurns,
      mirrorX: _previewMirrorX,
      bytesPerPixel: 4,
    );
  }

  void _decodeFreezeFrame(Uint8List rgba, int w, int h) {
    try {
      ui.decodeImageFromPixels(
        rgba,
        w,
        h,
        ui.PixelFormat.rgba8888,
        (img) {
          if (!mounted) {
            img.dispose();
            return;
          }
          setState(() {
            _capturedFrame?.dispose();
            _capturedFrame = img;
          });
        },
      );
    } catch (e) {
      appLog.error('QrScannerView: 定格帧生成失败 - $e');
    }
  }

  List<Offset> _computeMappedEyePoints(int w, int h) {
    if (_eyePoints.isEmpty || w <= 0 || h <= 0) return const [];
    final side = ((w < h ? w : h) * _roiFractions.first).round();
    if (side <= 0) return const [];
    final boxSize = widget.dimension * widget.scanBoxRatio;
    final boxOffset = (widget.dimension - boxSize) / 2;
    final scale = boxSize / side;
    return [
      for (final p in _eyePoints)
        Offset(boxOffset + p.dx * scale, boxOffset + p.dy * scale),
    ];
  }

  void _onTapToFocus(Offset local) {
    unawaited(_refocusAt(local));
    _lockFocusBriefly();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _camera;
    final previewReady = controller != null && controller.value.isInitialized;
    return SizedBox.square(
      dimension: widget.dimension,
      child: ClipRRect(
        borderRadius: AppRadius.allLG,
        child: previewReady
            ? Stack(
                fit: StackFit.expand,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _onTapToFocus(d.localPosition),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final box = constraints.biggest;
                        if (box.isEmpty) return const SizedBox.shrink();
                        final ratio = controller.value.aspectRatio < 1
                            ? controller.value.aspectRatio
                            : 1 / controller.value.aspectRatio;
                        final scale = math.max(box.width / ratio, box.height);
                        final size = Size(ratio * scale, scale);
                        _previewBoxSize = box;
                        _previewContentSize = size;
                        return OverflowBox(
                          minWidth: 0,
                          minHeight: 0,
                          maxWidth: double.infinity,
                          maxHeight: double.infinity,
                          alignment: Alignment.center,
                          child: SizedBox.fromSize(
                            size: size,
                            child: (_stopped && _capturedFrame != null)
                                ? RawImage(
                                    image: _capturedFrame,
                                    fit: BoxFit.cover,
                                  )
                                : _buildCameraPreview(controller),
                          ),
                        );
                      },
                    ),
                  ),
                  if (widget.showOverlay) ...[
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _EyePointsPainter(
                            points: _mappedEyePoints,
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: widget.dimension * widget.scanBoxRatio,
                            height: widget.dimension * widget.scanBoxRatio,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: scheme.primary,
                                width: 2,
                              ),
                              borderRadius: AppRadius.allLG,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            _hint,
                            textAlign: TextAlign.center,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurface,
                                      backgroundColor:
                                          scheme.surface.withValues(alpha: 0.7),
                                    ),
                          ),
                        ],
                      ),
                    ),
                    if (_stopped)
                      Positioned(
                        top: AppSpacing.sm,
                        right: AppSpacing.sm,
                        child: IconButton.filledTonal(
                          tooltip: '重新扫描',
                          icon: const Icon(TablerIcons.refresh),
                          onPressed: restart,
                        ),
                      ),
                  ],
                ],
              )
            : _buildPlaceholder(context, scheme),
      ),
    );
  }

  Widget _buildCameraPreview(CameraController controller) {
    final preview = CameraPreview(controller);
    if (controller.description.lensDirection == CameraLensDirection.front) {
      return Transform.scale(scaleX: -1, child: preview);
    }
    return preview;
  }

  Widget _buildPlaceholder(BuildContext context, ColorScheme scheme) {
    return Container(
      color: scheme.surfaceContainerHighest,
      child: _initializing
          ? const Center(child: AppLoading(size: AppLoadingSize.medium))
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  TablerIcons.scan,
                  size: AppTypography.iconMassive,
                  color: scheme.outline,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  _error ?? '相机不可用',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
    );
  }
}

class _EyePointsPainter extends CustomPainter {
  _EyePointsPainter({required this.points, required this.color});

  final List<Offset> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final p in points) {
      canvas.drawCircle(p, 3.5, fill);
      canvas.drawCircle(p, 3.5, stroke);
    }
  }

  @override
  bool shouldRepaint(_EyePointsPainter oldDelegate) =>
      oldDelegate.color != color || !listEquals(oldDelegate.points, points);
}

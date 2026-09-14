import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback;
import 'package:gal/gal.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/QrRustDecoder.dart';
import 'package:gstore/page/qr_tool/zoom_controller.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 二维码工具模式：生成二维码 / 识别二维码
enum QrToolMode { generate, scan }

/// 二维码工具页：输入文本/链接 → 实时生成二维码；支持长按保存图片（应用目录 + 系统相册）；
/// 历史生成记录防抖持久化（shared_preferences），点击历史可回填输入。
/// 「识别二维码」模式复用同一预览区显示相机实时预览，识别结果自动回填输入框，
/// 识别历史独立持久化（qr_tool_scan_history）。
class QrToolPage extends StatefulWidget {
  const QrToolPage({super.key});

  /// 测试注入：系统相册写入结果（null = 走真实 gal；true/false = 模拟结果，不触发真实相册）。
  @visibleForTesting
  static bool? debugGallerySucceeds;

  /// 测试注入：枚举可用相机（null = 走真实 availableCameras()）。
  /// 测试环境平台通道未注册会挂起，注入后可确定性走「相机不可用」失败路径。
  @visibleForTesting
  static Future<List<CameraDescription>> Function()? debugAvailableCameras;

  /// 将紧凑像素帧按【顺时针 quarterTurns 次 90°】旋转，再可选水平镜像——
  /// 把 CameraImage（传感器方向）转成与 CameraPreview 一致的预览方向。
  /// 纯函数（无状态依赖），供解码/码眼/定格统一复用，且可直接单测。
  /// [w]/[h] 为输入宽高、[bytesPerPixel] 每像素字节数（灰度 1 / RGBA 4），
  /// 返回 <像素数据, 旋转后宽, 旋转后高>。
  @visibleForTesting
  static (Uint8List, int, int) rotateLumaToPreview(
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

  @override
  State<QrToolPage> createState() => _QrToolPageState();
}

class _QrToolPageState extends State<QrToolPage> {
  /// 历史记录存储键
  static const String _historyKey = 'qr_tool_history';

  /// 识别历史存储键
  static const String _scanHistoryKey = 'qr_tool_scan_history';

  /// 历史记录上限
  static const int _historyLimit = 20;

  /// 当前模式：生成二维码 / 识别二维码
  QrToolMode _mode = QrToolMode.generate;

  /// 输入控制器（「清除」时清空并复位 [_text]）
  final TextEditingController _controller = TextEditingController();

  /// 输入框焦点节点（保存完成后保持失焦，用户主动点击才重新聚焦）
  final FocusNode _focusNode = FocusNode();

  /// 当前要生成二维码的内容（空 → 显示占位）
  String _text = '';

  /// 历史生成记录（去重置顶，最近的在最前，上限 [_historyLimit]）
  List<String> _history = [];

  /// 识别历史记录（同样去重置顶 + 上限 + 持久化；chips 点击回填输入框）
  List<String> _scanHistory = [];

  /// 相机控制器（仅识别模式持有；切回生成模式时释放）
  CameraController? _cameraController;

  /// 相机初始化中（用于扫描区占位显示 loading）
  bool _cameraInitializing = false;

  /// 相机初始化失败原因（非空 → 扫描区显示「相机不可用」占位，不崩溃）
  String? _cameraError;

  /// 已识别一次即停（避免连续触发）：true 时不再处理新帧，显示「重新扫描」入口
  bool _scanningStopped = false;

  /// 识别成功当帧解码出的可显示图（BGRA→RGBA 经 [ui.decodeImageFromPixels]，
  /// 预览窗定格显示用；重新扫描/清除/销毁时 dispose 清空）
  ui.Image? _capturedFrame;

  /// 最近一帧解码收集的码候选角点（zxing-cpp 返回 4 角定位点；ROI 局部坐标）。
  /// 解码成功后保留供 ROI 绘制；解码失败但检测到候选时同样保留供引导判断。
  final List<Offset> _eyePoints = [];

  /// 最近一帧码眼映射到 240×240 预览窗的坐标（空则不绘制；随帧刷新仅变化时 setState）
  final List<Offset> _mappedEyePoints = [];

  /// 最近一帧图像尺寸（码眼包围盒占 0.75 ROI 面积比例估算用）
  int _lastFrameW = 0;
  int _lastFrameH = 0;

  /// 只解码最新帧：处理中到达的新帧覆盖待处理帧，避免"丢帧"降低有效解码率
  CameraImage? _pendingFrame;

  /// 解码循环运行标志（替代原 _processingFrame：循环内始终取最新帧）
  bool _drainRunning = false;

  /// 曝光补偿范围（initialize 后缓存；平台不支持时保持 0..0）
  double _minExposureOffset = 0;
  double _maxExposureOffset = 0;

  /// 当前曝光补偿值（EV，相对自动测光）
  double _currentExposureOffset = 0;

  /// 曝光调整限频与连续判据（防抖：连续多帧过曝/欠曝才动作）
  DateTime _lastExposureAdjustAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _overExposureStreak = 0;
  int _underExposureStreak = 0;

  /// 曝光引导（过曝/欠曝已到补偿边界时提示用户调整环境），优先级高于解码引导
  String? _exposureHint;

  /// 预览内容区（cover 适配后的实际显示尺寸）与取景框尺寸——点击对焦坐标正确映射用
  Size? _previewContentSize;
  Size? _previewBoxSize;

  /// 最近一帧参考 ROI 的锐度（相邻梯度均值）：反馈驱动重对焦，避免定时"拉风箱"
  double _lastRoiSharpness = 0;

  /// 连续解码失败帧数（反馈驱动重对焦的另一判据）
  int _consecutiveDecodeFailures = 0;

  /// 点击对焦后的短暂锁焦定时器（用户主动对焦 → 锁 2s → 回自动，减少抖动）
  Timer? _focusLockTimer;

  /// 锐度良好阈值：高于该值视为画面清晰，不再主动重对焦
  static const double _sharpnessGoodThreshold = 6.0;

  /// 当前生效变焦倍率（自动变焦防抖基准：相邻期望差值 <0.1 跳过）
  double _currentZoom = 0;

  /// 变焦范围（initialize 后缓存一次；平台不支持时保持 1.0）
  double _minZoomLevel = 1;
  double _maxZoomLevel = 1;

  /// 数据驱动的变焦控制器（initialize 拿到变焦范围后创建/复用）。
  /// 决策依据、去抖/静默/阻尼参数与分档实测统计都收敛在控制器内，便于单测与调参。
  QrZoomController? _zoomController;

  /// [_zoomController] 当前对应的相机名：同相机重开只刷新范围，不重建（保学习结果）
  String? _zoomControllerCamera;

  /// 最近一帧是否「定位到但校验失败」（几何可信、像质不足）——变焦与曝光的判据
  bool _lastChecksumError = false;

  /// 变焦决策日志限频（同一动作 ≥1s 才再记一次，见 [_logZoomDecision]）
  DateTime _lastZoomLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastZoomLogAction = '';

  /// 上一次自动重新对焦时间（周期对焦限频：每 ~1.5s 触发一次中心对焦，
  /// 补偿 CameraX 一次性 AF 不持续跟焦导致的扫描中焦距漂移）
  DateTime _lastAutoFocusAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 自动变焦边界引导文案（非空 = 已到变焦边界仍偏离目标，如「请靠近一点」「请拿远一点」）。
  /// 解码失败引导不覆盖它；条件解除（方向归滞回带/变焦成功/画面无候选）时清空。
  String? _zoomBoundaryHint;

  /// 帧→预览方向旋转（顺时针 quarterTurns）。CameraX 输出的 CameraImage 是**传感器方向**
  ///（横屏），而 CameraPreview 已由插件按 sensorOrientation 转成竖屏显示；
  /// 解码/码眼/定格想做到「所见即所扫」，必须先把帧旋转到与预览一致的方向。
  int _previewQuarterTurns = 0;

  /// 帧→预览方向水平镜像（前置相机预览做了 scaleX:-1，解码须配对，否则图像镜像无法识别）
  bool _previewMirrorX = false;

  /// 识别框下方引导文案：解码失败时按码眼有无区分「检测到但解析失败」/「未检测到」，
  /// 默认提示「将二维码对准框内」（扫描区初始与重新扫描时复位）；自动变焦到边界时
  /// 置「靠近一点」/「拿远一点」引导用户调整距离。
  String _scanHint = '将二维码对准框内';

  /// 整页滑动手势跟踪：
  /// 手势累计位移（起手指针原始事件累计；用于方向锁定 + 上滑/下滑/左右滑判定）。
  double _gestureDx = 0, _gestureDy = 0;

  /// 当前手势锁定的方向：'h' 水平 / 'v' 垂直 / null 未锁定。
  /// 首 2~3 帧按「|dx| > |dy|×1.2 锁定水平，|dy| > |dx|×1.2 锁定垂直」，
  /// 锁定后忽略另一方向位移，避免斜滑/抖动误触发。
  String? _gestureAxis;

  /// 手势起点的全局 Y（用于向下滑清空时排除输入区——起点落在 TextField 范围内不认领）
  bool _gestureStartedInInput = false;

  /// 下一次 [TextField] 构建时用于标记其局部坐标（供手势命中判定）
  final GlobalKey _inputFieldKey = GlobalKey();

  /// 保存中标志（防重复触发长按保存）
  bool _saving = false;

  /// 历史写入防抖计时器（输入停顿 [_historyDebounceDuration] 后才落历史）
  Timer? _historyDebounce;

  /// 历史写入防抖时长：输入停顿 800ms 后才写入历史（避免逐字符记录）
  static const Duration _historyDebounceDuration = Duration(milliseconds: 800);

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadScanHistory();
  }

  @override
  void dispose() {
    _historyDebounce?.cancel();
    _focusLockTimer?.cancel();
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) {
      // 页面销毁：停止图像流并释放相机（fire-and-forget，异常仅记录日志）
      unawaited(_releaseCamera(controller));
    }
    _controller.dispose();
    _focusNode.dispose();
    _capturedFrame?.dispose();
    _capturedFrame = null;
    super.dispose();
  }

  /// 从 shared_preferences 加载历史记录（失败不阻塞 UI）
  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_historyKey) ?? const [];
      if (!mounted) return;
      setState(() {
        _history = stored.where((e) => e.trim().isNotEmpty).toList();
      });
    } catch (e) {
      appLog.error('QrToolPage: 加载历史记录失败 - $e');
    }
  }

  /// 从 shared_preferences 加载识别历史（失败不阻塞 UI）
  Future<void> _loadScanHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_scanHistoryKey) ?? const [];
      if (!mounted) return;
      setState(() {
        _scanHistory = stored.where((e) => e.trim().isNotEmpty).toList();
      });
    } catch (e) {
      appLog.error('QrToolPage: 加载识别历史失败 - $e');
    }
  }

  /// 输入变化：即时更新二维码内容；历史写入改为防抖（停顿 800ms 后 [_commitHistory]）。
  /// 防抖只在生成模式生效（识别模式的回填走 [_onScanSuccess]/[_applyHistory]，不走防抖）。
  void _onTextChanged(String value) {
    final text = value.trim();
    setState(() => _text = text);
    if (_mode != QrToolMode.generate) return;
    _historyDebounce?.cancel();
    _historyDebounce = Timer(_historyDebounceDuration, _commitHistory);
  }

  /// 防抖到期：把当前非空内容去重置顶写入历史（与首条相同则跳过），异步持久化
  void _commitHistory() {
    final text = _text.trim();
    if (text.isEmpty || (_history.isNotEmpty && _history.first == text)) return;
    setState(() {
      _history = [text, ..._history.where((e) => e != text)]
          .take(_historyLimit)
          .toList();
    });
    unawaited(_persistHistory());
  }

  /// 将当前历史写回 shared_preferences（fire-and-forget，失败仅记录日志）
  Future<void> _persistHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_historyKey, _history);
    } catch (e) {
      appLog.error('QrToolPage: 写入历史记录失败 - $e');
    }
  }

  /// 将当前识别历史写回 shared_preferences（fire-and-forget，失败仅记录日志）
  Future<void> _persistScanHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_scanHistoryKey, _scanHistory);
    } catch (e) {
      appLog.error('QrToolPage: 写入识别历史失败 - $e');
    }
  }

  /// 点击历史 chip：回填输入框并重新生成二维码（识别模式回填后不再自动重新扫描）
  void _applyHistory(String item) {
    _historyDebounce?.cancel();
    _controller.text = item;
    _controller.selection = TextSelection.collapsed(offset: item.length);
    setState(() => _text = item);
  }

  /// 清空当前模式对应的历史记录
  void _clearHistory() {
    setState(() {
      if (_mode == QrToolMode.scan) {
        _scanHistory = [];
      } else {
        _history = [];
      }
    });
    unawaited(_mode == QrToolMode.scan ? _persistScanHistory() : _persistHistory());
  }

  /// 当前模式对应的历史记录（生成历史 / 识别历史）
  List<String> get _activeHistory =>
      _mode == QrToolMode.scan ? _scanHistory : _history;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        // 无标题；分段切换放右侧 actions（与返回按钮不挤；短标签「生成|识别」，去图标）
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: AppSegmentedButton<QrToolMode>(
              value: _mode,
              segments: const [
                AppSegment(value: QrToolMode.generate, label: '生成'),
                AppSegment(value: QrToolMode.scan, label: '识别'),
              ],
              onChanged: _onModeChanged,
              density: VisualDensity.compact,
            ),
          ),
        ],
      ),
      // 悬浮清除按钮已移除：清空输入由「下滑」手势承担（见 _onGestureUp），
      // 避免与手势系统重复、也减少页面冗余控件。
      body: Listener(
        // 整页滑动手势：上滑=历史 / 下滑=清空(起点非输入区) / 左右滑=切模式。
        // 必须放在 Stack 最外层：Stack hitTest 逆序、命中即停——若 Listener 作为
        // Stack 的兄弟层，会被上层 TextField 拦截而收不到任何指针事件。
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onGestureDown,
        onPointerMove: _onGestureMove,
        onPointerUp: _onGestureUp,
        child: Stack(
          children: [
            // 主体内容：预览区 + 输入区（历史记录已移入底部弹窗）
            Padding(
            padding: AppSpacing.allLG,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 预览区 / 输入区 5:4：预览(取景/生成)与输入框区域接近均衡，
                // 视觉比例协调；键盘弹出时输入区先收缩、预览等比缩小。
                Expanded(flex: 5, child: _buildQrArea(context)),
                const SizedBox(height: AppSpacing.sm),

                // 输入区（flex 4 ≈ 剩余空间，撑开多行输入；识别模式下只读展示识别结果）
                // 底部留白避免输入框贴地（视觉上浮起，与页面留白协调）
                Expanded(
                  flex: 4,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.md),
                    child: TextField(
                      key: _inputFieldKey,
                      controller: _controller,
                      focusNode: _focusNode,
                      // 识别模式结果只读；生成模式可编辑
                      readOnly: _mode == QrToolMode.scan,
                      // 识别结果长按可选择/复制（系统选择菜单）
                      enableInteractiveSelection: true,
                      // 长按输入框 → 自定义菜单：识别/只读模式提供「复制全文」（生成模式保留系统菜单）
                      contextMenuBuilder: _mode == QrToolMode.scan
                          ? (context, editableTextState) {
                              return AdaptiveTextSelectionToolbar.buttonItems(
                                anchors:
                                    editableTextState.contextMenuAnchors,
                                buttonItems: [
                                  ContextMenuButtonItem(
                                    label: '复制',
                                    onPressed: () {
                                      // 点击后收起工具栏（自定义按钮不会自动隐藏）
                                      editableTextState.hideToolbar();
                                      _copyResult();
                                    },
                                  ),
                                ],
                              );
                            }
                          : null,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                    decoration: InputDecoration(
                      hintText: _mode == QrToolMode.scan
                          ? '将二维码对准相机，识别结果自动填入此处'
                          : '输入文本或链接生成二维码',
                      hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.outline,
                          ),
                      border: const OutlineInputBorder(
                        borderRadius: AppRadius.allLG,
                      ),
                    ),
                    onChanged: _onTextChanged,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 右上角手势规则说明入口
          Positioned(
            top: AppSpacing.sm,
            right: AppSpacing.sm,
            child: IconButton(
              tooltip: '手势操作说明',
              icon: const Icon(Icons.info_outline, size: AppTypography.iconSM),
              onPressed: _showGestureHelp,
            ),
          ),
          ],
        ),
      ),
    );
  }

  /// ===== 整页滑动手势系统 =====

  /// 手势方向锁定比例：|dx| > |dy|×1.2 → 水平；|dy| > |dx|×1.2 → 垂直。
  static const double _gestureLockRatio = 1.2;

  /// 触发阈值（逻辑像素）：上滑弹历史 / 下滑清空 / 左右滑切模式。
  static const double _swipeUpHistory = 80;
  static const double _swipeDownClear = 120;
  static const double _swipeHorizontalSwitch = 80;

  /// 重置手势跟踪状态（起手指针时）
  void _onGestureDown(PointerDownEvent e) {
    _gestureDx = 0;
    _gestureDy = 0;
    _gestureAxis = null;
    _gestureStartedInInput = _isPointInsideInput(e.position);
  }

  /// 手势移动：方向锁定（首帧按比例定轴，锁定后只累计该轴位移）
  void _onGestureMove(PointerMoveEvent e) {
    _gestureDx += e.delta.dx;
    _gestureDy += e.delta.dy;
    if (_gestureAxis == null) {
      if (_gestureDx.abs() > _gestureDy.abs() * _gestureLockRatio) {
        _gestureAxis = 'h';
      } else if (_gestureDy.abs() > _gestureDx.abs() * _gestureLockRatio) {
        _gestureAxis = 'v';
      }
    }
  }

  /// 手势结束：按锁定方向分派动作
  void _onGestureUp(PointerUpEvent e) {
    final axis = _gestureAxis;
    _gestureAxis = null;
    if (axis == null) return;
    final horizontal = _gestureDx;
    final vertical = _gestureDy;

    if (axis == 'h' && horizontal.abs() >= _swipeHorizontalSwitch) {
      // 左右滑切换模式：右滑=生成（预览区），左滑=识别（扫码）
      final target = horizontal > 0 ? QrToolMode.generate : QrToolMode.scan;
      if (target != _mode) {
        HapticFeedback.mediumImpact();
        _onModeChanged(target);
      }
      return;
    }

    if (axis != 'v') return;

    if (vertical <= -_swipeUpHistory) {
      // 上滑 → 弹出历史记录 sheet
      HapticFeedback.mediumImpact();
      _showHistorySheet();
    } else if (vertical >= _swipeDownClear && !_gestureStartedInInput) {
      // 下滑 → 清空输入框（起点在输入框内除外——避免编辑时误触发）
      HapticFeedback.mediumImpact();
      _clear();
    }
  }

  /// 判断指针是否落在输入框内（起点在输入区时不认领“下滑清空”，尊重编辑手势）
  bool _isPointInsideInput(Offset globalPos) {
    final box = _inputFieldKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return false;
    final topLeft = box.localToGlobal(Offset.zero);
    final size = box.size;
    return globalPos.dx >= topLeft.dx &&
        globalPos.dx <= topLeft.dx + size.width &&
        globalPos.dy >= topLeft.dy &&
        globalPos.dy <= topLeft.dy + size.height;
  }

  /// 上滑手势：弹出当前模式的历史记录底部弹窗（复用 AppDialogs.showBottomSheet）。
  /// 样式与「导入渠道包」sheet 保持一致：内容整体左右 padding 不贴边，
  /// 底部操作按钮右下角（取消 + 确认风格清空）。
  void _showHistorySheet() {
    final history = _activeHistory;
    final title = _mode == QrToolMode.scan ? '识别历史' : '历史记录';
    if (history.isEmpty) {
      AppDialogs.showInfo('暂无$title');
      return;
    }
    // 弹窗打开前收起键盘/失焦，避免关闭后焦点自动归还输入框、键盘重新弹出
    _focusNode.unfocus();
    AppDialogs.showBottomSheet(
      title: title,
      children: [
        // children 无水平 padding（标题才带），内容整体补左右边距避免贴边（对齐渠道包 sheet）
        Padding(
          padding: AppSpacing.onlyHorizontalLG,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '点击历史项回填输入框',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: AppSpacing.md),
              // 历史列表（点击回填输入框并关闭弹窗）
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: history.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: Theme.of(context).colorScheme.borderLight,
                  ),
                  itemBuilder: (context, index) {
                    final item = history[index];
                    return InkWell(
                      onTap: () {
                        _applyHistory(item);
                        AppDialogs.popSheet<void>(null);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.md,
                        ),
                        child: Text(
                          item,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              // 操作按钮（右下角，对齐渠道包 sheet：取消 + 确认风格清空）
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => AppDialogs.popSheet<void>(null),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton.icon(
                    onPressed: () {
                      _clearHistory();
                      AppDialogs.popSheet<void>(null);
                    },
                    icon: const Icon(Icons.delete_outline,
                        size: AppTypography.iconSM),
                    label: const Text('清空'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 右上角「手势操作说明」弹窗（打开前收起键盘/失焦，避免关闭后焦点归还输入框）
  Future<void> _showGestureHelp() async {
    const rules = [
      ('已启用手势', '就像在聊天软件里滑动一样，在页面内滑动即可快捷操作'),
      ('上滑', '查看历史记录'),
      ('下滑', '清空输入框（在输入框内下滑除外）'),
      ('左滑 / 右滑', '切换「识别」/「生成」模式'),
      ('长按输入框', '复制识别结果（识别模式）'),
    ];
    // 弹窗打开前收起键盘/失焦，避免关闭后焦点自动归还输入框、键盘重新弹出
    _focusNode.unfocus();
    await AppDialogs.showDialog(
      title: '手势操作说明',
      icon: const Icon(Icons.swipe),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (action, desc) in rules)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      action,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ),
                  Expanded(child: Text(desc)),
                ],
              ),
            ),
        ],
      ),
      confirmText: '知道了',
    );
    // 弹窗关闭后再确保失焦（不归还输入框焦点）
    _focusNode.unfocus();
  }

  /// 长按输入框复制当前内容（识别/只读模式；内容为空时不动作）。
  /// 以 controller 实际文本为准（与识别回填 / 手输路径均一致）。
  void _copyResult() {
    final content = _controller.text;
    if (content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: content));
    AppDialogs.showSuccess('已复制');
  }

  /// 二维码预览区：生成模式显示占位/二维码；识别模式显示相机实时预览 + 识别框。
  /// 统一包一层与输入框同款的圆角描边容器（宽度一致、视觉成组），
  /// 内部内容居中；扫码相机 240 取景居中，生成内容等比放大填满可用空间。
  Widget _buildQrArea(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: AppRadius.allLG,
        border: Border.all(color: colorScheme.borderLight),
      ),
      clipBehavior: Clip.antiAlias,
      child: _mode == QrToolMode.scan
          ? _buildScanArea(context)
          : Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: _text.isEmpty ? _buildPlaceholder(context) : _buildQr(),
              ),
            ),
    );
  }

  /// 识别模式预览区：相机预览（圆角裁剪 + 识别框 overlay）；
  /// 相机未初始化 → loading 占位；初始化失败 → 「相机不可用」提示（绝不崩溃）。
  Widget _buildScanArea(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final controller = _cameraController;
    return Center(
      child: SizedBox(
        width: 240,
        height: 240,
        child: ClipRRect(
          borderRadius: AppRadius.allLG,
          child: (controller == null || !controller.value.isInitialized)
              ? _buildScanPlaceholder(context)
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    // 相机预览：CameraPreview 内部是 AspectRatio（竖屏 1/aspectRatio）。
                    // 关键：不能把它塞进 tight SizedBox(240×240)（AspectRatio 受 tight 约束
                    // → 纹理拉伸变形），也不能直接放 FittedBox（FittedBox 以无限约束布局子
                    // 组件，AspectRatio 双轴无界时塌缩为 0 → 预览黑屏）。
                    // 正确做法：LayoutBuilder 拿到 240×240 有界区域，按相机比例算 cover 尺寸
                    //（等比放大填满窗口、长边溢出居中裁切），用 OverflowBox 提供有界约束，
                    // 与定格帧 RawImage(cover) 等价。
                    if (controller.value.aspectRatio > 0)
                      GestureDetector(
                        // 点按重新对焦：CameraX 的 setFocusPoint 会主动触发对焦，
                        // 应对长时间扫描后自动对焦漂移导致的模糊（不支持的平台忽略）。
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => _onTapToFocus(d.localPosition),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final box = constraints.biggest; // 240×240
                            if (box.isEmpty) return const SizedBox.shrink();
                            // 相机自然方向已是竖屏规格（aspectRatio<1）直接用，否则转竖屏比例
                            final ratio = controller.value.aspectRatio < 1
                                ? controller.value.aspectRatio
                                : 1 / controller.value.aspectRatio;
                            // cover：等比放大完全覆盖 box（min 边填满，长边溢出居中裁切）
                            final scale = math.max(box.width / ratio, box.height);
                            final size = Size(ratio * scale, scale);
                            // 记录预览内容区尺寸：点击对焦坐标映射用（cover 裁剪还原）
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
                                child:
                                    (_scanningStopped && _capturedFrame != null)
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
                    // 码眼映射点绘制（识别框之下；IgnorePointer 避免挡点击）
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _EyePointsPainter(
                            points: _mappedEyePoints,
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                    // 居中识别框 + 底部提示
                    IgnorePointer(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 180,
                            height: 180,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: colorScheme.primary,
                                width: 2,
                              ),
                              borderRadius: AppRadius.allLG,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          Text(
                            _scanHint,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: colorScheme.onSurface,
                                  backgroundColor: colorScheme.surface
                                      .withValues(alpha: 0.7),
                                ),
                          ),
                        ],
                      ),
                    ),
                    // 识别成功后提供「重新扫描」入口
                    if (_scanningStopped)
                      Positioned(
                        top: AppSpacing.sm,
                        right: AppSpacing.sm,
                        child: IconButton.filledTonal(
                          tooltip: '重新扫描',
                          icon: const Icon(Icons.refresh),
                          onPressed: _restartScan,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  /// 相机预览 Widget：前置相机水平镜像（与系统相机自拍观感一致）
  Widget _buildCameraPreview(CameraController controller) {
    final preview = CameraPreview(controller);
    if (controller.description.lensDirection == CameraLensDirection.front) {
      return Transform.scale(scaleX: -1, child: preview);
    }
    return preview;
  }

  /// 相机未初始化 / 初始化失败占位（AppLoading 或「相机不可用」提示）
  Widget _buildScanPlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.allLG,
      ),
      // Center 松约束：容器是 tight 240×240，直接放 AppLoading 会被父约束
      // 拉伸成满窗大小（SizedBox 内部尺寸被 tight 覆盖）；包 Center 后
      // loading 按自身尺寸(48)居中显示。
      child: _cameraInitializing
          ? const Center(
              child: AppLoading(size: AppLoadingSize.medium),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.qr_code_scanner,
                  size: AppTypography.iconMassive,
                  color: colorScheme.outline,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  _cameraError ?? '相机不可用',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.outline,
                      ),
                ),
              ],
            ),
    );
  }

  /// 空输入占位提示
  Widget _buildPlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 240,
      height: 240,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.allLG,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.qr_code_2,
            size: AppTypography.iconMassive,
            color: colorScheme.outline,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '输入内容后生成二维码',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colorScheme.outline,
                ),
          ),
        ],
      ),
    );
  }

  /// 二维码预览（白底保证可扫描；圆角容器；长按弹确认框保存图片）
  Widget _buildQr() {
    return GestureDetector(
      onLongPress: _confirmSaveImage,
      child: Container(
        padding: AppSpacing.allLG,
        decoration: const BoxDecoration(
          // 二维码需要浅色底才能被识别扫描：功能必需，非主题配色
          color: Colors.white,
          borderRadius: AppRadius.allLG,
        ),
        child: QrImageView(
          data: _text,
          version: QrVersions.auto,
          size: 240,
          backgroundColor: Colors.white,
        ),
      ),
    );
  }

  /// 长按确认后保存图片（确认框 → 真保存）
  Future<void> _confirmSaveImage() async {
    if (_saving) return;
    // 长按先收起键盘
    _focusNode.unfocus();
    final confirmed = await AppDialogs.showDialog(
      title: '保存二维码',
      content: '将二维码图片保存到系统相册?',
      confirmText: '保存',
      cancelText: '取消',
    );
    if (confirmed != true || !mounted) return;
    await _saveImage();
    // 抵消确认框关闭时的焦点恢复：保存后输入框保持失焦，用户主动点击才重新聚焦
    _focusNode.unfocus();
  }

  /// 保存二维码：PNG 写应用文档目录 qr_codes/<时间戳>.png（保留落盘），
  /// 并同步写入系统相册（gal）；提示以相册结果为准。
  Future<void> _saveImage() async {
    setState(() => _saving = true);
    try {
      final byteData = await _renderQrImage();
      if (byteData == null) {
        throw const FileSystemException('生成二维码图片失败');
      }
      // 应用目录落盘保留（不再作为主提示）
      await _writePng(byteData);
      // 系统相册写入（gal）：成功为主提示；失败仅提示，不影响已落盘文件
      final galleryOk =
          await _saveToGallery(byteData.buffer.asUint8List());
      if (!mounted) return;
      if (galleryOk) {
        AppDialogs.showSuccess('已保存到相册');
      } else {
        AppDialogs.showError('保存到相册失败');
      }
    } catch (e) {
      if (mounted) AppDialogs.showError('保存二维码失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存用画布边长（px）
  static const double _qrSaveSize = 512;

  /// 保存用 QR 与白底之间留白（px）
  static const double _qrSavePadding = 48;

  /// 保存用白底圆角半径（px）
  static const double _qrSaveRadius = 32;

  /// 合成保存用二维码 PNG：512×512 白色圆角背景 + 居中 QR（padding 留白），
  /// 替代 QrPainter.toImageData 的透明背景输出；失败返回 null。
  Future<ByteData?> _renderQrImage() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const rect = Rect.fromLTWH(0, 0, _qrSaveSize, _qrSaveSize);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(_qrSaveRadius)),
      Paint()..color = Colors.white,
    );
    canvas.translate(_qrSavePadding, _qrSavePadding);
    QrPainter(
      data: _text,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
    ).paint(
      canvas,
      const Size(_qrSaveSize - 2 * _qrSavePadding, _qrSaveSize - 2 * _qrSavePadding),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(_qrSaveSize.round(), _qrSaveSize.round());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData;
  }

  /// 将 PNG 字节写入系统相册（gal）。返回是否成功；失败仅记录日志不抛出。
  /// 测试通过 [QrToolPage.debugGallerySucceeds] 注入结果，避免依赖真实相册。
  Future<bool> _saveToGallery(Uint8List bytes) async {
    final injected = QrToolPage.debugGallerySucceeds;
    if (injected != null) return injected;
    try {
      await Gal.putImageBytes(
        bytes,
        name: 'qr_${DateTime.now().millisecondsSinceEpoch}',
      );
      return true;
    } catch (e) {
      appLog.error('QrToolPage: 写入系统相册失败 - $e');
      return false;
    }
  }

  /// 将 PNG 字节写入文档目录 qr_codes/（参照 apk_info_service._saveIconBytes）
  Future<String> _writePng(ByteData byteData) async {
    final dir = await getApplicationDocumentsDirectory();
    final qrDir = Directory('${dir.path}/qr_codes');
    await qrDir.create(recursive: true);
    final file = File('${qrDir.path}/${DateTime.now().millisecondsSinceEpoch}.png');
    await file.writeAsBytes(byteData.buffer.asUint8List());
    debugPrint('QrToolPage: 二维码已保存 - ${file.path}');
    return file.path;
  }

  /// 模式切换：切到识别 → 初始化并启动相机；切回生成 → 释放相机（切回识别再重新初始化）
  void _onModeChanged(QrToolMode mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    if (mode == QrToolMode.scan) {
      unawaited(_initCamera());
    } else {
      unawaited(_releaseCamera(_cameraController));
      _cameraController = null;
    }
  }

  /// 初始化相机：后置优先 → 低分辨率 → 关闭音频 → 启动逐帧图像流。
  /// 任何失败都不崩溃：记录错误、置 [_cameraError] 显示占位、提示用户，保持在识别模式。
  Future<void> _initCamera() async {
    if (_cameraController != null || _cameraInitializing) return;
    setState(() {
      _cameraInitializing = true;
      _cameraError = null;
      _scanningStopped = false;
      _scanHint = '将二维码对准框内';
      // 重新进入识别：丢弃上次的定格帧，回到实时预览
      _capturedFrame?.dispose();
      _capturedFrame = null;
    });
    _eyePoints.clear();
    // 重置自动变焦状态机（去抖计数 + 边界引导），避免跨会话残留
    _zoomBoundaryHint = null;
    try {
      final cameras = await (QrToolPage.debugAvailableCameras?.call() ??
          availableCameras());
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
      // 帧→预览方向：Android 上 CameraImage 是传感器方向（横屏），预览已按 sensorOrientation
      // 旋转成竖屏；解码/码眼/定格须先旋转到同一方向才能「所见即所扫」。
      // iOS 预览输出已竖向（插件内部已处理），不做旋转，仅前置镜像与预览 scaleX:-1 配对。
      _previewQuarterTurns = defaultTargetPlatform == TargetPlatform.android
          ? (desc.sensorOrientation ~/ 90) % 4
          : 0;
      _previewMirrorX = desc.lensDirection == CameraLensDirection.front;
      final controller = CameraController(
        desc,
        // high（≈720p）：远距离小码需要足够像素，medium 下 module 常不足 2px 无法解码。
        // 提分辨率的帧率/CPU 代价由"只解码最新帧"策略吸收。
        ResolutionPreset.high,
        enableAudio: false,
        // 注意：不设 imageFormatGroup（保持默认 YUV420）——CameraX 默认帧即 YUV420，
        // 请求 bgra8888 时转换布局/宽高与 CameraImage 报告值可能不匹配，导致 luma 错乱解码失败。
        // 解码走 Y 平面灰度；定格帧也从 Y 平面构造灰度图。
      );
      await controller.initialize();
      // 变焦范围缓存一次（平台不支持时降级默认 1.0，仅记录日志）
      try {
        _minZoomLevel = await controller.getMinZoomLevel();
        _maxZoomLevel = await controller.getMaxZoomLevel();
      } catch (e) {
        appLog.error('QrToolPage: 读取变焦范围失败（平台不支持则忽略） - $e');
      }
      // 变焦控制器按相机复用（学习结果随相机共享）：切「生成/识别」或重进页面会重新
      // 走这里的初始化，若每次新建控制器，学到的焦段与分档统计就全丢了——真机日志里
      // 表现为 zoom 从 2.86 掉回 1.0、每轮重新爬 ~5 步。
      final cameraKey = desc.name;
      final existing = _zoomController;
      if (existing == null || _zoomControllerCamera != cameraKey) {
        _zoomController = QrZoomController(
          minZoom: _minZoomLevel,
          maxZoom: _maxZoomLevel,
          learning: QrZoomLearning.of(cameraKey),
        );
        _zoomControllerCamera = cameraKey;
      } else {
        // 同相机重开：只刷新倍率范围，保留学习结果
        existing.updateZoomRange(_minZoomLevel, _maxZoomLevel);
      }
      _lastChecksumError = false;
      // 曝光补偿范围（EV）：过曝/欠曝闭环调节的边界；不支持时保持 0..0（闭环自动禁用）
      try {
        _minExposureOffset = await controller.getMinExposureOffset();
        _maxExposureOffset = await controller.getMaxExposureOffset();
      } catch (e) {
        appLog.error('QrToolPage: 读取曝光补偿范围失败（平台不支持则忽略） - $e');
        _minExposureOffset = 0;
        _maxExposureOffset = 0;
      }
      _currentExposureOffset = 0;
      _overExposureStreak = 0;
      _underExposureStreak = 0;
      _consecutiveDecodeFailures = 0;
      _lastRoiSharpness = 0;
      _exposureHint = null;
      // 起始倍率：优先用实测成功倍率，其次 1.0（原生视角）。最小倍率常 <1
      //（实测该机 0.67 超广角），从那里起步只会让码更小、白爬几步。实际下发在相机挂载后。
      _currentZoom = _minZoomLevel;
      final startZoom = _zoomController!.preferredStartZoom;
      // 自动对焦/曝光：连续识别场景下避免锁焦/锁曝光导致越扫越糊；
      // 平台不支持时降级（不中断相机启动）。
      try {
        await controller.setFocusMode(FocusMode.auto);
      } catch (e) {
        appLog.error('QrToolPage: 设置自动对焦失败（平台不支持则忽略） - $e');
      }
      // 主动触发一次对焦（CameraX 会在 setFocusPoint 时重新对焦，
      // 避免初始化后对焦未收敛导致画面模糊；失败忽略不中断启动）
      try {
        await controller.setFocusPoint(const Offset(0.5, 0.5));
      } catch (e) {
        appLog.error('QrToolPage: 触发对焦失败（平台不支持则忽略） - $e');
      }
      try {
        await controller.setExposureMode(ExposureMode.auto);
      } catch (e) {
        appLog.error('QrToolPage: 设置自动曝光失败（平台不支持则忽略） - $e');
      }
      // 曝光点对齐取景区中心：让自动测光偏向二维码所在区域，减少背景强光的影响
      try {
        await controller.setExposurePoint(const Offset(0.5, 0.5));
      } catch (e) {
        appLog.error('QrToolPage: 设置曝光点失败（平台不支持则忽略） - $e');
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _cameraInitializing = false;
      });
      // 下发起始倍率（失败仅记录日志：保底留在最小倍率）
      if ((startZoom - _currentZoom).abs() >= 0.1) {
        await _applyZoom(startZoom);
      }
      await controller.startImageStream(_onFrame);
    } catch (e) {
      appLog.error('QrToolPage: 相机初始化失败 - $e');
      if (!mounted) return;
      setState(() {
        _cameraInitializing = false;
        _cameraError = '相机不可用';
      });
      AppDialogs.showError('无法启动相机，请检查相机权限');
    }
  }

  /// 点按预览重新对焦。坐标映射：取景框（240×240）→ 预览内容区（cover 适配，可能纵向溢出）
  /// 的归一化坐标；前置相机做水平镜像配对。修掉原先"直接 /240"在 cover 裁剪下对不准的问题。
  Future<void> _refocusAt(Offset localPosition) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    final point = _toPreviewNormalized(localPosition);
    try {
      await controller.setFocusPoint(point);
      await controller.setExposurePoint(point);
    } catch (e) {
      appLog.error('QrToolPage: 对焦失败（平台不支持则忽略） - $e');
    }
  }

  /// 点击对焦入口：对焦后再短暂锁焦（用户主动指定了目标，锁 2s 防抖）
  Future<void> _onTapToFocus(Offset local) async {
    await _refocusAt(local);
    _lockFocusBriefly();
  }

  /// 取景框局部坐标 → 预览归一化坐标（setFocusPoint/setExposurePoint 用）。
  /// 取景框是 240×240，预览按 cover 居中裁剪；映射需还原 cover 缩放与镜像。
  Offset _toPreviewNormalized(Offset local) {
    final box = _previewBoxSize;
    final content = _previewContentSize;
    if (box == null || content == null || content.isEmpty) {
      // 尚未完成布局：退回近似（保持可用，不崩）
      return Offset((local.dx / 240).clamp(0.0, 1.0), (local.dy / 240).clamp(0.0, 1.0));
    }
    final originX = (box.width - content.width) / 2;
    final originY = (box.height - content.height) / 2;
    var u = (local.dx - originX) / content.width;
    final v = (local.dy - originY) / content.height;
    if (_previewMirrorX) u = 1 - u;
    return Offset(u.clamp(0.0, 1.0), v.clamp(0.0, 1.0));
  }

  /// 用户主动对焦后短暂锁焦（2s）再回自动，减少连续识别时的对焦抖动；不支持则静默忽略。
  void _lockFocusBriefly() {
    final controller = _cameraController;
    if (controller == null) return;
    _focusLockTimer?.cancel();
    unawaited(() async {
      try {
        await controller.setFocusMode(FocusMode.locked);
      } catch (_) {
        // 平台不支持 locked：忽略
      }
    }());
    _focusLockTimer = Timer(const Duration(seconds: 2), () {
      unawaited(() async {
        final c = _cameraController;
        if (c == null || !c.value.isInitialized) return;
        try {
          await c.setFocusMode(FocusMode.auto);
        } catch (_) {
          // 忽略
        }
      }());
    });
  }

  /// 反馈驱动重对焦：不再固定 1.5s 周期，而是在"画面发虚（锐度低）"或"连续解码失败"时
  /// 才重对焦（限频 ≥1s）；画面清晰时不动，避免屏幕码/暗光下反复"拉风箱"。
  /// 有码眼时对焦码眼几何中心（码在哪对焦哪），无码眼回退画面中心。
  void _maybeAutoRefocus() {
    if (_scanningStopped) return;
    final now = DateTime.now();
    if (now.difference(_lastAutoFocusAt).inMilliseconds < 1000) return;
    final blurry = _lastRoiSharpness > 0 && _lastRoiSharpness < _sharpnessGoodThreshold;
    final failing = _consecutiveDecodeFailures >= 8;
    if (!blurry && !failing) return;
    _lastAutoFocusAt = now;
    final target = _eyePointsCenterInPreview();
    unawaited(_refocusAt(target ?? const Offset(120, 120)));
  }

  /// 当前码眼几何中心在预览窗中的坐标（码眼在 0.75 ROI 内，映射到 240×240 预览窗，
  /// 与 [_computeMappedEyePoints] 同比例；无码眼返回 null）。
  Offset? _eyePointsCenterInPreview() {
    if (_eyePoints.isEmpty) return null;
    final shortSide = _lastFrameW < _lastFrameH ? _lastFrameW : _lastFrameH;
    final side = (shortSide * 0.75).round();
    if (side <= 0) return null;
    const boxSize = 180.0; // 识别框边长（预览窗 240×240 居中，left/top = 30）
    const boxOffset = (240 - boxSize) / 2; // 30
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

  /// 释放相机：停止图像流 + dispose（异常仅记录日志）
  Future<void> _releaseCamera(CameraController? controller) async {
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (e) {
      appLog.error('QrToolPage: 停止图像流失败 - $e');
    }
    try {
      await controller.dispose();
    } catch (e) {
      appLog.error('QrToolPage: 释放相机失败 - $e');
    }
  }

  /// 逐帧回调：防重（上一帧未处理完跳过）→ 异步解码（zxing-cpp via Rust FFI）。
  /// 识别命中 → 回填输入框 + 写识别历史 + 停止图像流。
  void _onFrame(CameraImage image) {
    if (_scanningStopped) return;
    _lastFrameW = image.width;
    _lastFrameH = image.height;
    // 只保留最新帧：处理中到达的新帧覆盖待处理帧（旧实现直接丢帧，有效解码率低）
    _pendingFrame = image;
    if (_drainRunning) return;
    unawaited(_drainFrames());
  }

  /// 解码循环：始终处理最新帧，直到扫描停止或无新帧到达。
  Future<void> _drainFrames() async {
    _drainRunning = true;
    try {
      while (!_scanningStopped) {
        final image = _pendingFrame;
        if (image == null) break;
        _pendingFrame = null;
        // 反馈驱动重对焦（限频在内部）
        _maybeAutoRefocus();
        final stop = await _processFrame(image);
        if (stop) break;
        // 自动变焦放在解码之后：用**同一帧**的几何/checksum 证据决策。
        // 原顺序读的是上一帧证据，会让 checksum 统计串帧（成功那一帧被记成校验失败）。
        if (_eyePoints.isNotEmpty) {
          await _adjustZoomToEyes();
        }
      }
    } catch (e) {
      appLog.error('QrToolPage: 帧调度异常 - $e');
    } finally {
      _drainRunning = false;
      _syncEyePointsOverlay();
    }
  }

  /// 异步处理单帧。返回 true = 应停止扫描（识别成功）。
  Future<bool> _processFrame(CameraImage image) async {
    try {
      final text = await _decodeQr(image);
      if (!mounted) return true;
      if (text != null && text.isNotEmpty) {
        _consecutiveDecodeFailures = 0;
        _onScanSuccess(text, image);
        return true;
      }
      _consecutiveDecodeFailures++;
      _updateScanGuidance();
    } catch (e) {
      appLog.error('QrToolPage: 帧解码异常 - $e');
    }
    return false;
  }

  /// 更新取景框下方引导文案：优先级 变焦边界 > 曝光 > 解码状态。
  /// 解码失败按候选有无区分「检测到但解析失败」/「未检测到」；文案变化才 setState。
  void _updateScanGuidance() {
    // 画面无候选时边界引导失效（码已移出视野），清空恢复常规引导
    if (_eyePoints.isEmpty) {
      _zoomBoundaryHint = null;
    }
    final hint = _zoomBoundaryHint ??
        _exposureHint ??
        (_eyePoints.isNotEmpty
            ? '检测到二维码，请移近/对准框内'
            : '未检测到，请将二维码对准框内');
    if (hint != _scanHint && mounted) {
      setState(() => _scanHint = hint);
    }
  }

  /// 符号四角包围盒占 ROI 面积比；无候选或几何无效返回 0。
  /// 候选坐标统一归一化到 0.75 参考系，ROI 边长同为短边×0.75，故直接与 side² 相比。
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
    final bboxW = maxX - minX;
    final bboxH = maxY - minY;
    if (bboxW <= 0 || bboxH <= 0) return 0;
    return (bboxW * bboxH) / (side * side);
  }

  /// 自动变焦：把逐帧几何/解码证据交给 [QrZoomController]，按决策下发倍率。
  /// 稳定性（EMA 平滑、连续帧共识、动作后静默期、步长阻尼、反冲验证）都在控制器内，
  /// 这里只负责取观测数据、执行动作与记录遥测。
  Future<void> _adjustZoomToEyes() async {
    final controller = _cameraController;
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
          // 变焦改变焦平面：下一帧允许重新对焦（远码小码场景 AF 可能锁在背景）
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
        // 回到滞回带：清掉边界提示，恢复常规解码引导
        if (observation.detected &&
            !zc.isOutOfBand(zc.smoothedRatio) &&
            _zoomBoundaryHint != null) {
          _zoomBoundaryHint = null;
          if (mounted) setState(() {});
        }
    }
  }

  /// 变焦决策遥测：只在真正动作/触边界时记录；导出日志即可看到抖动与收敛过程，
  /// 也是判定「阈值该调到多少」的原始依据。
  ///
  /// 同一动作 ≥1s 才再记一次：`tooFar` 这类**持续状态**会逐帧命中，真机上曾把日志环
  /// （2000 条上限）刷掉上百条，把有价值的记录挤出去。
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
      'emaRatio':
          double.parse((zc?.smoothedRatio ?? 0).toStringAsFixed(3)),
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

  /// 分档实测统计落日志：每个焦段的检测/解码/校验失败/清晰度，供离线调参
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

  /// 设置变焦边界引导文案（仅变化时 setState，避免逐帧重建）
  void _setBoundaryHint(String hint) {
    if (_zoomBoundaryHint == hint) return;
    _zoomBoundaryHint = hint;
    _setScanHint(hint);
  }

  /// 更新扫描引导文案（仅变化时 setState，避免逐帧重建）
  void _setScanHint(String hint) {
    if (!mounted || hint == _scanHint) return;
    setState(() => _scanHint = hint);
  }

  /// 执行变焦：与当前期望 zoom 差 <0.1 跳过（防抖）；返回是否实际变焦成功。
  /// setZoomLevel 为数字变焦（裁剪放大），不改变光学焦平面，但远码场景
  /// AF 可能锁在背景——调用方在变焦后应重新触发对焦（见 _adjustZoomToEyes）。
  Future<bool> _applyZoom(double target) async {
    if ((target - _currentZoom).abs() < 0.1) return false;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return false;
    try {
      await controller.setZoomLevel(target);
      _currentZoom = target;
      return true;
    } catch (e) {
      appLog.error('QrToolPage: 设置变焦失败（平台不支持则忽略） - $e');
      return false;
    }
  }

  /// 将码眼 ROI 裁切坐标映射到 240×240 预览窗坐标：
  /// 解码 ROI 为帧中心正方形（边长 side = 帧短边×0.75），识别框 180×180 在预览窗中心
  /// （left/top = 30），ROI 与识别框 1:1 对应 → 预览坐标 = 30 + p × (180 / side)。
  List<Offset> _computeMappedEyePoints(int w, int h) {
    if (_eyePoints.isEmpty || w <= 0 || h <= 0) return const [];
    final side = ((w < h ? w : h) * 0.75).round();
    if (side <= 0) return const [];
    const boxSize = 180.0; // 识别框边长（预览窗 240×240 居中，left/top = 30）
    const boxOffset = (240 - boxSize) / 2; // 30
    final scale = boxSize / side; // ROI 内坐标 → 识别框内坐标
    return [
      for (final p in _eyePoints)
        Offset(boxOffset + p.dx * scale, boxOffset + p.dy * scale),
    ];
  }

  /// 码眼映射点同步到 [_mappedEyePoints]（仅变化时 setState，避免逐帧重建）
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

  /// 解码单帧：取 YUV420 首平面（Y）灰度 → **旋转到预览方向**（见 [_previewQuarterTurns]/
  /// [_previewMirrorX]）→ 依次尝试多个中心正方形 ROI → 交 Rust zxing-cpp 解码（内部还会做
  /// 对比度拉伸/CLAHE/锐化 + 多二值化重试）。
  /// 多 ROI：0.75 主取景区（与识别框 180/240 严格 1:1）、0.45 远距离小码、0.95 兜底大码。
  /// 解码前清空码候选；zxing-cpp 返回的 4 角定位点写入 [_eyePoints]（"检测到但不可读"
  /// 时同样返回，供失败引导/自动变焦判断），坐标统一归一化到 0.75 参考系。
  static const List<double> _roiFractions = <double>[0.75, 0.45, 0.95];

  Future<String?> _decodeQr(CameraImage image) async {
    if (image.planes.isEmpty) return null;
    final (data, w, h) = _extractLumaRotated(image);
    if (w <= 0 || h <= 0 || data.length < w * h) return null;
    final shortSide = w < h ? w : h;
    // 0.75 参考系：码眼坐标统一归一化到此坐标系，供叠加绘制与自动变焦复用
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
      // ROI 紧凑拷贝（旋转后 data 为紧凑布局，row_stride == w）
      final roi = Uint8List(side * side);
      for (var y = 0; y < side; y++) {
        roi.setRange(y * side, (y + 1) * side, data, (top + y) * w + left);
      }

      // 光照/锐度反馈只在主取景区做（避免多 ROI 重复测光造成抖动）
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

      // 成功判定优先看 isValid：校验失败的候选即使带了部分文本也不能当成结果
      // （把含部分文本的无效码当成功返回，正是"识别错误"的一种来源）。
      // 旧版模块无 isValid 字段时回退到「无错误类型 + text 非空」，行为与改动前一致。
      final decoded =
          result.isValid || (result.error.isEmpty && result.text.isNotEmpty);
      if (decoded) {
        // 命中：只保留命中 ROI 的四角，避免与先前候选角点混叠
        _eyePoints
          ..clear()
          ..addAll(corners);
        return result.text;
      }

      // 定位到但不可读：保留候选角点供引导与变焦使用，并**继续尝试其余 ROI**。
      // （原实现在此直接 return null，等于放弃 0.45/0.95 两个 ROI，白丢识别率。）
      _lastChecksumError = _lastChecksumError || result.isChecksumFailure;
      if (_eyePoints.isEmpty) _eyePoints.addAll(corners);
    }
    return null;
  }

  /// 曝光反馈：统计参考 ROI 的亮度均值与近饱和占比，驱动曝光补偿闭环。
  void _updateExposureFeedback(Uint8List roi) {
    if (roi.isEmpty) return;
    var sum = 0;
    var saturated = 0;
    var n = 0;
    // 步长 4 采样：足以代表亮度分布，成本极低
    for (var i = 0; i < roi.length; i += 4) {
      final v = roi[i];
      sum += v;
      if (v >= 250) saturated++;
      n++;
    }
    if (n == 0) return;
    final mean = sum / n;
    final satRatio = saturated / n;

    // 过曝：高光连片（屏幕码/反光）或整体偏亮
    _overExposureStreak = (satRatio > 0.06 || mean > 190) ? _overExposureStreak + 1 : 0;
    // 欠曝：整体偏暗（暗光）
    _underExposureStreak = mean < 55 ? _underExposureStreak + 1 : 0;

    _maybeAdjustExposure();

    // 光照恢复正常：清除环境提示（引导回到解码状态）
    if (_overExposureStreak == 0 &&
        _underExposureStreak == 0 &&
        _exposureHint != null) {
      _exposureHint = null;
      _updateScanGuidance();
    }
  }

  /// 依据连续过曝/欠曝判据调节曝光补偿（限频 ≥400ms）；到补偿边界则给出环境引导。
  void _maybeAdjustExposure() {
    // 平台不支持曝光补偿（范围退化为 0..0）→ 禁用闭环，避免误报引导
    if (_minExposureOffset == 0 && _maxExposureOffset == 0) return;
    final now = DateTime.now();
    if (now.difference(_lastExposureAdjustAt).inMilliseconds < 400) return;

    if (_overExposureStreak >= 3) {
      _overExposureStreak = 0;
      _lastExposureAdjustAt = now;
      final next = (_currentExposureOffset - 0.5).clamp(_minExposureOffset, _maxExposureOffset);
      if ((next - _currentExposureOffset).abs() < 0.01) {
        _setExposureHint('光线过曝，请调低屏幕亮度或避开反光');
      } else {
        unawaited(_applyExposureOffset(next));
      }
    } else if (_underExposureStreak >= 6) {
      _underExposureStreak = 0;
      _lastExposureAdjustAt = now;
      final next = (_currentExposureOffset + 0.5).clamp(_minExposureOffset, _maxExposureOffset);
      if ((next - _currentExposureOffset).abs() < 0.01) {
        _setExposureHint('光线太暗，请移到明亮处');
      } else {
        unawaited(_applyExposureOffset(next));
      }
    }
  }

  Future<void> _applyExposureOffset(double value) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if ((value - _currentExposureOffset).abs() < 0.01) return;
    try {
      await controller.setExposureOffset(value);
      _currentExposureOffset = value;
      if (_exposureHint != null) {
        _exposureHint = null; // 补偿已生效，清除环境提示
        _updateScanGuidance();
      }
    } catch (e) {
      appLog.error('QrToolPage: 调整曝光补偿失败（平台不支持则忽略） - $e');
    }
  }

  void _setExposureHint(String hint) {
    if (_exposureHint == hint) return;
    _exposureHint = hint;
    _updateScanGuidance();
  }

  /// ROI 锐度（相邻像素梯度均值）：反馈驱动重对焦判据，无额外内存分配。
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

  /// 从 YUV420 首平面（Y）抽取灰度并把帧**旋转/镜像到预览方向**。
  /// 返回 (预览方向灰度, 旋转后宽, 旋转后高)。
  /// - 旋转：顺时针 [_previewQuarterTurns]×90°（与 CameraPreview 的 RotatedBox 一致）；
  /// - 镜像：前置相机预览 scaleX:-1，解码配对水平翻转（否则镜像图像无法识别）。
  /// 旋转/镜像逻辑复用可单测的 [QrToolPage.rotateLumaToPreview]。
  (Uint8List, int, int) _extractLumaRotated(CameraImage image) {
    final plane = image.planes[0];
    final w = image.width;
    final h = image.height;
    final rowStride = plane.bytesPerRow;
    final bytes = plane.bytes;
    // 源紧凑灰度（处理 bytesPerRow 行对齐 padding）
    final src = Int8List(w * h);
    if (rowStride == w) {
      src.setAll(0, bytes);
    } else {
      for (var y = 0; y < h; y++) {
        src.setRange(y * w, (y + 1) * w, bytes, y * rowStride);
      }
    }
    return QrToolPage.rotateLumaToPreview(
      src.buffer.asUint8List(src.offsetInBytes, src.lengthInBytes),
      w,
      h,
      quarterTurns: _previewQuarterTurns,
      mirrorX: _previewMirrorX,
    );
  }

  /// 识别命中：定格保存当帧 + 回填输入框 + 写入识别历史（去重置顶、上限、持久化）+ 停止图像流
  void _onScanSuccess(String text, CameraImage image) {
    _scanningStopped = true;
    // 数据支撑：记录「该焦段 + 该尺寸确实解出过码」，并落一次分档统计供离线调参
    _zoomController?.onDecoded(_currentZoom, _symbolRatio());
    _logZoomBuckets();
    // 定格保存识别到的那一帧（BGR888 → RGBA8888 后交给 ui.Image，供预览窗定格显示）
    _captureFreezeFrame(image);
    final controller = _cameraController;
    if (controller != null && controller.value.isStreamingImages) {
      unawaited(controller.stopImageStream().catchError((Object e) {
        appLog.error('QrToolPage: 停止图像流失败 - $e');
      }));
    }
    _historyDebounce?.cancel();
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
    setState(() {
      _text = text;
      _scanHistory = [text, ..._scanHistory.where((e) => e != text)]
          .take(_historyLimit)
          .toList();
    });
    unawaited(_persistScanHistory());
    AppDialogs.showSuccess('已识别二维码');
  }

  /// 把识别成功那一帧转成可显示图片：YUV420 三平面 → **彩色 RGB**，再旋转/镜像到预览方向
  /// （与 [_buildCameraPreview] 显示一致，避免黑白、方向相反的问题）。
  /// 失败仅记录日志（不影响识别结果与历史）；生成后 setState 交给预览窗渲染。
  void _captureFreezeFrame(CameraImage image) {
    if (image.planes.length < 3) {
      // 仅 Y 平面（非标准 YUV420）时降级灰度静态帧，方向仍统一到预览
      _captureFreezeFrameGrayscale(image);
      return;
    }
    final w = image.width, h = image.height;
    final yPlane = image.planes[0], uPlane = image.planes[1], vPlane = image.planes[2];
    // 先按当前（传感器）方向转全帧彩色 RGB → 再旋转/镜像到预览方向
    final rgb = Uint8List(w * h * 4); // RGBA
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final yi = yPlane.bytesPerRow == w
            ? y * w + x
            : y * yPlane.bytesPerRow + x;
        final ui = uPlane.bytesPerRow == (w / 2).ceil()
            ? (y ~/ 2) * (w ~/ 2) + x ~/ 2
            : (y ~/ 2) * uPlane.bytesPerRow + x ~/ 2;
        final vi = vPlane.bytesPerRow == (w / 2).ceil()
            ? (y ~/ 2) * (w ~/ 2) + x ~/ 2
            : (y ~/ 2) * vPlane.bytesPerRow + x ~/ 2;
        final yv = yPlane.bytes[yi];
        final u = uPlane.bytes[ui] - 128;
        final v = vPlane.bytes[vi] - 128;
        // BT.601 full-range YUV→RGB
        final r = yv + (1.402 * v).round();
        final g = yv - (0.344 * u).round() - (0.714 * v).round();
        final b = yv + (1.772 * u).round();
        final di = (y * w + x) * 4;
        rgb[di] = r.clamp(0, 255);
        rgb[di + 1] = g.clamp(0, 255);
        rgb[di + 2] = b.clamp(0, 255);
        rgb[di + 3] = 0xFF;
      }
    }
    final (rotated, rw, rh) = _rotateRgbaToPreview(rgb, w, h);
    try {
      ui.decodeImageFromPixels(
        rotated,
        rw,
        rh,
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
      appLog.error('QrToolPage: 定格帧生成失败（忽略） - $e');
    }
  }

  /// RGBA8888（4 字节/像素）旋转/镜像到预览方向——复用可单测的
  /// [QrToolPage.rotateLumaToPreview]（bytesPerPixel=4）
  (Uint8List, int, int) _rotateRgbaToPreview(Uint8List src, int w, int h) {
    return QrToolPage.rotateLumaToPreview(
      src,
      w,
      h,
      quarterTurns: _previewQuarterTurns,
      mirrorX: _previewMirrorX,
      bytesPerPixel: 4,
    );
  }

  /// 降级：仅 Y 平面时构造灰度定格帧（同样旋转到预览方向）
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
    try {
      ui.decodeImageFromPixels(
        rotated,
        rw,
        rh,
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
      appLog.error('QrToolPage: 定格帧生成失败（忽略） - $e');
    }
  }

  /// 重新扫描：图像流已停止时重新启动
  Future<void> _restartScan() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isStreamingImages) return;
    setState(() {
      _scanningStopped = false;
      _scanHint = '将二维码对准框内';
      // 清掉定格帧，预览回到实时相机画面
      _capturedFrame?.dispose();
      _capturedFrame = null;
    });
    _eyePoints.clear();
    _mappedEyePoints.clear();
    // 重置变焦瞬态（平滑/共识/静默/反冲验证 + 边界引导）；分档统计跨轮保留
    _zoomController?.resetTransient();
    _zoomBoundaryHint = null;
    // 重置解码/曝光/对焦状态（新一轮扫码从干净状态开始）
    _pendingFrame = null;
    _consecutiveDecodeFailures = 0;
    _overExposureStreak = 0;
    _underExposureStreak = 0;
    _exposureHint = null;
    _lastRoiSharpness = 0;
    _lastAutoFocusAt = DateTime.fromMillisecondsSinceEpoch(0);
    _lastExposureAdjustAt = DateTime.fromMillisecondsSinceEpoch(0);
    // 若此前点按锁过焦，先解除再回自动（避免新一轮沿用锁定焦平面）
    _focusLockTimer?.cancel();
    try {
      await controller.setFocusMode(FocusMode.auto);
    } catch (_) {
      // 平台不支持：忽略
    }
    // 起始倍率回到「实测成功过的那一档」（无记录时 1.0），而不是打回最小倍率。
    // 实测：每轮成功扫码后回到 minZoom(0.67) 要从头爬 5 步左右才又能解码，学习成果白丢。
    final startZoom = _zoomController?.preferredStartZoom ?? _minZoomLevel;
    if ((_currentZoom - startZoom).abs() > 0.1) {
      await _applyZoom(startZoom);
    } else {
      _currentZoom = startZoom;
    }
    try {
      await controller.startImageStream(_onFrame);
    } catch (e) {
      appLog.error('QrToolPage: 重新扫描失败 - $e');
      if (mounted) AppDialogs.showError('重新扫描失败');
    }
  }

  /// 清除输入与内容（取消待写的历史防抖计时；识别模式下同时清掉定格帧）
  void _clear() {
    _historyDebounce?.cancel();
    _controller.clear();
    setState(() {
      _text = '';
      _capturedFrame?.dispose();
      _capturedFrame = null;
    });
  }
}

/// 码眼预览绘制：在 240×240 预览窗上绘制码眼映射点（实心小圆点 + 描边提高可见性）。
/// 坐标由 [_QrToolPageState._mappedEyePoints] 提供（帧坐标 → 预览窗 cover 近似映射）。
class _EyePointsPainter extends CustomPainter {
  _EyePointsPainter({required this.points, required this.color});

  /// 码眼在预览窗中的坐标列表
  final List<Offset> points;

  /// 码眼颜色（主题 primary）
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

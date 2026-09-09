import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, listEquals;
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:gstore/core/core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zxing2/qrcode.dart';

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

  /// 帧解码防重：上一帧未处理完时跳过新帧
  bool _processingFrame = false;

  /// 已识别一次即停（避免连续触发）：true 时不再处理新帧，显示「重新扫描」入口
  bool _scanningStopped = false;

  /// 识别成功当帧解码出的可显示图（BGRA→RGBA 经 [ui.decodeImageFromPixels]，
  /// 预览窗定格显示用；重新扫描/清除/销毁时 dispose 清空）
  ui.Image? _capturedFrame;

  /// 最近一帧解码收集的码眼候选点（zxing2 [DecodeHintType.needResultPointCallback]
  /// 逐候选点回调追加；每次解码前清空，解码后保留供失败引导判断）
  final List<ResultPoint> _eyePoints = [];

  /// 最近一帧码眼映射到 240×240 预览窗的坐标（空则不绘制；随帧刷新仅变化时 setState）
  final List<Offset> _mappedEyePoints = [];

  /// 最近一帧图像尺寸（码眼包围盒占 0.75 ROI 面积比例估算用）
  int _lastFrameW = 0;
  int _lastFrameH = 0;

  /// 当前生效变焦倍率（自动变焦防抖基准：相邻期望差值 <0.05 跳过）
  double _currentZoom = 0;

  /// 变焦范围（initialize 后缓存一次；平台不支持时保持 1.0）
  double _minZoomLevel = 1;
  double _maxZoomLevel = 1;

  /// 数字变焦有效上限：CameraX 放大为 crop+上采样，不增加细节，过度放大只会更糊且无解码收益。
  /// 放大目标一律 clamp 到 [minZoom, min(maxZoom, 此上限)]。
  static const double _zoomDigitalCap = 3.0;

  /// 自动变焦目标区间（bbox 占 0.75 ROI 面积比例）与去抖参数：
  /// 占比 < [_zoomInRatio] → 放大；> [_zoomOutRatio] → 缩小；介于两者之间为滞回带不动，
  /// 避免临界抖动。连续超界 [_zoomDebounceFrames] 帧才真正动作一次（单帧噪声不影响）。
  static const double _zoomInRatio = 0.25;
  static const double _zoomOutRatio = 0.50;
  static const int _zoomDebounceFrames = 4;

  /// 自动变焦去抖：连续超界帧计数（累计到 [_zoomDebounceFrames] 才触发一次变焦）
  int _zoomOutOfRangeFrames = 0;

  /// 上一次有效变焦动作时间（变焦时间限频：两次调整至少间隔此值，避免镜头频繁微动）
  DateTime _lastZoomAdjustAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 上一次自动重新对焦时间（周期对焦限频：每 ~1.5s 触发一次中心对焦，
  /// 补偿 CameraX 一次性 AF 不持续跟焦导致的扫描中焦距漂移）
  DateTime _lastAutoFocusAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 上一次码眼包围盒占比（记忆：单码眼时没有包围盒，借“上次数”与「此前是否偏大」
  /// 判断该缩小还是放大——3 码眼占比大掉到 1 码眼 = 放大过头 → 缩小；一直单码眼 = 太小 → 放大）
  double _lastEyesRatio = 0;

  /// 上一次码眼数量（与 [_lastEyesRatio] 一起用于单码眼场景的方向判定）
  int _lastEyeCount = 0;

  /// 自动变焦边界引导文案（非空 = 已到变焦边界仍偏离目标，如「请靠近一点」「请拿远一点」）。
  /// 解码失败引导（_onFrame catch）不覆盖它；条件解除（方向归滞回带/变焦成功动作）时清空。
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
      // 悬浮清除：恒可点（空输入为无操作），heroTag 防冲突
      floatingActionButton: FloatingActionButton.small(
        tooltip: '清除',
        heroTag: 'qr_tool_clear',
        onPressed: _clear,
        child: const Icon(Icons.clear),
      ),
      body: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 二维码预览区 / 相机识别预览区（flex 2；高度充足时原尺寸居中，键盘压缩时等比缩小完整可见）
            Expanded(flex: 2, child: _buildQrArea(context)),

            // 历史记录区（固定高，不参与 flex，横向滚动 chips；数据源随模式切换）
            if (_activeHistory.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(height: 64, child: _buildHistory(context)),
              const SizedBox(height: AppSpacing.sm),
            ],

            // 输入区（flex 1 ≈ 剩余空间，撑开多行输入）
            Expanded(
              flex: 1,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
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
          ],
        ),
      ),
    );
  }

  /// 历史记录区：标题（含清空）+ 固定高横向滚动 chips；数据源随模式切换
  Widget _buildHistory(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final history = _activeHistory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _mode == QrToolMode.scan ? '识别历史' : '历史记录',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colorScheme.outline,
                  ),
            ),
            TextButton.icon(
              onPressed: _clearHistory,
              icon: const Icon(Icons.delete_outline, size: AppTypography.iconSM),
              label: const Text('清空'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Expanded(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: history.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, index) {
              final item = history[index];
              return ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: ActionChip(
                  label: Text(item, overflow: TextOverflow.ellipsis),
                  onPressed: () => _applyHistory(item),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 二维码预览区：生成模式显示占位/二维码；识别模式显示相机实时预览 + 识别框
  Widget _buildQrArea(BuildContext context) {
    if (_mode == QrToolMode.scan) {
      return _buildScanArea(context);
    }
    return Center(
      child: FittedBox(
        fit: BoxFit.contain,
        child: _text.isEmpty ? _buildPlaceholder(context) : _buildQr(),
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
                        onTapDown: (d) => _refocusAt(d.localPosition),
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
      child: _cameraInitializing
          ? const AppLoading(size: AppLoadingSize.medium)
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
    // 重置自动变焦状态机（去抖计数 + 趋势记忆），避免跨会话残留
    _zoomOutOfRangeFrames = 0;
    _lastEyesRatio = 0;
    _lastEyeCount = 0;
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
        ResolutionPreset.medium,
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
      // 变焦防抖基准：以最小倍率为起点（后续期望差 <0.05 才真正 setZoomLevel）
      _currentZoom = _minZoomLevel;
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
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _cameraController = controller;
        _cameraInitializing = false;
      });
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

  /// 点按预览触发重新对焦（CameraX 的 setFocusPoint 主动触发对焦；坐标归一化 0-1，
  /// 失败仅记录日志——不支持的平台忽略，不阻断扫码）
  Future<void> _refocusAt(Offset localPosition) async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.setFocusPoint(Offset(
        (localPosition.dx / 240).clamp(0.0, 1.0),
        (localPosition.dy / 240).clamp(0.0, 1.0),
      ));
    } catch (e) {
      appLog.error('QrToolPage: 点按对焦失败（平台不支持则忽略） - $e');
    }
  }

  /// 周期性自动重新对焦（每 1.5s 一次中心对焦）：CameraX 的 setFocusMode(auto) 只触发
  /// 一次对焦动作，不持续跟焦；长时间扫描焦距漂移 → 模糊 → 解码率骤降。
  /// 主动 setFocusPoint(0.5, 0.5) 会让 CameraX 重新发起自动对焦，保持镜头收敛。
  /// 限频避免对焦动作过于频繁；扫描已停止（识别成功）时不再触发。
  void _maybeAutoRefocus() {
    if (_scanningStopped) return;
    final now = DateTime.now();
    if (now.difference(_lastAutoFocusAt).inMilliseconds < 1500) return;
    _lastAutoFocusAt = now;
    unawaited(_refocusAt(const Offset(120, 120))); // 中心点
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

  /// 逐帧回调：防重（上一帧未处理完跳过）→ YUV→灰度 → zxing2 解码。
  /// 未识别异常忽略继续下一帧；识别命中 → 回填输入框 + 写识别历史 + 停止图像流。
  void _onFrame(CameraImage image) {
    if (_processingFrame || _scanningStopped) return;
    _processingFrame = true;
    _lastFrameW = image.width;
    _lastFrameH = image.height;
    try {
      // 周期性重新对焦：CameraX 的 setFocusMode(auto) 只触发一次自动对焦动作，
      // 不会持续跟焦——长时间扫描（移近/移远/稳定后）焦距会漂移导致画面模糊、
      // 解码率骤降。这里每 ~1.5s 主动用 setFocusPoint 重新触发一次中心对焦，
      // 保证扫码过程中镜头持续收敛（平台不支持/异常仅记录日志，不影响解码）。
      _maybeAutoRefocus();

      // 码眼自动变焦：≥1 码眼即进入状态机评估（单码眼也借"趋势记忆"区分远近，
      // 见 _adjustZoomToEyes；内部有连续帧去抖 + 时间限频；不阻断解码，平台不支持/异常仅记录日志）
      if (_eyePoints.isNotEmpty) {
        unawaited(_adjustZoomToEyes());
      }
      final text = _decodeQr(image);
      if (text != null && text.isNotEmpty) {
        _onScanSuccess(text, image);
      }
    } catch (e) {
      // 单帧解码失败：按码眼有无区分引导——有码眼候选（≥3）说明检测到但解析失败，
      // 提示移近/对准；一个都没有说明没看到二维码。
      // 若处于变焦边界引导（_zoomBoundaryHint 非空，如「请靠近一点」「请拿远一点」），
      // 保持边界提示优先，不覆盖。文案变化才 setState，避免逐帧重建。
      if (_zoomBoundaryHint == null) {
        final hint = _eyePoints.length >= 3
            ? '检测到二维码，请移近/对准框内'
            : '未检测到，请将二维码对准框内';
        if (mounted && hint != _scanHint) {
          setState(() => _scanHint = hint);
        }
      }
    } finally {
      _processingFrame = false;
    }
    // 码眼映射点随帧刷新（仅变化时 setState，避免逐帧重建）
    _syncEyePointsOverlay();
  }

  /// 码眼自动变焦（闭环状态机）：
  /// - **触发**：≥1 码眼即评估（原 ≥3 才动，导致"1~2 码眼完全不管"=只会放大的根因）；
  /// - **判据**：码眼包围盒占 0.75 ROI 面积比例——占比 <[_zoomInRatio] 放大、>[_zoomOutRatio]
  ///   缩小，中间为滞回带不动（临界防抖）。单码眼无包围盒时借"趋势记忆"分远近：
  ///   此前 3 码眼且占比偏大→掉到 1 码眼 = 放大过头 → **缩小**；一直单码眼 = 码太小 → **放大**；
  /// - **去抖**：连续超界 [_zoomDebounceFrames] 帧才真正动作一次；两次动作间隔 ≥150ms；与
  ///   [_applyZoom] 0.05 差值防抖叠加，避免镜头持续抖动；
  /// - **数字变焦上限**：目标 clamp 到 [_minZoomLevel, min(_maxZoomLevel, _zoomDigitalCap)]；
  /// - **边界引导**：已到上限仍该放大 → 提示「靠近一点」；已到最小仍该缩小 → 「拿远一点」。
  Future<void> _adjustZoomToEyes() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (_lastFrameW <= 0 || _lastFrameH <= 0) return;
    final eyes = _eyePoints;
    if (eyes.isEmpty) return;
    // 解码 ROI 为**中心正方形**（边长 = 帧短边×0.75），码眼坐标即该 ROI 内坐标，
    // 包围盒占比直接与 side×side 比（旋转不改变短边，短边×0.75 与旋转前一致）。
    final shortSide = _lastFrameW < _lastFrameH ? _lastFrameW : _lastFrameH;
    final side = (shortSide * 0.75).round();
    if (side <= 0) return;

    // 计算当前码眼包围盒占比（≥2 码眼才有；单码眼时用趋势记忆判方向）
    double? ratio;
    if (eyes.length >= 2) {
      var minX = double.infinity, minY = double.infinity;
      var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
      for (final p in eyes) {
        if (p.x < minX) minX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.x > maxX) maxX = p.x;
        if (p.y > maxY) maxY = p.y;
      }
      final bboxW = maxX - minX;
      final bboxH = maxY - minY;
      if (bboxW > 0 && bboxH > 0) {
        ratio = (bboxW * bboxH) / (side * side);
        _lastEyesRatio = ratio;
      }
    }

    // 方向判定：none=在滞回带内不动
    String? direction;
    if (ratio != null) {
      if (ratio < _zoomInRatio) {
        direction = 'zoomIn';
      } else if (ratio > _zoomOutRatio) {
        direction = 'zoomOut';
      }
    } else if (eyes.length == 1) {
      // 单码眼（本帧无包围盒）：此前 ≥2 码眼且占比偏大 → 掉到 1 个 = 放大过头
      //（其余码眼被移出 ROI）→ **缩小**寻回完整；否则（一直单码眼）= 码太小/太远 → **放大**。
      direction = (_lastEyeCount >= 2 && _lastEyesRatio >= _zoomInRatio)
          ? 'zoomOut'
          : 'zoomIn';
    }
    // 记录本次码眼数量供下一帧用作“上次”趋势记忆（必须在方向判定之后，否则读不到旧值）
    _lastEyeCount = eyes.length;
    if (direction == null) {
      _zoomOutOfRangeFrames = 0; // 回到滞回带：清去抖计数
      // 目标已居中：若此前有边界提示则清除（回到常规解码引导文案）
      if (_zoomBoundaryHint != null) {
        _zoomBoundaryHint = null;
        if (mounted) setState(() {}); // 让 _scanHint 恢复常规文案由 _onFrame catch 更新
      }
      return;
    }

    // 连续帧去抖 + 时间限频（避免每帧微动）
    final now = DateTime.now();
    if (now.difference(_lastZoomAdjustAt) < const Duration(milliseconds: 150)) {
      return;
    }
    _zoomOutOfRangeFrames++;
    if (_zoomOutOfRangeFrames < _zoomDebounceFrames) return;
    _zoomOutOfRangeFrames = 0;
    _lastZoomAdjustAt = now;

    final base = _currentZoom > 0 ? _currentZoom : 1.0;
    // 有效放大上限 = min(平台 maxZoom, 数字变焦上限)；目标一律 clamp 到 [minZoom, 该上限]
    final effectiveMax = _maxZoomLevel < _zoomDigitalCap
        ? _maxZoomLevel
        : _zoomDigitalCap;
    if (direction == 'zoomIn') {
      if (base >= effectiveMax - 0.01) {
        // 已到数字变焦上限仍偏小 → 引导靠近（放大无收益）
        if (_zoomBoundaryHint != '请靠近一点') {
          _zoomBoundaryHint = '请靠近一点';
          _setScanHint('请靠近一点');
        }
        return;
      }
      _zoomBoundaryHint = null;
      await _applyZoom((base * 1.2).clamp(_minZoomLevel, effectiveMax));
    } else {
      if (base <= _minZoomLevel + 0.01) {
        // 已缩到最小仍偏大 → 引导拿远（无法更小）
        const hint = '请拿远一点，让二维码完整入框';
        if (_zoomBoundaryHint != hint) {
          _zoomBoundaryHint = hint;
          _setScanHint('请拿远一点，让二维码完整入框');
        }
        return;
      }
      _zoomBoundaryHint = null;
      await _applyZoom((base * 0.8).clamp(_minZoomLevel, effectiveMax));
    }
  }

  /// 更新扫描引导文案（仅变化时 setState，避免逐帧重建）
  void _setScanHint(String hint) {
    if (!mounted || hint == _scanHint) return;
    setState(() => _scanHint = hint);
  }

  /// 执行变焦：与当前期望 zoom 差 <0.05 跳过（防抖）；平台不支持/异常仅记录日志
  Future<void> _applyZoom(double target) async {
    if ((target - _currentZoom).abs() < 0.05) return;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.setZoomLevel(target);
      _currentZoom = target;
    } catch (e) {
      appLog.error('QrToolPage: 设置变焦失败（平台不支持则忽略） - $e');
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
        Offset(boxOffset + p.x * scale, boxOffset + p.y * scale),
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
  /// [_previewMirrorX]）→ 取**中心正方形 ROI**（边长 = 短边×0.75，与识别框 180/240 严格 1:1，
  /// 预览 FittedBox cover 显示的正是旋转图中心短边正方形区域）→ RGBLuminanceSource →
  /// GlobalHistogramBinarizer → QRCodeReader。
  /// 仅解码中心区域排除框外干扰；解码前清空码眼候选，解码过程中通过 ResultPointCallback
  /// 实时收集码眼点（即使最终失败也能拿到，供失败引导判断）。
  String? _decodeQr(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final (data, w, h) = _extractLumaRotated(image);
    // 中心正方形 ROI：边长 = 短边×0.75（对应识别框 180/240，预览与解码 1:1）
    final side = ((w < h ? w : h) * 0.75).round();
    if (side <= 0 || side > w || side > h) return null;
    final left = (w - side) ~/ 2;
    final top = (h - side) ~/ 2;
    // zxing2 的 RGBLuminanceSource 需要 Int8List；旋转结果 Uint8List → 视图零拷贝转换
    final luma = data.buffer.asInt8List(data.offsetInBytes, data.lengthInBytes);
    final source = RGBLuminanceSource.crop(luma, w, h, left, top, side, side);
    final bitmap = BinaryBitmap(GlobalHistogramBinarizer(source));
    _eyePoints.clear();
    final hints = DecodeHints()
      ..put(
        DecodeHintType.needResultPointCallback,
        (ResultPoint p) => _eyePoints.add(p),
      );
    return QRCodeReader().decode(bitmap, hints: hints).text;
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
    // 重置自动变焦状态机（去抖计数 + 趋势记忆），重新扫码从默认倍率重新评估
    _zoomOutOfRangeFrames = 0;
    _lastEyesRatio = 0;
    _lastEyeCount = 0;
    _zoomBoundaryHint = null;
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

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show listEquals;
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

  /// 识别框下方引导文案：解码失败时按码眼有无区分「检测到但解析失败」/「未检测到」，
  /// 默认提示「将二维码对准框内」（扫描区初始与重新扫描时复位）
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
        // 生成/识别分段切换移入导航头标题位（紧凑密度适配 AppBar 高度）
        title: AppSegmentedButton<QrToolMode>(
          value: _mode,
          segments: const [
            AppSegment(
              value: QrToolMode.generate,
              label: '生成二维码',
              icon: Icons.qr_code_2,
            ),
            AppSegment(
              value: QrToolMode.scan,
              label: '识别二维码',
              icon: Icons.qr_code_scanner,
            ),
          ],
          onChanged: _onModeChanged,
          density: VisualDensity.compact,
        ),
        actions: [
          IconButton(
            tooltip: '清除',
            icon: const Icon(Icons.clear),
            onPressed: _text.isEmpty ? null : _clear,
          ),
        ],
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
                    // 相机预览：CameraPreview 内部已按屏幕方向处理比例（竖屏 1/aspectRatio），
                    // 外层仅用 FittedBox cover 等比裁切适配 240×240 窗口，避免双重换算比例错乱
                    if (controller.value.aspectRatio > 0)
                      FittedBox(
                        fit: BoxFit.cover,
                        clipBehavior: Clip.hardEdge,
                        child: SizedBox(
                          width: 240,
                          height: 240,
                          child: _buildCameraPreview(controller),
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
    });
    _eyePoints.clear();
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
      final controller =
          CameraController(desc, ResolutionPreset.low, enableAudio: false);
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
      // 码眼自动变焦：≥3 码眼时按包围盒占比引导缩放（使用上一帧收集的码眼；
      // 不阻断解码，平台不支持/异常仅记录日志）
      if (_eyePoints.length >= 3) {
        unawaited(_adjustZoomToEyes());
      }
      final text = _decodeQr(image);
      if (text != null && text.isNotEmpty) {
        _onScanSuccess(text);
      }
    } catch (e) {
      // 单帧解码失败：按码眼有无区分引导——有码眼候选（≥3）说明检测到但解析失败，
      // 提示移近/对准；一个都没有说明没看到二维码。文案变化才 setState，避免逐帧重建。
      final hint = _eyePoints.length >= 3
          ? '检测到二维码，请移近/对准框内'
          : '未检测到，请将二维码对准框内';
      if (mounted && hint != _scanHint) {
        setState(() => _scanHint = hint);
      }
    } finally {
      _processingFrame = false;
    }
    // 码眼映射点随帧刷新（仅变化时 setState，避免逐帧重建）
    _syncEyePointsOverlay();
  }

  /// 码眼自动变焦：由 3 码眼包围盒面积占 0.75 ROI 帧面积的比例估算覆盖占比——
  /// 占比过小（<0.08，二维码偏小）放大 ×1.3；过大（>0.5，未对准/过大）缩小 ×0.8；
  /// 目标倍率 clamp 到 [getMinZoomLevel, getMaxZoomLevel] 缓存值，
  /// 与当前期望 zoom 差值 <0.05 跳过（防抖，避免镜头持续抖动）。
  Future<void> _adjustZoomToEyes() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (_lastFrameW <= 0 || _lastFrameH <= 0) return;
    final eyes = _eyePoints;
    if (eyes.length < 3) return;
    // 码眼包围盒（zxing2 回调坐标为 0.75 ROI 裁切后坐标，直接与 ROI 尺寸比）
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
    if (bboxW <= 0 || bboxH <= 0) return;
    const roi = 0.75; // 与 _decodeQr 解码 ROI 一致
    final cropW = (_lastFrameW * roi).round();
    final cropH = (_lastFrameH * roi).round();
    if (cropW <= 0 || cropH <= 0) return;
    final ratio = (bboxW * bboxH) / (cropW * cropH);
    final base = _currentZoom > 0 ? _currentZoom : 1.0;
    if (ratio < 0.08) {
      // 偏小 → 放大（clamp 上限）
      await _applyZoom((base * 1.3).clamp(_minZoomLevel, _maxZoomLevel));
    } else if (ratio > 0.5) {
      // 偏大 → 缩小（clamp 下限）
      await _applyZoom((base * 0.8).clamp(_minZoomLevel, _maxZoomLevel));
    }
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
  /// 先加回 left/top 偏移还原帧坐标，再按 cover 近似（scale = 240/帧宽，纵向居中）转 Offset。
  List<Offset> _computeMappedEyePoints(int w, int h) {
    if (_eyePoints.isEmpty || w <= 0) return const [];
    const roi = 0.75;
    final cropW = (w * roi).round();
    final cropH = (h * roi).round();
    final left = ((w - cropW) / 2).round();
    final top = ((h - cropH) / 2).round();
    final scale = 240 / w;
    final dy = (240 - h * scale) / 2; // cover 纵向居中近似
    return [
      for (final p in _eyePoints)
        Offset((p.x + left) * scale, (p.y + top) * scale + dy),
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

  /// 解码单帧：取 Y 平面灰度 → RGBLuminanceSource → GlobalHistogramBinarizer → QRCodeReader。
  /// 仅解码**中心 3/4 区域**（与识别框 180/240 对应），排除框外干扰；解码前清空码眼候选，
  /// 解码过程中通过 ResultPointCallback 实时收集码眼点（即使最终失败也能拿到，供失败引导判断）。
  String? _decodeQr(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final luma = _extractLuma(image);
    const roi = 0.75; // 与识别框 180/240 对应：只解框内区域
    final w = image.width, h = image.height;
    final cropW = (w * roi).round();
    final cropH = (h * roi).round();
    final left = ((w - cropW) / 2).round();
    final top = ((h - cropH) / 2).round();
    final source =
        RGBLuminanceSource.crop(luma, w, h, left, top, cropW, cropH);
    final bitmap = BinaryBitmap(GlobalHistogramBinarizer(source));
    _eyePoints.clear();
    final hints = DecodeHints()
      ..put(
        DecodeHintType.needResultPointCallback,
        (ResultPoint p) => _eyePoints.add(p),
      );
    return QRCodeReader().decode(bitmap, hints: hints).text;
  }

  /// 从 YUV420 首平面（Y）抽取灰度字节（处理 bytesPerRow 行对齐 padding）
  Int8List _extractLuma(CameraImage image) {
    final plane = image.planes[0];
    final w = image.width;
    final h = image.height;
    final rowStride = plane.bytesPerRow;
    final luma = Int8List(w * h);
    final bytes = plane.bytes;
    if (rowStride == w) {
      luma.setAll(0, bytes);
    } else {
      for (var y = 0; y < h; y++) {
        final src = y * rowStride;
        final dst = y * w;
        luma.setRange(dst, dst + w, bytes, src);
      }
    }
    return luma;
  }

  /// 识别命中：回填输入框 + 写入识别历史（去重置顶、上限、持久化）+ 停止图像流
  void _onScanSuccess(String text) {
    _scanningStopped = true;
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

  /// 重新扫描：图像流已停止时重新启动
  Future<void> _restartScan() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isStreamingImages) return;
    setState(() {
      _scanningStopped = false;
      _scanHint = '将二维码对准框内';
    });
    _eyePoints.clear();
    _mappedEyePoints.clear();
    try {
      await controller.startImageStream(_onFrame);
    } catch (e) {
      appLog.error('QrToolPage: 重新扫描失败 - $e');
      if (mounted) AppDialogs.showError('重新扫描失败');
    }
  }

  /// 清除输入与内容（取消待写的历史防抖计时）
  void _clear() {
    _historyDebounce?.cancel();
    _controller.clear();
    setState(() => _text = '');
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

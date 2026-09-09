import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:gstore/core/core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 二维码工具页：输入文本/链接 → 实时生成二维码；支持长按保存图片（应用目录 + 系统相册）；
/// 历史生成记录防抖持久化（shared_preferences），点击历史可回填输入。
class QrToolPage extends StatefulWidget {
  const QrToolPage({super.key});

  /// 测试注入：系统相册写入结果（null = 走真实 gal；true/false = 模拟结果，不触发真实相册）。
  @visibleForTesting
  static bool? debugGallerySucceeds;

  @override
  State<QrToolPage> createState() => _QrToolPageState();
}

class _QrToolPageState extends State<QrToolPage> {
  /// 历史记录存储键
  static const String _historyKey = 'qr_tool_history';

  /// 历史记录上限
  static const int _historyLimit = 20;

  /// 输入控制器（「清除」时清空并复位 [_text]）
  final TextEditingController _controller = TextEditingController();

  /// 当前要生成二维码的内容（空 → 显示占位）
  String _text = '';

  /// 历史生成记录（去重置顶，最近的在最前，上限 [_historyLimit]）
  List<String> _history = [];

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
  }

  @override
  void dispose() {
    _historyDebounce?.cancel();
    _controller.dispose();
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

  /// 输入变化：即时更新二维码内容；历史写入改为防抖（停顿 800ms 后 [_commitHistory]）
  void _onTextChanged(String value) {
    final text = value.trim();
    setState(() => _text = text);
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

  /// 点击历史 chip：回填输入框并重新生成二维码
  void _applyHistory(String item) {
    _historyDebounce?.cancel();
    _controller.text = item;
    _controller.selection = TextSelection.collapsed(offset: item.length);
    setState(() => _text = item);
  }

  /// 清空历史记录
  void _clearHistory() {
    setState(() => _history = []);
    unawaited(_persistHistory());
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('二维码'),
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
            // 二维码预览区（flex 2；高度充足时原尺寸居中，键盘压缩时等比缩小完整可见）
            Expanded(flex: 2, child: _buildQrArea(context)),

            // 历史记录区（固定高，不参与 flex，横向滚动 chips）
            if (_history.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(height: 64, child: _buildHistory(context)),
              const SizedBox(height: AppSpacing.sm),
            ],

            // 输入区（flex 1 ≈ 剩余空间，撑开多行输入）
            Expanded(
              flex: 1,
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: '输入文本或链接生成二维码',
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

  /// 历史记录区：标题（含清空）+ 固定高横向滚动 chips
  Widget _buildHistory(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '历史记录',
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
            itemCount: _history.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.sm),
            itemBuilder: (context, index) {
              final item = _history[index];
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

  /// 二维码预览区：高度充足时原尺寸居中；键盘压缩高度不足时 FittedBox 等比缩小，完整可见
  Widget _buildQrArea(BuildContext context) {
    return Center(
      child: FittedBox(
        fit: BoxFit.contain,
        child: _text.isEmpty ? _buildPlaceholder(context) : _buildQr(),
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
    final confirmed = await AppDialogs.showDialog(
      title: '保存二维码',
      content: '将二维码图片保存到系统相册?',
      confirmText: '保存',
      cancelText: '取消',
    );
    if (confirmed != true || !mounted) return;
    await _saveImage();
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
  static const double _qrSavePadding = 24;

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

  /// 清除输入与内容（取消待写的历史防抖计时）
  void _clear() {
    _historyDebounce?.cancel();
    _controller.clear();
    setState(() => _text = '');
  }
}

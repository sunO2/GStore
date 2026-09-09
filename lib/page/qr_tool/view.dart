import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 二维码工具页：输入文本/链接 → 实时生成二维码；支持复制内容与长按保存图片；
/// 历史生成记录持久化（shared_preferences），点击历史可回填输入。
class QrToolPage extends StatefulWidget {
  const QrToolPage({super.key});

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

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
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

  /// 输入变化：更新二维码内容，并把非空内容去重置顶写入历史（异步持久化）
  void _onTextChanged(String value) {
    final text = value.trim();
    final shouldRecord =
        text.isNotEmpty && (_history.isEmpty || _history.first != text);
    setState(() {
      _text = text;
      if (shouldRecord) {
        _history = [text, ..._history.where((e) => e != text)]
            .take(_historyLimit)
            .toList();
      }
    });
    if (shouldRecord) unawaited(_persistHistory());
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
      appBar: AppBar(title: const Text('二维码')),
      body: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 二维码预览区（flex 2；高度充足时居中，键盘压缩时可滚动查看完整二维码）
            Expanded(flex: 2, child: _buildQrArea(context)),

            // 历史记录区（固定高，不参与 flex，横向滚动 chips）
            if (_history.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              SizedBox(height: 64, child: _buildHistory(context)),
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

            // 操作区（有内容才显示，置于底部）
            if (_text.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _buildActions(context),
            ],
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

  /// 二维码预览区：高度充足时居中；键盘压缩高度不足时可滚动查看完整二维码
  Widget _buildQrArea(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child:
                  _text.isEmpty ? _buildPlaceholder(context) : _buildQr(),
            ),
          ),
        );
      },
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

  /// 操作区：复制 / 清除（保存图片改为长按二维码触发）
  Widget _buildActions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: _copyText,
            icon: const Icon(Icons.copy, size: AppTypography.iconMD),
            label: const Text('复制'),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _clear,
            icon: const Icon(Icons.clear, size: AppTypography.iconMD),
            label: const Text('清除'),
          ),
        ),
      ],
    );
  }

  /// 长按确认后保存图片（确认框 → 真保存）
  Future<void> _confirmSaveImage() async {
    if (_saving) return;
    final confirmed = await AppDialogs.showDialog(
      title: '保存二维码',
      content: '将二维码图片保存到应用目录?',
      confirmText: '保存',
      cancelText: '取消',
    );
    if (confirmed != true || !mounted) return;
    await _saveImage();
  }

  /// 复制当前内容到剪贴板
  Future<void> _copyText() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (mounted) AppDialogs.showSnackbar('已复制');
  }

  /// 保存二维码为 PNG（应用文档目录 qr_codes/<时间戳>.png，不申请相册权限）
  Future<void> _saveImage() async {
    setState(() => _saving = true);
    try {
      final byteData = await QrPainter(
        data: _text,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      ).toImageData(512);
      if (byteData == null) {
        throw const FileSystemException('生成二维码图片失败');
      }
      final path = await _writePng(byteData);
      if (mounted) {
        AppDialogs.showSuccess('已保存到 $path');
      }
    } catch (e) {
      if (mounted) AppDialogs.showError('保存二维码失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
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

  /// 清除输入与内容
  void _clear() {
    _controller.clear();
    setState(() => _text = '');
  }
}

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 二维码工具页：输入文本/链接 → 实时生成二维码；支持复制内容与保存图片。
class QrToolPage extends StatefulWidget {
  const QrToolPage({super.key});

  @override
  State<QrToolPage> createState() => _QrToolPageState();
}

class _QrToolPageState extends State<QrToolPage> {
  /// 输入控制器（「清除」时清空并复位 [_text]）
  final TextEditingController _controller = TextEditingController();

  /// 当前要生成二维码的内容（空 → 显示占位）
  String _text = '';

  /// 保存中标志（防重复点击）
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('二维码')),
      body: SingleChildScrollView(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 输入区
            TextField(
              controller: _controller,
              maxLines: 4,
              minLines: 1,
              decoration: InputDecoration(
                hintText: '输入文本或链接生成二维码',
                hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.outline,
                    ),
                prefixIcon: const Icon(Icons.edit_outlined),
                border: OutlineInputBorder(
                  borderRadius: AppRadius.allLG,
                ),
              ),
              onChanged: (value) => setState(() => _text = value.trim()),
            ),

            const SizedBox(height: AppSpacing.lg),

            // 实时预览 / 占位
            Center(
              child: _text.isEmpty ? _buildPlaceholder(context) : _buildQr(),
            ),

            const SizedBox(height: AppSpacing.lg),

            // 操作区（有内容才显示）
            if (_text.isNotEmpty) _buildActions(context),
          ],
        ),
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

  /// 二维码预览（白底保证可扫描；圆角容器）
  Widget _buildQr() {
    return Container(
      padding: AppSpacing.allLG,
      decoration: BoxDecoration(
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
    );
  }

  /// 操作区：复制 / 保存图片 / 清除
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
          child: FilledButton.tonalIcon(
            onPressed: _saving ? null : _saveImage,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: AppLoading(size: AppLoadingSize.small),
                  )
                : const Icon(Icons.save_alt, size: AppTypography.iconMD),
            label: Text(_saving ? '保存中...' : '保存图片'),
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

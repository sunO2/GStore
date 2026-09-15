import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/contract/ModuleTypes.dart';
import 'package:gstore/core/service/apk_browser_service.dart';
import 'package:gstore/core/utils/unit.dart';

/// 条目类型 → 图标（与 Rust `browser::classify` 的 kind 取值一一对应）
///
/// 文字标签见 [apkEntryKindLabel]（放在 service 层，UI 与 Agent 共用同一份）。
IconData apkEntryIcon(String kind, {bool isDir = false}) {
  if (isDir) return Icons.folder_outlined;
  return switch (kind) {
    'zip' || 'apk' || 'jar' || 'aar' => Icons.folder_zip_outlined,
    'dex' => Icons.data_object,
    'so' => Icons.memory,
    'arsc' => Icons.grid_on,
    'manifest' => Icons.description_outlined,
    'image' => Icons.image_outlined,
    'json' => Icons.data_array,
    'text' => Icons.article_outlined,
    'font' => Icons.font_download_outlined,
    'cert' => Icons.verified_user_outlined,
    'video' => Icons.movie_outlined,
    'audio' => Icons.music_note_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// 单条内容预览页
///
/// 取舍：Rust 只把内容**导出成缓存文件**（字节不跨 FFI），
/// 本页按类型选渲染方式；不支持的（视频/音频播放）先给元数据，播放依赖待定。
class ApkEntryPreviewPage extends StatefulWidget {
  const ApkEntryPreviewPage({
    super.key,
    required this.apkPath,
    required this.entry,
    this.containerChain = '',
  });

  final String apkPath;
  final ApkBrowsableEntry entry;

  /// 嵌套容器链（空 = APK 根）
  final String containerChain;

  @override
  State<ApkEntryPreviewPage> createState() => _ApkEntryPreviewPageState();
}

class _ApkEntryPreviewPageState extends State<ApkEntryPreviewPage> {
  /// 文本类预览的读取上限（超出只显示前段并提示）
  static const int _textLimit = 256 * 1024;

  /// 十六进制预览的读取上限
  static const int _hexLimit = 4 * 1024;

  String? _filePath;
  Uint8List? _head;
  String? _error;
  bool _loading = true;
  int _fileSize = 0;

  /// 已加载的字体族（字体预览用）
  String? _fontFamily;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  String get _kind => widget.entry.kind;

  Future<void> _prepare() async {
    try {
      final result = await ApkBrowserService.instance.exportEntry(
        widget.apkPath,
        entryPath: widget.entry.path,
        containerChain: widget.containerChain,
      );
      if (result == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = '导出失败：分析模块未就绪或条目不可读';
        });
        return;
      }
      final file = File(result.outPath);
      _fileSize = result.size;
      final head = await _readHead(file, _needsBytes ? _limitFor(_kind) : 0);
      if (!mounted) return;
      setState(() {
        _filePath = result.outPath;
        _head = head;
        _loading = false;
      });
      if (_kind == 'font' && head != null) {
        await _loadFont(head);
      }
    } catch (e) {
      appLog.error('ApkEntryPreviewPage: 预览失败 - $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '预览失败：$e';
      });
    }
  }

  /// 该类型是否需要把内容读进内存
  bool get _needsBytes => switch (_kind) {
        'image' => false,
        'font' || 'json' || 'text' || 'cert' => true,
        _ => true,
      };

  int _limitFor(String kind) => switch (kind) {
        'font' => 8 * 1024 * 1024,
        'json' || 'text' => _textLimit,
        _ => _hexLimit,
      };

  static Future<Uint8List?> _readHead(File file, int limit) async {
    if (limit <= 0) return null;
    final raf = await file.open();
    try {
      final len = await file.length();
      final want = len < limit ? len : limit;
      return await raf.read(want);
    } finally {
      await raf.close();
    }
  }

  Future<void> _loadFont(Uint8List bytes) async {
    try {
      const family = 'apk_browser_font_preview';
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length)));
      await loader.load();
      if (!mounted) return;
      setState(() => _fontFamily = family);
    } catch (e) {
      appLog.warning('ApkEntryPreviewPage: 字体加载失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.entry.name,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: AppSpacing.onlyVerticalSM,
              children: [
                _metaCard(),
                if (_error != null)
                  _messageCard(_error!)
                else
                  _contentCard(),
              ],
            ),
    );
  }

  /// 元信息卡：无论能否渲染都先给出「这是什么」
  Widget _metaCard() {
    final theme = Theme.of(context);
    final e = widget.entry;
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            apkEntryKindLabel(e.kind),
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xs),
          _metaRow('路径', e.path, mono: true),
          _metaRow('大小', byteSize(_fileSize == 0 ? e.size : _fileSize)),
          if (e.compressedSize > 0)
            _metaRow('压缩后', byteSize(e.compressedSize)),
          _metaRow('存放方式', e.stored ? 'STORED（未压缩）' : 'DEFLATE'),
          if (e.crc32 != 0)
            _metaRow(
              'CRC32',
              'crc32:${e.crc32.toUnsigned(32).toRadixString(16).padLeft(8, '0')}',
              mono: true,
            ),
        ],
      ),
    );
  }

  Widget _metaRow(String label, String value, {bool mono = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: mono ? AppTypography.code : theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageCard(String text) => AppCard(
        margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
        child: Text(text),
      );

  Widget _contentCard() {
    return switch (_kind) {
      'image' => _imageCard(),
      'font' => _fontCard(),
      'json' => _textCard(_prettyJson(), mono: true),
      'text' => _textCard(_decodeText(), mono: true),
      'cert' => _certCard(),
      'video' || 'audio' => _mediaCard(),
      _ => _hexCard(),
    };
  }

  Widget _imageCard() {
    final path = _filePath;
    if (path == null) return _messageCard('无内容');
    final isSvg = widget.entry.name.toLowerCase().endsWith('.svg');
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: isSvg
          ? SvgPicture.file(File(path))
          : InteractiveViewer(
              maxScale: 6,
              child: Image.file(
                File(path),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Padding(
                  padding: AppSpacing.allMD,
                  child: Text('无法解码为图片（可能是不支持的格式或损坏文件）'),
                ),
              ),
            ),
    );
  }

  Widget _fontCard() {
    final theme = Theme.of(context);
    final family = _fontFamily;
    if (family == null) return _messageCard('字体加载失败，可能不是有效的字体文件');
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('示例', style: theme.textTheme.labelMedium),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'ABCDEFG abcdefg 0123456789',
            style: TextStyle(fontFamily: family, fontSize: 22),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '中文字体预览：应用文件浏览器 快照对比 原生库',
            style: TextStyle(fontFamily: family, fontSize: 18),
          ),
        ],
      ),
    );
  }

  Widget _textCard(String text, {bool mono = false}) {
    final theme = Theme.of(context);
    final truncated = _head != null && _head!.length >= _limitFor(_kind) && _fileSize > _head!.length;
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (truncated)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                '内容较长，仅显示前 ${byteSize(_head!.length)}（共 ${byteSize(_fileSize)}）',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          SelectableText(
            text,
            style: mono ? AppTypography.code : theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  String _decodeText() {
    final bytes = _head;
    if (bytes == null || bytes.isEmpty) return '（空文件）';
    return utf8.decode(bytes, allowMalformed: true);
  }

  String _prettyJson() {
    final raw = _decodeText();
    try {
      final decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }

  /// 证书：PEM 文本直接显示；DER 等二进制给十六进制
  Widget _certCard() {
    final raw = _decodeText();
    if (raw.contains('-----BEGIN')) {
      return _textCard(raw, mono: true);
    }
    return _hexCard(
      hint: '二进制证书（DER/P12 等）：完整字段解析待接入（可复用平台侧 X.509 解析）',
    );
  }

  /// 视频/音频：内置播放需新增依赖，先给元数据与导出位置
  Widget _mediaCard() {
    final theme = Theme.of(context);
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _kind == 'video' ? Icons.movie_outlined : Icons.music_note_outlined,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('媒体文件', style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '已导出到缓存：${_filePath ?? '—'}',
            style: AppTypography.code,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '内置播放需要新增媒体播放依赖（video_player / just_audio），当前仅提供元数据与导出。',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 十六进制预览（二进制 / dex / so / arsc 等）
  Widget _hexCard({String? hint}) {
    final theme = Theme.of(context);
    final bytes = _head;
    if (bytes == null || bytes.isEmpty) return _messageCard('（空文件）');
    final truncated = _fileSize > bytes.length;
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text(
                hint,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          Text(
            truncated
                ? '十六进制预览（前 ${byteSize(bytes.length)}，共 ${byteSize(_fileSize)}）'
                : '十六进制预览',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.xs),
          SelectableText(
            hexDump(bytes),
            style: AppTypography.code,
          ),
        ],
      ),
    );
  }
}

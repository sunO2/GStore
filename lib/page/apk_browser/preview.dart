import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

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
  if (isDir) return TablerIcons.folder;
  return switch (kind) {
    'zip' || 'apk' || 'jar' || 'aar' => TablerIcons.file_zip,
    'dex' => TablerIcons.braces,
    'so' => TablerIcons.cpu_2,
    'arsc' => TablerIcons.grid_4x4,
    'manifest' => TablerIcons.file_description,
    'image' => TablerIcons.photo,
    'json' => TablerIcons.brackets,
    'text' => TablerIcons.file_text,
    'font' => TablerIcons.typography,
    'cert' => TablerIcons.shield_check,
    'video' => TablerIcons.movie,
    'audio' => TablerIcons.music,
    _ => TablerIcons.file,
  };
}

/// 条目预览的准备缝（可注入，便于测试）。
///
/// 默认实现 [defaultApkEntryPreparer] 走 [ApkBrowserService] 真实导出；
/// 测试可注入假数据渲染字段卡 / 切换 / 密码流，而不触碰真机与 Rust 模块。
typedef ApkEntryPreparer = Future<ApkEntryPreviewData?> Function({
  required String apkPath,
  required ApkBrowsableEntry entry,
  required String containerChain,
  String? password,
});

/// 预览准备结果：导出路径 + 元数据 + 可选证书解析结果。
///
/// [bytes] 可空：仅需字段（如证书字段卡）时可只带元数据；
/// [certInfo] 仅在 `kind == 'cert'` 时由默认准备器填充——模块不可用为 null。
/// [error] 非空时页面显示降级提示（而非崩溃）。
class ApkEntryPreviewData {
  const ApkEntryPreviewData({
    required this.path,
    required this.size,
    required this.crc32,
    this.bytes,
    this.certInfo,
    this.error,
  });

  /// 落地绝对路径（原始查看器消费）
  final String path;

  /// 实际写出字节数
  final int size;

  /// 条目 CRC32
  final int crc32;

  /// 读取到的内容字节（按类型限长；仅字段预览时为 null）
  final Uint8List? bytes;

  /// 证书解析结果（仅证书条目；模块不可用为 null）
  final CertInfo? certInfo;

  /// 准备失败原因（可选；非空即降级）
  final String? error;
}

/// 默认准备器：真实导出**一次**（`ApkBrowserService.exportEntry`），按类型读取头部字节；
/// 证书条目额外对**同一个**导出路径调用 `parseCertificate`（不重复导出）。
Future<ApkEntryPreviewData?> defaultApkEntryPreparer({
  required String apkPath,
  required ApkBrowsableEntry entry,
  required String containerChain,
  String? password,
}) async {
  final result = await ApkBrowserService.instance.exportEntry(
    apkPath,
    entryPath: entry.path,
    containerChain: containerChain,
  );
  if (result == null) return null;
  final limit = _ApkEntryPreviewPageState._needsBytesFor(entry.kind)
      ? _ApkEntryPreviewPageState._limitFor(entry.kind)
      : 0;
  final bytes =
      await _ApkEntryPreviewPageState._readHead(File(result.outPath), limit);
  CertInfo? certInfo;
  if (entry.kind == 'cert') {
    certInfo = await ApkBrowserService.instance.parseCertificate(
      result.outPath,
      password: password ?? '',
    );
  }
  return ApkEntryPreviewData(
    path: result.outPath,
    size: result.size,
    crc32: result.crc32,
    bytes: bytes,
    certInfo: certInfo,
  );
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
    this.preparer,
  });

  final String apkPath;
  final ApkBrowsableEntry entry;

  /// 嵌套容器链（空 = APK 根）
  final String containerChain;

  /// 可注入的预览准备器（null = 走 [defaultApkEntryPreparer] 真实导出）
  final ApkEntryPreparer? preparer;

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

  /// 证书解析结果（Todo 14 字段卡消费；模块不可用为 null）。
  ///
  /// 非下划线命名：Todo 13 先落存储，字段卡在 Todo 14 消费（避免暂未使用的私有字段告警）。
  CertInfo? certInfo;

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
      final preparer = widget.preparer ?? defaultApkEntryPreparer;
      final data = await preparer(
        apkPath: widget.apkPath,
        entry: widget.entry,
        containerChain: widget.containerChain,
      );
      if (!mounted) return;
      if (data == null) {
        setState(() {
          _loading = false;
          _error = '导出失败：分析模块未就绪或条目不可读';
        });
        return;
      }
      setState(() {
        _filePath = data.path;
        _head = data.bytes;
        _fileSize = data.size;
        certInfo = data.certInfo;
        _error = data.error;
        _loading = false;
      });
      if (_error == null && _kind == 'font' && data.bytes != null) {
        await _loadFont(data.bytes!);
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
  static bool _needsBytesFor(String kind) => switch (kind) {
        'image' => false,
        'font' || 'json' || 'text' || 'cert' => true,
        _ => true,
      };

  static int _limitFor(String kind) => switch (kind) {
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

  /// 证书卡：按模块返回的 [certInfo] 状态渲染。
  ///
  /// - `ok` → 逐证书字段分节（链序编号）
  /// - `password_required` / `bad_password` → 密码入口 + 提示（弹层见 Todo 16）
  /// - `unsupported` → 容器类型提示（BKS/JCEKS/PKCS#12/BER/私钥/公钥）
  /// - `unrecognized` / `malformed` → 内联错误文案
  /// - `certInfo == null`（模块不可用）→ 「模块不可用」提示 + 保留原始查看器，
  ///   **不**报「解析失败」
  Widget _certCard() {
    final info = certInfo;
    if (info == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _certHintCard('证书解析模块不可用，仅显示原始内容'),
          _rawCertViewer(),
        ],
      );
    }
    return switch (info.status) {
      CertInfoStatus.ok => _certFieldCard(info),
      CertInfoStatus.passwordRequired ||
      CertInfoStatus.badPassword =>
        _certPasswordCard(info),
      CertInfoStatus.unsupported => _certContainerHintCard(info),
      CertInfoStatus.unrecognized ||
      CertInfoStatus.malformed =>
        _certErrorCard(info),
    };
  }

  /// `ok`：逐证书字段卡（链序编号）。
  Widget _certFieldCard(CertInfo info) {
    final theme = Theme.of(context);
    final certs = info.certificates;
    if (certs.isEmpty) {
      return _certHintCard('未解析到证书字段');
    }
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '证书字段',
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          for (var i = 0; i < certs.length; i++) ...[
            if (i > 0) const Divider(height: AppSpacing.xxl),
            _certSection(certs[i], index: i, total: certs.length),
          ],
        ],
      ),
    );
  }

  /// 单张证书分节：链序标题（仅多证书时显示）+ 全部字段行。
  Widget _certSection(CertEntry cert, {required int index, required int total}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (total > 1) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            '证书 ${index + 1} / $total',
            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        _certNameRows('主体', cert.subject),
        _certNameRows('颁发者', cert.issuer),
        _certRow('有效期', _validityText(cert)),
        _certRow('序列号', cert.serialNumberHex, mono: true),
        _certRow('签名算法', cert.signatureAlgorithm),
        _certRow('公钥算法', _publicKeyText(cert)),
        _certRow('版本', cert.version > 0 ? 'v${cert.version}' : ''),
        _certRow('SAN', _sanText(cert.san)),
        _certRow('SKI', cert.subjectKeyIdentifier, mono: true),
        _certRow('AKI', cert.authorityKeyIdentifier, mono: true),
        _certRow('KeyUsage', _listText(cert.keyUsage)),
        _certRow('EKU', _listText(cert.extendedKeyUsage)),
        _certRow('是否 CA', cert.basicConstraints.isCa ? '是' : '否'),
        _certRow('路径长度', cert.basicConstraints.pathLen?.toString() ?? ''),
        _certRow('CRL 分发点', _listText(cert.crlDistributionPoints)),
        _certRow('AIA', _aiaText(cert.authorityInfoAccess)),
        _certRow('SHA-256 指纹', cert.sha256Fingerprint, mono: true),
        _certRow('SHA-1 指纹', cert.sha1Fingerprint, mono: true),
        if (cert.pem.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'PEM',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.xs),
          SelectableText(cert.pem, style: AppTypography.code),
        ],
      ],
    );
  }

  /// 主体 / 颁发者：全串 + 逐字段明细（有明细时）。
  Widget _certNameRows(String label, CertName name) {
    final full = name.full.isNotEmpty ? name.full : name.commonName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _certRow(label, full),
        if (name.fields.isNotEmpty)
          _certRow(
            '$label字段',
            name.fields.map((f) => '${f.name}=${f.value}').join(', '),
            mono: true,
          ),
      ],
    );
  }

  /// 证书字段行：值缺省统一渲染「无」；hex / 指纹行用等宽字体。
  Widget _certRow(String label, String value, {bool mono = false}) {
    final theme = Theme.of(context);
    final display = value.trim().isEmpty ? '无' : value;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              display,
              style: mono ? AppTypography.code : theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// 原始查看器：PEM 文本直显，其余二进制走 hex。
  ///
  /// 模块不可用（[certInfo] == null）时的兜底——保留原始内容而非空白。
  Widget _rawCertViewer() {
    final raw = _decodeText();
    if (raw.contains('-----BEGIN')) {
      return _textCard(raw, mono: true);
    }
    return _hexCard();
  }

  /// 纯提示卡（模块不可用 / 空证书集）。
  Widget _certHintCard(String text) {
    final theme = Theme.of(context);
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Text(text, style: theme.textTheme.bodySmall),
    );
  }

  /// `password_required` / `bad_password`：提示 + 密码入口（底部弹层见 Todo 16）。
  Widget _certPasswordCard(CertInfo info) {
    final theme = Theme.of(context);
    final bad = info.status == CertInfoStatus.badPassword;
    final message = info.message.isNotEmpty
        ? info.message
        : (bad ? '密码错误，请重新输入。' : '该证书容器受密码保护，需输入密码才能解析字段。');
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            bad ? '密码错误' : '需要密码',
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(message, style: theme.textTheme.bodySmall),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _requestPasswordEntry,
              icon: const Icon(TablerIcons.lock),
              label: Text(bad ? '重新输入密码' : '输入密码'),
            ),
          ),
        ],
      ),
    );
  }

  /// 密码入口占位：Todo 16 接入统一底部密码层后在此弹出。
  void _requestPasswordEntry() {
    appLog.debug('ApkEntryPreviewPage: 请求证书容器密码（底部密码层见 Todo 16）');
  }

  /// `unsupported`：容器类型提示（BKS/JCEKS/PKCS#12/BER/私钥/公钥等）。
  Widget _certContainerHintCard(CertInfo info) {
    final theme = Theme.of(context);
    final message = info.message.isNotEmpty
        ? info.message
        : '该证书容器暂不支持字段解析，仅识别为容器。';
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '容器格式：${_certFormatLabel(info.format)}',
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(message, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  /// `unrecognized` / `malformed`：内联错误文案。
  Widget _certErrorCard(CertInfo info) {
    final theme = Theme.of(context);
    final message = info.message.isNotEmpty
        ? info.message
        : (info.status == CertInfoStatus.malformed
            ? '证书数据损坏或无法解析。'
            : '无法识别的证书格式。');
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(TablerIcons.alert_triangle, color: theme.colorScheme.error),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(message, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }

  /// 容器格式 → 展示标签。
  static String _certFormatLabel(CertFormat format) => switch (format) {
        CertFormat.pem => 'PEM',
        CertFormat.der => 'DER',
        CertFormat.pkcs7 => 'PKCS#7',
        CertFormat.pkcs12 => 'PKCS#12',
        CertFormat.jks => 'JKS',
        CertFormat.bks => 'BKS',
        CertFormat.jceks => 'JCEKS',
        CertFormat.unknown => '未知',
      };

  /// 有效期：not_before ~ not_after（单侧缺失渲染「无」；两侧皆缺为空 → 行显示「无」）。
  static String _validityText(CertEntry cert) {
    if (cert.notBefore.isEmpty && cert.notAfter.isEmpty) return '';
    final from = cert.notBefore.isEmpty ? '无' : cert.notBefore;
    final to = cert.notAfter.isEmpty ? '无' : cert.notAfter;
    return '$from ~ $to';
  }

  /// 公钥算法：算法 + 位数（仅 `publicKeyBits != 0`）+ 曲线（非空时）。
  static String _publicKeyText(CertEntry cert) {
    final parts = <String>[];
    if (cert.publicKeyAlgorithm.isNotEmpty) parts.add(cert.publicKeyAlgorithm);
    if (cert.publicKeyBits != 0) parts.add('${cert.publicKeyBits} 位');
    if (cert.publicKeyCurve.isNotEmpty) parts.add(cert.publicKeyCurve);
    return parts.join(' · ');
  }

  static String _listText(List<String> values) => values.join(', ');

  static String _sanText(List<CertSan> san) =>
      san.map((s) => '${s.type}: ${s.value}').join(', ');

  static String _aiaText(List<CertAia> aia) =>
      aia.map((a) => '${a.type}: ${a.url}').join(', ');

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
                _kind == 'video' ? TablerIcons.movie : TablerIcons.music,
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

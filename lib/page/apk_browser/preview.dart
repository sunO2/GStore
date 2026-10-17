import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_sheet.dart';
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

/// 证书原始内容的展示方式（仅证书条目提供该切换）。
enum _CertRawView { text, hex }

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

  /// 证书原始内容视图（「原文」/「Hex」）；仅证书条目使用。
  _CertRawView _certRawView = _CertRawView.text;

  /// 密码流状态（Todo 16）：
  /// - [_passwordCancelled]：用户取消 / 留空 → 降级为容器信息 + 原始查看器；
  /// - [_passwordError]：错误密码重试耗尽后的内联提示（非空即不再自动重弹，杜绝死循环）。
  bool _passwordCancelled = false;
  String? _passwordError;

  /// 已加载的字体族（字体预览用）
  String? _fontFamily;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  String get _kind => widget.entry.kind;

  Future<void> _prepare({String? password}) async {
    try {
      final preparer = widget.preparer ?? defaultApkEntryPreparer;
      final data = await preparer(
        apkPath: widget.apkPath,
        entry: widget.entry,
        containerChain: widget.containerChain,
        password: password,
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
        // 解析成功（非「需要密码 / 密码错误」）→ 清除密码流降级 / 错误态，
        // 否则重解析后的字段卡不会残留旧的密码提示。
        final status = data.certInfo?.status;
        if (status != CertInfoStatus.passwordRequired &&
            status != CertInfoStatus.badPassword) {
          _passwordCancelled = false;
          _passwordError = null;
        }
        // 初次/重解析后按内容选默认原始视图（文本含 PEM 头 → 原文，否则 Hex）。
        _certRawView = _defaultCertRawViewFor(data.bytes);
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
        // 证书读取上限固定 256 KB：Hex 用显式 limit 渲染全部读到的字节，
        // 避免 hexDump 默认 4096 造成的「假满屏」（不改 _hexLimit 与其它 kind）。
        'cert' => 256 * 1024,
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

  /// 默认原始视图：读到文本且含 PEM 头 → 「原文」，其余（如 DER 二进制）→ 「Hex」。
  ///
  /// 与旧 `_rawCertViewer` 的「PEM 直显、二进制走 hex」语义一致，
  /// 只是现在可由用户在证书卡内切换。
  static _CertRawView _defaultCertRawViewFor(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return _CertRawView.text;
    return utf8.decode(bytes, allowMalformed: true).contains('-----BEGIN')
        ? _CertRawView.text
        : _CertRawView.hex;
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
          ? const Center(child: AppLoading(size: AppLoadingSize.large))
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
          _metaRow('存放方式', _compressionLabel(e)),
          if (e.compressedSize > 0 && e.compressedSize < e.size)
            _metaRow('压缩率', _compressionRate(e)),
          _metaRow('修改时间', e.modified ?? '无'),
          if (e.created != null) _metaRow('创建时间', e.created!),
          if (e.accessed != null) _metaRow('访问时间', e.accessed!),
          if (e.unixMode != null) _metaRow('权限', _permText(e.unixMode!)),
          _metaRow('加密', e.encrypted ? '是' : '否'),
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

  /// 存放方式展示：优先用模块的 `compression`；空串回落旧的 `stored` 布尔。
  static String _compressionLabel(ApkBrowsableEntry e) {
    final c = e.compression;
    if (c.isEmpty) return e.stored ? 'STORED（未压缩）' : 'DEFLATE';
    return switch (c.toLowerCase()) {
      'stored' => 'STORED（未压缩）',
      'deflate' => 'DEFLATE',
      _ => c.toUpperCase(),
    };
  }

  /// 压缩率：仅在压缩确实生效（`0 < compressedSize < size`）时展示，`节省 N%`。
  static String _compressionRate(ApkBrowsableEntry e) {
    final saved = ((e.size - e.compressedSize) / e.size * 100).round();
    return '节省 $saved%';
  }

  /// Unix 权限：`0o<octal> · rwxrwxrwx`（仅取低 9 位）。
  static String _permText(int unixMode) {
    // 0x1FF = 低 9 位权限（Dart 无八进制字面量，0o777 用十六进制表达）。
    final mode = unixMode & 0x1FF;
    final octal = '0o${mode.toRadixString(8).padLeft(3, '0')}';
    final rwx = [
      for (final shift in const [6, 3, 0])
        '${(mode >> shift) & 4 != 0 ? 'r' : '-'}'
            '${(mode >> shift) & 2 != 0 ? 'w' : '-'}'
            '${(mode >> shift) & 1 != 0 ? 'x' : '-'}',
    ].join();
    return '$octal · $rwx';
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
    final Widget body;
    if (info == null) {
      body = _certHintCard('证书解析模块不可用，仅显示原始内容');
    } else {
      body = switch (info.status) {
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
    // 仅证书条目：状态卡之后固定附「原文 ↔ Hex」原始内容卡（含模块不可用兜底）。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        body,
        _certRawCard(),
      ],
    );
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

  /// 证书原始内容卡：`[原文 | Hex]` 分段切换（仅证书条目）。
  ///
  /// - 「原文」：可读 PEM 直显；二进制但已解析出证书时显示 Rust 返回的 PEM armor
  ///   （多证书按链序拼接）；未解析二进制则宽容 UTF-8 + 「二进制原文，可能不可读」。
  /// - 「Hex」：`hexDump(bytes, limit: bytes.length)`——**显式 limit** 渲染全部读到的
  ///   字节（覆盖默认 4096），截断提示按**实际渲染字节数**比较，杜绝「假满屏」。
  Widget _certRawCard() {
    final theme = Theme.of(context);
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSegmentedButton<_CertRawView>(
            value: _certRawView,
            segments: const [
              AppSegment(value: _CertRawView.text, label: '原文'),
              AppSegment(value: _CertRawView.hex, label: 'Hex'),
            ],
            onChanged: (view) => setState(() => _certRawView = view),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_certRawView == _CertRawView.text)
            _certRawTextView(theme)
          else
            _certRawHexView(theme),
        ],
      ),
    );
  }

  /// 「原文」视图（见 [_certRawCard] 语义）。
  Widget _certRawTextView(ThemeData theme) {
    final bytes = _head;
    if (bytes == null || bytes.isEmpty) return const Text('（空文件）');
    final decoded = utf8.decode(bytes, allowMalformed: true);
    final readablePem = decoded.contains('-----BEGIN');
    // 二进制但已解析出证书 → 用 Rust 返回的 PEM armor（多证书按链序拼接）。
    final armor = readablePem ? null : _parsedPemArmor();
    final binaryWarn = armor == null && !readablePem;
    // armor 来自解析结果（完整），不按读取量提示截断；字节视图才按实际渲染字节数比较。
    final truncated = armor == null && _fileSize > bytes.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (binaryWarn) _rawHint(theme, '二进制原文，可能不可读'),
        if (truncated)
          _rawHint(
            theme,
            '内容较长，仅显示前 ${byteSize(bytes.length)}（共 ${byteSize(_fileSize)}）',
          ),
        SelectableText(armor ?? decoded, style: AppTypography.code),
      ],
    );
  }

  /// 「Hex」视图：显式 limit = 已读取字节数，渲染全部读到的字节；按实际渲染量提示截断。
  Widget _certRawHexView(ThemeData theme) {
    final bytes = _head;
    if (bytes == null || bytes.isEmpty) return const Text('（空文件）');
    final renderedBytes = bytes.length;
    final dump = hexDump(bytes, limit: renderedBytes);
    final truncated = _fileSize > renderedBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _rawHint(
          theme,
          truncated
              ? '十六进制预览（前 ${byteSize(renderedBytes)}，共 ${byteSize(_fileSize)}）'
              : '十六进制预览',
        ),
        const SizedBox(height: AppSpacing.xs),
        SelectableText(dump, style: AppTypography.code),
      ],
    );
  }

  /// Rust 返回的 PEM armor：多证书按链序拼接（无证书或无 PEM 时为 null）。
  String? _parsedPemArmor() {
    final info = certInfo;
    if (info == null || info.certificates.isEmpty) return null;
    final parts = info.certificates
        .map((c) => c.pem)
        .where((p) => p.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    return parts.join('\n');
  }

  /// 原始视图内的小号提示文案（等宽区上方的次要说明）。
  Widget _rawHint(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Text(
          text,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );

  /// 纯提示卡（模块不可用 / 空证书集）。
  Widget _certHintCard(String text) {
    final theme = Theme.of(context);
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      child: Text(text, style: theme.textTheme.bodySmall),
    );
  }

  /// `password_required` / `bad_password`：提示 + 密码入口（统一底部弹层，见 Todo 16）。
  ///
  /// - 用户取消 / 留空 → 降级为「容器信息 + 原始查看器」（[_certPasswordDegradedCard]）；
  /// - 错误密码自动重试一次后 → 内联错误提示（不再自动重弹，杜绝死循环）。
  Widget _certPasswordCard(CertInfo info) {
    if (_passwordCancelled) return _certPasswordDegradedCard(info);
    final theme = Theme.of(context);
    final bad = info.status == CertInfoStatus.badPassword;
    final exhausted = _passwordError != null;
    final message = _passwordError ??
        (info.message.isNotEmpty
            ? info.message
            : (bad ? '密码错误，请重新输入。' : '该证书容器受密码保护，需输入密码才能解析字段。'));
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
          if (!exhausted) ...[
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
        ],
      ),
    );
  }

  /// 取消 / 留空密码后的降级卡：容器信息 + （下方）原始查看器。
  Widget _certPasswordDegradedCard(CertInfo info) {
    final theme = Theme.of(context);
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
          Text('未提供密码，仅显示原始内容。', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  /// 密码入口：弹出统一底部密码层，确认后带密码重解析并刷新字段卡。
  ///
  /// 重试策略：错误密码自动重弹**一次**；仍错误则落 `_passwordError` 内联提示。
  Future<void> _requestPasswordEntry() async {
    if (mounted) {
      setState(() {
        _passwordCancelled = false;
        _passwordError = null;
      });
    }
    await _promptPassword(remainingRetries: 1);
  }

  Future<void> _promptPassword({required int remainingRetries}) async {
    final info = certInfo;
    final result = await AppSheet.showCustom<String>(
      context: context,
      builder: (_) => _CertPasswordSheet(
        isRetry: info?.status == CertInfoStatus.badPassword,
      ),
    );
    if (!mounted) return;
    final password = (result ?? '').trim();
    if (password.isEmpty) {
      // 取消 / 留空 → 降级为容器信息 + 原始查看器。
      setState(() {
        _passwordCancelled = true;
        _passwordError = null;
      });
      return;
    }
    setState(() => _loading = true);
    await _prepare(password: password);
    if (!mounted) return;
    final wrong =
        _error == null && certInfo?.status == CertInfoStatus.badPassword;
    if (wrong && remainingRetries > 0) {
      await _promptPassword(remainingRetries: remainingRetries - 1);
      return;
    }
    if (wrong) {
      final msg = certInfo?.message ?? '';
      setState(() {
        _passwordError =
            msg.isNotEmpty ? msg : '密码错误，无法解析该容器的证书字段。';
      });
    }
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

/// 证书容器密码输入弹层（Todo 16）。
///
/// 统一走 [AppSheet.showCustom] + [AppSheetScaffold]（AGENTS.md：弹层一律走统一
/// 底部弹层，禁止 `showDialog` / `Get.defaultDialog` / 手写 `showModalBottomSheet`）。
/// 确认返回去空白后的密码字符串；取消 / 关闭返回 `null`。
class _CertPasswordSheet extends StatefulWidget {
  const _CertPasswordSheet({required this.isRetry});

  /// 是否为「密码错误后重试」态（影响标题 / 副标题文案）。
  final bool isRetry;

  @override
  State<_CertPasswordSheet> createState() => _CertPasswordSheetState();
}

class _CertPasswordSheetState extends State<_CertPasswordSheet> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = _controller.text;
    Navigator.of(context).pop(value.trim().isEmpty ? null : value);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: widget.isRetry ? '密码错误' : '输入密码',
      subtitle: widget.isRetry
          ? '密码不正确，请重新输入容器密码。'
          : '该证书容器受密码保护，输入密码以解析证书字段。',
      icon: const Icon(TablerIcons.lock),
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: TextField(
        key: const Key('apk-cert-password-field'),
        controller: _controller,
        autofocus: true,
        obscureText: true,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '密码',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _confirm(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('apk-cert-password-confirm'),
          onPressed: _confirm,
          child: const Text('确认'),
        ),
      ],
    );
  }
}

/// 抓包 MITM CA 管理页（`proxy-http-capture` Todo 19，纯展示 / 触发层）。
///
/// 端到端管理抓包证书：
/// * **状态**：`capture.ca.get` 展示「已生成 / 未生成」与 SHA-256 指纹（未生成
///   是正常空态，**不是**错误）；
/// * **生成 / 重置**：`capture.ca.generate` / `capture.ca.reset`，均经
///   [AppDialogs.showConfirmSheet]（危险操作红色确认）；
/// * **导出**：把 PEM / CRT 字节经 [FilePicker.platform.saveFile] 另存；
/// * **安装**：用户证书 / 系统证书（root）走 [ProxyCaService]（Todo 18），
///   用户取消 → 静默提示，失败 → [AppDialogs.showError]，绝不崩溃。
///
/// ## 诚实契约（不得夸大为「安装成功」）
/// * 系统证书写入**仅 root 可用**；非 root 只能装用户证书。
/// * 用户证书安装器拉起后仍需用户在系统 UI 确认（`userActionRequired`）。
/// * 启用**固定证书（pinning）** 的 App 不会信任本 CA，其 HTTPS 无法被抓取。
/// * 真机安装路径本仓库无 adb 设备，**UNVERIFIED**，仅静态分支审查。
///
/// 门面与接缝全部经构造函数注入，测试无需原生模块 / FFI（[facade] 默认适配
/// [ProxyModule]，[caService] 默认走 [MethodChannelProxyCaService]）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:gstore/core/design/app_colors.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/service/proxy_ca_service.dart';

/// 导出另存的测试接缝：调用系统保存对话框并返回落地路径（取消 → `null`）。
///
/// 生产默认走 [FilePicker.platform.saveFile]，测试注入假实现断言「保存被调用」。
typedef ProxyCaptureCaSaveFile = Future<String?> Function({
  required String fileName,
  required Uint8List bytes,
  required List<String> allowedExtensions,
});

/// CA 生命周期能力的可注入门面（生产见 [ProxyModuleCaptureCaFacade]）。
abstract class ProxyCaptureCaFacade {
  /// `capture.ca.get`：读取 CA 状态（未生成 `generated:false`，非错误）。
  Future<CaptureCaInfo> caGet();

  /// `capture.ca.generate`：确保 CA 存在（`regenerate:false` 幂等）。
  Future<CaptureCaInfo> caGenerate({bool regenerate = false});

  /// `capture.ca.reset`：移除落盘 CA 材料并释放内存句柄。
  Future<CaptureCaResetResult> caReset();
}

/// 生产适配器：[ProxyModule] → [ProxyCaptureCaFacade] 的薄转发。
class ProxyModuleCaptureCaFacade implements ProxyCaptureCaFacade {
  ProxyModuleCaptureCaFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<CaptureCaInfo> caGet() =>
      _module.invoke(ProxyMethods.captureCaGet, CaptureCaInfo.fromJson);

  @override
  Future<CaptureCaInfo> caGenerate({bool regenerate = false}) => _module.invoke(
        ProxyMethods.captureCaGenerate,
        CaptureCaInfo.fromJson,
        payload: CaptureCaGenerateRequest(regenerate: regenerate).toJson(),
      );

  @override
  Future<CaptureCaResetResult> caReset() => _module.invoke(
        ProxyMethods.captureCaReset,
        CaptureCaResetResult.fromJson,
        payload: const <String, dynamic>{},
      );
}

/// 导出格式（PEM 文本 / CRT 二进制）。
enum CaptureCaExportFormat {
  /// `.pem`：UTF-8 文本 PEM（用户证书 / OpenSSL 工具链通用）。
  pem,

  /// `.crt`：DER 二进制（部分系统安装器偏好）。
  crt,
}

/// 系统证书存储的安装 / 信任状态（[ProxyCaService.systemCaInstalled] 探测结果）。
///
/// [unsupported] 与 [unknown] 严格区分：前者表示**当前平台不支持检测**（通道
/// 不可用），后者表示检测失败。两者都**不得**谎报为「已安装 / 未安装」。
enum CaptureCaTrustStatus {
  /// 尚未探测 / 探测失败（不展示为已安装或未安装）。
  unknown,

  /// 系统证书存储已存在该 CA。
  installed,

  /// 系统证书存储未安装该 CA。
  notInstalled,

  /// 当前平台不支持证书安装状态检测（通道不可用）。
  unsupported,
}

/// 抓包 CA 管理页。
class ProxyCaptureCaPage extends StatefulWidget {
  const ProxyCaptureCaPage({
    super.key,
    this.facade,
    this.caService,
    this.saveFile,
  });

  /// CA 生命周期门面（测试可注入假实现；为空时用生产适配器）。
  final ProxyCaptureCaFacade? facade;

  /// CA 安装 / 状态能力（测试可注入假实现；为空时走平台通道）。
  final ProxyCaService? caService;

  /// 导出另存接缝（测试注入；为空时走 [FilePicker.platform.saveFile]）。
  final ProxyCaptureCaSaveFile? saveFile;

  @override
  State<ProxyCaptureCaPage> createState() => _ProxyCaptureCaPageState();
}

class _ProxyCaptureCaPageState extends State<ProxyCaptureCaPage> {
  late final ProxyCaptureCaFacade _facade;
  late final ProxyCaService _caService;
  late final ProxyCaptureCaSaveFile _saveFile;

  bool _loading = true;
  bool _busy = false;
  String? _loadError;
  CaptureCaInfo _info = const CaptureCaInfo();
  CaptureCaExportFormat _exportFormat = CaptureCaExportFormat.pem;

  /// 系统证书安装 / 信任状态（best-effort；仅已生成时探测）。
  CaptureCaTrustStatus _trust = CaptureCaTrustStatus.unknown;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleCaptureCaFacade();
    _caService = widget.caService ?? MethodChannelProxyCaService();
    _saveFile = widget.saveFile ?? _defaultSaveFile;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
      _trust = CaptureCaTrustStatus.unknown;
    });
    try {
      final info = await _facade.caGet();
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
      // 安装 / 信任状态（best-effort）：仅在已生成时探测；平台不支持时明确标记，
      // 绝不把「无法检测」谎报成「未安装」。
      if (info.generated) {
        final trust = await _probeTrust(info);
        if (!mounted) return;
        setState(() => _trust = trust);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = '$error';
        _loading = false;
      });
    }
  }

  /// 探测系统证书存储是否已安装该 CA。
  ///
  /// 通道不可用（[CaInstallResult.channelUnavailableCode]）→ [CaptureCaTrustStatus.unsupported]；
  /// 其它探测失败 → [CaptureCaTrustStatus.unknown]。两者都不谎报为「未安装」。
  Future<CaptureCaTrustStatus> _probeTrust(CaptureCaInfo info) async {
    try {
      final installed = await _caService.systemCaInstalled(
        pem: info.pem.isEmpty ? null : info.pem,
      );
      return installed
          ? CaptureCaTrustStatus.installed
          : CaptureCaTrustStatus.notInstalled;
    } on ProxyCaException catch (error) {
      if (error.code == CaInstallResult.channelUnavailableCode) {
        return CaptureCaTrustStatus.unsupported;
      }
      return CaptureCaTrustStatus.unknown;
    } catch (_) {
      return CaptureCaTrustStatus.unknown;
    }
  }

  // ==================== 生成 / 重置 ====================

  Future<void> _generate() async {
    if (_busy) return;
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '生成抓包证书？',
      message: '将生成新的根 CA 供 HTTPS 中间人解密使用。请仅在可信设备上使用，'
          '并妥善保管；生成后需导出并安装到设备证书存储。',
      confirmText: '确认生成',
      isDangerous: true,
      icon: const Icon(TablerIcons.certificate),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final info = await _facade.caGenerate();
      if (!mounted) return;
      setState(() {
        _info = info;
        _busy = false;
      });
      AppDialogs.showSuccess('抓包证书已生成');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppDialogs.showError('生成失败：$error');
    }
  }

  Future<void> _reset() async {
    if (_busy) return;
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '重置抓包证书？',
      message: '将删除本地 CA 私钥与证书，并使此前签发的所有临时证书失效。'
          '已安装到系统的证书需到系统设置中手动移除，本操作无法自动回收。',
      confirmText: '确认重置',
      isDangerous: true,
      icon: const Icon(TablerIcons.trash),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await _facade.caReset();
      if (!mounted) return;
      final info = await _facade.caGet();
      if (!mounted) return;
      setState(() {
        _info = info;
        _busy = false;
      });
      if (result.cleared) {
        AppDialogs.showSuccess('抓包证书已重置');
      } else {
        AppDialogs.showInfo('本地没有可重置的证书');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppDialogs.showError('重置失败：$error');
    }
  }

  // ==================== 导出 ====================

  Future<void> _export() async {
    if (_busy) return;
    if (!_info.generated) {
      AppDialogs.showError('证书尚未生成，请先生成后再导出');
      return;
    }
    final format = _exportFormat;
    final Uint8List bytes;
    final String extension;
    try {
      if (format == CaptureCaExportFormat.pem) {
        if (_info.pem.isEmpty) {
          AppDialogs.showError('证书内容为空，无法导出');
          return;
        }
        bytes = Uint8List.fromList(utf8.encode(_info.pem));
        extension = 'pem';
      } else {
        if (_info.derBase64.isEmpty) {
          AppDialogs.showError('证书 DER 内容为空，无法导出');
          return;
        }
        bytes = base64Decode(_info.derBase64);
        extension = 'crt';
      }
    } catch (error) {
      AppDialogs.showError('证书内容解析失败：$error');
      return;
    }

    setState(() => _busy = true);
    try {
      final path = await _saveFile(
        fileName: 'gstore-capture-ca.$extension',
        bytes: bytes,
        allowedExtensions: <String>[extension],
      );
      if (!mounted) return;
      setState(() => _busy = false);
      // 取消（null / 空路径）：静默停止，不报错、不提示失败。
      if (path == null || path.isEmpty) return;
      AppDialogs.showSuccess('证书已导出：$path', title: '导出成功');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppDialogs.showError('导出失败：$error');
    }
  }

  /// 生产默认另存：系统保存对话框（与日志 / 请求记录导出同机制）。
  static Future<String?> _defaultSaveFile({
    required String fileName,
    required Uint8List bytes,
    required List<String> allowedExtensions,
  }) {
    return FilePicker.platform.saveFile(
      dialogTitle: '保存抓包证书',
      fileName: fileName,
      lockParentWindow: true,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
    );
  }

  // ==================== 分享（复制指纹 / 二维码）====================

  /// 一键复制 SHA-256 指纹（用于跨设备核对 / 粘贴到系统安装向导）。
  Future<void> _copyFingerprint() async {
    final fingerprint = _info.fingerprintSha256;
    if (fingerprint.isEmpty) {
      AppDialogs.showError('暂无指纹可复制');
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: fingerprint));
      if (!mounted) return;
      AppDialogs.showSuccess('指纹已复制');
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('复制指纹失败：$error');
    }
  }

  /// 展示证书二维码（底部弹层）：扫码即可把指纹带到另一台设备核对 / 安装。
  ///
  /// 仅编码**指纹**（不包含私钥 / PEM），避免二维码泄露敏感材料。
  Future<void> _showQr() async {
    final fingerprint = _info.fingerprintSha256;
    if (fingerprint.isEmpty) {
      AppDialogs.showError('暂无指纹可生成二维码');
      return;
    }
    await AppSheet.show<void>(
      context: context,
      title: '证书二维码',
      subtitle: '扫码核对 SHA-256 指纹（不含私钥）',
      icon: const Icon(TablerIcons.qrcode),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QrCodeView(data: fingerprint),
          const SizedBox(height: AppSpacing.md),
          SelectableText(
            fingerprint,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('capture_ca_qr_copy'),
          onPressed: _copyFingerprint,
          child: const Text('复制指纹'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  // ==================== 安装 ====================

  Future<void> _installUser() async {
    if (_busy) return;
    if (!_info.generated) {
      AppDialogs.showError('证书尚未生成，请先生成后再安装');
      return;
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(_info.derBase64);
    } catch (error) {
      AppDialogs.showError('证书 DER 内容解析失败：$error');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await _caService.installUserCa(bytes);
      if (!mounted) return;
      setState(() => _busy = false);
      _reportResult(result, label: '用户证书安装');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppDialogs.showError('用户证书安装失败：$error');
    }
  }

  Future<void> _installSystem() async {
    if (_busy) return;
    if (!_info.generated) {
      AppDialogs.showError('证书尚未生成，请先生成后再安装');
      return;
    }
    setState(() => _busy = true);
    final bool rooted;
    try {
      rooted = await _caService.detectRoot();
    } on ProxyCaException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppDialogs.showError('root 检测失败：${error.message}');
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppDialogs.showError('root 检测失败：$error');
      return;
    }
    if (!mounted) return;
    if (!rooted) {
      setState(() => _busy = false);
      AppDialogs.showError(
        '未检测到 root，无法写入系统证书存储。请改用「安装到用户证书」，'
        '但部分 App 不信任用户证书。',
      );
      return;
    }
    try {
      final result = await _caService.installSystemCa(_info.pem);
      if (!mounted) return;
      setState(() => _busy = false);
      _reportResult(result, label: '系统证书安装');
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppDialogs.showError('系统证书安装失败：$error');
    }
  }

  /// 结构化安装结果的统一呈现：取消 → 提示；失败 → 错误；已装 / 待确认分列。
  void _reportResult(CaInstallResult result, {required String label}) {
    if (result.cancelled) {
      AppDialogs.showInfo('$label已取消');
      return;
    }
    if (!result.ok) {
      AppDialogs.showError(result.message ?? '$label失败（${result.code}）');
      return;
    }
    if (result.installed) {
      AppDialogs.showSuccess('$label完成');
      return;
    }
    if (result.userActionRequired) {
      AppDialogs.showInfo(result.message ?? '$label引导已下发，请在系统界面确认');
      return;
    }
    AppDialogs.showSuccess('$label已提交');
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('抓包证书'),
        actions: [
          IconButton(
            tooltip: '刷新',
            key: const Key('capture_ca_refresh'),
            icon: const Icon(TablerIcons.refresh),
            onPressed: _loading || _busy ? null : _load,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading());
    }
    if (_loadError != null) {
      return _buildError(context);
    }
    return ListView(
      padding: AppSpacing.pagePadding,
      children: [
        _buildStatusCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildLifecycleCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildExportCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildInstallCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildHintsCard(context),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(TablerIcons.alert_triangle,
                size: AppTypography.iconXXXL, color: scheme.error),
            const SizedBox(height: AppSpacing.md),
            Text('证书状态加载失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _loadError ?? '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.tonalIcon(
              key: const Key('capture_ca_retry'),
              onPressed: _load,
              icon: const Icon(TablerIcons.refresh,
                  size: AppTypography.iconSM),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final generated = _info.generated;
    return _CaptureCaSectionCard(
      icon: TablerIcons.certificate,
      title: '证书状态',
      children: [
        Row(
          children: [
            Icon(
              generated
                  ? TablerIcons.circle_check_filled
                  : TablerIcons.circle_dashed,
              size: AppTypography.iconMD,
              color: generated ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                generated ? '已生成' : '尚未生成',
                key: Key(generated
                    ? 'capture_ca_status_generated'
                    : 'capture_ca_status_empty'),
                style: theme.textTheme.bodyLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (generated) ...[
          _buildTrustRow(context),
          const SizedBox(height: AppSpacing.md),
          Text(
            '指纹 (SHA-256)',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _info.fingerprintSha256.isEmpty
                      ? '（未提供）'
                      : _info.fingerprintSha256,
                  key: const Key('capture_ca_fingerprint'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              IconButton(
                key: const Key('capture_ca_copy_fingerprint'),
                tooltip: '复制指纹',
                onPressed: _busy || _info.fingerprintSha256.isEmpty
                    ? null
                    : _copyFingerprint,
                icon: const Icon(TablerIcons.copy,
                    size: AppTypography.iconSM),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('capture_ca_show_qr'),
              onPressed: _busy || _info.fingerprintSha256.isEmpty
                  ? null
                  : _showQr,
              icon: const Icon(TablerIcons.qrcode,
                  size: AppTypography.iconSM),
              label: const Text('证书二维码 / 分享'),
            ),
          ),
          // TODO(C5): CaptureCaInfo 目前无有效期字段；待 C5 契约波新增
          // notBefore / notAfter（或 validFrom / validTo）后在此展示有效期。
        ] else
          Text(
            '尚未生成抓包证书。启用 HTTPS 解密前需先生成根 CA，'
            '再导出并安装到设备证书存储。',
            key: const Key('capture_ca_empty_hint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  /// 系统证书安装 / 信任状态行。
  ///
  /// [CaptureCaTrustStatus.unsupported] 与 [CaptureCaTrustStatus.unknown] 只描述
  /// 「无法确认」，**绝不**谎报为「未安装」。
  Widget _buildTrustRow(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final Key key;
    final IconData icon;
    final Color color;
    final String text;
    switch (_trust) {
      case CaptureCaTrustStatus.installed:
        key = const Key('capture_ca_trust_installed');
        icon = TablerIcons.circle_check_filled;
        color = scheme.primary;
        text = '已安装到系统证书存储';
      case CaptureCaTrustStatus.notInstalled:
        key = const Key('capture_ca_trust_not_installed');
        icon = TablerIcons.alert_triangle;
        color = scheme.error;
        text = '尚未安装到系统证书存储：HTTPS 抓包需先安装并信任证书';
      case CaptureCaTrustStatus.unsupported:
        key = const Key('capture_ca_trust_unsupported');
        icon = TablerIcons.info_circle;
        color = scheme.onSurfaceVariant;
        text = '当前平台不支持证书安装状态检测，无法确认是否已信任';
      case CaptureCaTrustStatus.unknown:
        key = const Key('capture_ca_trust_unknown');
        icon = TablerIcons.help_circle;
        color = scheme.onSurfaceVariant;
        text = '证书安装状态未知（检测失败）';
    }
    return Row(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: AppTypography.iconSM, color: color),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Widget _buildLifecycleCard(BuildContext context) {
    final theme = Theme.of(context);
    return _CaptureCaSectionCard(
      icon: TablerIcons.settings,
      title: '生成 / 重置',
      children: [
        Text(
          '生成会创建新的根 CA；重置会删除私钥与证书，使已签发的临时证书失效。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            FilledButton.tonalIcon(
              key: const Key('capture_ca_generate'),
              onPressed: _busy ? null : _generate,
              icon: const Icon(TablerIcons.certificate,
                  size: AppTypography.iconSM),
              label: Text(_info.generated ? '重新生成' : '生成'),
            ),
            OutlinedButton.icon(
              key: const Key('capture_ca_reset'),
              onPressed: _busy || !_info.generated ? null : _reset,
              icon: const Icon(TablerIcons.trash, size: AppTypography.iconSM),
              label: const Text('重置'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildExportCard(BuildContext context) {
    final theme = Theme.of(context);
    return _CaptureCaSectionCard(
      icon: TablerIcons.download,
      title: '导出证书',
      children: [
        Text(
          '导出后可在系统「安全 → 加密与凭据 → 安装证书」中手动安装。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppSegmentedButton<CaptureCaExportFormat>(
          key: const Key('capture_ca_export_format'),
          value: _exportFormat,
          enabled: !_busy,
          segments: const [
            AppSegment(
              value: CaptureCaExportFormat.pem,
              label: '.pem',
              key: Key('capture_ca_export_pem_segment'),
            ),
            AppSegment(
              value: CaptureCaExportFormat.crt,
              label: '.crt',
              key: Key('capture_ca_export_crt_segment'),
            ),
          ],
          onChanged: (value) => setState(() => _exportFormat = value),
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('capture_ca_export'),
            onPressed: _busy || !_info.generated ? null : _export,
            icon: const Icon(TablerIcons.file_download,
                size: AppTypography.iconSM),
            label: const Text('导出证书'),
          ),
        ),
      ],
    );
  }

  Widget _buildInstallCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _CaptureCaSectionCard(
      icon: TablerIcons.shield_lock,
      title: '安装到设备',
      children: [
        Text(
          '用户证书：无需 root，但部分 App 不信任；系统证书：仅 root 可用，'
          '对所有 App 生效。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.tonalIcon(
              key: const Key('capture_ca_install_user'),
              onPressed: _busy || !_info.generated ? null : _installUser,
              icon: const Icon(TablerIcons.user, size: AppTypography.iconSM),
              label: Text(_busy ? '处理中…' : '安装到用户证书'),
            ),
            const SizedBox(height: AppSpacing.sm),
            FilledButton.tonalIcon(
              key: const Key('capture_ca_install_system'),
              onPressed: _busy || !_info.generated ? null : _installSystem,
              icon: const Icon(TablerIcons.device_mobile,
                  size: AppTypography.iconSM),
              label: const Text('安装到系统证书 (root)'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHintsCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _CaptureCaSectionCard(
      icon: TablerIcons.info_circle,
      title: '诚实提示',
      children: [
        const _HintRow(
          key: Key('capture_ca_hint_user'),
          icon: TablerIcons.user,
          text: '非 root 设备无法写入系统证书存储，只能安装到用户证书；'
              'Android 11+ 需按引导到系统「安全设置」手动安装。',
        ),
        const SizedBox(height: AppSpacing.sm),
        const _HintRow(
          key: Key('capture_ca_hint_pinned'),
          icon: TablerIcons.pin,
          text: '启用固定证书（certificate pinning）的 App 不会信任本 CA，'
              '其 HTTPS 流量无法被抓取，这是预期行为而非故障。',
        ),
        const SizedBox(height: AppSpacing.sm),
        const _HintRow(
          key: Key('capture_ca_hint_verify'),
          icon: TablerIcons.circle_check,
          text: '「已生成」仅表示本地存在根 CA；是否真正生效取决于证书是否'
              '安装并被 App 信任，请以实际抓包结果为准。',
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '真机安装路径未经设备验证（UNVERIFIED — 无 adb 设备）。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 提示行（图标 + 文本）。
class _HintRow extends StatelessWidget {
  const _HintRow({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon,
            size: AppTypography.iconSM,
            color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 卡片小节骨架（与抓包设置页一致的标题行 + 正文）。
class _CaptureCaSectionCard extends StatelessWidget {
  const _CaptureCaSectionCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon,
                    size: AppTypography.iconMD,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 二维码视图：白底衬板保证夜间模式可扫（与下载二维码弹窗同一处理）。
class _QrCodeView extends StatelessWidget {
  const _QrCodeView({required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: AppSpacing.allMD,
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: AppRadius.allMD,
      ),
      child: QrImageView(
        data: data,
        version: QrVersions.auto,
        size: 200,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
      ),
    );
  }
}

/// 抓包设置页（`proxy-http-capture` Todo 21，纯展示 / 触发层）。
///
/// 公开冻结契约 `capture.config.get` / `capture.config.set`（Todo 10）只暴露给
/// [ProxyModule]；本页为**不改动冻结契约**，在页面内声明窄接口
/// [ProxyCaptureSettingsFacade]，生产用 [ProxyModuleCaptureSettingsFacade] 适配，
/// 测试注入假实现即可（无需原生模块 / 平台通道）。
///
/// 覆盖（按功能区自上而下）：
/// * **MITM 总开关**：`enabled`，与首页抓包区块共享同一 `capture.config`；
/// * **上游证书校验**：`skipCertVerify`（默认关），开启需危险二次确认；
/// * **域名白名单**：增删（主门控，命中 SNI/host 才解密）；
/// * **App 白名单**：多选（复用 [ProxyInstalledAppsProvider]，仅域名白名单为空时
///   兜底）；
/// * **内容开关**：Body / WS / H2；
/// * **TLS 端口集合**：只读展示（解密仅作用于这些目的端口）；
/// * **存储统计**：保留 / 淘汰 / 丢弃（来自 `requests.get` 的执行环计数）。
///
/// 保存：全量 `capture.config.set`；失败 → `AppDialogs.showError`，绝不崩溃。
///
/// **纯展示 / 转发层**：不含解析 / 网络 / 路由逻辑（全部在 Rust 的
/// `gstore_mod_proxy`，见 `rust/gstore_mod_proxy/API.md` §2.16）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_capture_ca_page.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';

/// 允许在白名单中保留的条目数上限（镜像 Rust `capture.rs::MAX_ALLOWLIST_ENTRIES`）。
const int kCaptureMaxAllowlistEntries = 256;

/// 单条白名单条目的字节上限（镜像 Rust
/// `capture.rs::MAX_ALLOWLIST_ENTRY_BYTES`，即 DNS 名上限）。
const int kCaptureMaxAllowlistEntryBytes = 253;

/// 「跳过上游证书校验」的风险说明（卡片常显 + 危险确认弹层共用同一文案）。
///
/// 语义：关闭上游 TLS 证书校验后，代理不再验证上游服务器证书，任何人可用任意
/// 证书冒充目标站点，流量可被「二次中间人」窃听 / 篡改，并会转发任何证书的内容；
/// 仅用于自签名来源或企业中间代理。
const String kCaptureSkipCertVerifyRiskText =
    '关闭上游 TLS 证书校验：代理不再验证服务器证书，任何人可用任意证书冒充目标站点，'
    '流量可被「二次中间人」窃听或篡改，并会转发任何证书的内容。'
    '仅用于自签名来源或企业中间代理。';

/// 抓包存储统计（保留 / 容量 / 淘汰 / 丢弃）。
///
/// 这些计数来自执行环（`requests.get` 的 [RequestPage]）；页面只展示。
@immutable
class CaptureStorageStats {
  const CaptureStorageStats({
    this.retained = 0,
    this.capacity = 0,
    this.evicted = 0,
    this.dropped = 0,
  });

  final int retained;
  final int capacity;
  final int evicted;
  final int dropped;
}

/// 抓包设置页所需的模块能力（`capture.config.get` / `capture.config.set` +
/// 执行环存储统计）。
abstract class ProxyCaptureSettingsFacade {
  /// `capture.config.get`：读取当前 MITM / 白名单 / 内容开关配置。
  Future<CaptureConfig> configGet();

  /// `capture.config.set`：提交**全量**配置，返回冻结后的同一形状。
  Future<CaptureConfig> configSet(CaptureConfig next);

  /// 执行环存储统计（保留 / 容量 / 淘汰 / 丢弃）。
  Future<CaptureStorageStats> storageStats();
}

/// 生产适配器：[ProxyModule] → [ProxyCaptureSettingsFacade] 的薄转发。
class ProxyModuleCaptureSettingsFacade implements ProxyCaptureSettingsFacade {
  ProxyModuleCaptureSettingsFacade([ProxyModule? module])
      : _module = module ?? ProxyModule.instance;

  final ProxyModule _module;

  @override
  Future<CaptureConfig> configGet() =>
      _module.invoke(ProxyMethods.captureConfigGet, CaptureConfig.fromJson);

  @override
  Future<CaptureConfig> configSet(CaptureConfig next) => _module.invoke(
        ProxyMethods.captureConfigSet,
        CaptureConfig.fromJson,
        payload: next.toJson(),
      );

  @override
  Future<CaptureStorageStats> storageStats() async {
    // `limit: 1` 即可拿到环计数（records 无关，计数随页返回）。
    final page = await _module.requestsGet(const RequestGetRequest(limit: 1));
    return CaptureStorageStats(
      retained: page.retained,
      capacity: page.capacity,
      evicted: page.evicted,
      dropped: page.dropped,
    );
  }
}

/// 抓包设置页。
class ProxyCaptureSettingsPage extends StatefulWidget {
  const ProxyCaptureSettingsPage({
    super.key,
    this.facade,
    this.installedApps,
    this.routing,
  });

  /// 抓包设置门面（测试可注入假实现；为空时用生产适配器）。
  final ProxyCaptureSettingsFacade? facade;

  /// 已安装应用来源（测试可注入假实现；为空时用平台通道）。
  final ProxyInstalledAppsProvider? installedApps;

  /// 分流门面（应用范围 `routing` 与 VPN 分流耦合 / 漂移检测用）。
  ///
  /// 为空时用生产 [ProxyModuleSettingsFacade]。注入窄接缝便于密闭式组件测试。
  final ProxySplitTunnelFacade? routing;

  @override
  State<ProxyCaptureSettingsPage> createState() =>
      _ProxyCaptureSettingsPageState();
}

/// 「启用应用范围抓包」时对分流的处理结果。
enum _MirrorOutcome {
  /// 分流已是合法镜像，或用户确认后已成功镜像。
  applied,

  /// 用户拒绝切换分流 → 应用范围抓包保持关闭。
  declined,

  /// 读取 / 写入分流失败 → 应用范围抓包保持关闭（绝不静默改路由）。
  failed,
}

class _ProxyCaptureSettingsPageState extends State<ProxyCaptureSettingsPage> {
  late final ProxyCaptureSettingsFacade _facade;
  late final ProxyInstalledAppsProvider _installedApps;
  late final ProxySplitTunnelFacade _routing;

  final TextEditingController _domainInput = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  CaptureConfig _config = const CaptureConfig();
  CaptureStorageStats? _stats;

  /// 已安装应用缓存（`null` = 尚未加载；首次打开选择器时按需枚举）。
  List<InstalledAppOption>? _appsCache;
  Future<List<InstalledAppOption>>? _appsInFlight;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleCaptureSettingsFacade();
    _installedApps = widget.installedApps ?? const PlatformInstalledAppsProvider();
    _routing = widget.routing ?? ProxyModuleSettingsFacade();
    _load();
  }

  @override
  void dispose() {
    _domainInput.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await _facade.configGet();
      if (!mounted) return;
      setState(() {
        _config = config;
        _loading = false;
      });
      unawaited(_reconcileRoutingDrift(config));
      unawaited(_loadStats());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  /// 拉取存储统计（非致命：失败保持占位，不清空已加载配置）。
  Future<void> _loadStats() async {
    try {
      final stats = await _facade.storageStats();
      if (!mounted) return;
      setState(() => _stats = stats);
    } catch (_) {
      if (!mounted) return;
      setState(() => _stats = null);
    }
  }

  // ==================== 证书管理入口 ====================

  /// 「证书管理」：进入 [ProxyCaptureCaPage] 管理 MITM 根证书（生成 / 重置 /
  /// 导出 / 安装）。生产入口由此可达，与 `_promptCaptureNeedsCa` 的文案一致。
  void _openCaManagement() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ProxyCaptureCaPage(),
      ),
    );
  }

  // ==================== 编辑动作（本地，保存时一次性提交） ====================
  void _setEnabled(bool value) =>
      setState(() => _config = _config.copyWith(enabled: value));

  void _addDomain() {
    final raw = _domainInput.text.trim();
    if (raw.isEmpty) return;
    if (raw.length > kCaptureMaxAllowlistEntryBytes) {
      AppDialogs.showError(
        '域名过长：单条上限 $kCaptureMaxAllowlistEntryBytes 字节',
      );
      return;
    }
    if (_config.domainAllowlist.contains(raw)) {
      AppDialogs.showWarning('该域名已在白名单中');
      return;
    }
    if (_config.domainAllowlist.length >= kCaptureMaxAllowlistEntries) {
      AppDialogs.showError('域名白名单已达上限 $kCaptureMaxAllowlistEntries 条');
      return;
    }
    setState(() {
      _config = _config.copyWith(
        domainAllowlist: <String>[..._config.domainAllowlist, raw],
      );
      _domainInput.clear();
    });
  }

  void _removeDomain(String domain) => setState(() {
        _config = _config.copyWith(
          domainAllowlist: _config.domainAllowlist
              .where((entry) => entry != domain)
              .toList(growable: false),
        );
      });

  void _setCaptureBody(bool value) =>
      setState(() => _config = _config.copyWith(captureBody: value));

  void _setCaptureWs(bool value) =>
      setState(() => _config = _config.copyWith(captureWs: value));

  void _setCaptureH2(bool value) =>
      setState(() => _config = _config.copyWith(captureH2: value));

  /// 切换「跳过上游证书校验」。
  ///
  /// 开启属下风险操作：先经统一 [AppDialogs.showConfirmSheet]（`isDangerous:true`）
  /// 二次确认，确认后才把 `skipCertVerify:true` **经既有保存路径**
  /// （`capture.config.set`）持久化；取消则保持关闭、绝不落库。关闭无需确认。
  Future<void> _setSkipCertVerify(bool value) async {
    if (!value) {
      setState(() => _config = _config.copyWith(skipCertVerify: false));
      await _save();
      return;
    }
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '跳过上游证书校验？',
      message: kCaptureSkipCertVerifyRiskText,
      confirmText: '仍然开启',
      cancelText: '取消',
      isDangerous: true,
      icon: const Icon(TablerIcons.shield_off),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _config = _config.copyWith(skipCertVerify: true));
    await _save();
  }

  /// 按需加载已安装应用（页面生命周期内缓存，仅首次枚举；失败回落空列表）。
  Future<List<InstalledAppOption>> _ensureApps() {
    final cached = _appsCache;
    if (cached != null) return Future<List<InstalledAppOption>>.value(cached);
    final inFlight = _appsInFlight;
    if (inFlight != null) return inFlight;
    final future = _installedApps.list().then((apps) {
      _appsCache = apps;
      return apps;
    }).whenComplete(() => _appsInFlight = null);
    _appsInFlight = future;
    return future;
  }

  Future<void> _openAppPicker() async {
    List<InstalledAppOption> apps;
    try {
      apps = await _ensureApps();
    } catch (error) {
      debugPrint('抓包设置：读取已安装应用失败，回落空列表：$error');
      apps = const <InstalledAppOption>[];
    }
    if (!mounted) return;
    final result = await AppSheet.showCustom<Set<String>>(
      context: context,
      builder: (sheetContext) => _CaptureAppPickerSheet(
        apps: apps,
        initial: _config.appAllowlist.toSet(),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      final sorted = result.toList()..sort();
      _config = _config.copyWith(appAllowlist: sorted);
    });
  }

  /// 启用应用范围抓包（routing）时，对 VPN 分流提出的**派生镜像**要求。
  ///
  /// 成立条件：总开关开启 + 范围=`routing` + 域名白名单为空（域名优先）+
  /// App 白名单非空（否则无应用可分流）。
  bool _needsRoutingMirror(CaptureConfig config) =>
      config.enabled &&
      config.appScope == ProxyCaptureAppScope.routing &&
      config.domainAllowlist.isEmpty &&
      config.appAllowlist.isNotEmpty;

  /// 确保 VPN 分流是 [appAllowlist] 的合法镜像。
  ///
  /// 已是镜像 → 直接通过；否则经统一 [AppDialogs.showConfirmSheet] 征求用户同意
  /// 后把分流切为 `allow` + 清单 = [appAllowlist]。**拒绝 / 失败绝不静默重定路由**，
  /// 由调用方保持应用范围抓包关闭。
  Future<_MirrorOutcome> _ensureRoutingMirror(List<String> appAllowlist) async {
    final ProxySettingsConfig split;
    try {
      split = await _routing.loadSplitTunnel();
    } catch (_) {
      return _MirrorOutcome.failed;
    }
    if (split.mirrorsAppAllowlist(appAllowlist)) return _MirrorOutcome.applied;

    final confirmed = await AppDialogs.showConfirmSheet(
      title: '切换 VPN 分流',
      message: '「VPN 分流」范围依赖按应用分流。将把分流模式切换为「仅选中应用」，'
          '清单与抓包 App 白名单保持一致（共 ${appAllowlist.length} 个应用）。',
      confirmText: '切换分流',
      cancelText: '取消',
    );
    if (confirmed != true) return _MirrorOutcome.declined;
    try {
      await _routing.saveSplitTunnel(
        mode: ProxySplitTunnelMode.allow,
        apps: appAllowlist.toSet(),
      );
    } catch (_) {
      return _MirrorOutcome.failed;
    }
    return _MirrorOutcome.applied;
  }

  /// 启动 / 加载对账：`routing` 应用范围抓包与现行分流不一致（漂移）时，
  /// **自动关闭抓包**（`enabled:false`）并提示；绝不静默重写用户分流路由。
  Future<void> _reconcileRoutingDrift(CaptureConfig config) async {
    if (!_needsRoutingMirror(config)) return;
    final ProxySettingsConfig split;
    try {
      split = await _routing.loadSplitTunnel();
    } catch (_) {
      // 读不到分流 → 无法判定，保持现状（下次加载重试）。
      return;
    }
    if (split.mirrorsAppAllowlist(config.appAllowlist)) return;
    try {
      final saved = await _facade.configSet(config.copyWith(enabled: false));
      if (!mounted) return;
      setState(() => _config = saved);
      AppDialogs.showWarning('VPN 分流已变更，应用范围抓包已自动关闭');
    } catch (_) {
      // best-effort：关闭失败不崩，下次加载重试。
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      var next = _config;
      var outcome = _MirrorOutcome.applied;
      if (_needsRoutingMirror(next)) {
        outcome = await _ensureRoutingMirror(next.appAllowlist);
        if (outcome != _MirrorOutcome.applied) {
          // 拒绝 / 失败 → 应用范围抓包保持关闭（域名抓包不受影响）。
          next = next.copyWith(enabled: false);
        }
      }
      final saved = await _facade.configSet(next);
      if (!mounted) return;
      setState(() {
        _config = saved;
        _saving = false;
      });
      switch (outcome) {
        case _MirrorOutcome.applied:
          AppDialogs.showSuccess('抓包设置已保存');
        case _MirrorOutcome.declined:
          AppDialogs.showWarning('未切换分流，应用范围抓包保持关闭');
        case _MirrorOutcome.failed:
          AppDialogs.showError('切换分流失败，应用范围抓包保持关闭');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppDialogs.showError('保存失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('抓包设置'),
        actions: [
          IconButton(
            tooltip: '刷新',
            key: const Key('capture_settings_refresh'),
            icon: const Icon(TablerIcons.refresh),
            onPressed: _loading ? null : _load,
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
    if (_error != null) {
      return _buildError(context);
    }
    return ListView(
      padding: AppSpacing.pagePadding,
      children: [
        _buildMitmCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildUpstreamTlsCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildCaCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildDomainCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildAppCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildContentCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildPortsCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildStorageCard(context),
        const SizedBox(height: AppSpacing.xl),
        FilledButton.icon(
          key: const Key('capture_settings_save'),
          onPressed: _saving ? null : _save,
          icon: const Icon(TablerIcons.device_floppy,
              size: AppTypography.iconSM),
          label: Text(_saving ? '保存中…' : '保存设置'),
        ),
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
            Text('抓包配置加载失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.tonalIcon(
              key: const Key('capture_settings_retry'),
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

  Widget _buildMitmCard(BuildContext context) {
    final theme = Theme.of(context);
    return _CaptureSectionCard(
      icon: TablerIcons.shield_lock,
      title: 'MITM 总开关',
      children: [
        SwitchListTile(
          key: const Key('capture_mitm_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('启用 HTTPS 中间人解密'),
          subtitle: const Text(
            '开启后仅对「域名白名单」命中的主机解密；白名单为空时退化为 App 白名单。'
            '两者皆空则不抓取任何 HTTPS。',
          ),
          value: _config.enabled,
          onChanged: _saving ? null : _setEnabled,
        ),
        Text(
          '与首页「抓包」区块共享同一份 capture.config；此处保存后首页状态即时同步。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.gapSM),
        // 常显提示（不随开关状态显隐）：改动只影响后续新建连接。
        Text(
          key: const Key('capture_existing_conn_hint'),
          '改动仅对新建连接生效；已在运行的 App 连接不会被解密/捕获，'
          '请重启目标 App 或等待其连接重建。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 「上游证书校验」小节：开关默认关；开启需危险二次确认。
  ///
  /// 风险文案 [kCaptureSkipCertVerifyRiskText] 常显（绝不隐藏），并原样用于确认弹层。
  Widget _buildUpstreamTlsCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _CaptureSectionCard(
      icon: TablerIcons.shield_off,
      title: '上游证书校验',
      children: [
        SwitchListTile(
          key: const Key('capture_skip_cert_verify_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('跳过上游证书校验'),
          subtitle: const Text(kCaptureSkipCertVerifyRiskText),
          value: _config.skipCertVerify,
          onChanged: _saving ? null : _setSkipCertVerify,
          secondary: _config.skipCertVerify
              ? Icon(TablerIcons.alert_triangle, color: scheme.error)
              : null,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '默认关闭（严格校验）。仅在明确知道上游为自签名来源或企业中间代理时'
          '临时开启；开启后上游不再验签，可被二次中间人。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 「证书管理」小节：说明 MITM 根证书用途并提供进入 [ProxyCaptureCaPage] 的入口。
  ///
  /// 根证书独立于 `capture.config`（不随保存下发），故本卡只做导航、不参与表单提交。
  Widget _buildCaCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _CaptureSectionCard(
      icon: TablerIcons.certificate,
      title: '证书管理',
      children: [
        Text(
          'HTTPS 解密依赖本机 MITM 根证书：需先生成，再导出并安装到设备证书存储。'
          '启用固定证书（pinning）的 App 不会信任本证书。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('capture_settings_ca_entry'),
            onPressed: _saving ? null : _openCaManagement,
            icon: const Icon(TablerIcons.certificate,
                size: AppTypography.iconSM),
            label: const Text('证书管理'),
          ),
        ),
      ],
    );
  }

  Widget _buildDomainCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final domains = _config.domainAllowlist;
    return _CaptureSectionCard(
      icon: TablerIcons.world,
      title: '域名白名单',
      children: [
        Text(
          '命中 SNI / host 的域名才会被解密；为空时改由 App 白名单兜底。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('capture_domain_field'),
                controller: _domainInput,
                enabled: !_saving,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addDomain(),
                decoration: const InputDecoration(
                  labelText: '添加域名',
                  hintText: 'example.com',
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Padding(
              padding: AppSpacing.onlyTopSM,
              child: FilledButton.tonalIcon(
                key: const Key('capture_domain_add'),
                onPressed: _saving ? null : _addDomain,
                icon: const Icon(TablerIcons.plus, size: AppTypography.iconSM),
                label: const Text('添加'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (domains.isEmpty)
          Text(
            '尚未添加域名（白名单为空）。',
            key: const Key('capture_domain_empty'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final domain in domains)
                InputChip(
                  key: Key('capture_domain_chip_$domain'),
                  label: Text(domain),
                  onDeleted: _saving ? null : () => _removeDomain(domain),
                  deleteIcon: const Icon(TablerIcons.x,
                      size: AppTypography.iconSM),
                ),
            ],
          ),
      ],
    );
  }

  Widget _buildAppCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = _config.appAllowlist.length;
    final routing = _config.appScope == ProxyCaptureAppScope.routing;
    return _CaptureSectionCard(
      icon: TablerIcons.apps,
      title: 'App 白名单',
      children: [
        Text(
          '按包名匹配（best-effort）。仅在域名白名单为空时生效；未知 UID 只会拒绝解密。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text('应用范围判定方式', style: theme.textTheme.labelLarge),
        const SizedBox(height: AppSpacing.xs),
        AppSegmentedButton<ProxyCaptureAppScope>(
          key: const Key('capture_scope_selector'),
          value: _config.appScope,
          enabled: !_saving,
          density: AppSegmentedButton.mediumDensity,
          segments: const <AppSegment<ProxyCaptureAppScope>>[
            AppSegment(
              value: ProxyCaptureAppScope.routing,
              label: 'VPN 分流',
              key: Key('capture_scope_routing'),
            ),
            AppSegment(
              value: ProxyCaptureAppScope.uid,
              label: 'UID 归因',
              key: Key('capture_scope_uid'),
            ),
          ],
          onChanged: _setAppScope,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          routing
              ? '生效模式：VPN 分流（依赖代理分流按应用限定，无需 UID）'
              : '生效模式：UID 归因（Android 10+；未知 UID 拒绝解密）',
          key: const Key('capture_scope_active_mode'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: Text(
                '已选 $count 个应用',
                key: const Key('capture_apps_count'),
                style: theme.textTheme.bodyMedium,
              ),
            ),
            FilledButton.tonalIcon(
              key: const Key('capture_apps_button'),
              onPressed: _saving ? null : _openAppPicker,
              icon: const Icon(TablerIcons.list_check,
                  size: AppTypography.iconSM),
              label: const Text('选择应用'),
            ),
          ],
        ),
      ],
    );
  }

  /// 切换应用范围判定方式（保存时按 `routing` 耦合分流）。
  void _setAppScope(ProxyCaptureAppScope scope) =>
      setState(() => _config = _config.copyWith(appScope: scope));

  Widget _buildContentCard(BuildContext context) {
    return _CaptureSectionCard(
      icon: TablerIcons.adjustments,
      title: '内容开关',
      children: [
        SwitchListTile(
          key: const Key('capture_toggle_body'),
          contentPadding: EdgeInsets.zero,
          title: const Text('抓取请求 / 响应体 (Body)'),
          value: _config.captureBody,
          onChanged: _saving ? null : _setCaptureBody,
        ),
        SwitchListTile(
          key: const Key('capture_toggle_ws'),
          contentPadding: EdgeInsets.zero,
          title: const Text('抓取 WebSocket 帧 (WS)'),
          value: _config.captureWs,
          onChanged: _saving ? null : _setCaptureWs,
        ),
        SwitchListTile(
          key: const Key('capture_toggle_h2'),
          contentPadding: EdgeInsets.zero,
          title: const Text('抓取 HTTP/2 (H2)'),
          value: _config.captureH2,
          onChanged: _saving ? null : _setCaptureH2,
        ),
      ],
    );
  }

  Widget _buildPortsCard(BuildContext context) {
    final theme = Theme.of(context);
    return _CaptureSectionCard(
      icon: TablerIcons.plug,
      title: 'TLS 端口集合',
      children: [
        Text(
          '端口集合：${_config.tlsPorts.join(' / ')}',
          key: const Key('capture_tls_ports'),
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '仅这些目的端口会被 MITM 终止；集合由内核契约固定，本页只读。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildStorageCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = _stats;
    return _CaptureSectionCard(
      icon: TablerIcons.database,
      title: '存储统计',
      children: [
        if (stats == null)
          Text(
            '统计暂不可用',
            key: const Key('capture_storage_unavailable'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          Text(
            '保留 ${stats.retained}/${stats.capacity} · '
            '淘汰 ${stats.evicted} · 丢弃 ${stats.dropped}',
            key: const Key('capture_storage_stats'),
            style: theme.textTheme.bodyMedium,
          ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '淘汰 = 超出容量被回收；丢弃 = 背压期间未能入环。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 卡片小节骨架（与设置页一致的标题行 + 正文）。
class _CaptureSectionCard extends StatelessWidget {
  const _CaptureSectionCard({
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
                Icon(icon, size: AppTypography.iconMD,
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

/// App 白名单多选弹层（统一 [AppSheetScaffold] 骨架）。
///
/// 空列表渲染显式空态；结果经 `pop(Set)` 返回。
class _CaptureAppPickerSheet extends StatefulWidget {
  const _CaptureAppPickerSheet({required this.apps, required this.initial});

  final List<InstalledAppOption> apps;
  final Set<String> initial;

  @override
  State<_CaptureAppPickerSheet> createState() => _CaptureAppPickerSheetState();
}

class _CaptureAppPickerSheetState extends State<_CaptureAppPickerSheet> {
  late final Set<String> _selected = <String>{...widget.initial};
  String _query = '';

  List<InstalledAppOption> get _filtered {
    final query = _query.toLowerCase();
    final List<InstalledAppOption> matches = query.isEmpty
        ? <InstalledAppOption>[...widget.apps]
        : widget.apps
            .where((app) =>
                app.name.toLowerCase().contains(query) ||
                app.packageName.toLowerCase().contains(query))
            .toList();
    matches.sort((a, b) {
      final aSelected = _selected.contains(a.packageName);
      final bSelected = _selected.contains(b.packageName);
      if (aSelected != bSelected) return aSelected ? -1 : 1;
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) return byName;
      return a.packageName.compareTo(b.packageName);
    });
    return matches;
  }

  void _toggle(String packageName) {
    setState(() {
      if (!_selected.add(packageName)) _selected.remove(packageName);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final filtered = _filtered;
    return AppSheetScaffold(
      title: '选择应用',
      subtitle: widget.apps.isEmpty ? '无可用应用' : '共 ${widget.apps.length} 个已安装应用',
      icon: const Icon(TablerIcons.apps),
      contentPadding: AppSpacing.onlyHorizontalXL,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('capture_apps_confirm'),
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确定'),
        ),
      ],
      scrollable: false,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('capture_app_search'),
            onChanged: (value) => setState(() => _query = value.trim()),
            decoration: const InputDecoration(
              labelText: '搜索',
              hintText: '应用名 / 包名',
              prefixIcon: Icon(TablerIcons.search),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (widget.apps.isEmpty)
            Padding(
              key: const Key('capture_apps_empty'),
              padding: AppSpacing.onlyVerticalXXL,
              child: Column(
                children: [
                  Icon(TablerIcons.apps,
                      size: AppTypography.iconXXXL,
                      color: scheme.onSurfaceVariant),
                  const SizedBox(height: AppSpacing.md),
                  Text('未获取到已安装应用', style: theme.textTheme.titleMedium),
                ],
              ),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: AppSpacing.onlyVerticalXXL,
              child: Text(
                '没有匹配的应用',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            SizedBox(
              height: 340,
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final app = filtered[index];
                  final checked = _selected.contains(app.packageName);
                  return InkWell(
                    key: Key('capture_app_${app.packageName}'),
                    onTap: () => _toggle(app.packageName),
                    child: Padding(
                      padding: AppSpacing.onlyVerticalXS,
                      child: Row(
                        children: [
                          Checkbox(
                            value: checked,
                            onChanged: (_) => _toggle(app.packageName),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  app.name,
                                  style: theme.textTheme.bodyMedium,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  app.packageName,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

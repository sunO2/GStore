import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

import 'proxy_settings_facade.dart';

/// 代理设置页（Todos 23 / 28，纯展示 / 触发层）。
///
/// 覆盖：
/// * **应用分流**：全局 / 仅选中 / 排除选中 + 已安装应用选择器（统一底部弹层）；
/// * **始终开启**：应用侧意图开关 + 系统设置引导（应用无法直接切换系统开关）；
/// * **本地端口 / 混合入站**：本地持久化；
/// * **局域网监听 (LAN)**：`lan.get` / `lan.set` / `lan.status`（默认关闭，
///   未配置认证时展示安全警告）；
/// * **日志级别**：`log.set_level`；
/// * **重置统计**：危险确认弹层 → `stats.domain.reset`；
/// * **引擎调试信息**：`version` / `ping` / `core.get_mode`。
///
/// 所有解析 / 网络 / 路由 / 统计逻辑都在 Rust 侧（`gstore_mod_proxy`），本页只
/// 翻译并持久化。门面经构造函数注入，测试无需原生模块 / 平台通道。
class ProxySettingsPage extends StatefulWidget {
  const ProxySettingsPage({super.key, this.facade});

  /// 设置门面（测试可注入假实现；为空时用生产适配器）。
  final ProxySettingsFacade? facade;

  @override
  State<ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<ProxySettingsPage> {
  late final ProxySettingsFacade _facade;

  final TextEditingController _mixedPort = TextEditingController();
  final TextEditingController _socksPort = TextEditingController();
  final TextEditingController _httpPort = TextEditingController();
  final TextEditingController _lanPort = TextEditingController();
  final TextEditingController _lanBind = TextEditingController();
  final TextEditingController _lanUser = TextEditingController();
  final TextEditingController _lanPass = TextEditingController();
  final TextEditingController _lanAllowed = TextEditingController();

  bool _loading = true;
  String? _error;
  bool _busy = false;
  ProxySettingsConfig _config = const ProxySettingsConfig();
  List<InstalledAppOption> _apps = const <InstalledAppOption>[];
  ProxyEngineInfo _engine = const ProxyEngineInfo();
  ProxyLanConfig _lan = const ProxyLanConfig();
  ProxyLanStatus _lanStatus = const ProxyLanStatus();

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleSettingsFacade();
    _syncPortControllers(_config.localPorts);
    _syncLanControllers(_lan);
    _load();
  }

  @override
  void dispose() {
    _mixedPort.dispose();
    _socksPort.dispose();
    _httpPort.dispose();
    _lanPort.dispose();
    _lanBind.dispose();
    _lanUser.dispose();
    _lanPass.dispose();
    _lanAllowed.dispose();
    super.dispose();
  }

  void _syncPortControllers(ProxyLocalPorts ports) {
    _mixedPort.text = '${ports.mixedPort}';
    _socksPort.text = '${ports.socksPort}';
    _httpPort.text = '${ports.httpPort}';
  }

  void _syncLanControllers(ProxyLanConfig config) {
    _lanPort.text = '${config.port}';
    _lanBind.text = config.bindAddress;
    _lanUser.text = config.authUser;
    _lanPass.text = config.authPass;
    _lanAllowed.text = config.allowedIps.join(', ');
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await _facade.loadSettings();
      final apps = await _facade.loadInstalledApps();
      final engine = await _facade.loadEngineInfo();
      ProxyLanConfig? lan;
      ProxyLanStatus? lanStatus;
      try {
        lan = await _facade.loadLanConfig();
      } catch (_) {
        // 模块不可用 → 保留默认（LAN 关闭）
      }
      try {
        lanStatus = await _facade.loadLanStatus();
      } catch (_) {
        // 模块不可用 → 保留默认（未监听）
      }
      if (!mounted) return;
      setState(() {
        _config = config;
        _apps = apps;
        _engine = engine;
        if (lan != null) _lan = lan;
        if (lanStatus != null) _lanStatus = lanStatus;
        _loading = false;
      });
      _syncPortControllers(config.localPorts);
      _syncLanControllers(_lan);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  Future<void> _refreshEngine() async {
    final engine = await _facade.loadEngineInfo();
    if (!mounted) return;
    setState(() => _engine = engine);
  }

  // ==================== 应用分流 ====================

  Future<void> _saveSplitTunnel({
    ProxySplitTunnelMode? mode,
    Set<String>? apps,
  }) async {
    final nextMode = mode ?? _config.splitMode;
    final nextApps = apps ?? _config.selectedApps;
    final previous = _config;
    setState(() {
      _busy = true;
      _config = _config.copyWith(splitMode: nextMode, selectedApps: nextApps);
    });
    try {
      await _facade.saveSplitTunnel(mode: nextMode, apps: nextApps);
      if (!mounted) return;
      AppDialogs.showSuccess('分流设置已保存');
    } catch (error) {
      if (!mounted) return;
      setState(() => _config = previous);
      AppDialogs.showError('分流设置保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openAppPicker() async {
    final result = await AppSheet.showCustom<Set<String>>(
      context: context,
      builder: (sheetContext) => _AppPickerSheet(
        apps: _apps,
        initial: _config.selectedApps,
      ),
    );
    if (!mounted || result == null) return;
    await _saveSplitTunnel(apps: result);
  }

  // ==================== 始终开启 ====================

  Future<void> _toggleAlwaysOn(bool value) async {
    final previous = _config;
    setState(() => _config = _config.copyWith(alwaysOnIntent: value));
    try {
      await _facade.setAlwaysOnIntent(value);
      if (!mounted) return;
      AppDialogs.showSuccess(value ? '已记录「始终开启」意图' : '已关闭「始终开启」意图');
    } catch (error) {
      if (!mounted) return;
      setState(() => _config = previous);
      AppDialogs.showError('保存失败：$error');
    }
  }

  Future<void> _showAlwaysOnHelp() async {
    await AppDialogs.showAlertSheet(
      title: '系统「始终开启的 VPN」',
      message: '应用无法直接修改系统的「始终开启的 VPN」开关。\n\n'
          '请前往「系统设置 → 网络与互联网 → VPN → GStore」，手动开启'
          '「始终开启的 VPN」。开启后系统会在开机 / 网络切换时以已保存的配置'
          '自动拉起隧道；此处开关仅记录应用侧意图。',
    );
  }

  // ==================== 本地端口 ====================

  Future<void> _saveLocalPorts() async {
    final mixed = int.tryParse(_mixedPort.text.trim());
    final socks = int.tryParse(_socksPort.text.trim());
    final http = int.tryParse(_httpPort.text.trim());
    if (mixed == null || socks == null || http == null) {
      AppDialogs.showError('端口必须是数字');
      return;
    }
    final ports = ProxyLocalPorts(
      mixedPort: mixed,
      socksPort: socks,
      httpPort: http,
      allowLan: _config.localPorts.allowLan,
    );
    setState(() => _busy = true);
    try {
      await _facade.saveLocalPorts(ports);
      if (!mounted) return;
      setState(() => _config = _config.copyWith(localPorts: ports));
      AppDialogs.showSuccess('端口设置已保存');
    } catch (error) {
      if (!mounted) return;
      AppDialogs.showError('端口保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleAllowLan(bool value) async {
    final ports = _config.localPorts.copyWith(allowLan: value);
    final previous = _config;
    setState(() => _config = _config.copyWith(localPorts: ports));
    try {
      await _facade.saveLocalPorts(ports);
    } catch (error) {
      if (!mounted) return;
      setState(() => _config = previous);
      AppDialogs.showError('保存失败：$error');
    }
  }

  // ==================== 局域网监听（LAN） ====================

  ProxyLanConfig _lanFromFields() {
    final port = int.tryParse(_lanPort.text.trim()) ?? _lan.port;
    final allowed = _lanAllowed.text
        .split(RegExp(r'[,\s]+'))
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
    final bind = _lanBind.text.trim();
    return _lan.copyWith(
      port: port,
      bindAddress: bind.isEmpty ? '0.0.0.0' : bind,
      authUser: _lanUser.text.trim(),
      authPass: _lanPass.text,
      allowedIps: allowed,
    );
  }

  Future<void> _toggleLan(bool value) async {
    setState(() => _lan = _lan.copyWith(enabled: value));
    await _applyLanConfig();
  }

  Future<void> _applyLanConfig() async {
    if (_busy) return;
    final next = _lanFromFields();
    setState(() {
      _busy = true;
      _lan = next;
    });
    try {
      final status = await _facade.saveLanConfig(next);
      if (!mounted) return;
      setState(() {
        _lanStatus = status;
        if (status.config != null) _lan = status.config!;
        _busy = false;
      });
      _syncLanControllers(_lan);
      if (_lan.needsWarning || status.hasWarning) {
        AppDialogs.showWarning('LAN 已启用但未配置认证，同一网络下的任何设备都可使用此代理');
      } else {
        AppDialogs.showSuccess('LAN 设置已保存');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppDialogs.showError('LAN 设置失败：$error');
    }
  }

  Future<String> _copyableLanAddress() async {
    if (_lanStatus.addresses.isEmpty) return '';
    final raw = _lanStatus.addresses.first;
    final separator = raw.lastIndexOf(':');
    final host = separator > 0 ? raw.substring(0, separator) : raw;
    if (host == '0.0.0.0' || host == '::' || host.isEmpty) {
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        for (final interface in interfaces) {
          for (final address in interface.addresses) {
            if (!address.isLoopback) return '${address.address}:${_lan.port}';
          }
        }
      } catch (_) {
        // 受限环境（无网卡枚举）→ 回退到绑定地址
      }
    }
    return raw;
  }

  Future<void> _copyLanAddress() async {
    final text = await _copyableLanAddress();
    if (text.isEmpty || !mounted) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppDialogs.showSuccess('已复制到剪贴板');
  }

  // ==================== 日志级别 / 统计 ====================

  Future<void> _setLogLevel(ProxyLogLevel level) async {
    final previous = _config;
    setState(() => _config = _config.copyWith(logLevel: level));
    try {
      await _facade.setLogLevel(level);
      if (!mounted) return;
      AppDialogs.showSuccess('日志级别已设为 ${level.wire.toUpperCase()}');
    } catch (error) {
      if (!mounted) return;
      setState(() => _config = previous);
      AppDialogs.showError('级别设置失败：$error');
    }
  }

  Future<void> _resetStats() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '重置域名统计',
      message: '将清空域名聚合与持久化统计行，确定继续吗？',
      confirmText: '重置',
      isDangerous: true,
      icon: const Icon(Icons.restart_alt),
    );
    if (ok != true || !mounted) return;
    try {
      final result = await _facade.resetStats();
      if (!mounted) return;
      AppDialogs.showSuccess('已重置 ${result.cleared} 条统计');
    } on ProxyModuleException catch (error) {
      AppDialogs.showError(error.message, title: '重置失败');
    } catch (error) {
      AppDialogs.showError('重置失败：$error');
    }
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('代理设置'),
        actions: [
          IconButton(
            tooltip: '刷新调试信息',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refreshEngine,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final error = _error;
    if (error != null) {
      return _SettingsMessageState(
        icon: Icons.error_outline,
        title: '设置不可用',
        message: error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: AppSpacing.allLG,
        children: [
          _buildSplitTunnelCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildAlwaysOnCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildLocalPortsCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildLanCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildLogLevelCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildStatsCard(context),
          const SizedBox(height: AppSpacing.lg),
          _buildEngineCard(context),
        ],
      ),
    );
  }

  Widget _buildSplitTunnelCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectedCount = _config.selectedApps.length;
    return _SectionCard(
      icon: Icons.apps_outlined,
      title: '应用分流',
      children: [
        SegmentedButton<ProxySplitTunnelMode>(
          key: const Key('split_mode_selector'),
          segments: const [
            ButtonSegment(
              value: ProxySplitTunnelMode.full,
              label: Text('全局'),
            ),
            ButtonSegment(
              value: ProxySplitTunnelMode.allow,
              label: Text('仅选中'),
            ),
            ButtonSegment(
              value: ProxySplitTunnelMode.disallow,
              label: Text('排除选中'),
            ),
          ],
          selected: {_config.splitMode},
          showSelectedIcon: false,
          onSelectionChanged: _busy
              ? null
              : (selection) =>
                  _saveSplitTunnel(mode: selection.first),
        ),
        const SizedBox(height: AppSpacing.md),
        if (_config.splitMode == ProxySplitTunnelMode.full)
          Text(
            '全局模式：所有应用都通过代理。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else
          Row(
            children: [
              Expanded(
                child: Text(
                  '已选 $selectedCount 个应用',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TextButton(
                key: const Key('split_apps_button'),
                onPressed: _busy ? null : _openAppPicker,
                child: const Text('选择应用'),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildAlwaysOnCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _SectionCard(
      icon: Icons.power_settings_new_outlined,
      title: '始终开启',
      children: [
        SwitchListTile(
          key: const Key('always_on_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('记录「始终开启」意图'),
          subtitle: const Text('应用无法直接切换系统开关，需在系统设置中手动开启。'),
          value: _config.alwaysOnIntent,
          onChanged: _busy ? null : _toggleAlwaysOn,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('always_on_help'),
            onPressed: _showAlwaysOnHelp,
            icon: const Icon(Icons.help_outline, size: AppTypography.iconSM),
            label: const Text('如何开启系统「始终开启的 VPN」？'),
          ),
        ),
        Text(
          '关闭应用后，系统可能停止隧道。开启系统「始终开启」后，系统会在开机 / '
          '网络切换时按已保存配置自动恢复。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildLocalPortsCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return _SectionCard(
      icon: Icons.settings_ethernet_outlined,
      title: '本地端口 / 混合入站',
      children: [
        TextField(
          key: const Key('local_mixed_port_field'),
          controller: _mixedPort,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '混合端口 (mixed)',
            hintText: '7890',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('local_socks_port_field'),
          controller: _socksPort,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'SOCKS 端口',
            hintText: '7891',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('local_http_port_field'),
          controller: _httpPort,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'HTTP 端口',
            hintText: '7892',
          ),
        ),
        SwitchListTile(
          key: const Key('local_allow_lan_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('允许局域网访问 (allow-lan)'),
          value: _config.localPorts.allowLan,
          onChanged: _busy ? null : _toggleAllowLan,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('local_ports_save'),
            onPressed: _busy ? null : _saveLocalPorts,
            icon: const Icon(Icons.save_outlined, size: AppTypography.iconSM),
            label: const Text('保存端口设置'),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '说明：本地端口为应用侧配置；共享给其它设备请使用下方「局域网监听 (LAN)」。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildLanCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showWarning = _lan.needsWarning || _lanStatus.hasWarning;
    return _SectionCard(
      icon: Icons.lan_outlined,
      title: '局域网监听 (LAN)',
      children: [
        SwitchListTile(
          key: const Key('lan_enabled_switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('允许局域网设备使用本机代理'),
          subtitle: Text(
            _lanStatus.bound
                ? '监听中：${_lanStatus.addresses.join(', ')}'
                : '未监听（默认关闭）',
          ),
          value: _lan.enabled,
          onChanged: _busy ? null : _toggleLan,
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const Key('lan_port_field'),
                controller: _lanPort,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'LAN 端口',
                  hintText: '1087',
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: TextField(
                key: const Key('lan_bind_field'),
                controller: _lanBind,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '监听地址',
                  hintText: '0.0.0.0',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('lan_auth_user_field'),
          controller: _lanUser,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '认证用户名（可选）',
            hintText: 'user',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('lan_auth_pass_field'),
          controller: _lanPass,
          enabled: !_busy,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: '认证密码（可选）',
            hintText: 'password',
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          key: const Key('lan_allowed_ips_field'),
          controller: _lanAllowed,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '允许的 IP / CIDR（逗号分隔，留空=不限）',
            hintText: '192.168.1.0/24',
          ),
        ),
        if (showWarning) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            _lanStatus.warning ?? '已启用但未配置认证：同一网络下的任何设备都可使用此代理。',
            key: const Key('lan_warning_text'),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: Text(
                _lanStatus.addresses.isEmpty
                    ? '监听地址：未监听'
                    : '监听地址：${_lanStatus.addresses.first}',
                key: const Key('lan_address_text'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            IconButton(
              key: const Key('lan_copy_address'),
              onPressed: _lanStatus.bound ? _copyLanAddress : null,
              icon: const Icon(Icons.copy_outlined, size: AppTypography.iconSM),
              tooltip: '复制地址',
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('lan_save_button'),
            onPressed: _busy ? null : _applyLanConfig,
            icon: const Icon(Icons.save_outlined, size: AppTypography.iconSM),
            label: const Text('保存 LAN 设置'),
          ),
        ),
      ],
    );
  }

  Widget _buildLogLevelCard(BuildContext context) {
    return _SectionCard(
      icon: Icons.article_outlined,
      title: '日志级别',
      children: [
        SegmentedButton<ProxyLogLevel>(
          key: const Key('settings_log_level_selector'),
          segments: const [
            ButtonSegment(value: ProxyLogLevel.debug, label: Text('DEBUG')),
            ButtonSegment(value: ProxyLogLevel.info, label: Text('INFO')),
            ButtonSegment(value: ProxyLogLevel.warn, label: Text('WARN')),
            ButtonSegment(value: ProxyLogLevel.error, label: Text('ERROR')),
          ],
          selected: {_config.logLevel},
          showSelectedIcon: false,
          onSelectionChanged: _busy
              ? null
              : (selection) => _setLogLevel(selection.first),
        ),
      ],
    );
  }

  Widget _buildStatsCard(BuildContext context) {
    final theme = Theme.of(context);
    return _SectionCard(
      icon: Icons.bar_chart_outlined,
      title: '域名统计',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            key: const Key('stats_reset_button'),
            onPressed: _busy ? null : _resetStats,
            icon: const Icon(Icons.restart_alt, size: AppTypography.iconSM),
            label: const Text('重置域名统计'),
            style: FilledButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '重置会清空域名聚合与持久化统计行，操作不可撤销。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildEngineCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final version = _engine.version;
    final ping = _engine.ping;
    final mode = _engine.mode;
    return _SectionCard(
      icon: Icons.memory_outlined,
      title: '引擎调试信息',
      trailing: IconButton(
        key: const Key('engine_refresh'),
        tooltip: '刷新',
        icon: const Icon(Icons.refresh, size: AppTypography.iconMD),
        onPressed: _refreshEngine,
      ),
      children: [
        if (_engine.isEmpty)
          Text(
            '代理模块不可用，暂无调试信息。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          )
        else ...[
          if (version != null) ...[
            _kv(theme, '模块版本', version.moduleVersion),
            _kv(theme, 'API 版本', '${version.apiVersion}'),
            _kv(theme, '宿主 ABI', '${version.minHostAbi} ≤ ${version.hostAbi}'),
            _kv(theme, 'meow 版本', version.meowRev),
            _kv(theme, '目标架构', version.targetArch),
          ],
          if (ping != null) ...[
            _kv(theme, '心跳', ping.pong ? '正常' : '无响应'),
            if (ping.state != null) _kv(theme, '引擎状态', ping.state!.wire),
            if (ping.mode != null) _kv(theme, '引擎模式', ping.mode!.wire),
            if (ping.protectFdPresent != null)
              _kv(theme, 'protect_fd', ping.protectFdPresent! ? '已注入' : '缺失'),
            if (ping.instanceId != null)
              _kv(theme, '实例 ID', '${ping.instanceId}'),
          ],
          if (mode != null) ...[
            _kv(theme, '当前模式', mode.mode.wire),
            _kv(theme, '当前状态', mode.state.wire),
          ],
        ],
      ],
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== 通用小节卡片 ====================

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.children,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;
  final Widget? trailing;

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
                if (trailing != null) trailing!,
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

// ==================== 应用选择弹层 ====================

/// 已安装应用多选弹层（统一 [AppSheetScaffold] 骨架）。
///
/// 空列表渲染**显式空态**（非空白、不崩溃）；选择结果经 `pop(Set)` 返回。
class _AppPickerSheet extends StatefulWidget {
  const _AppPickerSheet({required this.apps, required this.initial});

  final List<InstalledAppOption> apps;
  final Set<String> initial;

  @override
  State<_AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<_AppPickerSheet> {
  late final Set<String> _selected = <String>{...widget.initial};
  String _query = '';

  List<InstalledAppOption> get _filtered {
    if (_query.isEmpty) return widget.apps;
    final q = _query.toLowerCase();
    return widget.apps
        .where((app) =>
            app.name.toLowerCase().contains(q) ||
            app.packageName.toLowerCase().contains(q))
        .toList();
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
      icon: const Icon(Icons.apps_outlined),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('split_apps_confirm'),
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确定'),
        ),
      ],
      scrollable: false,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('split_app_search'),
            onChanged: (value) => setState(() => _query = value.trim()),
            decoration: const InputDecoration(
              labelText: '搜索',
              hintText: '应用名 / 包名',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (widget.apps.isEmpty)
            Padding(
              key: const Key('split_apps_empty'),
              padding: AppSpacing.onlyVerticalXXL,
              child: Column(
                children: [
                  Icon(Icons.apps_outlined,
                      size: AppTypography.iconXXXL,
                      color: scheme.onSurfaceVariant),
                  const SizedBox(height: AppSpacing.md),
                  Text('未获取到已安装应用', style: theme.textTheme.titleMedium),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '请确认已授予应用列表权限，或稍后重试。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
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
                  return _AppPickerRow(
                    key: Key('split_app_${app.packageName}'),
                    app: app,
                    checked: checked,
                    onToggle: () => _toggle(app.packageName),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _AppPickerRow extends StatelessWidget {
  const _AppPickerRow({
    super.key,
    required this.app,
    required this.checked,
    required this.onToggle,
  });

  final InstalledAppOption app;
  final bool checked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: AppSpacing.onlyVerticalXS,
        child: Row(
          children: [
            Checkbox(value: checked, onChanged: (_) => onToggle()),
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
                      color: theme.colorScheme.onSurfaceVariant,
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
  }
}

// ==================== 空 / 错误态 ====================

class _SettingsMessageState extends StatelessWidget {
  const _SettingsMessageState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: AppTypography.iconXXXL,
                color: scheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpacing.lg),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

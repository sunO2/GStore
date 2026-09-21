import 'package:flutter/material.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';

/// 代理状态页（最小骨架，纯展示）。
///
/// **只消费 [ProxyFacade]**：状态文字、模式与错误全部由门面（模块事件 / ping）
/// 驱动；连接开关是**占位**，不含任何解析 / 网络 / 路由逻辑（全部在 Rust）。
///
/// 模块未安装 / 不可用时展示结构化错误态与「重试」，绝不崩溃。
class ProxyHomePage extends StatefulWidget {
  const ProxyHomePage({super.key, this.facade});

  /// 门面（测试可注入假实现；为空时用生产单例 [ProxyModule.instance]）。
  final ProxyFacade? facade;

  @override
  State<ProxyHomePage> createState() => _ProxyHomePageState();
}

class _ProxyHomePageState extends State<ProxyHomePage> {
  late final ProxyFacade _facade;
  StreamSubscription<ProxyEvent>? _eventSub;

  bool _loading = true;
  String? _loadError;
  ProxyVersionInfo? _version;
  ProxyConnState? _connState;
  ProxyMode _mode = ProxyMode.unknown;
  ProxyStateError? _stateError;
  String? _stateReason;
  ProxyStatsEvent? _stats;
  ProxyNodeDelayEvent? _nodeDelay;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModule.instance;
    _eventSub = _facade.events.listen(_onEvent, onError: _onEventError);
    _load();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final ping = await _facade.ping();
      final version = await _facade.version();
      if (!mounted) return;
      setState(() {
        _connState = ping.state ?? ProxyConnState.stopped;
        _mode = ping.mode ?? ProxyMode.unknown;
        _version = version;
        _loading = false;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = '代理模块加载失败：$error';
        _loading = false;
      });
    }
  }

  void _onEvent(ProxyEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case ProxyStateEvent():
          _connState = event.state;
          _mode = event.mode;
          _stateError = event.error;
          _stateReason = event.reason;
        case ProxyModeEvent():
          _mode = event.mode;
        case ProxyStatsEvent():
          _stats = event;
        case ProxyNodeDelayEvent():
          _nodeDelay = event;
        case ProxySubscriptionUpdatedEvent():
        case ProxySubscriptionAddedEvent():
        case ProxySubscriptionRemovedEvent():
        case ProxySubscriptionProgressEvent():
        case ProxySubscriptionFailedEvent():
        case ProxyConnEvent():
        case ProxyDnsEvent():
        case ProxyTunReleasedEvent():
        case ProxyConfigAppliedEvent():
          break;
      }
    });
  }

  void _onEventError(Object error) {
    if (!mounted) return;
    setState(() => _loadError = '代理事件流错误：$error');
  }

  ProxyConnState get _effectiveState => _connState ?? ProxyConnState.stopped;

  bool get _isConnected => _effectiveState == ProxyConnState.running;

  String get _statusText => switch (_effectiveState) {
        ProxyConnState.stopped => '未连接',
        ProxyConnState.starting => '正在连接…',
        ProxyConnState.running => '已连接',
        ProxyConnState.stopping => '正在断开…',
        ProxyConnState.unknown => '状态未知',
      };

  String get _modeText => switch (_mode) {
        ProxyMode.off => '关闭',
        ProxyMode.vpn => 'VPN',
        ProxyMode.lanProxy => '局域网代理',
        ProxyMode.unknown => '未知',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('代理')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final loadError = _loadError;
    if (loadError != null) {
      return _buildUnavailable(context, loadError);
    }
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        _buildStatusCard(context),
        const SizedBox(height: AppSpacing.lg),
        _buildToggleCard(context),
        if (_stats != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _buildStatsCard(context, _stats!),
        ],
        if (_nodeDelay != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _buildDelayCard(context, _nodeDelay!),
        ],
        if (_version != null) ...[
          const SizedBox(height: AppSpacing.lg),
          _buildVersionCard(context, _version!),
        ],
      ],
    );
  }

  /// 模块未安装 / 不可用：结构化错误态（非崩溃）。
  Widget _buildUnavailable(BuildContext context, String message) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: AppSpacing.allLG,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: AppSpacing.allXL,
            child: Column(
              children: [
                Icon(
                  Icons.extension_off_outlined,
                  size: AppTypography.iconXXXL,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '代理模块不可用',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.lg),
                FilledButton(
                  onPressed: _load,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusColor = _stateError != null
        ? scheme.error
        : _isConnected
            ? scheme.primary
            : scheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isConnected
                      ? Icons.shield_outlined
                      : Icons.shield_moon_outlined,
                  size: AppTypography.iconXL,
                  color: statusColor,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    _statusText,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '模式：$_modeText',
              style: theme.textTheme.bodyMedium,
            ),
            if (_stateReason != null && _stateReason!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                _stateReason!,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_stateError != null) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                width: double.infinity,
                padding: AppSpacing.allMD,
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: AppRadius.allMD,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _stateError!.code.isEmpty
                          ? '代理引擎错误'
                          : _stateError!.code,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: AppTypography.weightMedium,
                      ),
                    ),
                    if (_stateError!.message.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        _stateError!.message,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 连接开关（占位）：仅反映门面状态，点击提示后续开放。
  Widget _buildToggleCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        title: const Text('连接'),
        subtitle: const Text('连接开关（占位，由 Rust 引擎驱动）'),
        value: _isConnected,
        onChanged: (_) => AppDialogs.showInfo('连接功能将在后续版本开放'),
      ),
    );
  }

  Widget _buildStatsCard(BuildContext context, ProxyStatsEvent stats) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('流量', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            _statsRow(theme, '上传', _formatBytes(stats.uploadBytes)),
            _statsRow(theme, '下载', _formatBytes(stats.downloadBytes)),
            _statsRow(theme, '活动连接', '${stats.activeConns}'),
          ],
        ),
      ),
    );
  }

  Widget _statsRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: AppSpacing.onlyVerticalXS,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _buildDelayCard(BuildContext context, ProxyNodeDelayEvent delay) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.speed_outlined),
        title: Text(delay.node.isEmpty ? delay.group : delay.node),
        subtitle: Text(delay.group),
        trailing: Text(
          delay.error == null ? '${delay.delayMs} ms' : '失败',
          style: theme.textTheme.labelLarge?.copyWith(
            color: delay.error == null
                ? theme.colorScheme.primary
                : theme.colorScheme.error,
          ),
        ),
      ),
    );
  }

  Widget _buildVersionCard(BuildContext context, ProxyVersionInfo version) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('模块信息', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            _statsRow(theme, '版本', version.moduleVersion),
            _statsRow(theme, 'API', '${version.apiVersion}'),
            _statsRow(
              theme,
              'Host ABI',
              '${version.hostAbi}（最低 ${version.minHostAbi}）',
            ),
            if (version.targetArch.isNotEmpty)
              _statsRow(theme, '架构', version.targetArch),
          ],
        ),
      ),
    );
  }

  /// 字节格式化（纯展示；不做任何网络 / 解析）。
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

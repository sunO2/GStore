import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/config_reactive.dart';

/// GitHub 代理预设地址
const List<String> presetProxyHosts = [
  'https://gh-proxy.org/',
  'https://v4.gh-proxy.org/',
  'https://v6.gh-proxy.org/',
  'https://cdn.gh-proxy.org/',
  'https://axisnow.gh-proxy.org/',
];

/// 显示统一「下载设置」弹层（传输 + 网络/代理）。
///
/// 这是全应用**唯一**的可编辑下载/代理设置入口：设置页只保留一个跳转项，
/// 下载管理页 AppBar 也打开同一个弹层，避免两处重复控件。
Future<void> showDownloadSettingsSheet(BuildContext context) {
  return AppSheet.showCustom<void>(
    context: context,
    builder: (_) => const _DownloadSettingsSheet(),
  );
}

/// 下载设置弹层主体（统一 [AppSheetScaffold] 骨架）。
class _DownloadSettingsSheet extends StatelessWidget {
  const _DownloadSettingsSheet();

  /// 分组标题（主题色 + 半粗，带轻微上下留白）
  Widget _sectionLabel(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        top: AppSpacing.md,
        bottom: AppSpacing.sm,
      ),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: AppTypography.weightSemiBold,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: '下载设置',
      subtitle: '传输与代理设置',
      icon: const Icon(TablerIcons.adjustments),
      contentPadding: AppSpacing.onlyHorizontalXL,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
      // Material 承载 ListTile 的底色与水波纹：AppSheetScaffold 外层是带底色的
      // DecoratedBox，若不在此处提供 Material，ListTile 会命中框架的
      // 「背景/水波纹不可见」断言（debug 下直接报错）。
      content: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionLabel(context, '传输'),
            // 多段下载开关
            const ConfigReactive(
              keys: <String>{ConfigKeys.downloadMultiSegmentEnabled},
              child: _MultiSegmentDownloadTile(),
            ),
            const Divider(height: 1),
            // 最大并发下载数
            const ConfigReactive(
              keys: <String>{ConfigKeys.downloadMaxConcurrent},
              child: _MaxConcurrentDownloadTile(),
            ),
            const Divider(height: 1),
            // 仅WiFi下载
            const ConfigReactive(
              keys: <String>{ConfigKeys.downloadWifiOnly},
              child: _WifiOnlyDownloadTile(),
            ),
            const Divider(height: 1),
            // 最大重试次数
            const ConfigReactive(
              keys: <String>{ConfigKeys.downloadMaxRetries},
              child: _MaxRetryCountTile(),
            ),
            const SizedBox(height: AppSpacing.xl),
            _sectionLabel(context, '网络'),
            const _GitHubProxySection(),
          ],
        ),
      ),
    );
  }
}

/// GitHub 代理内联区块（不再嵌套二级弹层）。
///
/// 复刻原设置页代理弹层的交互：输入框/预设下拉即生效，单独「应用代理」
/// 按钮归一化保存；「下载自动使用代理」开关在代理前缀为空时置灰。
class _GitHubProxySection extends StatefulWidget {
  const _GitHubProxySection();

  @override
  State<_GitHubProxySection> createState() => _GitHubProxySectionState();
}

class _GitHubProxySectionState extends State<_GitHubProxySection> {
  late final TextEditingController _controller =
      TextEditingController(text: getProxy());
  bool _autoProxyEnabled = true;
  bool _loaded = false;

  /// 最近一次已应用的代理值（归一化后）；用于判断「应用代理」是否可点。
  late String _appliedProxy = _normalizeProxy(getProxy());

  /// 归一化：trim；非空时补尾部 '/'；空串表示不使用代理。
  static String _normalizeProxy(String raw) {
    final value = raw.trim();
    if (value.isNotEmpty && !value.endsWith('/')) {
      return '$value/';
    }
    return value;
  }

  /// 输入框内容是否与已应用值不同（决定「应用代理」置灰/高亮）。
  bool get _hasProxyChanges =>
      _normalizeProxy(_controller.text) != _appliedProxy;

  void _onProxyTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onProxyTextChanged);
    _loadAutoProxy();
  }

  Future<void> _loadAutoProxy() async {
    try {
      _autoProxyEnabled = await ConfigService.instance
              .getT<bool>(ConfigKeys.downloadAutoProxyEnabled) ??
          true;
    } catch (e) {
      debugPrint('DownloadSettingsSheet: 读取下载自动代理开关失败 - $e');
      _autoProxyEnabled = true;
    }
    if (mounted) {
      setState(() => _loaded = true);
    } else {
      _loaded = true;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onProxyTextChanged);
    _controller.dispose();
    super.dispose();
  }

  /// 归一化（trim；非空补尾部 '/'；空串 = 禁用）并立即持久化。
  Future<void> _applyProxy() async {
    final value = _normalizeProxy(_controller.text);
    await updateProxy(value.isEmpty ? null : value);
    if (!mounted) return;
    _appliedProxy = value;
    if (_controller.text != value) {
      _controller.text = value;
    }
    setState(() {});
    AppDialogs.showInfo(value.isEmpty ? '已禁用 GitHub 代理' : '代理已更新: $value');
  }

  /// 保存「下载自动使用代理」开关（乐观更新，失败回滚）。
  Future<void> _setAutoProxy(bool enabled) async {
    final previous = _autoProxyEnabled;
    setState(() => _autoProxyEnabled = enabled);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.downloadAutoProxyEnabled,
        enabled,
        source: ConfigChangeSource.user,
      );
      if (!result.success) {
        if (!mounted) return;
        setState(() => _autoProxyEnabled = previous);
        AppDialogs.showError(result.message);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _autoProxyEnabled = previous);
      AppDialogs.showError('保存下载自动代理开关失败: $e');
    }
  }

  /// 选中预设：立即生效并同步「已应用值」（按钮回到置灰态）。
  void _selectPreset(String value) {
    _controller.text = value;
    _appliedProxy = _normalizeProxy(value);
    unawaited(updateProxy(value));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'GitHub 代理',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: AppTypography.weightSemiBold,
              ),
            ),
            const Spacer(),
            // 未修改时置灰不可点；输入变化后才高亮可点。
            TextButton(
              key: const Key('download_settings_apply_proxy'),
              onPressed: _hasProxyChanges ? _applyProxy : null,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              ),
              child: const Text('应用代理'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '设置 GitHub 相关下载的代理前缀，用于加速国内访问；留空表示不使用代理。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        // 代理输入框：点击只聚焦编辑；仅右侧箭头弹出预设列表。
        // 背景由外层 Container 绘制（TextField 自身 filled=false → 输入内容
        // 不再被 4px 的 filled 内缩偏移，严格与标题左对齐）。
        Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.circle),
          ),
          child: TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _applyProxy(),
            decoration: InputDecoration(
              hintText: 'https://gh-proxy.org/',
              hintStyle: TextStyle(color: scheme.onSurfaceVariant),
              filled: false,
              // 主题默认给 enabled/focused 配了 OutlineInputBorder，这里必须
              // 逐个置 none，否则仍会画出边框。
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              // 左侧不缩进：输入内容与「GitHub 代理」标题左对齐。
              contentPadding: const EdgeInsets.only(
                right: AppSpacing.sm,
                top: AppSpacing.md,
                bottom: AppSpacing.md,
              ),
              suffixIcon: PopupMenuButton<String>(
                tooltip: '选择预设代理',
                icon: Icon(
                  TablerIcons.chevron_down,
                  color: scheme.onSurfaceVariant,
                ),
                onSelected: _selectPreset,
                itemBuilder: (context) => [
                  for (final host in presetProxyHosts)
                    PopupMenuItem<String>(
                      value: host,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_controller.text == host)
                            const Text(
                              '✅ ',
                              style: TextStyle(fontSize: AppTypography.sizeSM),
                            ),
                          Flexible(
                            child: Text(
                              host,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        // 下载自动套代理开关：代理前缀为空时置灰（不修改已保存开关值）。
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) {
            final hasProxy = value.text.trim().isNotEmpty;
            return SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('下载自动使用代理'),
              subtitle: const Text(
                '开启后下载服务会自动为 GitHub 资源添加代理前缀；关闭则使用原始地址',
              ),
              value: _autoProxyEnabled,
              onChanged: (hasProxy && _loaded) ? _setAutoProxy : null,
            );
          },
        ),
      ],
    );
  }
}

/// 多段下载开关 Tile
///
/// 控制是否启用多段并行下载（自适应分段，可显著加速大文件下载）。
/// 弱网/网络不稳定时可关闭，回退为单连接下载。
class _MultiSegmentDownloadTile extends StatefulWidget {
  const _MultiSegmentDownloadTile();

  @override
  State<_MultiSegmentDownloadTile> createState() =>
      _MultiSegmentDownloadTileState();
}

class _MultiSegmentDownloadTileState extends State<_MultiSegmentDownloadTile> {
  bool _enabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled = await ConfigService.instance
          .getT<bool>(ConfigKeys.downloadMultiSegmentEnabled);
      if (mounted) {
        setState(() {
          _enabled = enabled ?? true;
          _loaded = true;
        });
      }
    } catch (e) {
      debugPrint('DownloadSettingsSheet: 读取多段下载配置失败 - $e');
      if (mounted) {
        setState(() {
          _enabled = true;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.downloadMultiSegmentEnabled,
        value,
        source: ConfigChangeSource.user,
      );
      if (result.success) {
        appLog.info('DownloadSettingsSheet: 多段下载已${value ? "开启" : "关闭"}');
      } else {
        debugPrint('DownloadSettingsSheet: 保存多段下载配置失败 - ${result.message}');
      }
    } catch (e) {
      debugPrint('DownloadSettingsSheet: 保存多段下载配置失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(
        TablerIcons.route,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('多段下载'),
      subtitle: const Text('自适应分段并行下载（最大 8 段），大文件下载更快。弱网或不稳定时可关闭'),
      value: _enabled,
      onChanged: _loaded ? _toggle : null,
    );
  }
}

/// 最大并发下载数 Tile
///
/// 滑块控制同时下载的最大任务数（范围 1-10），
/// 多任务同时下载可提高总带宽利用率，但过高可能导致网络拥塞。
class _MaxConcurrentDownloadTile extends StatefulWidget {
  const _MaxConcurrentDownloadTile();

  @override
  State<_MaxConcurrentDownloadTile> createState() =>
      _MaxConcurrentDownloadTileState();
}

class _MaxConcurrentDownloadTileState
    extends State<_MaxConcurrentDownloadTile> {
  int _value = 3;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await ConfigService.instance
          .getT<int>(ConfigKeys.downloadMaxConcurrent);
      if (mounted) {
        setState(() {
          _value = value ?? 3;
          _loaded = true;
        });
      }
    } catch (e) {
      debugPrint('DownloadSettingsSheet: 读取并发数配置失败 - $e');
      if (mounted) {
        setState(() {
          _value = 3;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _update(int value) async {
    // 滑块已限定 1-10；这里再 clamp 一次，避免程序化调用写入越界值
    // （ConfigService 仍会按注册表范围校验并拒绝非法写入）。
    final clamped = value.clamp(1, 10);
    setState(() => _value = clamped);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.downloadMaxConcurrent,
        clamped,
        source: ConfigChangeSource.user,
      );
      if (!result.success) {
        debugPrint('DownloadSettingsSheet: 保存并发数配置失败 - ${result.message}');
      }
    } catch (e) {
      debugPrint('DownloadSettingsSheet: 保存并发数配置失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        TablerIcons.download,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('最大并发下载数'),
      subtitle: Text('同时下载的最大任务数: $_value'),
      trailing: SizedBox(
        width: 150,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                value: _value.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                label: '$_value',
                onChanged: _loaded ? (v) => _update(v.round()) : null,
              ),
            ),
            Text('$_value', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

/// 仅WiFi下载 Tile
///
/// 开关控制是否仅在 WiFi 环境下下载，
/// 开启后可避免消耗移动数据流量。
///
/// **已知 UI-only 设置**：`download.wifi_only` 是 Dart 侧偏好，Rust 下载引擎
/// 当前不消费该键（见 `gstore_mod_download/src/config/mod.rs`）；此处仅负责
/// 通过 [ConfigService] 持久化，供下载入口/后续消费方读取。不要静默删除键或
/// Tile——迁移工具与备份仍需要它。
class _WifiOnlyDownloadTile extends StatefulWidget {
  const _WifiOnlyDownloadTile();

  @override
  State<_WifiOnlyDownloadTile> createState() => _WifiOnlyDownloadTileState();
}

class _WifiOnlyDownloadTileState extends State<_WifiOnlyDownloadTile> {
  bool _enabled = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final enabled =
          await ConfigService.instance.getT<bool>(ConfigKeys.downloadWifiOnly);
      if (mounted) {
        setState(() {
          _enabled = enabled ?? false;
          _loaded = true;
        });
      }
    } catch (e) {
      debugPrint('DownloadSettingsSheet: 读取WiFi-only配置失败 - $e');
      if (mounted) {
        setState(() {
          _enabled = false;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _toggle(bool value) async {
    setState(() => _enabled = value);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.downloadWifiOnly,
        value,
        source: ConfigChangeSource.user,
      );
      if (!result.success) {
        debugPrint(
            'DownloadSettingsSheet: 保存WiFi-only配置失败 - ${result.message}');
      }
    } catch (e) {
      debugPrint('DownloadSettingsSheet: 保存WiFi-only配置失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(
        TablerIcons.wifi,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('仅WiFi下载'),
      subtitle: const Text('开启后仅在WiFi环境下下载，避免消耗移动数据'),
      value: _enabled,
      onChanged: _loaded ? _toggle : null,
    );
  }
}

/// 最大重试次数 Tile
///
/// 滑块控制下载失败后的自动重试次数（范围 0-5），
/// 设为 0 表示不重试，较高的重试次数可提高弱网环境下的成功率。
class _MaxRetryCountTile extends StatefulWidget {
  const _MaxRetryCountTile();

  @override
  State<_MaxRetryCountTile> createState() => _MaxRetryCountTileState();
}

class _MaxRetryCountTileState extends State<_MaxRetryCountTile> {
  int _value = 3;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value =
          await ConfigService.instance.getT<int>(ConfigKeys.downloadMaxRetries);
      if (mounted) {
        setState(() {
          _value = value ?? 3;
          _loaded = true;
        });
      }
    } catch (e) {
      debugPrint('DownloadSettingsSheet: 读取重试次数配置失败 - $e');
      if (mounted) {
        setState(() {
          _value = 3;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _update(int value) async {
    // 滑块已限定 0-5；这里再 clamp 一次，避免程序化调用写入越界值
    // （ConfigService 仍会按注册表范围校验并拒绝非法写入）。
    final clamped = value.clamp(0, 5);
    setState(() => _value = clamped);
    try {
      final result = await ConfigService.instance.set(
        ConfigKeys.downloadMaxRetries,
        clamped,
        source: ConfigChangeSource.user,
      );
      if (!result.success) {
        debugPrint('DownloadSettingsSheet: 保存重试次数配置失败 - ${result.message}');
      }
    } catch (e) {
      debugPrint('DownloadSettingsSheet: 保存重试次数配置失败 - $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        TablerIcons.reload,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: const Text('最大重试次数'),
      subtitle: Text('下载失败后自动重试: $_value 次'),
      trailing: SizedBox(
        width: 150,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                value: _value.toDouble(),
                min: 0,
                max: 5,
                divisions: 5,
                label: '$_value',
                onChanged: _loaded ? (v) => _update(v.round()) : null,
              ),
            ),
            Text('$_value', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

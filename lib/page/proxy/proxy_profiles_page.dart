import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/compent/entrance_list.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/icons/Icons.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/page/proxy/proxy_active_profile_store.dart';
import 'package:gstore/page/proxy/proxy_profiles_facade.dart';

/// 选择本地订阅文件并返回（文件名 + 文本内容；null = 取消 / 失败）。
typedef ProfileFilePick = Future<({String name, String text})?> Function();

/// 读取系统剪贴板文本（null = 无内容）。
typedef ProfileClipboardRead = Future<String?> Function();

/// 订阅与配置管理页（Todo 20，**纯展示层**）。
///
/// 职责边界：
/// * 列表 / 导入 / 刷新 / 删除全部经 [ProxyProfilesFacade] 透传给 Rust 模块；
/// * 订阅的抓取、解析、流量(userinfo)计算、节点计数全部由模块返回；
///   本页**绝不解析订阅**，也不做任何网络请求；
/// * 只对模块返回的 `ImportedProfile` / `ProfileSummary` 做展示格式化。
///
/// 选择语义：点击订阅卡片即「设为当前订阅」——持久化 profile id
/// （[ProxyActiveProfileStore]，key `proxy_active_profile_id`），首页据此作为
/// 默认 `profileId` 连接；只有 1 个订阅时自动选中并持久化。模块没有
/// `profile.select`，选中仅是**应用侧**状态。
///
/// 交互入口：
/// * 导入：URL / 粘贴文本 / 分享链接（剪贴板）/ 本地文件；
/// * 刷新：单个（卡片按钮）与全部（AppBar，`profile.refresh_all`）；
/// * 删除：统一危险确认弹层 `showConfirmSheet(isDangerous: true)`。
///
/// 依赖注入：[facade]、[filePicker]、[clipboardReader]、[profileStore] 均可注入
/// 假实现，组件测试无需原生模块 / 平台通道。
class ProxyProfilesPage extends StatefulWidget {
  const ProxyProfilesPage({
    super.key,
    this.facade,
    this.filePicker,
    this.clipboardReader,
    this.profileStore,
  });

  /// 门面（测试注入假实现；为空时用生产适配器 [ProxyModuleProfilesFacade]）。
  final ProxyProfilesFacade? facade;

  /// 本地文件选择（测试注入；为空时走 [FilePicker.platform.pickFiles]）。
  final ProfileFilePick? filePicker;

  /// 剪贴板读取（测试注入；为空时走 `Clipboard.getData`）。
  final ProfileClipboardRead? clipboardReader;

  /// 选中订阅的持久化接缝（测试注入内存实现；为空时用 [ConfigStore]）。
  final ProxyActiveProfileStore? profileStore;

  @override
  State<ProxyProfilesPage> createState() => _ProxyProfilesPageState();
}

class _ProxyProfilesPageState extends State<ProxyProfilesPage> {
  late final ProxyProfilesFacade _facade;
  late final ProfileFilePick _filePicker;
  late final ProfileClipboardRead _clipboardReader;
  late final ProxyActiveProfileStore _profileStore;

  StreamSubscription<ProxyEvent>? _eventSub;

  bool _loading = true;
  bool _importing = false;
  bool _refreshingAll = false;
  String? _loadError;
  List<ProfileSummary> _profiles = const <ProfileSummary>[];
  List<ProfileWarning> _warnings = const <ProfileWarning>[];

  /// 当前选中的订阅 id（持久化于 [ProxyActiveProfileStore]）。
  String? _selectedId;

  /// 正在刷新的 profile id 集合（含事件驱动的 started 状态）。
  final Set<String> _refreshingIds = <String>{};

  /// 防竞态：仅最后一次 `profile.list` 的结果生效。
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? ProxyModuleProfilesFacade();
    _filePicker = widget.filePicker ?? _defaultPickFile;
    _clipboardReader = widget.clipboardReader ?? _defaultReadClipboard;
    _profileStore =
        widget.profileStore ?? const ConfigStoreProxyActiveProfileStore();
    _eventSub = _facade.events.listen(_onEvent, onError: (_) {});
    _load();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  // ==================== 数据加载 ====================

  Future<void> _load() async {
    final token = ++_loadToken;
    if (_profiles.isEmpty) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final list = await _facade.profileList();
      final String? selected = await _resolveSelection(list.profiles);
      if (!mounted || token != _loadToken) return;
      setState(() {
        _profiles = list.profiles;
        _warnings = list.warnings;
        _selectedId = selected;
        _loading = false;
        _loadError = null;
      });
    } on ProxyModuleException catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _loadError = error.message;
      });
    } catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _loadError = '订阅列表加载失败：$error';
      });
    }
  }

  /// 解析「当前订阅」：优先沿用持久化 id；失效时若只剩 1 个订阅则自动选中并
  /// 持久化，否则清除。
  Future<String?> _resolveSelection(List<ProfileSummary> profiles) async {
    final String? persisted = await _profileStore.read();
    final Set<String> ids = <String>{for (final p in profiles) p.id};
    if (persisted != null && ids.contains(persisted)) {
      return persisted;
    }
    if (profiles.length == 1) {
      final String only = profiles.first.id;
      await _profileStore.write(only);
      return only;
    }
    if (persisted != null) {
      await _profileStore.clear();
    }
    return null;
  }

  /// 点击订阅卡片：设为当前订阅（持久化 + 视觉标识）。
  Future<void> _selectProfile(ProfileSummary profile) async {
    setState(() => _selectedId = profile.id);
    await _profileStore.write(profile.id);
    if (!mounted) return;
    AppDialogs.showSuccess('已设为当前订阅「${profile.name}」');
  }

  // ==================== 事件 ====================

  void _onEvent(ProxyEvent event) {
    if (!mounted) return;
    switch (event) {
      case ProxySubscriptionProgressEvent():
        setState(() {
          if (event.state == ProxySubscriptionProgressState.started) {
            _refreshingIds.add(event.profileId);
          } else {
            _refreshingIds.remove(event.profileId);
          }
        });
        if (event.state != ProxySubscriptionProgressState.started) {
          _load();
        }
      case ProxySubscriptionAddedEvent():
      case ProxySubscriptionRemovedEvent():
      case ProxySubscriptionUpdatedEvent():
        _load();
      case ProxySubscriptionFailedEvent():
        setState(() => _refreshingIds.remove(event.profileId));
        final message = event.error?.message ?? '';
        if (message.isNotEmpty) {
          AppDialogs.showError(message);
        }
      case ProxyStateEvent():
      case ProxyModeEvent():
      case ProxyNodeDelayEvent():
      case ProxyStatsEvent():
      case ProxyConnEvent():
      case ProxyDnsEvent():
      case ProxyTunReleasedEvent():
      case ProxyConfigAppliedEvent():
        break;
    }
  }

  // ==================== 导入 ====================

  Future<void> _openImportSheet() async {
    if (_importing || _refreshingAll) return;
    final request = await AppSheet.showCustom<_ImportRequest>(
      context: context,
      builder: (_) => _ImportSheet(clipboardReader: _clipboardReader),
    );
    if (request == null || !mounted) return;
    await _performImport(request);
  }

  Future<void> _performImport(_ImportRequest request) async {
    setState(() => _importing = true);
    try {
      final ImportedProfile imported;
      switch (request.mode) {
        case ProxyImportMode.url:
          imported = await _facade.profileImportUrl(url: request.value);
        case ProxyImportMode.text:
          imported = await _facade.profileImportText(text: request.value);
        case ProxyImportMode.link:
          imported = await _facade.profileImportLink(link: request.value);
        case ProxyImportMode.file:
          final picked = await _filePicker();
          if (picked == null) return; // 用户取消
          imported = await _facade.profileImportText(
            text: picked.text,
            name: picked.name,
            contentType: 'text/yaml',
          );
      }
      await _facade.profileCreate(ProfileCreateRequest(profile: imported));
      if (!mounted) return;
      final name = imported.name.isEmpty ? '订阅' : imported.name;
      AppDialogs.showSuccess('已导入「$name」，共 ${imported.nodeCount} 个节点');
      await _load();
    } on ProxyModuleException catch (error) {
      await _showErrorSheet('导入失败', error.message);
    } catch (error) {
      await _showErrorSheet('导入失败', '$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  // ==================== 刷新 ====================

  Future<void> _refreshAll() async {
    if (_refreshingAll || _importing) return;
    setState(() => _refreshingAll = true);
    try {
      final result = await _facade.profileRefreshAll();
      if (!mounted) return;
      if (result.failedCount > 0) {
        AppDialogs.showWarning(
          '已更新 ${result.count} 个，${result.failedCount} 个失败',
        );
      } else {
        AppDialogs.showSuccess('已更新 ${result.count} 个订阅');
      }
      await _load();
    } on ProxyModuleException catch (error) {
      await _showErrorSheet('全部更新失败', error.message);
    } catch (error) {
      await _showErrorSheet('全部更新失败', '$error');
    } finally {
      if (mounted) setState(() => _refreshingAll = false);
    }
  }

  Future<void> _refreshProfile(ProfileSummary profile) async {
    if (_refreshingIds.contains(profile.id) || _refreshingAll) return;
    setState(() => _refreshingIds.add(profile.id));
    try {
      final result = await _facade.profileRefresh(profile.id);
      if (!mounted) return;
      if (result.state == 'failed') {
        final message = result.error?.message ?? '刷新失败';
        await _showErrorSheet('更新失败', message);
      } else {
        AppDialogs.showSuccess('「${profile.name}」已更新');
      }
      await _load();
    } on ProxyModuleException catch (error) {
      await _showErrorSheet('更新失败', error.message);
    } catch (error) {
      await _showErrorSheet('更新失败', '$error');
    } finally {
      if (mounted) setState(() => _refreshingIds.remove(profile.id));
    }
  }

  // ==================== 删除 ====================

  Future<void> _deleteProfile(ProfileSummary profile) async {
    final scheme = Theme.of(context).colorScheme;
    final name = profile.name.isEmpty ? '该订阅' : '「${profile.name}」';
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '删除订阅',
      message: '确定删除 $name 吗？删除后无法恢复。',
      confirmText: '删除',
      isDangerous: true,
      icon: const Icon(Icons.delete_outline),
      iconColor: scheme.error,
    );
    if (confirmed != true || !mounted) return;
    try {
      await _facade.profileDelete(profile.id);
      if (!mounted) return;
      AppDialogs.showSuccess('已删除 $name');
      await _load();
    } on ProxyModuleException catch (error) {
      await _showErrorSheet('删除失败', error.message);
    } catch (error) {
      await _showErrorSheet('删除失败', '$error');
    }
  }

  // ==================== 工具 ====================

  Future<void> _showErrorSheet(String title, String message) async {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    await AppDialogs.showAlertSheet(
      title: title,
      message: message.isEmpty ? '未知错误' : message,
      icon: const Icon(Icons.error_outline),
      iconColor: scheme.error,
    );
  }

  static Future<({String name, String text})?> _defaultPickFile() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    final files = result?.files;
    if (files == null || files.isEmpty) return null;
    final file = files.first;
    final bytes = file.bytes;
    if (bytes == null) return null;
    return (name: file.name, text: utf8.decode(bytes, allowMalformed: true));
  }

  static Future<String?> _defaultReadClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅与配置'),
        actions: _buildActions(context),
      ),
      body: _buildBody(context),
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    if (_importing || _refreshingAll) {
      return const <Widget>[
        Padding(
          padding: AppSpacing.onlyHorizontalLG,
          child: Center(child: AppLoading(size: AppLoadingSize.small)),
        ),
      ];
    }
    return <Widget>[
      IconButton(
        tooltip: '导入订阅',
        icon: const Icon(Icons.add),
        onPressed: _openImportSheet,
      ),
      IconButton(
        tooltip: '全部更新',
        icon: const Icon(Icons.refresh),
        onPressed: _profiles.isEmpty ? null : _refreshAll,
      ),
    ];
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final error = _loadError;
    if (error != null && _profiles.isEmpty) {
      return _buildErrorState(context, error);
    }
    if (_profiles.isEmpty) {
      return _buildEmptyState(context);
    }

    final children = <Widget>[
      if (_warnings.isNotEmpty) ...[
        _buildWarnings(context),
        const SizedBox(height: AppSpacing.md),
      ],
      for (final profile in _profiles)
        Padding(
          padding: AppSpacing.onlyBottomMD,
          child: _ProfileCard(
            profile: profile,
            selected: profile.id == _selectedId,
            refreshing: _refreshingIds.contains(profile.id),
            onSelect: () => _selectProfile(profile),
            onRefresh: () => _refreshProfile(profile),
            onDelete: () => _deleteProfile(profile),
          ),
        ),
    ];

    // EntranceList：挂载 / 列表变化时逐项交错淡入（数据变化换 key 重放）。
    return EntranceList<void>(
      key: ValueKey<int>(_profiles.length),
      itemCount: children.length,
      padding: AppSpacing.allLG,
      itemBuilder: (context, index) => children[index],
    );
  }

  Widget _buildErrorState(BuildContext context, String message) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.extension_off_outlined,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('订阅列表不可用', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredAliIcon(
              icon: Icons.link,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('还没有订阅', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '通过 URL、文本、分享链接或本地文件导入订阅配置',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: _openImportSheet,
              icon: const Icon(Icons.add),
              label: const Text('导入订阅'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWarnings(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: AppSpacing.allMD,
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: AppRadius.allMD,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.warning_amber_outlined,
                size: AppTypography.iconMD,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '有 ${_warnings.length} 条订阅读取警告',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onErrorContainer,
                  fontWeight: AppTypography.weightMedium,
                ),
              ),
            ],
          ),
          for (final warning in _warnings.take(3))
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                warning.message.isEmpty
                    ? warning.code
                    : '${warning.code}：${warning.message}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ==================== 单个订阅卡片 ====================

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.selected,
    required this.refreshing,
    required this.onSelect,
    required this.onRefresh,
    required this.onDelete,
  });

  final ProfileSummary profile;

  /// 是否为「当前订阅」（连接时生效）。
  final bool selected;
  final bool refreshing;
  final VoidCallback onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final refresh = profile.refresh;
    final refreshError = refresh?.error ?? '';
    final failed = refresh?.state == ProxyRefreshState.failed;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onSelect,
        borderRadius: AppRadius.allLG,
        child: Padding(
          padding: AppSpacing.allLG,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ColoredAliIcon(
                    icon: Icons.link,
                    size: AppTypography.iconXL,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.name.isEmpty ? '未命名订阅' : profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          _sourceText(profile),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selected) ...<Widget>[
                    const SizedBox(width: AppSpacing.xs),
                    Icon(
                      Icons.check_circle,
                      key: Key('proxy_profile_current_${profile.id}'),
                      size: AppTypography.iconMD,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '当前',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: AppTypography.weightMedium,
                      ),
                    ),
                  ],
                  if (refreshing)
                    const Padding(
                      padding: AppSpacing.onlyHorizontalSM,
                      child: AppLoading(size: AppLoadingSize.small),
                    )
                  else
                    IconButton(
                      tooltip: '更新',
                      icon: const Icon(Icons.refresh),
                      onPressed: onRefresh,
                    ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onDelete,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  _Tag(text: '节点 ${profile.nodeCount}'),
                  if (profile.groupCount > 0)
                    _Tag(text: '分组 ${profile.groupCount}'),
                  _Tag(
                    text: profile.format.isEmpty ? '未知格式' : profile.format,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              _InfoRow(
                icon: Icons.data_usage_outlined,
                text: _trafficText(profile.userinfo),
              ),
              const SizedBox(height: AppSpacing.xs),
              _InfoRow(
                icon: Icons.event_outlined,
                text: _expiryText(profile.userinfo),
                color: _isExpired(profile.userinfo) ? scheme.error : null,
              ),
              const SizedBox(height: AppSpacing.xs),
              _InfoRow(
                icon: Icons.update_outlined,
                text: _updatedText(profile),
              ),
              if (failed && refreshError.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  width: double.infinity,
                  padding: AppSpacing.allMD,
                  decoration: BoxDecoration(
                    color: scheme.errorContainer,
                    borderRadius: AppRadius.allMD,
                  ),
                  child: Text(
                    refreshError,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: AppRadius.allSM,
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final effective = color ?? scheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: AppTypography.iconSM, color: effective),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: effective),
          ),
        ),
      ],
    );
  }
}

// ==================== 导入弹层 ====================

enum ProxyImportMode { url, text, link, file }

class _ImportRequest {
  const _ImportRequest(this.mode, this.value);

  final ProxyImportMode mode;
  final String value;
}

class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.clipboardReader});

  final ProfileClipboardRead clipboardReader;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  ProxyImportMode _mode = ProxyImportMode.url;
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _label => switch (_mode) {
        ProxyImportMode.url => '订阅 URL',
        ProxyImportMode.text => '订阅内容',
        ProxyImportMode.link => '分享链接',
        ProxyImportMode.file => '本地文件',
      };

  String get _hint => switch (_mode) {
        ProxyImportMode.url => 'https://example.com/sub',
        ProxyImportMode.text => '粘贴 Clash / base64 / 节点列表内容',
        ProxyImportMode.link => 'ss:// / vmess:// / trojan:// …',
        ProxyImportMode.file => '',
      };

  void _selectMode(ProxyImportMode mode) {
    setState(() {
      _mode = mode;
      _controller.clear();
    });
  }

  Future<void> _readClipboard() async {
    final text = await widget.clipboardReader();
    if (!mounted) return;
    final link = text?.trim() ?? '';
    if (link.isEmpty) {
      AppDialogs.showInfo('剪贴板中没有可导入的内容');
      return;
    }
    setState(() {
      _mode = ProxyImportMode.link;
      _controller.text = link;
    });
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      AppDialogs.showError('请输入订阅内容');
      return;
    }
    Navigator.of(context).pop(_ImportRequest(_mode, value));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSheetScaffold(
      title: '导入订阅',
      subtitle: '解析与存储全部在 Rust 模块内完成，应用内不解析订阅',
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<ProxyImportMode>(
            segments: const <ButtonSegment<ProxyImportMode>>[
              ButtonSegment<ProxyImportMode>(
                value: ProxyImportMode.url,
                label: Text('URL'),
                icon: Icon(Icons.link),
              ),
              ButtonSegment<ProxyImportMode>(
                value: ProxyImportMode.text,
                label: Text('文本'),
                icon: Icon(Icons.article_outlined),
              ),
              ButtonSegment<ProxyImportMode>(
                value: ProxyImportMode.link,
                label: Text('分享链接'),
                icon: Icon(Icons.share_outlined),
              ),
            ],
            selected: <ProxyImportMode>{
              _mode == ProxyImportMode.file ? ProxyImportMode.url : _mode,
            },
            onSelectionChanged: (selection) => _selectMode(selection.first),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _controller,
            minLines: _mode == ProxyImportMode.text ? 3 : 1,
            maxLines: _mode == ProxyImportMode.text ? 6 : 1,
            decoration: InputDecoration(
              labelText: _label,
              hintText: _hint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _readClipboard,
              icon: const Icon(Icons.content_paste_go, size: 18),
              label: const Text('读取剪贴板中的分享链接'),
            ),
          ),
          const Divider(height: 1),
          InkWell(
            onTap: () => Navigator.of(context).pop(
              const _ImportRequest(ProxyImportMode.file, ''),
            ),
            borderRadius: AppRadius.allMD,
            child: Padding(
              padding: AppSpacing.onlyVerticalSM,
              child: Row(
                children: [
                  ColoredAliIcon(
                    icon: AliIcon.downloadSuccess,
                    size: AppTypography.iconXL,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('从文件导入', style: theme.textTheme.bodyLarge),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '选择本地 Clash / 订阅文本文件',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('导入'),
        ),
      ],
    );
  }
}

// ==================== 展示格式化（纯展示，不解析订阅） ====================

String _sourceText(ProfileSummary profile) {
  final origin = profile.sourceOrigin ?? '';
  final url = profile.sourceUrl ?? '';
  switch (origin) {
    case 'url':
      return url.isEmpty ? 'URL 订阅' : url;
    case 'text':
      return '粘贴文本导入';
    case 'link':
      return '分享链接导入';
    default:
      if (origin.isNotEmpty) return origin;
      return profile.format.isEmpty ? '本地配置' : profile.format;
  }
}

String _trafficText(SubscriptionUserinfo? userinfo) {
  if (userinfo == null) return '流量信息：无';
  final used = (userinfo.upload ?? 0) + (userinfo.download ?? 0);
  final total = userinfo.total ?? 0;
  if (total > 0) {
    return '已用 ${byteSize(used)} / ${byteSize(total)}';
  }
  return '已用 ${byteSize(used)} / 不限量';
}

bool _isExpired(SubscriptionUserinfo? userinfo) {
  final expire = userinfo?.expire ?? 0;
  if (expire <= 0) return false;
  final at = DateTime.fromMillisecondsSinceEpoch(expire * 1000);
  return at.isBefore(DateTime.now());
}

String _expiryText(SubscriptionUserinfo? userinfo) {
  final expire = userinfo?.expire ?? 0;
  if (expire <= 0) return '有效期：长期有效';
  final at = DateTime.fromMillisecondsSinceEpoch(expire * 1000);
  return '到期：${at.year}-${_two(at.month)}-${_two(at.day)}';
}

String _updatedText(ProfileSummary profile) {
  final parts = <String>[];
  if (profile.updatedAtMs > 0) {
    parts.add('更新于 ${_formatDateTime(profile.updatedAtMs)}');
  } else {
    parts.add('尚未更新');
  }
  final interval = profile.refresh?.intervalMs ?? 0;
  parts.add(interval > 0 ? '自动更新 ${_formatInterval(interval)}' : '仅手动更新');
  return parts.join(' · ');
}

String _formatDateTime(int ms) {
  final at = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${at.year}-${_two(at.month)}-${_two(at.day)} '
      '${_two(at.hour)}:${_two(at.minute)}';
}

String _formatInterval(int ms) {
  if (ms >= Duration.millisecondsPerDay) {
    return '${ms ~/ Duration.millisecondsPerDay} 天';
  }
  if (ms >= Duration.millisecondsPerHour) {
    return '${ms ~/ Duration.millisecondsPerHour} 小时';
  }
  return '${ms ~/ Duration.millisecondsPerMinute} 分钟';
}

String _two(int value) => value.toString().padLeft(2, '0');

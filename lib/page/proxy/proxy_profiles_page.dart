import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
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

/// 导出 Clash 配置的另存接缝：调用系统保存对话框并返回落地路径（取消 → `null`）。
///
/// 生产默认走 [FilePicker.platform.saveFile]，测试注入假实现断言「保存被调用」。
typedef ProfileSaveFile = Future<String?> Function({
  required String fileName,
  required Uint8List bytes,
  required List<String> allowedExtensions,
});

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
/// `profile.select`，但切换时会 best-effort `config.apply` 把新订阅热应用到
/// 运行中引擎；引擎未运行时 Rust 只记录 active profile 并返回 `applied:false`
/// （不报错），离线路径下同一次切换即刻生效，避免「已换订阅但引擎仍用旧订阅」。
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
    this.saveFile,
  });

  /// 门面（测试注入假实现；为空时用生产适配器 [ProxyModuleProfilesFacade]）。
  final ProxyProfilesFacade? facade;

  /// 本地文件选择（测试注入；为空时走 [FilePicker.platform.pickFiles]）。
  final ProfileFilePick? filePicker;

  /// 剪贴板读取（测试注入；为空时走 `Clipboard.getData`）。
  final ProfileClipboardRead? clipboardReader;

  /// 选中订阅的持久化接缝（测试注入内存实现；为空时用 [ConfigStore]）。
  final ProxyActiveProfileStore? profileStore;

  /// 导出 Clash 配置的另存接缝（测试注入；为空时走 [FilePicker.platform.saveFile]）。
  final ProfileSaveFile? saveFile;

  @override
  State<ProxyProfilesPage> createState() => _ProxyProfilesPageState();
}

class _ProxyProfilesPageState extends State<ProxyProfilesPage> {
  late final ProxyProfilesFacade _facade;
  late final ProfileFilePick _filePicker;
  late final ProfileClipboardRead _clipboardReader;
  late final ProxyActiveProfileStore _profileStore;
  late final ProfileSaveFile _saveFile;

  StreamSubscription<ProxyEvent>? _eventSub;

  bool _loading = true;
  bool _importing = false;
  bool _refreshingAll = false;
  bool _exporting = false;
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
    _saveFile = widget.saveFile ?? _defaultSaveFile;
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
        _loadError = '网络组列表加载失败：$error';
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

  /// 点击订阅卡片：设为当前订阅（持久化 + 视觉标识），并 best-effort 同步给
  /// Rust（引擎运行中时热应用该订阅，避免「换了订阅但引擎仍用旧订阅」；
  /// 引擎未运行时 Rust 只记录 active profile 并返回 `applied:false`，不报错，
  /// 离线路径即刻生效；下方 try/catch 仅作防御性兜底）。
  Future<void> _selectProfile(ProfileSummary profile) async {
    setState(() => _selectedId = profile.id);
    await _profileStore.write(profile.id);
    // best-effort：应用失败不影响「已设为当前订阅」的本地语义。
    try {
      await _facade.applyProfile(profile.id);
    } catch (error) {
      debugPrint('订阅切换同步引擎失败（profileId=${profile.id}）：$error');
    }
    if (!mounted) return;
    AppDialogs.showSuccess('已设为当前网络组「${profile.name}」');
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
      case ProxyRequestEvent():
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
      final name = imported.name.isEmpty ? '网络组' : imported.name;
      AppDialogs.showSuccess('已导入「$name」，共 ${imported.nodeCount} 个端子');
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
      var result = await _facade.profileRefreshAll();
      if (!mounted) return;
      // 有被跳过的来源（不可刷新 / 退避 / 未到期 / 超上限）→ 展示原因并允许强制。
      if (result.skipped.isNotEmpty) {
        final force = await _showSkippedSheet(result);
        if (!mounted) return;
        if (force == true) {
          result = await _facade.profileRefreshAll(force: true);
          if (!mounted) return;
        }
      }
      _announceRefreshAll(result);
      await _load();
    } on ProxyModuleException catch (error) {
      await _showErrorSheet('全部更新失败', error.message);
    } catch (error) {
      await _showErrorSheet('全部更新失败', '$error');
    } finally {
      if (mounted) setState(() => _refreshingAll = false);
    }
  }

  /// 汇总批量刷新结果并提示（跳过数计入文案，不谎报为失败）。
  void _announceRefreshAll(RefreshAllResult result) {
    final parts = <String>['已更新 ${result.count} 个网络组'];
    if (result.failedCount > 0) parts.add('${result.failedCount} 个失败');
    if (result.skipped.isNotEmpty) parts.add('${result.skipped.length} 个跳过');
    final message = parts.join('，');
    if (result.failedCount > 0) {
      AppDialogs.showWarning(message);
    } else {
      AppDialogs.showSuccess(message);
    }
  }

  /// 展示 `profile.refresh_all` 的 `skipped[]` 原因；返回 `true` 表示用户选择强制更新。
  Future<bool?> _showSkippedSheet(RefreshAllResult result) {
    final names = <String, String>{
      for (final profile in _profiles)
        profile.id: profile.name.isEmpty ? '未命名网络组' : profile.name,
    };
    final scheme = Theme.of(context).colorScheme;
    return AppDialogs.showContentSheet<bool>(
      title: '部分网络组已跳过',
      subtitle: '共 ${result.skipped.length} 个未更新，可选择强制更新',
      icon: const Icon(TablerIcons.refresh_dot),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final skip in result.skipped)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    TablerIcons.clock,
                    size: AppTypography.iconSM,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          names[skip.profileId] ?? skip.profileId,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        Text(
                          _skipReasonLabel(skip.reason),
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<bool>(false),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: () => AppDialogs.popSheet<bool>(true),
          child: const Text('强制更新'),
        ),
      ],
    );
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

  // ==================== 编辑 / 导出 / 排程 ====================

  /// 单个 profile 的「更多」菜单：重命名 / 导出 Clash / 自动更新间隔。
  Future<void> _openProfileMenu(ProfileSummary profile) async {
    final action = await AppDialogs.showContentSheet<_ProfileAction>(
      title: profile.name.isEmpty ? '未命名网络组' : profile.name,
      icon: const Icon(TablerIcons.dots_vertical),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MenuOption(
            key: const Key('profile_menu_rename'),
            icon: TablerIcons.pencil,
            title: '重命名',
            subtitle: '修改网络组的显示名称',
            onTap: () => AppDialogs.popSheet<_ProfileAction>(
              _ProfileAction.rename,
            ),
          ),
          _MenuOption(
            key: const Key('profile_menu_export'),
            icon: TablerIcons.file_download,
            title: '导出 Clash',
            subtitle: '生成并另存该网络组的 Clash 配置',
            onTap: () => AppDialogs.popSheet<_ProfileAction>(
              _ProfileAction.export,
            ),
          ),
          _MenuOption(
            key: const Key('profile_menu_schedule'),
            icon: TablerIcons.clock,
            title: '自动更新间隔',
            subtitle: '设置或关闭该网络组的定时更新',
            onTap: () => AppDialogs.popSheet<_ProfileAction>(
              _ProfileAction.schedule,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<_ProfileAction>(null),
          child: const Text('取消'),
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _ProfileAction.rename:
        await _renameProfile(profile);
      case _ProfileAction.export:
        await _exportClash(profile);
      case _ProfileAction.schedule:
        await _scheduleProfile(profile);
    }
  }

  /// `profile.update`：重命名并刷新列表。
  Future<void> _renameProfile(ProfileSummary profile) async {
    final request = await AppSheet.showCustom<_RenameRequest>(
      context: context,
      builder: (_) => _RenameSheet(initialName: profile.name),
    );
    if (request == null || !mounted) return;
    final name = request.name.trim();
    if (name.isEmpty) {
      AppDialogs.showError('名称不能为空');
      return;
    }
    if (name == profile.name) return;
    try {
      await _facade.profileUpdate(<String, dynamic>{
        'id': profile.id,
        'name': name,
      });
      if (!mounted) return;
      AppDialogs.showSuccess('已重命名为「$name」');
      await _load();
    } on ProxyModuleException catch (error) {
      await _showErrorSheet('重命名失败', error.message);
    } catch (error) {
      await _showErrorSheet('重命名失败', '$error');
    }
  }

  /// `profile.export_clash`：生成 Clash 配置并另存（取消不报错）。
  Future<void> _exportClash(ProfileSummary profile) async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final generated = await _facade.profileExportClash(
        ProfileExportRequest(id: profile.id),
      );
      if (!mounted) return;
      final bytes = Uint8List.fromList(utf8.encode(generated.config));
      final path = await _saveFile(
        fileName: '${_safeFileName(profile.name)}.yaml',
        bytes: bytes,
        allowedExtensions: const <String>['yaml', 'yml'],
      );
      if (!mounted) return;
      // 用户取消：静默停止，不提示失败。
      if (path == null || path.isEmpty) return;
      AppDialogs.showSuccess('已导出「${profile.name}」的 Clash 配置');
    } on ProxyModuleException catch (error) {
      await _showErrorSheet('导出失败', error.message);
    } catch (error) {
      await _showErrorSheet('导出失败', '$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// `profile.set_schedule`：设置 / 清除自动更新间隔并回读。
  Future<void> _scheduleProfile(ProfileSummary profile) async {
    const options = <int>[
      0,
      Duration.millisecondsPerHour,
      6 * Duration.millisecondsPerHour,
      12 * Duration.millisecondsPerHour,
      Duration.millisecondsPerDay,
    ];
    final current = profile.refresh?.intervalMs ?? 0;
    final intervalMs = await AppDialogs.showSelectionBottomSheet<int>(
      title: '自动更新间隔',
      items: options,
      selectedItem: current,
      itemLabel: _intervalLabel,
    );
    if (intervalMs == null || !mounted) return;
    try {
      await _facade.profileSetSchedule(profile.id, intervalMs);
      if (!mounted) return;
      AppDialogs.showSuccess(
        intervalMs == 0
            ? '已关闭自动更新'
            : '自动更新间隔已设为 ${_intervalLabel(intervalMs)}',
      );
      await _load();
    } on ProxyModuleException catch (error) {
      await _showErrorSheet('设置自动更新失败', error.message);
    } catch (error) {
      await _showErrorSheet('设置自动更新失败', '$error');
    }
  }

  /// 生产默认另存：系统保存对话框（与请求记录 / 备份导出同机制）。
  static Future<String?> _defaultSaveFile({
    required String fileName,
    required Uint8List bytes,
    required List<String> allowedExtensions,
  }) {
    return FilePicker.platform.saveFile(
      dialogTitle: '导出 Clash 配置',
      fileName: fileName,
      lockParentWindow: true,
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      bytes: bytes,
    );
  }

  // ==================== 删除 ====================

  Future<void> _deleteProfile(ProfileSummary profile) async {
    final scheme = Theme.of(context).colorScheme;
    final name = profile.name.isEmpty ? '该网络组' : '「${profile.name}」';
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '删除网络组',
      message: '确定删除 $name 吗？删除后无法恢复。',
      confirmText: '删除',
      isDangerous: true,
      icon: const Icon(TablerIcons.trash),
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
      icon: const Icon(TablerIcons.alert_circle),
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
        title: const Text('网络组与配置'),
        actions: _buildActions(context),
      ),
      body: _buildBody(context),
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    if (_importing || _refreshingAll || _exporting) {
      return const <Widget>[
        Padding(
          padding: AppSpacing.onlyHorizontalLG,
          child: Center(child: AppLoading(size: AppLoadingSize.small)),
        ),
      ];
    }
    return <Widget>[
      IconButton(
        tooltip: '导入网络组',
        icon: const Icon(TablerIcons.plus),
        onPressed: _openImportSheet,
      ),
      IconButton(
        tooltip: '全部更新',
        icon: const Icon(TablerIcons.refresh),
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
            refreshable: _isRefreshable(profile),
            onSelect: () => _selectProfile(profile),
            onRefresh: () => _refreshProfile(profile),
            onMore: () => _openProfileMenu(profile),
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
              TablerIcons.puzzle_off,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('网络组列表不可用', style: theme.textTheme.titleMedium),
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
              icon: TablerIcons.link,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('还没有网络组', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '通过 URL、文本、分享链接或本地文件导入网络组配置',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: _openImportSheet,
              icon: const Icon(TablerIcons.plus),
              label: const Text('导入网络组'),
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
                TablerIcons.alert_triangle,
                size: AppTypography.iconMD,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '有 ${_warnings.length} 条网络组读取警告',
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
    required this.refreshable,
    required this.onSelect,
    required this.onRefresh,
    required this.onMore,
    required this.onDelete,
  });

  final ProfileSummary profile;

  /// 是否为「当前订阅」（连接时生效）。
  final bool selected;
  final bool refreshing;

  /// 该来源是否可刷新（`url` 来源才有可重取的地址）。
  final bool refreshable;
  final VoidCallback onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onMore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final refresh = profile.refresh;
    final refreshError = refresh?.error ?? '';
    final failed = refresh?.state == ProxyRefreshState.failed;

    return Card(
      key: selected ? Key('proxy_profile_active_${profile.id}') : null,
      margin: EdgeInsets.zero,
      color: selected ? scheme.primaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.allLG,
        side: BorderSide(
          color: selected ? scheme.primary : scheme.outlineVariant,
        ),
      ),
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
                    icon: TablerIcons.link,
                    size: AppTypography.iconXL,
                    color: selected ? scheme.onPrimaryContainer : scheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.name.isEmpty ? '未命名网络组' : profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: selected ? scheme.onPrimaryContainer : null,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          _sourceText(profile),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: selected
                                ? scheme.onPrimaryContainer
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (refreshing)
                    const Padding(
                      padding: AppSpacing.onlyHorizontalSM,
                      child: AppLoading(size: AppLoadingSize.small),
                    )
                  else if (refreshable)
                    IconButton(
                      tooltip: '更新',
                      icon: const Icon(TablerIcons.refresh),
                      onPressed: onRefresh,
                    ),
                  IconButton(
                    tooltip: '更多',
                    icon: const Icon(TablerIcons.dots_vertical),
                    onPressed: onMore,
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(TablerIcons.trash),
                    onPressed: onDelete,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                children: [
                  _Tag(text: '端子 ${profile.nodeCount}'),
                  if (profile.groupCount > 0)
                    _Tag(text: '分组 ${profile.groupCount}'),
                  _Tag(
                    text: profile.format.isEmpty ? '未知格式' : profile.format,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              _InfoRow(
                icon: TablerIcons.activity,
                text: _trafficText(profile.userinfo),
              ),
              const SizedBox(height: AppSpacing.xs),
              _InfoRow(
                icon: TablerIcons.calendar_event,
                text: _expiryText(profile.userinfo),
                color: _isExpired(profile.userinfo) ? scheme.error : null,
              ),
              const SizedBox(height: AppSpacing.xs),
              _InfoRow(
                icon: TablerIcons.refresh_dot,
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
        ProxyImportMode.url => '网络组 URL',
        ProxyImportMode.text => '网络组内容',
        ProxyImportMode.link => '分享链接',
        ProxyImportMode.file => '本地文件',
      };

  String get _hint => switch (_mode) {
        ProxyImportMode.url => 'https://example.com/sub',
        ProxyImportMode.text => '粘贴 Clash / base64 / 端子列表内容',
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
      AppDialogs.showError('请输入网络组内容');
      return;
    }
    Navigator.of(context).pop(_ImportRequest(_mode, value));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppSheetScaffold(
      title: '导入网络组',
      subtitle: '解析与存储全部在 Rust 模块内完成，应用内不解析网络组',
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
                icon: Icon(TablerIcons.link),
              ),
              ButtonSegment<ProxyImportMode>(
                value: ProxyImportMode.text,
                label: Text('文本'),
                icon: Icon(TablerIcons.file_text),
              ),
              ButtonSegment<ProxyImportMode>(
                value: ProxyImportMode.link,
                label: Text('分享链接'),
                icon: Icon(TablerIcons.share),
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
              icon: const Icon(TablerIcons.file_import, size: 18),
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
                          '选择本地 Clash / 网络组文本文件',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    TablerIcons.chevron_right,
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
      return url.isEmpty ? 'URL 网络组' : url;
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

/// 该来源是否可刷新：仅带 URL 的 `url` 来源可重新抓取（`text` / `link` 无地址）。
bool _isRefreshable(ProfileSummary profile) {
  final origin = profile.sourceOrigin ?? '';
  if (origin == 'text' || origin == 'link') return false;
  return profile.sourceUrl?.isNotEmpty ?? false;
}

/// 自动更新间隔的人类可读标签（用于选择器与提示）。
String _intervalLabel(int ms) {
  if (ms <= 0) return '关闭自动更新';
  if (ms >= Duration.millisecondsPerDay) {
    return '每 ${ms ~/ Duration.millisecondsPerDay} 天';
  }
  if (ms >= Duration.millisecondsPerHour) {
    return '每 ${ms ~/ Duration.millisecondsPerHour} 小时';
  }
  return '每 ${ms ~/ Duration.millisecondsPerMinute} 分钟';
}

/// `refresh_all.skipped[].reason` 的中文说明。
String _skipReasonLabel(String reason) => switch (reason) {
      'not_refreshable' => '来源不可刷新',
      'backoff' => '失败退避中，稍后重试',
      'interval' => '未到自动更新间隔',
      'limit' => '超出本次批量上限',
      'error' => '上次刷新出错',
      _ => reason.isEmpty ? '未知原因' : reason,
    };

/// 导出文件名安全化：去掉路径分隔符 / 控制字符，空名回退 `clash-config`。
String _safeFileName(String name) {
  final cleaned =
      name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return cleaned.isEmpty ? 'clash-config' : cleaned;
}

// ==================== 更多菜单 / 重命名弹层 ====================

enum _ProfileAction { rename, export, schedule }

class _RenameRequest {
  const _RenameRequest(this.name);

  final String name;
}

/// 更多菜单的可点行（避免 [ListTile] 对 Material 祖先的依赖）。
class _MenuOption extends StatelessWidget {
  const _MenuOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.allMD,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Row(
          children: [
            ColoredAliIcon(
              icon: icon,
              size: AppTypography.iconMD,
              color: scheme.primary,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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

/// 重命名表单弹层（返回 [ _RenameRequest ]；取消返回 null）。
class _RenameSheet extends StatefulWidget {
  const _RenameSheet({required this.initialName});

  final String initialName;

  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      AppDialogs.showError('名称不能为空');
      return;
    }
    Navigator.of(context).pop(_RenameRequest(name));
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: '重命名网络组',
      subtitle: '仅修改显示名称，不影响订阅内容',
      content: TextField(
        controller: _controller,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: '名称',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}


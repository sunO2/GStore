import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';

import 'logic.dart';
import 'gstore_catalog_update.dart';
import 'widgets/gstore_app_row.dart';
import 'widgets/gstore_update_action.dart';

/// GStore 目录浏览页：分页浏览本地 catalog，搜索 + 加入/移除。
///
/// - 列表：[CatalogFacade.listPage] 分页（每页 [_pageSize]，滚动到底加载更多）。
/// - 搜索：[CatalogFacade.search]（一次性返回，无分页）。
/// - 加入：`ChannelManager.addAppByCode('gstore', summary)` 写 `channel_apps`，
///   随后 [AddedAppsFacade.addMembership] 写 `added_apps` 成员关系（首页可见）。
/// - 已加入：[AddedAppsFacade.isAdded] 判定；移除走确认弹层 +
///   `ChannelManager.removeAppByCode` + [AddedAppsFacade.remove]。
/// - 加入成功后复用发现页的标签选择（[DiscoveryNotifier.showTagPickerForApp]）。
class GStoreBrowsePage extends StatefulWidget {
  const GStoreBrowsePage({super.key, this.discovery});

  /// 发现页 notifier（用于复用入库标签选择；为 null 时跳过标签流程）。
  final DiscoveryNotifier? discovery;

  /// gstore 渠道 code（Rust core 注册的可写渠道）。
  static const String channelCode = 'gstore';

  @override
  State<GStoreBrowsePage> createState() => _GStoreBrowsePageState();
}

class _GStoreBrowsePageState extends State<GStoreBrowsePage> {
  static const int _pageSize = 25;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;

  final List<AppSummary> _apps = [];
  final Set<String> _addedIds = {};
  final Set<String> _busyIds = {};

  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String _keyword = '';

  /// 当前 catalog 目录版本（`repoStatus().currentVersion`）。
  String? _version;

  /// 检查更新进行中（下载 + 物化 + 重载）。
  bool _updating = false;

  /// 递增请求序号：搜索/重载时丢弃过期的分页响应。
  int _requestSeq = 0;

  bool get _hasMore => _apps.length < _total;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    unawaited(_refreshStatus());
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 240) {
      unawaited(_loadMore());
    }
  }

  /// 读取当前目录版本并刷新 AppBar 副标题；失败保持原值（不打扰用户）。
  Future<void> _refreshStatus() async {
    try {
      final status = await CatalogFacade.instance.repoStatus();
      if (!mounted) return;
      setState(() => _version = status.currentVersion);
    } catch (e) {
      debugPrint('[GStore] 读取目录版本失败: $e');
    }
  }

  /// 检查更新：解析目录地址 → 下载 → 物化 → 刷新版本与列表。
  ///
  /// 地址解析失败（含 GitHub release 无 asset / 网络错误）时提示并终止；
  /// `repoDownload` 校验失败会抛错，因此不会物化。
  Future<void> _checkUpdate() async {
    if (_updating) return;
    final url = await CatalogUrlSetting.resolveDownloadUrl();
    if (url == null || url.isEmpty) {
      if (mounted) AppDialogs.showError('检查更新失败：无法解析目录地址');
      return;
    }
    if (!mounted) return;

    setState(() => _updating = true);
    try {
      final download = await CatalogFacade.instance.repoDownload(url: url);
      await CatalogFacade.instance.repoMaterialize();
      BadgeService.instance.clearBadge(BadgeKey.dbUpdate);
      await _refreshStatus();
      await _load(reset: true);
      if (!mounted) return;
      final version = download.version ?? _version;
      AppDialogs.showSuccess(
        version == null ? '目录已更新' : '目录已更新到 $version',
      );
    } catch (e) {
      if (mounted) AppDialogs.showError('检查更新失败：$e');
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _load({required bool reset}) async {
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      if (reset) _error = null;
    });
    try {
      final page = await CatalogFacade.instance.listPage(
        offset: reset ? 0 : _apps.length,
        limit: _pageSize,
      );
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        if (reset) _apps.clear();
        _apps.addAll(page.apps);
        _total = page.total;
        _loading = false;
        _loadingMore = false;
      });
      await _loadAdded(page.apps);
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || _keyword.isNotEmpty || !_hasMore) return;
    setState(() => _loadingMore = true);
    await _load(reset: false);
  }

  Future<void> _runSearch(String keyword) async {
    final seq = ++_requestSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await CatalogFacade.instance.search(keyword);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _apps
          ..clear()
          ..addAll(results);
        _total = results.length;
        _loading = false;
      });
      await _loadAdded(results);
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _loading = false;
        _error = '搜索失败：$e';
      });
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final keyword = value.trim();
      _keyword = keyword;
      if (keyword.isEmpty) {
        unawaited(_load(reset: true));
      } else {
        unawaited(_runSearch(keyword));
      }
    });
  }

  /// 刷新一页应用的「已加入」状态（并发查询，失败按未加入处理）。
  Future<void> _loadAdded(Iterable<AppSummary> apps) async {
    final checks = await Future.wait(apps.map((app) async {
      try {
        final added = await AddedAppsFacade.instance
            .isAdded(GStoreBrowsePage.channelCode, app.appId);
        return (app.appId, added);
      } catch (_) {
        return (app.appId, false);
      }
    }));
    if (!mounted) return;
    setState(() {
      for (final (appId, added) in checks) {
        if (added) {
          _addedIds.add(appId);
        } else {
          _addedIds.remove(appId);
        }
      }
    });
  }

  /// 打开应用详情；返回后刷新「已加入」状态（详情页可能完成入库）。
  Future<void> _openDetail(AppSummary app) async {
    await context.push(
      AppRoute.appDetail,
      extra: AppDetailRequest(
        appId: app.appId,
        name: app.name,
        packageName: app.packageName,
        icon: app.icon,
        description: app.des,
        channel: ChannelType.gstore,
        channelCode: GStoreBrowsePage.channelCode,
      ),
    );
    if (!mounted) return;
    await _loadAdded(_apps);
  }

  Future<void> _add(AppSummary app) async {
    setState(() => _busyIds.add(app.appId));
    try {
      final result = await ChannelManager.instance
          .addAppByCode(GStoreBrowsePage.channelCode, app);
      if (!result.success) {
        AppDialogs.showError('加入 GStore 失败：${result.error ?? '未知错误'}');
        return;
      }
      await AddedAppsFacade.instance
          .addMembership(GStoreBrowsePage.channelCode, app.appId);
      await AddedAppsFacade.instance.notifyAppsChanged();
      if (!mounted) return;
      setState(() => _addedIds.add(app.appId));
      AppDialogs.showSuccess('已加入 GStore：${app.name}');
      final discovery = widget.discovery;
      if (discovery != null && mounted) {
        unawaited(
          discovery.showTagPickerForApp(
              context, GStoreBrowsePage.channelCode, app),
        );
      }
    } catch (e) {
      if (mounted) AppDialogs.showError('加入 GStore 失败：$e');
    } finally {
      if (mounted) setState(() => _busyIds.remove(app.appId));
    }
  }

  Future<void> _remove(AppSummary app) async {
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '移出 GStore',
      message: '将「${app.name}」从首页移出？',
      confirmText: '移出',
      isDangerous: true,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyIds.add(app.appId));
    try {
      await ChannelManager.instance
          .removeAppByCode(GStoreBrowsePage.channelCode, app.appId);
      await AddedAppsFacade.instance
          .remove(GStoreBrowsePage.channelCode, app.appId);
      await AddedAppsFacade.instance.notifyAppsChanged();
      if (!mounted) return;
      setState(() => _addedIds.remove(app.appId));
    } catch (e) {
      if (mounted) AppDialogs.showError('移出 GStore 失败：$e');
    } finally {
      if (mounted) setState(() => _busyIds.remove(app.appId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GStoreTitle(version: _version),
        actions: [
          GStoreUpdateAction(
            updating: _updating,
            onPressed: () => unawaited(_checkUpdate()),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: AppSpacing.allLG,
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索目录应用...',
                prefixIcon: const Icon(TablerIcons.search),
                suffixIcon: _keyword.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(TablerIcons.x),
                        onPressed: () {
                          _searchController.clear();
                          _keyword = '';
                          unawaited(_load(reset: true));
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.circle),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                contentPadding: AppSpacing.allMD,
              ),
            ),
          ),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading && _apps.isEmpty) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final error = _error;
    if (error != null && _apps.isEmpty) {
      return ErrorState(
        message: error,
        retryLabel: '重试',
        onRetryPressed: () => unawaited(_load(reset: true)),
      );
    }
    if (_apps.isEmpty) {
      return EmptyState(
        message: _keyword.isEmpty ? '本地目录暂无应用' : '没有找到匹配的应用',
        icon: TablerIcons.database_off,
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: AppSpacing.horizontalLG_bottomLG,
      itemCount: _apps.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _apps.length) {
          return const Padding(
            padding: AppSpacing.allLG,
            child: Center(child: AppLoading(size: AppLoadingSize.small)),
          );
        }
        final app = _apps[index];
        return GStoreAppRow(
          app: app,
          isAdded: _addedIds.contains(app.appId),
          isBusy: _busyIds.contains(app.appId),
          onAdd: () => unawaited(_add(app)),
          onRemove: () => unawaited(_remove(app)),
          onTap: () => unawaited(_openDetail(app)),
        );
      },
    );
  }
}

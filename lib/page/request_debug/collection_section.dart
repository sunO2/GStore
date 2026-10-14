/// 「请求调试」集合分区（plan todo 31）：文件夹树 + 请求列表。
///
/// 独立文件，便于 todos 32-34 在 [RequestDebugPage] 中并列添加兄弟分区。
///
/// 能力：
/// - 文件夹树（支持嵌套子文件夹，可展开 / 折叠）；
/// - `+` 新建集合 / 子文件夹，cURL 导入（[importCurlSheet] → 门面解析）；
/// - 点击请求打开全屏 [RequestEditorPage]；
/// - 集合 / 请求的删除与重命名。
///
/// 设计约束：颜色 / 字号全取主题令牌（[Theme.of]），弹层走统一底部弹层
/// （[AppSheet] / [AppDialogs]），零硬编码颜色。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/import_export/import_export.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

import 'import_export_actions.dart';
import 'request_editor_page.dart';
import 'request_sheets.dart';
import 'search_sort_bar.dart';

/// 集合分区：文件夹树 + 请求列表。
class RequestDebugCollectionSection extends StatefulWidget {
  const RequestDebugCollectionSection({
    super.key,
    required this.facade,
    this.pickFile,
    this.saveFile,
    this.onSortModeChanged,
  });

  /// 窄门面（store CRUD + cURL 解析 + 发送）。
  final RequestDebugFacade facade;

  /// 导入文件选择接缝（测试注入；为空时走 [FilePicker]）。
  final DebugPickFile? pickFile;

  /// 导出文件保存接缝（测试注入；为空时走 [FilePicker]）。
  final DebugSaveFile? saveFile;

  /// 排序态变化回调（新值 `true` = 进入排序 / `false` = 退出）。
  ///
  /// 宿主（[RequestDebugPage] 导航头）据此在「更多」与「完成」按钮间切换；
  /// 为空时无副作用（裸分区测试不受影响）。
  final ValueChanged<bool>? onSortModeChanged;

  @override
  State<RequestDebugCollectionSection> createState() =>
      RequestDebugCollectionSectionState();
}

/// 集合分区状态：公开类型以便 [RequestDebugPage] 经 `GlobalKey` 驱动其
/// 导航头动作（添加集合 / 排序 / 导入 / 导出）。
class RequestDebugCollectionSectionState
    extends State<RequestDebugCollectionSection> {
  /// 处于折叠状态的集合 id（默认全部展开）。
  final Set<String> _collapsed = <String>{};

  /// 搜索查询串（空 = 不过滤）。
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// 排序顺序（默认原序）。
  DebugSortOrder _sort = DebugSortOrder.original;

  /// 排序模式（默认关闭）：仅开启后集合 / 请求条目尾部才显示拖拽手柄。
  bool _sorting = false;

  RequestDebugFacade get _facade => widget.facade;

  // ==================== 公开动作（供导航头 AppBar 驱动） ====================

  /// 排序模式是否开启（导航头「排序」菜单项据此显示勾选）。
  bool get sortMode => _sorting;

  /// 新建顶层集合（导航头「添加集合」）。
  Future<void> createCollection() => _createCollection();

  /// 导入 cURL（导航头「更多」→「导入 cURL」）。
  Future<void> importCurl() => _importCurl();

  /// 从文件导入集合（导航头「更多」→「导入集合文件…」）。
  Future<void> importCollections() => _importCollections();

  /// 导出当前集合树为指定格式（导航头「更多」→「导出为 …」）。
  Future<void> exportCollections(DebugTransferFormat format) =>
      _exportCollections(format);

  /// 切换排序模式（导航头「更多」→「排序」）。
  ///
  /// 与 Wave 7 的内联按钮语义一致：仅在「原序 + 无搜索」视图下可切换，
  /// 否则忽略（导航头菜单项此时不产生副作用）。
  void toggleSort() {
    final canReorder =
        _query.trim().isEmpty && _sort == DebugSortOrder.original;
    if (!canReorder) return;
    final next = !_sorting;
    setState(() => _sorting = next);
    widget.onSortModeChanged?.call(next);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ==================== 变更 ====================

  Future<void> _createCollection({String? parentId}) async {
    final name = await promptDebugName(
      context,
      title: parentId == null ? '新建集合' : '新建子文件夹',
      hint: '名称',
    );
    if (name == null || name.isEmpty || !mounted) return;
    _facade.store.addCollection(name: name, parentId: parentId);
    await _persist();
  }

  Future<void> _rename(DebugCollection collection) async {
    final name = await promptDebugName(
      context,
      title: '重命名集合',
      initial: collection.name,
    );
    if (name == null || name.isEmpty || name == collection.name || !mounted) {
      return;
    }
    _facade.store.updateCollection(collection.copyWith(name: name));
    await _persist();
  }

  Future<void> _deleteCollection(DebugCollection collection) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除集合',
      message: '将删除「${collection.name}」及其全部子文件夹与请求，此操作无法撤销。',
      confirmText: '删除',
      isDangerous: true,
    );
    if (ok != true || !mounted) return;
    _facade.store.removeCollection(collection.id);
    await _persist();
  }

  Future<void> _deleteRequest(DebugRequest request) async {
    final label = request.name.isEmpty ? request.url : request.name;
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除请求',
      message: '将删除请求「$label」，此操作无法撤销。',
      confirmText: '删除',
      isDangerous: true,
    );
    if (ok != true || !mounted) return;
    _facade.store.removeRequest(request.id);
    await _persist();
  }

  /// 复制请求（新 id，插在原请求之后）。
  Future<void> _duplicateRequest(DebugRequest request) async {
    final copy = _facade.store.duplicateRequest(request.id);
    if (copy == null) {
      AppDialogs.showError('复制失败：未找到请求');
      return;
    }
    await _persist();
  }

  /// 复制集合及其全部后代。
  Future<void> _duplicateCollection(DebugCollection collection) async {
    final copy = _facade.store.duplicateCollection(collection.id);
    if (copy == null) {
      AppDialogs.showError('复制失败：未找到集合');
      return;
    }
    await _persist();
  }

  Future<void> _importCurl() async {
    final text = await importCurlSheet(context);
    if (text == null || text.isEmpty || !mounted) return;
    final result = _facade.parseCurl(text);
    if (!result.isSuccess) {
      AppDialogs.showError(result.error ?? 'cURL 解析失败');
      return;
    }
    final target = _importTarget();
    _facade.store.addRequest(target.id, result.request!);
    await _persist();
    if (!mounted) return;
    await _reportIgnoredOptions(result.ignoredOptions);
  }

  /// 把被忽略 / 未处理的 cURL 选项汇总回传 UI（成功导入后可见，避免静默丢弃）。
  Future<void> _reportIgnoredOptions(List<String> ignored) async {
    if (ignored.isEmpty || !mounted) return;
    final theme = Theme.of(context);
    await AppDialogs.showAlertSheet(
      title: '部分选项被忽略',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in ignored)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Text('• $item', style: theme.textTheme.bodyMedium),
            ),
        ],
      ),
    );
  }

  /// 从文件导入集合（自动识别 HAR / Postman / OpenAPI / 原始 HTTP）。
  Future<void> _importCollections() =>
      importDebugCollections(context, _facade, pickFile: widget.pickFile);

  /// 把当前集合树导出为指定格式。
  Future<void> _exportCollections(DebugTransferFormat format) =>
      exportDebugCollections(
        context,
        _facade.store.collections,
        format,
        saveFile: widget.saveFile,
      );

  /// 导入目标：复用名为「导入」的顶层集合；不存在则新建。
  DebugCollection _importTarget() {    for (final c in _facade.store.collections) {
      if (c.parentId == null && c.name == '导入') return c;
    }
    return _facade.store.addCollection(name: '导入');
  }

  Future<void> _createRequest(DebugCollection collection) async {
    await _openEditor(collectionId: collection.id, request: null);
  }

  Future<void> _openEditor({
    required String collectionId,
    required DebugRequest? request,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RequestEditorPage(
          facade: _facade,
          collectionId: collectionId,
          request: request,
        ),
      ),
    );
    // 编辑器可能新增 / 修改了请求，返回后刷新列表。
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _persist() async {
    final ok = await _facade.save();
    if (!mounted) return;
    if (!ok) {
      AppDialogs.showError('保存失败，改动未写入磁盘');
    }
    setState(() {});
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final store = _facade.store;
    // 过滤 + 排序为纯函数（lib/core/request_debug/debug_search.dart），
    // 不改动 store 的 CRUD 语义。
    final displayed = sortDebugCollections(
      filterDebugCollections(store.collections, _query),
      _sort,
    );
    final roots = displayed.where((c) => c.parentId == null).toList();
    // 仅在「原序 + 无搜索」时允许拖拽重排：排序 / 过滤视图下的下标与 store
    // 原序不一致，若在此拖拽会写坏顺序。
    final canReorder =
        _query.trim().isEmpty && _sort == DebugSortOrder.original;
    // 搜索 / 非原序视图下无法安全重排：强制退出排序模式（手柄随之消失）。
    if (!canReorder && _sorting) {
      _sorting = false;
      // 被动复位同样需通知宿主（否则导航头会停在「完成」）。build 期间不能
      // 直接 setState 宿主，故排到当前帧之后回调。
      final onSortModeChanged = widget.onSortModeChanged;
      if (onSortModeChanged != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) onSortModeChanged(false);
        });
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const Divider(height: 1),
        Expanded(
          child: store.collections.isEmpty
              ? _buildEmpty(context)
              : displayed.isEmpty
                  ? _buildSearchEmpty(context)
                  : canReorder
                      ? ReorderableListView(
                          padding: AppSpacing.onlyVerticalSM,
                          buildDefaultDragHandles: false,
                          onReorderItem: (oldIndex, newIndex) {
                            _facade.store
                                .reorderCollection(null, oldIndex, newIndex);
                            _persist();
                          },
                          children: [
                            for (var i = 0; i < roots.length; i++)
                              _buildFolder(context, roots[i], 0, displayed,
                                  siblingIndex: i, reorderable: true),
                          ],
                        )
                      : ListView(
                          padding: AppSpacing.onlyVerticalSM,
                          children: [
                            for (final c in roots)
                              _buildFolder(context, c, 0, displayed),
                          ],
                        ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    return DebugSearchSortBar(
      sectionId: 'request-debug-collection',
      hint: '搜索集合 / 请求',
      controller: _searchCtrl,
      query: _query,
      sort: _sort,
      onQueryChanged: (value) => setState(() => _query = value),
      onSortChanged: (value) => setState(() => _sort = value),
    );
  }

  Widget _buildFolder(
    BuildContext context,
    DebugCollection collection,
    int depth,
    List<DebugCollection> collections, {
    int siblingIndex = 0,
    bool reorderable = false,
  }) {
    final expanded = !_collapsed.contains(collection.id);
    final children =
        collections.where((c) => c.parentId == collection.id).toList();

    final tile = ListTile(
      key: Key('request-debug-collection-${collection.id}'),
      contentPadding: EdgeInsets.only(
        left: AppSpacing.lg + depth * AppSpacing.lg,
        right: AppSpacing.sm,
      ),
      leading: Icon(
        expanded ? TablerIcons.chevron_down : TablerIcons.chevron_right,
      ),
      title: Text(collection.name),
      subtitle: Text('${collection.requests.length} 个请求'),
      onTap: () => setState(() {
        if (expanded) {
          _collapsed.add(collection.id);
        } else {
          _collapsed.remove(collection.id);
        }
      }),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reorderable && _sorting)
            SizedBox(
              width: 40,
              height: 40,
              child: Listener(
                key: Key('request-debug-collection-drag-${collection.id}'),
                onPointerDown: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                child: ReorderableDragStartListener(
                  index: siblingIndex,
                  child: const Icon(TablerIcons.grip_vertical),
                ),
              ),
            ),
          PopupMenuButton<String>(
            key: Key('request-debug-collection-menu-${collection.id}'),
            icon: const Icon(TablerIcons.dots),
            onSelected: (value) {
              switch (value) {
                case 'request':
                  _createRequest(collection);
                case 'folder':
                  _createCollection(parentId: collection.id);
                case 'duplicate':
                  _duplicateCollection(collection);
                case 'rename':
                  _rename(collection);
                case 'delete':
                  _deleteCollection(collection);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                key: Key('request-debug-collection-new-request-${collection.id}'),
                value: 'request',
                child: const Text('新建请求'),
              ),
              PopupMenuItem<String>(
                key: Key('request-debug-collection-new-folder-${collection.id}'),
                value: 'folder',
                child: const Text('新建子文件夹'),
              ),
              PopupMenuItem<String>(
                key: Key('request-debug-collection-duplicate-${collection.id}'),
                value: 'duplicate',
                child: const Text('复制'),
              ),
              PopupMenuItem<String>(
                key: Key('request-debug-collection-rename-${collection.id}'),
                value: 'rename',
                child: const Text('重命名'),
              ),
              PopupMenuItem<String>(
                key: Key('request-debug-collection-delete-${collection.id}'),
                value: 'delete',
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );

    // 跨文件夹拖拽移动：把请求拖到本文件夹标题即移入本集合。
    final folderHeader = reorderable
        ? DragTarget<DebugRequest>(
            onWillAcceptWithDetails: (details) =>
                details.data.collectionId != collection.id,
            onAcceptWithDetails: (details) {
              _facade.store.moveRequest(details.data.id, collection.id);
              _persist();
            },
            builder: (context, candidate, rejected) => tile,
          )
        : tile;

    return Column(
      key: Key('request-debug-folder-node-${collection.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        folderHeader,
        if (expanded) ...[
          if (reorderable && children.isNotEmpty)
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (oldIndex, newIndex) {
                _facade.store
                    .reorderCollection(collection.id, oldIndex, newIndex);
                _persist();
              },
              children: [
                for (var i = 0; i < children.length; i++)
                  _buildFolder(context, children[i], depth + 1, collections,
                      siblingIndex: i, reorderable: true),
              ],
            )
          else
            for (final child in children)
              _buildFolder(context, child, depth + 1, collections),
          if (reorderable && collection.requests.isNotEmpty)
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: (oldIndex, newIndex) {
                _facade.store
                    .reorderRequest(collection.id, oldIndex, newIndex);
                _persist();
              },
              children: [
                for (var i = 0; i < collection.requests.length; i++)
                  _buildRequest(context, collection.requests[i], depth + 1,
                      index: i, reorderable: true),
              ],
            )
          else
            for (final request in collection.requests)
              _buildRequest(context, request, depth + 1),
          if (collection.requests.isEmpty && children.isEmpty)
            Padding(
              key: Key('request-debug-collection-empty-${collection.id}'),
              padding: EdgeInsets.only(
                left: AppSpacing.xxxl + depth * AppSpacing.lg,
                bottom: AppSpacing.sm,
              ),
              child: Text(
                '暂无请求',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildRequest(
    BuildContext context,
    DebugRequest request,
    int depth, {
    int index = 0,
    bool reorderable = false,
  }) {
    if (!reorderable) {
      return KeyedSubtree(
        key: Key('request-debug-request-${request.id}'),
        child: _buildRequestTile(context, request, depth, index, false),
      );
    }
    // 长按整行 = 跨文件夹拖拽移动；右侧手柄 = 本文件夹内拖拽排序。
    return LongPressDraggable<DebugRequest>(
      key: Key('request-debug-request-${request.id}'),
      data: request,
      feedback: Material(
        elevation: 4,
        borderRadius: AppRadius.allSM,
        child: Padding(
          padding: AppSpacing.horizontalMD_verticalSM,
          child: Text(request.name.isEmpty ? request.url : request.name),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: _buildRequestTile(context, request, depth, index, true),
      ),
      child: _buildRequestTile(context, request, depth, index, true),
    );
  }

  Widget _buildRequestTile(
    BuildContext context,
    DebugRequest request,
    int depth,
    int index,
    bool reorderable,
  ) {
    return ListTile(
      contentPadding: EdgeInsets.only(
        left: AppSpacing.xxl + depth * AppSpacing.lg,
        right: AppSpacing.sm,
      ),
      leading: _methodChip(context, request.method),
      title: Text(
        request.name.isEmpty ? request.url : request.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        request.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _openEditor(
        collectionId: request.collectionId ?? '',
        request: request,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (reorderable && _sorting)
            SizedBox(
              width: 40,
              height: 40,
              child: Listener(
                key: Key('request-debug-request-drag-${request.id}'),
                onPointerDown: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                child: ReorderableDragStartListener(
                  index: index,
                  child: const Icon(TablerIcons.grip_vertical),
                ),
              ),
            ),
          PopupMenuButton<String>(
            key: Key('request-debug-request-menu-${request.id}'),
            icon: const Icon(TablerIcons.dots),
            onSelected: (value) {
              switch (value) {
                case 'duplicate':
                  _duplicateRequest(request);
                case 'delete':
                  _deleteRequest(request);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                key: Key('request-debug-request-duplicate-${request.id}'),
                value: 'duplicate',
                child: const Text('复制'),
              ),
              PopupMenuItem<String>(
                key: Key('request-debug-request-delete-${request.id}'),
                value: 'delete',
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _methodChip(BuildContext context, String method) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Container(
      padding: AppSpacing.horizontalSM_verticalXS,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: AppRadius.allSM,
      ),
      child: Text(
        method,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSecondaryContainer,
          fontWeight: AppTypography.weightSemiBold,
        ),
      ),
    );
  }

  Widget _buildSearchEmpty(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      key: const Key('request-debug-collection-search-empty'),
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              TablerIcons.search_off,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('未找到匹配的集合', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '试试其他关键字，或清空搜索查看全部。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              TablerIcons.folder,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('暂无集合', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '还没有请求集合，导入 cURL 或新建集合开始。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

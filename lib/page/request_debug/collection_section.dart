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
import 'package:gstore/core/request_debug/request_debug.dart';

import 'request_editor_page.dart';
import 'request_sheets.dart';

/// 集合分区：文件夹树 + 请求列表。
class RequestDebugCollectionSection extends StatefulWidget {
  const RequestDebugCollectionSection({super.key, required this.facade});

  /// 窄门面（store CRUD + cURL 解析 + 发送）。
  final RequestDebugFacade facade;

  @override
  State<RequestDebugCollectionSection> createState() =>
      _RequestDebugCollectionSectionState();
}

class _RequestDebugCollectionSectionState
    extends State<RequestDebugCollectionSection> {
  /// 处于折叠状态的集合 id（默认全部展开）。
  final Set<String> _collapsed = <String>{};

  RequestDebugFacade get _facade => widget.facade;

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
    _facade.store.updateCollection(
      DebugCollection(
        id: collection.id,
        name: name,
        parentId: collection.parentId,
        requests: collection.requests,
      ),
    );
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
    _facade.store.removeRequest(request.id);
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

  /// 导入目标：复用名为「导入」的顶层集合；不存在则新建。
  DebugCollection _importTarget() {
    for (final c in _facade.store.collections) {
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
    await _facade.save();
    if (!mounted) return;
    setState(() {});
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final store = _facade.store;
    final roots = store.collections.where((c) => c.parentId == null).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const Divider(height: 1),
        Expanded(
          child: store.collections.isEmpty
              ? _buildEmpty(context)
              : ListView(
                  padding: AppSpacing.onlyVerticalSM,
                  children: [
                    for (final c in roots) _buildFolder(context, c, 0),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text('集合树', style: theme.textTheme.titleMedium),
          ),
          IconButton(
            key: const Key('request-debug-curl-import'),
            tooltip: '导入 cURL',
            icon: const Icon(TablerIcons.file_import),
            onPressed: _importCurl,
          ),
          IconButton(
            key: const Key('request-debug-collection-add'),
            tooltip: '新建集合',
            icon: const Icon(TablerIcons.plus),
            onPressed: () => _createCollection(),
          ),
        ],
      ),
    );
  }

  Widget _buildFolder(BuildContext context, DebugCollection collection, int depth) {
    final expanded = !_collapsed.contains(collection.id);
    final children =
        _facade.store.collections.where((c) => c.parentId == collection.id).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
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
          trailing: PopupMenuButton<String>(
            key: Key('request-debug-collection-menu-${collection.id}'),
            icon: const Icon(TablerIcons.dots),
            onSelected: (value) {
              switch (value) {
                case 'request':
                  _createRequest(collection);
                case 'folder':
                  _createCollection(parentId: collection.id);
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
        ),
        if (expanded) ...[
          for (final child in children) _buildFolder(context, child, depth + 1),
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

  Widget _buildRequest(BuildContext context, DebugRequest request, int depth) {
    return ListTile(
      key: Key('request-debug-request-${request.id}'),
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
      trailing: PopupMenuButton<String>(
        key: Key('request-debug-request-menu-${request.id}'),
        icon: const Icon(TablerIcons.dots),
        onSelected: (value) {
          if (value == 'delete') _deleteRequest(request);
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            key: Key('request-debug-request-delete-${request.id}'),
            value: 'delete',
            child: const Text('删除'),
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

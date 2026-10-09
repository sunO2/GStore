/// 「请求调试」历史分区（plan todo 33）：发送历史 + 回看 / 重发 / 保存 / 删除 / 清空。
///
/// 独立文件，与 `collection_section.dart` 并列，避免与 todos 32/34 的并发编辑
/// 冲突（工作台壳 `request_debug_page.dart` 只做最小接线）。
///
/// 能力：
/// - 历史列表：方法 / URL / 状态 / 耗时 / 时间；
/// - `重发`：经门面**真正再次发送**（环境变量替换后），并追加一条新历史；
/// - `保存到集合`：克隆为新请求写入目标集合（换新 id，避免覆盖同名请求）；
/// - `删除` / `清空`：危险操作经 `showConfirmSheet(isDangerous: true)` 二次确认；
/// - 点击历史行：载入 [RequestEditorPage]（消费 todo 31 编辑器）；
/// - **有界**：追加统一走 [RequestDebugStore.addHistory]，超过 todo 25 的
///   [RequestDebugStore.historyLimit] 时由 store 淘汰最旧，绝不无限增长。
///
/// 设计约束：颜色 / 字号全取主题令牌（[Theme.of]），弹层走统一底部弹层
/// （[AppDialogs] / [AppSheet]），零硬编码颜色 / 字号。
library;

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

import 'request_editor_page.dart';
import 'response_diff_view.dart';
import 'search_sort_bar.dart';

// ==================== 追加接缝 ====================

/// 把完整 [DebugResponse] 折叠为历史用摘要（不保留大 Body）。
///
/// [DebugResponse.error] 非空时状态码置空（发送失败无有效状态码），错误信息
/// 原样保留；否则携带 `statusCode`（`0` 视为无状态码）。
DebugResponseSummary summarizeDebugResponse(DebugResponse response) {
  final error = response.error;
  final statusCode = (error == null && response.statusCode > 0)
      ? response.statusCode
      : null;
  return DebugResponseSummary(
    statusCode: statusCode,
    durationMs: response.durationMs,
    sizeBytes: response.sizeBytes,
    error: error,
  );
}

/// 记录一次发送到历史（最新在前，超出上限由 store 淘汰最旧），返回落库条目。
///
/// 这是「发送 → 历史」的**唯一追加接缝**：编辑器发送路径与历史分区的「重发」
/// 都经由此处，保证摘要映射一致、历史始终有界。仅内存写入，持久化由调用方
/// 随后显式 [RequestDebugFacade.save]。
DebugHistoryEntry appendDebugHistory(
  RequestDebugFacade facade, {
  required DebugRequest request,
  required DebugResponse response,
  int? tsMs,
}) {
  return facade.store.addHistory(DebugHistoryEntry(
    id: generateDebugId('hist'),
    tsMs: tsMs ?? DateTime.now().millisecondsSinceEpoch,
    request: request,
    responseSummary: summarizeDebugResponse(response),
    responseSnapshot: response.toHistorySnapshot(),
  ));
}

// ==================== 分区组件 ====================

/// 历史分区：发送历史列表 + 回看 / 重发 / 保存 / 删除 / 清空。
class RequestDebugHistorySection extends StatefulWidget {
  const RequestDebugHistorySection({super.key, required this.facade});

  /// 窄门面（store CRUD + sender + env）。
  final RequestDebugFacade facade;

  @override
  State<RequestDebugHistorySection> createState() =>
      _RequestDebugHistorySectionState();
}

class _RequestDebugHistorySectionState
    extends State<RequestDebugHistorySection> {
  RequestDebugFacade get _facade => widget.facade;

  /// 搜索查询串（空 = 不过滤）。
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// 排序顺序（默认原序 = 最新在前）。
  DebugSortOrder _sort = DebugSortOrder.original;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ==================== 动作 ====================

  /// 重发：经门面真正再次发送（环境替换），并追加一条新历史。
  Future<void> _resend(DebugHistoryEntry entry) async {
    final request = entry.request;
    final env = _facade.store.activeEnvironment;
    String resolve(String text) =>
        env == null ? text : _facade.resolveEnvIn(text, env).text;

    final headers = request.headers
        .map((h) => DebugHeader(
              name: h.name,
              value: resolve(h.value),
              enabled: h.enabled,
            ))
        .toList();
    final query = request.query
        .map((q) => DebugQueryParam(
              name: q.name,
              value: resolve(q.value),
              enabled: q.enabled,
            ))
        .toList();

    final response = await _facade.send(
      method: request.method,
      url: resolve(request.url),
      headers: headers,
      query: query,
      body: resolve(request.body),
    );
    if (!mounted) return;
    appendDebugHistory(_facade, request: request, response: response);
    final ok = await _persist();
    if (!mounted || !ok) return;
    if (response.error != null) {
      AppDialogs.showError('重发失败：${response.error}');
    } else {
      AppDialogs.showSuccess('已重发');
    }
  }

  /// 保存到集合：克隆为新请求（换新 id）写入目标集合并落盘。
  Future<void> _saveToCollection(DebugHistoryEntry entry) async {
    final collections = _facade.store.collections;
    if (collections.isEmpty) {
      await AppDialogs.showAlertSheet(
        title: '保存到集合',
        message: '还没有集合，请先在「集合」分区新建后再保存。',
      );
      return;
    }
    final picked = await AppSheet.showCustom<DebugCollection>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '保存到集合',
        subtitle: '选择目标集合',
        contentPadding: AppSpacing.onlyHorizontalXL,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in collections)
              Material(
                type: MaterialType.transparency,
                child: ListTile(
                  key: Key('request-debug-history-save-target-${c.id}'),
                  leading: const Icon(TablerIcons.folder),
                  title: Text(c.name),
                  subtitle: Text('${c.requests.length} 个请求'),
                  onTap: () => Navigator.of(sheetContext).pop(c),
                ),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final clone = entry.request.copyWith(
      id: generateDebugId('req'),
      collectionId: picked.id,
    );
    _facade.store.addRequest(picked.id, clone);
    final ok = await _persist();
    if (!mounted || !ok) return;
    AppDialogs.showSuccess('已保存到「${picked.name}」');
  }

  /// 删除单条：危险操作，二次确认。
  Future<void> _delete(DebugHistoryEntry entry) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除历史',
      message: '将删除这条历史记录，此操作无法撤销。',
      confirmText: '删除',
      isDangerous: true,
    );
    if (ok != true || !mounted) return;
    _facade.store.removeHistory(entry.id);
    await _persist();
  }

  /// 清空全部：危险操作，二次确认。
  Future<void> _clear() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清空历史',
      message: '将删除全部 ${_facade.store.history.length} 条历史记录，此操作无法撤销。',
      confirmText: '清空',
      isDangerous: true,
    );
    if (ok != true || !mounted) return;
    _facade.store.clearHistory();
    await _persist();
  }

  /// 点历史行：载入编辑器（消费 todo 31 编辑器），返回后刷新。
  Future<void> _openEditor(DebugHistoryEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RequestEditorPage(
          facade: _facade,
          collectionId: entry.request.collectionId,
          request: entry.request,
          initialResponseSnapshot: entry.responseSnapshot,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
  }

  /// 对比最近两条带快照的历史响应（旧 → 新）；不足两条时展示空态。
  Future<void> _showDiff() async {
    final withSnapshot = _facade.store.history
        .where((entry) => entry.responseSnapshot != null)
        .toList();
    final hasTwo = withSnapshot.length >= 2;
    final DebugResponseSnapshot? before =
        hasTwo ? withSnapshot[1].responseSnapshot : null;
    final DebugResponseSnapshot? after =
        hasTwo ? withSnapshot[0].responseSnapshot : null;
    await AppSheet.showCustom<void>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '响应对比',
        subtitle: '最近两条历史响应（旧 → 新）',
        scrollable: false,
        content: ResponseDiffView(before: before, after: after),
        actions: [
          FilledButton(
            key: const Key('request-debug-history-diff-close'),
            onPressed: () => Navigator.of(sheetContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<bool> _persist() async {
    final ok = await _facade.save();
    if (!mounted) return ok;
    if (!ok) {
      AppDialogs.showError('保存失败，改动未写入磁盘');
    }
    setState(() {});
    return ok;
  }

  // ==================== 构建 ====================

  @override
  Widget build(BuildContext context) {
    final store = _facade.store;
    // 过滤 + 排序为纯函数，不改动 store 的 CRUD 语义。
    final displayed = sortDebugHistory(
      filterDebugHistory(store.history, _query),
      _sort,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context),
        const Divider(height: 1),
        Expanded(
          child: store.history.isEmpty
              ? _buildEmpty(context)
              : displayed.isEmpty
                  ? _buildSearchEmpty(context)
                  : ListView.builder(
                      padding: AppSpacing.onlyVerticalSM,
                      itemCount: displayed.length,
                      itemBuilder: (context, index) =>
                          _buildEntry(context, displayed[index]),
                    ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final store = _facade.store;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.sm,
            AppSpacing.sm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text('发送历史', style: theme.textTheme.titleMedium),
              ),
              Text(
                '${store.history.length}/${store.historyLimit}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              IconButton(
                key: const Key('request-debug-history-diff'),
                tooltip: '对比最近两条',
                icon: const Icon(TablerIcons.arrows_diff),
                onPressed: _showDiff,
              ),
              IconButton(
                key: const Key('request-debug-history-clear'),
                tooltip: '清空历史',
                icon: const Icon(TablerIcons.clear_all),
                onPressed: store.history.isEmpty ? null : _clear,
              ),
            ],
          ),
        ),
        DebugSearchSortBar(
          sectionId: 'request-debug-history',
          hint: '搜索历史 URL / 方法',
          controller: _searchCtrl,
          query: _query,
          sort: _sort,
          onQueryChanged: (value) => setState(() => _query = value),
          onSortChanged: (value) => setState(() => _sort = value),
        ),
      ],
    );
  }

  Widget _buildEntry(BuildContext context, DebugHistoryEntry entry) {
    final theme = Theme.of(context);
    final summary = entry.responseSummary;
    final statusCode = summary.statusCode;
    final isError = summary.error != null;
    final isOk = !isError &&
        statusCode != null &&
        statusCode >= 200 &&
        statusCode < 300;
    final statusColor = isError
        ? theme.colorScheme.error
        : isOk
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant;
    final statusText = summary.error ??
        '${statusCode ?? '-'} · ${summary.durationMs}ms';

    return ListTile(
      key: Key('request-debug-history-${entry.id}'),
      leading: _methodChip(context, entry.request.method),
      title: Text(
        entry.request.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              statusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: statusColor),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            _formatTime(entry.tsMs),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      onTap: () => _openEditor(entry),
      trailing: PopupMenuButton<String>(
        key: Key('request-debug-history-menu-${entry.id}'),
        icon: const Icon(TablerIcons.dots),
        onSelected: (value) {
          switch (value) {
            case 'resend':
              _resend(entry);
            case 'save':
              _saveToCollection(entry);
            case 'delete':
              _delete(entry);
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            key: Key('request-debug-history-resend-${entry.id}'),
            value: 'resend',
            child: const Text('重发'),
          ),
          PopupMenuItem<String>(
            key: Key('request-debug-history-save-${entry.id}'),
            value: 'save',
            child: const Text('保存到集合'),
          ),
          PopupMenuItem<String>(
            key: Key('request-debug-history-delete-${entry.id}'),
            value: 'delete',
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Widget _methodChip(BuildContext context, String method) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
      key: const Key('request-debug-history-search-empty'),
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
            Text('未找到匹配的历史', style: theme.textTheme.titleMedium),
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
              TablerIcons.history,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('暂无历史', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '发送请求后，历史记录会出现在这里。',
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

  /// `MM-dd HH:mm:ss`（纯格式化，不引入本地化依赖）。
  static String _formatTime(int tsMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }
}

// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webview/web_browser_store.dart';

/// 内置浏览器「更多」菜单里的功能。
enum WebMoreAction {
  openUrl,
  search,
  history,
  bookmarks,
  toggleBookmark,
  refresh,
  copyLink,
  clearHistory,
}

/// 底部「更多」宫格菜单。
Future<WebMoreAction?> showWebMoreSheet(
  BuildContext context, {
  required bool bookmarked,
  required bool hasUrl,
}) {
  final tiles = <_MoreTileData>[
    const _MoreTileData(
      action: WebMoreAction.openUrl,
      icon: TablerIcons.world,
      label: '输入网址',
    ),
    const _MoreTileData(
      action: WebMoreAction.search,
      icon: TablerIcons.search,
      label: '搜索网页',
    ),
    const _MoreTileData(
      action: WebMoreAction.history,
      icon: TablerIcons.history,
      label: '历史记录',
    ),
    const _MoreTileData(
      action: WebMoreAction.bookmarks,
      icon: TablerIcons.bookmarks,
      label: '书签',
    ),
    _MoreTileData(
      action: WebMoreAction.toggleBookmark,
      icon: bookmarked ? TablerIcons.star_filled : TablerIcons.star,
      label: bookmarked ? '取消收藏' : '收藏页面',
      enabled: hasUrl,
    ),
    _MoreTileData(
      action: WebMoreAction.refresh,
      icon: TablerIcons.refresh,
      label: '刷新',
      enabled: hasUrl,
    ),
    _MoreTileData(
      action: WebMoreAction.copyLink,
      icon: TablerIcons.link,
      label: '复制链接',
      enabled: hasUrl,
    ),
    const _MoreTileData(
      action: WebMoreAction.clearHistory,
      icon: TablerIcons.trash,
      label: '清空历史',
      danger: true,
    ),
  ];

  return AppSheet.show<WebMoreAction>(
    context: context,
    title: '浏览器功能',
    icon: const Icon(TablerIcons.layout_grid),
    scrollable: false,
    content: GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 4,
      crossAxisSpacing: AppSpacing.sm,
      mainAxisSpacing: AppSpacing.sm,
      childAspectRatio: 0.82,
      children: [
        for (final tile in tiles)
          _MoreTile(
            data: tile,
            onTap: () => Navigator.of(context).pop(tile.action),
          ),
      ],
    ),
  );
}

class _MoreTileData {
  const _MoreTileData({
    required this.action,
    required this.icon,
    required this.label,
    this.enabled = true,
    this.danger = false,
  });

  final WebMoreAction action;
  final IconData icon;
  final String label;
  final bool enabled;
  final bool danger;
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.data, required this.onTap});

  final _MoreTileData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = data.danger ? scheme.error : scheme.onSurface;
    return InkWell(
      onTap: data.enabled ? onTap : null,
      borderRadius: AppRadius.allMD,
      child: Opacity(
        opacity: data.enabled ? 1 : 0.4,
        child: Container(
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: AppRadius.allMD,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xs,
            vertical: AppSpacing.sm,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(data.icon, size: 22, color: color),
              const SizedBox(height: AppSpacing.xs),
              Text(
                data.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 地址 / 搜索输入弹层；返回用户输入（已 trim），取消返回 null。
Future<String?> showWebInputSheet(
  BuildContext context, {
  String? initial,
  bool searchMode = false,
}) {
  return AppSheet.show<String>(
    context: context,
    title: searchMode ? '搜索网页' : '输入网址',
    subtitle: '网址直接打开；其它内容用 Bing 搜索',
    icon: Icon(searchMode ? TablerIcons.search : TablerIcons.world),
    content: _WebInputField(initial: initial, searchMode: searchMode),
  );
}

class _WebInputField extends StatefulWidget {
  const _WebInputField({this.initial, required this.searchMode});

  final String? initial;
  final bool searchMode;

  @override
  State<_WebInputField> createState() => _WebInputFieldState();
}

class _WebInputFieldState extends State<_WebInputField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      autofocus: true,
      textInputAction: TextInputAction.go,
      keyboardType: TextInputType.url,
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        hintText: widget.searchMode ? '搜索关键词' : 'example.com 或搜索关键词',
        prefixIcon: const Icon(TablerIcons.search),
        suffixIcon: IconButton(
          tooltip: '打开',
          icon: const Icon(TablerIcons.arrow_right),
          onPressed: _submit,
        ),
      ),
    );
  }
}

/// 历史记录 / 书签列表；点条目返回该条，关闭返回 null。
Future<WebPageEntry?> showWebEntriesSheet(
  BuildContext context, {
  required bool bookmarks,
}) {
  return AppSheet.show<WebPageEntry>(
    context: context,
    title: bookmarks ? '书签' : '历史记录',
    icon: Icon(bookmarks ? TablerIcons.bookmarks : TablerIcons.history),
    scrollable: false,
    content: _WebEntryList(bookmarks: bookmarks),
  );
}

class _WebEntryList extends StatefulWidget {
  const _WebEntryList({required this.bookmarks});

  final bool bookmarks;

  @override
  State<_WebEntryList> createState() => _WebEntryListState();
}

class _WebEntryListState extends State<_WebEntryList> {
  static const int _maxShown = 60;

  late List<WebPageEntry> _entries = widget.bookmarks
      ? WebBrowserStore.instance.bookmarks
      : WebBrowserStore.instance.history;

  Future<void> _remove(WebPageEntry entry) async {
    final store = WebBrowserStore.instance;
    if (widget.bookmarks) {
      await store.removeBookmark(entry.url);
    } else {
      await store.removeHistory(entry.url);
    }
    if (!mounted) return;
    setState(
        () => _entries = widget.bookmarks ? store.bookmarks : store.history);
  }

  Future<void> _clear() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清空历史记录',
      message: '确定清空全部浏览历史吗？书签不受影响。',
      confirmText: '清空',
      isDangerous: true,
    );
    if (ok != true) return;
    await WebBrowserStore.instance.clearHistory();
    if (!mounted) return;
    setState(() => _entries = WebBrowserStore.instance.history);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
        child: Column(
          children: [
            Icon(
              widget.bookmarks
                  ? TablerIcons.bookmarks_off
                  : TablerIcons.history_off,
              size: 36,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              widget.bookmarks ? '还没有收藏的页面' : '还没有浏览记录',
              style: textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final shown = _entries.take(_maxShown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.bookmarks)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _clear,
              icon: const Icon(TablerIcons.trash, size: 16),
              label: const Text('清空'),
            ),
          ),
        for (final entry in shown)
          _WebEntryRow(
            entry: entry,
            onOpen: () => Navigator.of(context).pop(entry),
            onDelete: () => _remove(entry),
          ),
        if (_entries.length > _maxShown)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Text(
              '仅显示最近 $_maxShown 条',
              style: textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

class _WebEntryRow extends StatelessWidget {
  const _WebEntryRow({
    required this.entry,
    required this.onOpen,
    required this.onDelete,
  });

  final WebPageEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onOpen,
      borderRadius: AppRadius.allSM,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xs,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Icon(TablerIcons.world, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle(entry),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '删除',
              icon: Icon(
                TablerIcons.x,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle(WebPageEntry entry) {
    final time = DateTime.fromMillisecondsSinceEpoch(entry.time);
    final now = DateTime.now();
    final sameDay =
        time.year == now.year && time.month == now.month && time.day == now.day;
    final stamp = sameDay
        ? '${time.hour.toString().padLeft(2, '0')}:'
            '${time.minute.toString().padLeft(2, '0')}'
        : '${time.month}/${time.day} '
            '${time.hour.toString().padLeft(2, '0')}:'
            '${time.minute.toString().padLeft(2, '0')}';
    return '${entry.host} · $stamp';
  }
}

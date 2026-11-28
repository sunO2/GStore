// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webview/web_browser_store.dart';

/// 内置浏览器「工具」菜单里的功能。
enum WebMoreAction {
  bookmarks,
  history,
  downloads,
  findInPage,
  nightMode,
  desktopMode,
  fontSize,
  viewSource,
  pageInfo,
  resources,
  bookmarkPage,
  settings,
}

/// 底部工具宫格：标准 5 列网格，只有内部分割线，无单元格底色/边框。
Future<WebMoreAction?> showWebMoreSheet(
  BuildContext context, {
  required bool hasUrl,
  required bool nightMode,
  bool bookmarked = false,
}) {
  final tiles = <_ToolTileData>[
    const _ToolTileData(
      action: WebMoreAction.bookmarks,
      icon: TablerIcons.bookmarks,
      label: '书签',
    ),
    const _ToolTileData(
      action: WebMoreAction.history,
      icon: TablerIcons.history,
      label: '历史',
    ),
    const _ToolTileData(
      action: WebMoreAction.downloads,
      icon: TablerIcons.download,
      label: '下载',
    ),
    _ToolTileData(
      action: WebMoreAction.findInPage,
      icon: TablerIcons.zoom_in,
      label: '页内查找',
      enabled: hasUrl,
    ),
    _ToolTileData(
      action: WebMoreAction.nightMode,
      icon: TablerIcons.moon,
      label: '夜间模式',
      enabled: hasUrl,
      active: nightMode,
    ),
    _ToolTileData(
      action: WebMoreAction.desktopMode,
      icon: TablerIcons.device_desktop,
      label: '电脑模式',
      enabled: hasUrl,
    ),
    _ToolTileData(
      action: WebMoreAction.fontSize,
      icon: TablerIcons.typography,
      label: '字体大小',
      enabled: hasUrl,
    ),
    _ToolTileData(
      action: WebMoreAction.viewSource,
      icon: TablerIcons.code,
      label: '查看源码',
      enabled: hasUrl,
    ),
    _ToolTileData(
      action: WebMoreAction.pageInfo,
      icon: TablerIcons.info_circle,
      label: '页面信息',
      enabled: hasUrl,
    ),
    _ToolTileData(
      action: WebMoreAction.resources,
      icon: TablerIcons.photo_search,
      label: '资源嗅探',
      enabled: hasUrl,
    ),
    // 导航头的位置让给了「本页脚本」，收藏入口挪到这里。
    _ToolTileData(
      action: WebMoreAction.bookmarkPage,
      icon: bookmarked ? TablerIcons.star_filled : TablerIcons.star,
      label: bookmarked ? '取消收藏' : '收藏本页',
      enabled: hasUrl,
      active: bookmarked,
    ),
  ];

  return AppSheet.showCustom<WebMoreAction>(
    context: context,
    builder: (sheetContext) => AppSheetScaffold(
      // 无标题、无左右内边距：整块就是功能宫格。
      scrollable: false,
      contentPadding: EdgeInsets.zero,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 没有标题栏；右上角保留设置入口，不占用宫格。
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.xs),
              child: IconButton(
                tooltip: '浏览器设置',
                visualDensity: VisualDensity.compact,
                icon: const Icon(TablerIcons.settings, size: 20),
                onPressed: () =>
                    Navigator.of(sheetContext).pop(WebMoreAction.settings),
              ),
            ),
          ),
          _ToolPager(
            tiles: tiles,
            onTap: (action) => Navigator.of(sheetContext).pop(action),
          ),
        ],
      ),
    ),
  );
}

class _ToolTileData {
  const _ToolTileData({
    required this.action,
    required this.icon,
    required this.label,
    this.enabled = true,
    this.active = false,
  });

  final WebMoreAction action;
  final IconData icon;
  final String label;
  final bool enabled;
  final bool active;
}

class _ToolPager extends StatefulWidget {
  const _ToolPager({required this.tiles, required this.onTap});

  static const int columns = 5;
  static const int rowsPerPage = 2;
  static const int pageSize = columns * rowsPerPage;

  final List<_ToolTileData> tiles;
  final ValueChanged<WebMoreAction> onTap;

  @override
  State<_ToolPager> createState() => _ToolPagerState();
}

class _ToolPagerState extends State<_ToolPager> {
  final PageController _controller = PageController();
  int _page = 0;

  int get _pageCount =>
      ((widget.tiles.length + _ToolPager.pageSize - 1) ~/ _ToolPager.pageSize)
          .clamp(1, 99);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: _ToolCell.height * _ToolPager.rowsPerPage,
          child: PageView.builder(
            controller: _controller,
            physics: _pageCount > 1
                ? const BouncingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            itemCount: _pageCount,
            onPageChanged: (page) => setState(() => _page = page),
            itemBuilder: (context, page) {
              final start = page * _ToolPager.pageSize;
              final end =
                  (start + _ToolPager.pageSize).clamp(0, widget.tiles.length);
              final pageTiles = widget.tiles.sublist(start, end);
              return Column(
                children: [
                  for (var rowStart = 0;
                      rowStart < pageTiles.length;
                      rowStart += _ToolPager.columns)
                    Row(
                      children: [
                        for (var i = rowStart;
                            i <
                                (rowStart + _ToolPager.columns)
                                    .clamp(0, pageTiles.length);
                            i++)
                          Expanded(
                            child: _ToolCell(
                              data: pageTiles[i],
                              onTap: widget.onTap,
                            ),
                          ),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
        if (_pageCount > 1) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _pageCount; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _page ? 16 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _page ? scheme.primary : scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ToolCell extends StatelessWidget {
  const _ToolCell({required this.data, required this.onTap});

  static const double height = 86;

  final _ToolTileData data;
  final ValueChanged<WebMoreAction> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = !data.enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
        : data.active
            ? scheme.primary
            : scheme.onSurfaceVariant;
    return InkWell(
      onTap: data.enabled ? () => onTap(data.action) : null,
      child: SizedBox(
        height: height,
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
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
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

/// 网站要求 HTTP 身份验证（Basic/Digest）时的账号密码输入框。
Future<({String username, String password})?> showWebHttpAuthSheet(
  BuildContext context, {
  required String host,
  String? realm,
}) {
  return AppSheet.showCustom<({String username, String password})>(
    context: context,
    builder: (_) => _HttpAuthSheet(host: host, realm: realm),
  );
}

class _HttpAuthSheet extends StatefulWidget {
  const _HttpAuthSheet({required this.host, this.realm});

  final String host;
  final String? realm;

  @override
  State<_HttpAuthSheet> createState() => _HttpAuthSheetState();
}

class _HttpAuthSheetState extends State<_HttpAuthSheet> {
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final username = _username.text.trim();
    if (username.isEmpty) return;
    Navigator.of(context).pop((
      username: username,
      password: _password.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final realm = widget.realm?.trim() ?? '';
    return AppSheetScaffold(
      title: '需要登录',
      subtitle: realm.isEmpty ? widget.host : '${widget.host} · $realm',
      icon: const Icon(TablerIcons.lock),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('登录')),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _username,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '用户名',
              prefixIcon: Icon(TablerIcons.user, size: 18),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _password,
            obscureText: _obscure,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: '密码',
              prefixIcon: const Icon(TablerIcons.key, size: 18),
              suffixIcon: IconButton(
                tooltip: _obscure ? '显示密码' : '隐藏密码',
                icon: Icon(
                  _obscure ? TablerIcons.eye : TablerIcons.eye_off,
                  size: 18,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

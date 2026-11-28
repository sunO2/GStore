// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webview/web_browser_store.dart';
import 'package:gstore/core/webview/web_suggestions.dart';

/// 内置浏览器「工具」菜单里的功能。
enum WebMoreAction {
  bookmarks,
  history,
  findInPage,
  nightMode,
  desktopMode,
  fontSize,
  viewSource,
  pageInfo,
  resources,
  clearData,
}

/// 底部工具宫格：标准 5 列网格，只有内部分割线，无单元格底色/边框。
Future<WebMoreAction?> showWebMoreSheet(
  BuildContext context, {
  required bool hasUrl,
  required bool nightMode,
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
    const _ToolTileData(
      action: WebMoreAction.clearData,
      icon: TablerIcons.trash,
      label: '清除数据',
      danger: true,
    ),
  ];

  return AppSheet.show<WebMoreAction>(
    context: context,
    title: '浏览器工具',
    icon: const Icon(TablerIcons.tool),
    scrollable: false,
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
    content: _ToolGrid(
      tiles: tiles,
      onTap: (action) => Navigator.of(context).pop(action),
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
    this.danger = false,
  });

  final WebMoreAction action;
  final IconData icon;
  final String label;
  final bool enabled;
  final bool active;
  final bool danger;
}

class _ToolGrid extends StatelessWidget {
  const _ToolGrid({required this.tiles, required this.onTap});

  static const int _columns = 5;

  final List<_ToolTileData> tiles;
  final ValueChanged<WebMoreAction> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final line = BorderSide(
      color: scheme.outlineVariant.withValues(alpha: 0.45),
      width: 1,
    );
    final rows = <TableRow>[];
    for (var i = 0; i < tiles.length; i += _columns) {
      rows.add(TableRow(
        children: [
          for (var j = 0; j < _columns; j++)
            if (i + j < tiles.length)
              _ToolCell(data: tiles[i + j], onTap: onTap)
            else
              const SizedBox.shrink(),
        ],
      ));
    }
    return Table(
      border: TableBorder(horizontalInside: line, verticalInside: line),
      children: rows,
    );
  }
}

class _ToolCell extends StatelessWidget {
  const _ToolCell({required this.data, required this.onTap});

  final _ToolTileData data;
  final ValueChanged<WebMoreAction> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final color = !data.enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
        : data.danger
            ? scheme.error
            : data.active
                ? scheme.primary
                : scheme.onSurfaceVariant;
    return InkWell(
      onTap: data.enabled ? () => onTap(data.action) : null,
      child: SizedBox(
        height: 86,
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

/// 地址 / 搜索输入弹层；返回用户输入（已 trim），取消返回 null。
Future<String?> showWebInputSheet(
  BuildContext context, {
  String? initial,
  bool searchMode = false,
}) {
  return AppSheet.show<String>(
    context: context,
    title: searchMode ? '搜索网页' : '输入网址',
    subtitle: '网址直接打开；其它内容用必应搜索',
    icon: Icon(searchMode ? TablerIcons.search : TablerIcons.world),
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
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
  static const Duration _debounce = Duration(milliseconds: 260);

  late final TextEditingController _controller =
      TextEditingController(text: widget.initial ?? '');
  Timer? _timer;
  List<String> _suggestions = const [];
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller
      ..removeListener(_onChanged)
      ..dispose();
    super.dispose();
  }

  void _onChanged() {
    _timer?.cancel();
    final text = _controller.text.trim();
    if (text.isEmpty || text.contains(' ') || _looksLikeUrl(text)) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = const []);
      return;
    }
    _timer = Timer(_debounce, () => _fetch(text));
  }

  Future<void> _fetch(String text) async {
    final id = ++_requestId;
    final items = await fetchBingSuggestions(text);
    if (!mounted || id != _requestId) return;
    setState(() => _suggestions = items);
  }

  bool _looksLikeUrl(String text) => text.contains('.') && !text.contains(' ');

  void _submit([String? value]) {
    final text = (value ?? _controller.text).trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
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
        ),
        if (_suggestions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          for (final item in _suggestions)
            InkWell(
              onTap: () => _submit(item),
              borderRadius: AppRadius.allSM,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      TablerIcons.search,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        item,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium,
                      ),
                    ),
                    Icon(
                      TablerIcons.arrow_up_left,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ],
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

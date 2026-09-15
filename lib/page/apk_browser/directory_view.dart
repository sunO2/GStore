import 'package:flutter/material.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/rust/contract/ModuleTypes.dart';
import 'package:gstore/core/service/apk_browser_service.dart';
import 'package:gstore/core/utils/unit.dart';
import 'package:gstore/page/apk_browser/preview.dart';

/// 列一层目录的加载函数（可注入，便于测试）
typedef ApkListingLoader = Future<ApkBrowseListing?> Function({
  required String apkPath,
  required String containerChain,
  required String dir,
});

/// 默认加载：走 [ApkBrowserService]（解压在 Rust）
Future<ApkBrowseListing?> defaultApkListingLoader({
  required String apkPath,
  required String containerChain,
  required String dir,
}) =>
    ApkBrowserService.instance.list(
      apkPath,
      containerChain: containerChain,
      dir: dir,
    );

/// **一个目录层**（APK 内容浏览的「目录组件」）
///
/// 设计：每一层目录是一个独立组件，由宿主页压进栈并**保活**——
/// 因此返回上一层时滚动位置、搜索词、已加载的清单都原样保留（不重新列举）。
///
/// 组件只负责「当前这一层」：面包屑 / 统计 / 搜索 / 条目列表；
/// 进入下一层、进入压缩包、打开文件、上一层、面包屑跳转都由宿主回调决定，
/// 这样宿主能统一维护栈与返回语义（见 `view.dart`）。
class ApkDirectoryView extends StatefulWidget {
  const ApkDirectoryView({
    super.key,
    required this.apkPath,
    required this.containerChain,
    required this.containerLabel,
    required this.dir,
    required this.loader,
    required this.onUp,
    required this.onJumpTo,
    required this.onOpenZip,
    required this.onOpenFile,
  });

  final String apkPath;

  /// 当前容器链（本页所属容器，空 = APK 根）
  final String containerChain;

  /// 容器显示名（`APK` 或压缩包文件名）
  final String containerLabel;

  /// 本层在容器内的目录前缀（空 = 容器根）
  final String dir;

  final ApkListingLoader loader;

  /// 上一层目录（仅当 [dir] 非空时可用）
  final VoidCallback onUp;

  /// 面包屑跳转到某个祖先目录
  final ValueChanged<String> onJumpTo;

  /// 打开压缩包（宿主决定新开页还是压栈）
  final ValueChanged<ApkBrowsableEntry> onOpenZip;

  /// 打开普通文件（预览）
  final ValueChanged<ApkBrowsableEntry> onOpenFile;

  @override
  State<ApkDirectoryView> createState() => _ApkDirectoryViewState();
}

class _ApkDirectoryViewState extends State<ApkDirectoryView> {
  final TextEditingController _queryCtrl = TextEditingController();

  ApkBrowseListing? _listing;
  bool _loading = true;
  String? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final listing = await widget.loader(
      apkPath: widget.apkPath,
      containerChain: widget.containerChain,
      dir: widget.dir,
    );
    if (!mounted) return;
    setState(() {
      _listing = listing;
      _loading = false;
      if (listing == null) _error = '分析模块未就绪，无法浏览 APK 内容';
    });
  }

  List<String> get _segments =>
      widget.dir.isEmpty ? const [] : widget.dir.split('/');

  List<ApkBrowsableEntry> get _visibleEntries {
    final entries = _listing?.entries ?? const <ApkBrowsableEntry>[];
    if (_query.isEmpty) return entries;
    final q = _query.toLowerCase();
    return entries
        .where((e) =>
            e.name.toLowerCase().contains(q) ||
            e.path.toLowerCase().contains(q) ||
            e.kind.toLowerCase().contains(q))
        .toList();
  }

  void _open(ApkBrowsableEntry entry) {
    if (entry.isDir) {
      widget.onJumpTo(entry.path);
    } else if (entry.browsable) {
      widget.onOpenZip(entry);
    } else {
      widget.onOpenFile(entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        _statsLine(),
        _searchBar(),
        Expanded(child: _body()),
      ],
    );
  }

  /// 面包屑 + 上一层 + 刷新
  Widget _toolbar() {
    final theme = Theme.of(context);
    final crumbs = <({String label, String dir, bool active})>[
      (label: widget.containerLabel, dir: '', active: _segments.isNotEmpty),
      for (var i = 1; i <= _segments.length; i++)
        (
          label: _segments[i - 1],
          dir: _segments.sublist(0, i).join('/'),
          active: i < _segments.length,
        ),
    ];
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          if (widget.dir.isNotEmpty)
            IconButton(
              tooltip: '上一层目录',
              icon: const Icon(Icons.arrow_upward, size: AppTypography.iconMD),
              onPressed: widget.onUp,
            )
          else
            const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: crumbs.length,
              separatorBuilder: (_, __) => Icon(
                Icons.chevron_right,
                size: AppTypography.iconSM,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              itemBuilder: (context, index) {
                final crumb = crumbs[index];
                return Center(
                  child: InkWell(
                    onTap: crumb.active
                        ? () => widget.onJumpTo(crumb.dir)
                        : null,
                    borderRadius: BorderRadius.circular(AppRadius.xs),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                        vertical: AppSpacing.xs,
                      ),
                      child: Text(
                        crumb.label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: crumb.active
                              ? theme.colorScheme.primary
                              : theme.colorScheme.onSurface,
                          fontWeight:
                              crumb.active ? null : FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: AppTypography.iconMD),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
    );
  }

  /// 目录统计行（条目数 / 容器大小）
  ///
  /// **常驻占位**：这一行原来是「有数据才渲染」，加载完成的瞬间才冒出来，
  /// 会把下面的搜索栏整行顶下去（看起来就是"搜索框闪一下"）。
  /// 现在无论加载中 / 失败 / 有数据都占同一行，且文案永不为空（保持单行高度一致），
  /// 搜索栏的位置在整层生命周期内不再跳动。
  Widget _statsLine() {
    final theme = Theme.of(context);
    final listing = _listing;
    final text = listing != null
        ? '条目 ${listing.totalFiles} · 当前容器 ${byteSize(listing.containerSize)}'
            '${listing.truncated ? ' · 已截断，请用搜索收窄' : ''}'
        : (_loading ? '正在读取目录…' : '—');
    return Padding(
      padding: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomXS),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyVerticalSM),
      child: TextField(
        controller: _queryCtrl,
        onChanged: (v) => setState(() => _query = v.trim()),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索文件名 / 路径 / 类型（如 lib、png、json）',
          prefixIcon: const Icon(Icons.search, size: AppTypography.iconSM),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: AppTypography.iconSM),
                  onPressed: () {
                    _queryCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _hint(_error!, Icons.error_outline);
    }
    final entries = _visibleEntries;
    if (entries.isEmpty) {
      return _hint(
        _query.isEmpty ? '该目录下没有条目' : '没有匹配「$_query」的条目',
        Icons.inbox_outlined,
      );
    }
    return ListView.builder(
      padding: AppSpacing.onlyBottomSM,
      itemCount: entries.length,
      itemBuilder: (context, index) => _entryRow(entries[index]),
    );
  }

  Widget _hint(String text, IconData icon) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpacing.sm),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryRow(ApkBrowsableEntry entry) {
    final theme = Theme.of(context);
    final meta = StringBuffer(apkEntryKindLabel(entry.kind, isDir: entry.isDir));
    meta.write(' · ${byteSize(entry.size)}');
    if (!entry.isDir) {
      if (entry.compressedSize > 0 && entry.compressedSize != entry.size) {
        meta.write(' · 压缩 ${byteSize(entry.compressedSize)}');
      }
      if (entry.stored) meta.write(' · STORED');
      if (entry.browsable) meta.write(' · 可进入');
    }
    final actionable = entry.isDir || entry.browsable;
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      onTap: () => _open(entry),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              apkEntryIcon(entry.kind, isDir: entry.isDir),
              size: AppTypography.iconMD,
              color: entry.isDir
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 长路径换行显示，不用省略号截断
                Text(entry.name, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  meta.toString(),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (actionable)
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
  }
}

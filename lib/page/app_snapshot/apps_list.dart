import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_radius.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:gstore/core/service/app_icon_service.dart';
import 'package:gstore/core/snapshot/app_snapshot_store.dart';
import 'package:gstore/core/snapshot/snapshot_diff_engine.dart' show formatTime;
import 'package:gstore/core/snapshot/snapshot_models.dart';
import 'package:gstore/page/app_snapshot/view.dart';

/// 快照总览：列出**已生成过快照的应用**，点条目进入该应用的快照页。
///
/// 入口来自「我的 → 工具 → 应用快照」。与应用分析页导航头的入口互补：
/// 那里是"从应用进快照"，这里是"从快照进应用"。
class AppSnapshotAppsPage extends StatefulWidget {
  const AppSnapshotAppsPage({super.key});

  /// 测试用：跳过数据库直接给列表数据（widget 测试里 sqflite 的 isolate 往返
  /// 与 pumpAndSettle 的伪时钟不兼容，故提供注入口）
  @visibleForTesting
  static List<SnapshotAppEntry>? debugAppsOverride;

  @override
  State<AppSnapshotAppsPage> createState() => _AppSnapshotAppsPageState();
}

class _AppSnapshotAppsPageState extends State<AppSnapshotAppsPage> {
  final AppSnapshotStore _store = AppSnapshotStore.instance;

  List<SnapshotAppEntry> _apps = const [];
  bool _loading = true;

  /// packageName → 应用真实图标（本地缓存文件路径；取不到为 null）
  final Map<String, String?> _icons = <String, String?>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final apps = AppSnapshotAppsPage.debugAppsOverride ?? await _store.listApps();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _loading = false;
    });
    await _resolveIcons(apps);
  }

  /// 解析各应用的真实图标（已安装应用 → 本地图标文件路径）。
  ///
  /// 放列表之后做：图标要过平台通道，不阻塞首屏；取不到（如应用已卸载）时
  /// 行内回落占位图标。
  Future<void> _resolveIcons(List<SnapshotAppEntry> apps) async {
    var changed = false;
    for (final a in apps) {
      if (_icons.containsKey(a.packageName)) continue;
      String? path;
      try {
        path = await AppIconService.instance.getInstalledAppIcon(a.packageName);
      } catch (e) {
        appLog.error('AppSnapshotAppsPage: 取应用图标失败 - ${a.packageName} - $e');
      }
      _icons[a.packageName] = path;
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  /// 打开某应用的快照页：sourceDir 现取（应用可能已卸载 → 交给页面按历史只读处理）
  Future<void> _openApp(SnapshotAppEntry entry) async {
    var sourceDir = '';
    List<String> dirs = const <String>[];
    try {
      sourceDir = await ApkSourceService.instance.getSourceDir(entry.packageName) ?? '';
      if (sourceDir.isNotEmpty) {
        dirs = await ApkSourceService.instance.getSourceDirs(entry.packageName);
      }
    } catch (e) {
      appLog.error('AppSnapshotAppsPage: 取安装包路径失败 - $e');
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppSnapshotPage(
          packageName: entry.packageName,
          appLabel: entry.displayName,
          sourceDir: sourceDir,
          sourceDirs: dirs.isEmpty ? null : dirs,
        ),
      ),
    );
    // 返回后刷新：份数/最近时间可能已变（新建或删除过）
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用快照'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _apps.isEmpty
              ? const _EmptyHint()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: AppSpacing.onlyVerticalSM,
                    itemCount: _apps.length,
                    itemBuilder: (context, i) => _AppRow(
                      entry: _apps[i],
                      iconPath: _icons[_apps[i].packageName],
                      onTap: () => _openApp(_apps[i]),
                    ),
                  ),
                ),
    );
  }
}

/// 单行：应用名 + 包名 + 份数/最近时间/版本
class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.entry,
    required this.onTap,
    this.iconPath,
  });

  final SnapshotAppEntry entry;
  final VoidCallback onTap;

  /// 真实图标（本地文件路径）；为空则用占位图标
  final String? iconPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      elevation: 0,
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.allLG),
      child: ListTile(
        // 应用真实图标；未安装/取不到时回落占位图标
        leading: (iconPath == null || iconPath!.isEmpty)
            ? Icon(Icons.history_outlined, color: theme.colorScheme.primary)
            : AppIcon(url: iconPath, width: 40, height: 40),
        title: Text(
          entry.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge
              ?.copyWith(fontWeight: AppTypography.weightMedium),
        ),
        // 长内容换行不截断：包名与统计各占一行
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: AppSpacing.xs),
            Text(
              entry.packageName,
              style: AppTypography.code.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${entry.count} 份快照 · 最近 ${formatTime(entry.latestAt)}'
              '${entry.latestVersionName.isEmpty ? '' : ' · v${entry.latestVersionName}'}',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right, size: AppTypography.iconMD),
        onTap: onTap,
      ),
    );
  }
}

/// 空态：顺带说明去哪里生成
class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: AppSpacing.allXXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_outlined, size: 48, color: muted),
            const SizedBox(height: AppSpacing.md),
            Text('还没有生成过快照', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '进入「应用列表 → 应用分析」，在右上角点「应用快照」即可生成',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: () => context.push(AppRoute.installedApps),
              icon: const Icon(Icons.apps_outlined),
              label: const Text('去应用列表'),
            ),
          ],
        ),
      ),
    );
  }
}

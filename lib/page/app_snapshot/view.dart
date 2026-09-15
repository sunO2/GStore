import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/snapshot/app_snapshot_store.dart';
import 'package:gstore/core/snapshot/snapshot_collector.dart';
import 'package:gstore/core/snapshot/snapshot_diff_engine.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';
import 'package:gstore/page/app_snapshot/compare.dart';
import 'package:gstore/page/app_snapshot/detail.dart';
import 'package:gstore/page/app_snapshot/widgets.dart';

/// 快照历史页：单应用快照的创建 / 查看 / 删除 / 两两对比
///
/// 入口来自「应用分析」页导航头（AppBar）。
class AppSnapshotPage extends StatefulWidget {
  const AppSnapshotPage({
    super.key,
    required this.packageName,
    required this.appLabel,
    required this.sourceDir,
    this.sourceDirs,
  });

  final String packageName;
  final String appLabel;
  final String sourceDir;
  final List<String>? sourceDirs;

  @override
  State<AppSnapshotPage> createState() => _AppSnapshotPageState();
}

class _AppSnapshotPageState extends State<AppSnapshotPage> {
  final AppSnapshotStore _store = AppSnapshotStore.instance;

  List<SnapshotRecord> _records = const [];
  final Set<int> _selected = <int>{};
  bool _loading = true;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    List<SnapshotRecord> records;
    try {
      records = await _store.listByApp(widget.packageName);
    } catch (e) {
      appLog.error('AppSnapshotPage: 读取快照失败 - $e');
      records = const [];
    }
    if (!mounted) return;
    setState(() {
      _records = records;
      _selected.removeWhere((id) => !records.any((r) => r.id == id));
      _loading = false;
    });
  }

  Future<void> _capture() async {
    if (_capturing) return;
    // 入口可能来自「快照总览」（应用可能已卸载，拿不到安装包）：
    // 此时只允许查看历史，不生成一份全是缺失告警的空快照
    if (widget.sourceDir.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到安装包，无法新建快照（历史快照仍可查看）')),
      );
      return;
    }
    setState(() => _capturing = true);
    try {
      final result = await SnapshotCollector.instance.capture(
        packageName: widget.packageName,
        appLabel: widget.appLabel,
        sourceDir: widget.sourceDir,
        sourceDirs: widget.sourceDirs,
      );
      final record = SnapshotCollector.instance.toRecord(
        result,
        packageName: widget.packageName,
        appLabel: widget.appLabel,
        capturedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await _store.insert(record);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.isComplete
                ? '快照已创建（规则命中 ${result.payload.summary.ruleHits} 项）'
                : '快照已创建，但有 ${result.warnings.length} 处数据缺失',
          ),
        ),
      );
    } catch (e) {
      appLog.error('AppSnapshotPage: 创建快照失败 - $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('创建快照失败：$e')));
    } finally {
      if (mounted) setState(() => _capturing = false);
      await _load();
    }
  }

  Future<void> _delete(SnapshotRecord record) async {
    final id = record.id;
    if (id == null) return;
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除快照',
      message: '确认删除 ${formatTime(record.createdAt)} 的快照？该操作不可恢复。',
      confirmText: '删除',
      cancelText: '取消',
      isDangerous: true,
    );
    if (ok != true) return;
    try {
      await _store.delete(id);
    } catch (e) {
      appLog.error('AppSnapshotPage: 删除快照失败 - $e');
    }
    await _load();
  }

  void _toggleSelect(SnapshotRecord record) {
    final id = record.id;
    if (id == null) return;
    setState(() {
      if (!_selected.remove(id)) {
        // 最多选两个：超出时顶掉最早选中的那个
        if (_selected.length >= 2) _selected.remove(_selected.first);
        _selected.add(id);
      }
    });
  }

  Future<void> _openDetail(SnapshotRecord record) async {
    final previous = _previousOf(record);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AppSnapshotDetailPage(record: record, previous: previous),
      ),
    );
  }

  Future<void> _openCompare() async {
    if (_selected.length != 2) return;
    final picked = _records.where((r) => _selected.contains(r.id)).toList();
    if (picked.length != 2) return;
    // 按时间升序：旧 → 新
    picked.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    await Navigator.push(
      context,
      MaterialPageRoute(
        // 方向默认「早 → 晚」；勾选顺序不参与决定，避免"先点后点"的歧义
        builder: (_) => AppSnapshotComparePage(
          oldRecord: picked.first,
          newRecord: picked.last,
        ),
      ),
    );
  }

  /// 时间上紧邻的上一份快照（用于详情页「与上一快照对比」）
  SnapshotRecord? _previousOf(SnapshotRecord record) {
    SnapshotRecord? best;
    for (final r in _records) {
      if (r.id == record.id) continue;
      if (r.createdAt >= record.createdAt) continue;
      if (best == null || r.createdAt > best.createdAt) best = r;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用快照'),
        actions: [
          IconButton(
            tooltip: '新建快照',
            icon: _capturing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_a_photo_outlined),
            onPressed: _capturing ? null : _capture,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? const SnapshotEmptyHint(
                  text: '还没有快照。\n创建快照可记录当前的应用信息，之后能对比出'
                      '版本更新带来的原生库、权限、组件、签名等变化。',
                  icon: Icons.camera_alt_outlined,
                )
              : Column(
                  children: [
                    Padding(
                      padding: AppSpacing.onlyHorizontalLG
                          .add(AppSpacing.onlyTopSM),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${widget.appLabel} · ${widget.packageName}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Text(
                            '共 ${_records.length} 份',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: AppSpacing.onlyVerticalSM,
                        itemCount: _records.length,
                        itemBuilder: (context, index) {
                          final record = _records[index];
                          return _buildRecordCard(record, index);
                        },
                      ),
                    ),
                  ],
                ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: AppSpacing.allMD,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        switch (_selected.length) {
                          2 => '已选 2 份：默认「旧 → 新」，进入后可互换方向',
                          1 => '已选 1 份，再选一份即可对比',
                          _ => '勾选两份快照进行对比',
                        },
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _selected.length == 2 ? _openCompare : null,
                      icon: const Icon(Icons.compare_arrows),
                      label: const Text('对比'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildRecordCard(SnapshotRecord record, int index) {
    final theme = Theme.of(context);
    final summary = record.summary;
    final selected = _selected.contains(record.id);
    final isLatest = index == 0;
    return AppCard(
      margin: AppSpacing.onlyHorizontalLG.add(AppSpacing.onlyBottomSM),
      onTap: () => _openDetail(record),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            value: selected,
            onChanged: (_) => _toggleSelect(record),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'v${record.versionName.isEmpty ? '?' : record.versionName}',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      formatTime(record.createdAt),
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    if (isLatest) ...[
                      const SizedBox(width: AppSpacing.sm),
                      const SnapshotTag(text: '最新', emphasized: true),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '规则命中 ${summary.ruleHits} · 组件 ${summary.components} · '
                  '原生库 ${summary.nativeLibs} · 权限 ${summary.permissions} · '
                  'DEX ${summary.dexFiles}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  children: [
                    SnapshotTag(text: formatBytes(summary.apkSize)),
                    if (summary.deepLinks > 0)
                      SnapshotTag(text: '深链 ${summary.deepLinks}'),
                    if (summary.classCount > 0)
                      SnapshotTag(text: '类 ${summary.classCount}'),
                    for (final f in summary.featureLabels) SnapshotTag(text: f),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              if (value == 'detail') _openDetail(record);
              if (value == 'compare') {
                setState(() => _selected.add(record.id!));
                _openCompare();
              }
              if (value == 'delete') _delete(record);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'detail', child: Text('查看详情')),
              PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }
}

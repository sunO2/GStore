import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/perf/perf_auto_export_settings.dart';
import 'package:gstore/core/perf/perf_export_service.dart';
import 'package:gstore/core/perf/perf_report.dart';
import 'package:gstore/core/perf/perf_report_store.dart';

import 'logic.dart';
import 'perf_common.dart';
import 'state.dart';

/// 性能报告页（Riverpod）。
///
/// 导出当前报告的入口（AppBar 右上角 `perf_export`）、自动导出配置卡与最近报告
/// 列表。自动导出服务的 start/stop 由 [perfAutoExportServiceProvider] 统一驱动
/// （见 `logic.dart`），本页只负责配置与展示，不再依赖自身挂载来启停服务。
///
/// 全部颜色 / 文字走 [Theme] 令牌，间距 / 圆角走设计令牌（AGENTS.md）。
class PerfReportsPage extends ConsumerWidget {
  const PerfReportsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('性能报告'),
        actions: [
          IconButton(
            key: const Key('perf_export'),
            icon: const Icon(TablerIcons.download, size: AppTypography.iconMD),
            tooltip: '导出报告',
            onPressed: () =>
                _exportPerfReport(context, ref, ref.read(perfMonitorProvider)),
          ),
        ],
      ),
      body: ListView(
        children: const [
          _AutoExportCard(),
          SizedBox(height: AppSpacing.md),
          _RecentReportsCard(),
          SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}

// ==================== 导出报告 ====================

/// 导出动作（分享 / 复制）。
enum _ReportAction { share, copy }

/// 导出当前性能报告：选择 JSON / CSV → 落盘 → 分享或复制。
Future<void> _exportPerfReport(
  BuildContext context,
  WidgetRef ref,
  PerfPageState state,
) async {
  final format = await AppSheet.showCustom<PerfReportFormat>(
    context: context,
    builder: (sheetContext) => AppSheetScaffold(
      title: '导出报告',
      subtitle: '选择导出格式',
      icon: const Icon(TablerIcons.download),
      content: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('perf_export_json'),
              leading: const Icon(TablerIcons.braces),
              title: const Text('JSON'),
              subtitle: const Text('结构化完整报告'),
              onTap: () => Navigator.of(sheetContext).pop(PerfReportFormat.json),
            ),
            const Divider(height: 1),
            ListTile(
              key: const Key('perf_export_csv'),
              leading: const Icon(TablerIcons.table),
              title: const Text('CSV'),
              subtitle: const Text('扁平指标表格'),
              onTap: () => Navigator.of(sheetContext).pop(PerfReportFormat.csv),
            ),
          ],
        ),
      ),
    ),
  );
  if (format == null || !context.mounted) return;

  final store = ref.read(perfReportStoreProvider);
  final target = await ref.read(perfTargetStoreProvider).load();
  final timestamp = DateTime.now();
  final stats = state.effectiveFrameStats;
  final content = format == PerfReportFormat.json
      ? const JsonEncoder.withIndent('  ').convert(
          buildPerfReportJson(
            timestamp: timestamp,
            cpu: state.cpu,
            memory: state.memory,
            battery: state.battery,
            thermal: state.thermal,
            gpu: state.gpu,
            network: state.network,
            frameStats: stats,
            targetLabel: target?.label,
          ),
        )
      : buildPerfReportCsv(
          timestamp: timestamp,
          cpu: state.cpu,
          memory: state.memory,
          battery: state.battery,
          thermal: state.thermal,
          gpu: state.gpu,
          network: state.network,
          frameStats: stats,
          targetLabel: target?.label,
        );
  if (!context.mounted) return;

  final SavedPerfReport saved;
  try {
    saved = await store.saveReport(
      format: format,
      content: content,
      timestamp: timestamp,
    );
  } catch (error) {
    debugPrint('[PerfMonitor] 保存报告失败: $error');
    if (context.mounted) AppDialogs.showError('保存报告失败，请检查存储权限');
    return;
  }
  if (!context.mounted) return;

  final action = await AppSheet.showCustom<_ReportAction>(
    context: context,
    builder: (sheetContext) => AppSheetScaffold(
      title: '报告已保存',
      subtitle: saved.fileName,
      icon: const Icon(TablerIcons.circle_check),
      content: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('perf_export_share'),
              leading: const Icon(TablerIcons.share),
              title: const Text('分享'),
              onTap: () => Navigator.of(sheetContext).pop(_ReportAction.share),
            ),
            const Divider(height: 1),
            ListTile(
              key: const Key('perf_export_copy'),
              leading: const Icon(TablerIcons.copy),
              title: const Text('复制'),
              onTap: () => Navigator.of(sheetContext).pop(_ReportAction.copy),
            ),
          ],
        ),
      ),
    ),
  );
  if (action == null || !context.mounted) return;

  switch (action) {
    case _ReportAction.copy:
      try {
        await Clipboard.setData(ClipboardData(text: content));
      } catch (error) {
        debugPrint('[PerfMonitor] 复制报告失败: $error');
      }
      if (context.mounted) AppDialogs.showSuccess('报告已复制到剪贴板');
    case _ReportAction.share:
      final ok = await PerfExportService.instance.shareReport(
        path: saved.path,
        content: content,
        mimeType: format.mimeType,
        title: '分享性能报告',
      );
      if (!context.mounted) return;
      if (ok) {
        AppDialogs.showSuccess('已打开分享面板');
      } else {
        AppDialogs.showInfo('已保存到 ${saved.path}');
      }
  }
}

// ==================== 自动导出 ====================

/// 自动导出配置行（图标 + 标题 + 当前值 + 可点编辑）。
class _AutoExportRow extends StatelessWidget {
  const _AutoExportRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      enabled: enabled,
      leading: Icon(
        icon,
        size: AppTypography.iconMD,
        color: enabled ? scheme.primary : scheme.onSurfaceVariant,
      ),
      title: Text(title, style: theme.textTheme.bodyMedium),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Icon(
            TablerIcons.chevron_right,
            size: AppTypography.iconSM,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
      onTap: enabled ? onTap : null,
    );
  }
}

/// 自动导出配置卡：开关 + 间隔 + 格式 + 保留份数。
///
/// **仅配置 UI + 状态展示**：[PerfAutoExportService] 的 start/stop 由
/// [perfAutoExportServiceProvider]（见 `logic.dart`）统一驱动，本卡不再启停服务，
/// 以免「概览页开采样、报告页未挂载」时出现静默回归。此处仍保留对服务与
/// 监控状态的 watch，用于显示当前是否运行。
class _AutoExportCard extends ConsumerStatefulWidget {
  const _AutoExportCard();

  @override
  ConsumerState<_AutoExportCard> createState() => _AutoExportCardState();
}

class _AutoExportCardState extends ConsumerState<_AutoExportCard> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 保持服务存活；start/stop 由 perfAutoExportServiceProvider 统一驱动。
    ref.watch(perfAutoExportServiceProvider);
    final settings = ref.watch(perfAutoExportSettingsProvider);
    final perfState = ref.watch(perfMonitorProvider);
    final pageActive = perfState.live || perfState.sampling;
    final shouldRun = pageActive && settings.enabled;

    final status = !settings.enabled
        ? '关闭（默认）'
        : shouldRun
            ? '运行中 · 每 ${settings.intervalMinutes} 分钟导出'
            : '已开启 · 需「实时刷新」或「后台采样」运行时生效';
    return Card(
      margin: AppSpacing.allLG,
      child: Column(
        children: [
          SwitchListTile(
            key: const Key('perf_auto_export_switch'),
            secondary: Icon(
              TablerIcons.calendar_stats,
              size: AppTypography.iconMD,
              color: scheme.primary,
            ),
            title: const Text('自动导出'),
            subtitle: Text(status),
            value: settings.enabled,
            onChanged: (value) => _save(settings.copyWith(enabled: value)),
          ),
          const Divider(height: AppSpacing.md),
          _AutoExportRow(
            key: const Key('perf_auto_export_interval'),
            icon: TablerIcons.clock,
            title: '导出间隔',
            value: '每 ${settings.intervalMinutes} 分钟',
            enabled: settings.enabled,
            onTap: () => _editInterval(settings),
          ),
          _AutoExportRow(
            key: const Key('perf_auto_export_format'),
            icon: TablerIcons.file_description,
            title: '导出格式',
            value: settings.format.label,
            enabled: settings.enabled,
            onTap: () => _editFormat(settings),
          ),
          _AutoExportRow(
            key: const Key('perf_auto_export_keep'),
            icon: TablerIcons.stack,
            title: '保留份数',
            value: '最近 ${settings.maxKeep} 份',
            enabled: settings.enabled,
            onTap: () => _editKeep(settings),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '自动导出仅在「实时刷新」或「后台采样」运行时按间隔执行；'
                '超出保留份数的最旧报告会被自动删除。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save(PerfAutoExportSettings settings) =>
      ref.read(perfAutoExportSettingsProvider.notifier).save(settings);

  Future<void> _editInterval(PerfAutoExportSettings settings) async {
    final minutes = await AppSheet.showCustom<int>(
      context: context,
      builder: (sheetContext) => _AutoExportIntSheet(
        title: '导出间隔',
        subtitle: '自动导出的时间间隔（分钟，最小 1）',
        initial: settings.intervalMinutes,
        minValue: kPerfAutoExportMinIntervalMinutes,
        suffix: '分钟',
        keyPrefix: 'perf_auto_export_interval',
      ),
    );
    if (minutes == null || !mounted) return;
    await _save(settings.copyWith(intervalMinutes: minutes));
  }

  Future<void> _editKeep(PerfAutoExportSettings settings) async {
    final keep = await AppSheet.showCustom<int>(
      context: context,
      builder: (sheetContext) => _AutoExportIntSheet(
        title: '保留份数',
        subtitle: '保留最近 N 份报告（最小 1，超出删除最旧）',
        initial: settings.maxKeep,
        minValue: kPerfAutoExportMinMaxKeep,
        suffix: '份',
        keyPrefix: 'perf_auto_export_keep',
      ),
    );
    if (keep == null || !mounted) return;
    await _save(settings.copyWith(maxKeep: keep));
  }

  Future<void> _editFormat(PerfAutoExportSettings settings) async {
    final selected = await AppSheet.showCustom<PerfAutoExportFormat>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '导出格式',
        subtitle: '选择自动导出的文件格式',
        icon: const Icon(TablerIcons.file_description),
        content: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < PerfAutoExportFormat.values.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  key: Key(
                    'perf_auto_export_format_'
                    '${PerfAutoExportFormat.values[i].value}',
                  ),
                  title: Text(PerfAutoExportFormat.values[i].label),
                  trailing: settings.format == PerfAutoExportFormat.values[i]
                      ? Icon(
                          TablerIcons.check,
                          color: Theme.of(sheetContext).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.of(sheetContext)
                      .pop(PerfAutoExportFormat.values[i]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    await _save(settings.copyWith(format: selected));
  }
}

/// 整数编辑弹层（间隔 / 保留份数共用）：保存 `pop(int)`，取消 `pop(null)`。
class _AutoExportIntSheet extends StatefulWidget {
  const _AutoExportIntSheet({
    required this.title,
    required this.subtitle,
    required this.initial,
    required this.minValue,
    required this.suffix,
    required this.keyPrefix,
  });

  final String title;
  final String subtitle;
  final int initial;
  final int minValue;
  final String suffix;
  final String keyPrefix;

  @override
  State<_AutoExportIntSheet> createState() => _AutoExportIntSheetState();
}

class _AutoExportIntSheetState extends State<_AutoExportIntSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null || value < widget.minValue) {
      AppDialogs.showError('请输入不小于 ${widget.minValue} 的整数');
      return;
    }
    Navigator.of(context).pop<int>(value);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: widget.title,
      subtitle: widget.subtitle,
      content: TextField(
        key: Key('${widget.keyPrefix}_input'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(suffixText: widget.suffix, isDense: true),
      ),
      actions: [
        TextButton(
          key: Key('${widget.keyPrefix}_cancel'),
          onPressed: () => Navigator.of(context).pop<int>(null),
          child: const Text('取消'),
        ),
        FilledButton(
          key: Key('${widget.keyPrefix}_save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

// ==================== 最近报告 ====================

/// 最近报告条目（报告元信息 + 近似字节大小）。
class _ReportEntry {
  const _ReportEntry(this.report, this.sizeBytes);

  final SavedPerfReport report;
  final int sizeBytes;
}

/// 报告条目操作。
enum _RecentReportAction { view, share, copy }

/// 最近报告列表卡：列出已保存报告（时间 + 文件名 + 大小），支持查看 / 分享 /
/// 复制 / 删除（滑动或菜单）与「全部清除」。
class _RecentReportsCard extends ConsumerStatefulWidget {
  const _RecentReportsCard();

  @override
  ConsumerState<_RecentReportsCard> createState() => _RecentReportsCardState();
}

class _RecentReportsCardState extends ConsumerState<_RecentReportsCard> {
  List<_ReportEntry> _entries = const <_ReportEntry>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(perfReportStoreProvider);
    var entries = const <_ReportEntry>[];
    try {
      final reports = await store.listReports();
      final built = <_ReportEntry>[];
      for (final report in reports) {
        final content = await store.readReport(report.path);
        built.add(
          _ReportEntry(report, content == null ? 0 : utf8.encode(content).length),
        );
      }
      entries = built;
    } catch (error) {
      debugPrint('[PerfMonitor] 读取最近报告失败: $error');
    }
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: AppSpacing.allLG,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  TablerIcons.history,
                  size: AppTypography.iconMD,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '最近报告',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
                  ),
                ),
                if (_entries.isNotEmpty)
                  TextButton(
                    key: const Key('perf_reports_clear_all'),
                    onPressed: _clearAll,
                    child: const Text('全部清除'),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (_loading)
              const Row(
                children: [
                  AppLoading(size: AppLoadingSize.small),
                  SizedBox(width: AppSpacing.md),
                  Expanded(child: Text('读取中…')),
                ],
              )
            else if (_entries.isEmpty)
              Text(
                '暂无报告（开启自动导出或点击右上角「导出报告」后在此查看）',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else
              Column(
                children: [
                  for (final entry in _entries) _reportTile(context, entry),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _reportTile(BuildContext context, _ReportEntry entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final report = entry.report;
    final ts = report.timestamp.millisecondsSinceEpoch;
    return Dismissible(
      key: ValueKey<String>('perf_report_dismiss_$ts'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: AppSpacing.onlyHorizontalLG,
        color: scheme.errorContainer,
        child: Icon(
          TablerIcons.trash,
          size: AppTypography.iconMD,
          color: scheme.onErrorContainer,
        ),
      ),
      confirmDismiss: (_) => _confirmDelete(report),
      onDismissed: (_) => _delete(report),
      child: ListTile(
        key: Key('perf_report_$ts'),
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          report.format == PerfReportFormat.json
              ? TablerIcons.braces
              : TablerIcons.table,
          size: AppTypography.iconMD,
          color: scheme.primary,
        ),
        title: Text(
          _formatReportTime(report.timestamp),
          style: theme.textTheme.bodyMedium,
        ),
        subtitle: Text(
          '${report.fileName} · ${perfBytesHuman(entry.sizeBytes.toDouble())}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        onTap: () => _openActions(report),
        trailing: PopupMenuButton<String>(
          key: Key('perf_report_menu_$ts'),
          onSelected: (value) {
            switch (value) {
              case 'view':
                _openActions(report);
              case 'delete':
                _deleteWithConfirm(report);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem<String>(value: 'view', child: Text('查看 / 分享')),
            PopupMenuItem<String>(value: 'delete', child: Text('删除')),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(SavedPerfReport report) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除报告？',
      message: '将删除 ${report.fileName}，此操作无法撤销。',
      confirmText: '删除',
      isDangerous: true,
    );
    return ok ?? false;
  }

  Future<void> _deleteWithConfirm(SavedPerfReport report) async {
    if (await _confirmDelete(report)) await _delete(report);
  }

  Future<void> _delete(SavedPerfReport report) async {
    final ok = await ref.read(perfReportStoreProvider).deleteReport(report.path);
    if (!mounted) return;
    if (ok) {
      AppDialogs.showInfo('已删除报告');
    } else {
      AppDialogs.showError('删除报告失败');
    }
    await _load();
  }

  Future<void> _clearAll() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清除全部报告？',
      message: '将删除最近报告中的全部文件，此操作无法撤销。',
      confirmText: '全部清除',
      isDangerous: true,
    );
    if (ok != true || !mounted) return;
    final store = ref.read(perfReportStoreProvider);
    for (final entry in _entries) {
      await store.deleteReport(entry.report.path);
    }
    if (!mounted) return;
    AppDialogs.showInfo('已清除全部报告');
    await _load();
  }

  Future<void> _openActions(SavedPerfReport report) async {
    final action = await AppSheet.showCustom<_RecentReportAction>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '报告操作',
        subtitle: report.fileName,
        icon: const Icon(TablerIcons.file_description),
        content: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                key: const Key('perf_report_view'),
                leading: const Icon(TablerIcons.eye),
                title: const Text('查看'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_RecentReportAction.view),
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('perf_report_share'),
                leading: const Icon(TablerIcons.share),
                title: const Text('分享'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_RecentReportAction.share),
              ),
              const Divider(height: 1),
              ListTile(
                key: const Key('perf_report_copy'),
                leading: const Icon(TablerIcons.copy),
                title: const Text('复制'),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_RecentReportAction.copy),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    final store = ref.read(perfReportStoreProvider);
    final content = await store.readReport(report.path);
    if (!mounted) return;
    if (content == null) {
      AppDialogs.showError('报告已不存在');
      await _load();
      return;
    }
    switch (action) {
      case _RecentReportAction.view:
        await _showContent(report, content);
      case _RecentReportAction.copy:
        try {
          await Clipboard.setData(ClipboardData(text: content));
        } catch (error) {
          debugPrint('[PerfMonitor] 复制报告失败: $error');
        }
        if (mounted) AppDialogs.showSuccess('报告已复制到剪贴板');
      case _RecentReportAction.share:
        final ok = await PerfExportService.instance.shareReport(
          path: report.path,
          content: content,
          mimeType: report.format.mimeType,
          title: '分享性能报告',
        );
        if (!mounted) return;
        if (ok) {
          AppDialogs.showSuccess('已打开分享面板');
        } else {
          AppDialogs.showInfo('已保存到 ${report.path}');
        }
    }
  }

  Future<void> _showContent(SavedPerfReport report, String content) {
    return AppSheet.showCustom<void>(
      context: context,
      builder: (sheetContext) => AppSheetScaffold(
        title: '报告内容',
        subtitle: '${report.fileName} · ${report.format.extension.toUpperCase()}',
        icon: const Icon(TablerIcons.file_description),
        content: Material(
          type: MaterialType.transparency,
          child: SelectableText(
            content,
            style: Theme.of(sheetContext).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

/// 时间 → `yyyy-MM-dd HH:mm:ss`（本地时区，零依赖）。
String _formatReportTime(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

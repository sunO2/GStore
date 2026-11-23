import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/agent_trace_store.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/module/module_manager.dart';

/// 回合记录页（P3-1 可观测性）
///
/// 展示最近若干回合的状态/耗时/token/工具计数；点开可看完整 trace JSON
/// （工具调用、错误原文），便于定位"为什么这轮变慢/失败"。
class AgentTracesPage extends StatefulWidget {
  const AgentTracesPage({super.key});

  @override
  State<AgentTracesPage> createState() => _AgentTracesPageState();
}

class _AgentTracesPageState extends State<AgentTracesPage> {
  AgentTraceStore? _store;
  List<AgentTurnRecord> _records = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final agent = ModuleManager.instance.get<AgentService>();
    final store = agent?.traceStore ?? await AgentTraceStore.load();
    final records = await store.recent(limit: 50);
    if (!mounted) return;
    setState(() {
      _store = store;
      _records = records;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清除回合记录',
      message: '确定清除全部回合记录？该操作只影响诊断数据。',
      isDangerous: true,
    );
    if (ok != true) return;
    await _store?.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('回合记录'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(TablerIcons.refresh),
          ),
          IconButton(
            tooltip: '清除',
            onPressed: _loading ? null : _clear,
            icon: const Icon(TablerIcons.trash),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: AppLoading())
          : _records.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(TablerIcons.activity,
                          size: 48, color: scheme.outline),
                      const SizedBox(height: AppSpacing.md),
                      Text('还没有回合记录',
                          style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '发一条消息后，这里会记录耗时、token 与工具调用。',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: AppSpacing.allLG,
                  itemCount: _records.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) =>
                      _TraceTile(record: _records[index]),
                ),
    );
  }
}

class _TraceTile extends StatelessWidget {
  const _TraceTile({required this.record});

  final AgentTurnRecord record;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = _statusStyle(context, record);
    final time = DateTime.fromMillisecondsSinceEpoch(record.createdAt);
    final latency = record.firstTokenMs == null
        ? '${record.totalMs}ms'
        : '首字 ${record.firstTokenMs}ms · 总 ${record.totalMs}ms';

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () => _showDetail(context),
          child: Padding(
            padding: AppSpacing.allMD,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: status.background,
                        borderRadius: BorderRadius.circular(AppRadius.xs),
                      ),
                      child: Text(
                        status.label,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(color: status.foreground),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        record.model ?? record.provider ?? '-',
                        style: Theme.of(context).textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _formatTime(time),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  latency,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '${record.modelSteps} 步 · 工具 ${record.toolRequests}'
                  '${record.toolErrors > 0 ? '（失败 ${record.toolErrors}）' : ''}'
                  ' · 提示 ${record.promptChars} 字'
                  '${record.totalTokensOrDash}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                if (record.error != null && record.error!.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    record.error!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.error,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showDetail(BuildContext context) async {
    final pretty = const JsonEncoder.withIndent('  ').convert({
      ...record.toJson(),
      'detail': record.parsedDetail,
    });
    await AppDialogs.showContentSheet(
      title: '回合详情',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            pretty,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
          ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: pretty));
                if (context.mounted) {
                  AppDialogs.showSuccess('已复制回合详情');
                }
              },
              icon: const Icon(TablerIcons.copy),
              label: const Text('复制'),
            ),
          ),
        ],
      ),
    );
  }

  static _StatusStyle _statusStyle(BuildContext context, AgentTurnRecord r) {
    final scheme = Theme.of(context).colorScheme;
    if (r.isError) {
      return _StatusStyle(
        label: '失败',
        background: scheme.errorContainer,
        foreground: scheme.onErrorContainer,
      );
    }
    if (r.isCancelled) {
      return _StatusStyle(
        label: '已停止',
        background: scheme.secondaryContainer,
        foreground: scheme.onSecondaryContainer,
      );
    }
    return _StatusStyle(
      label: '正常',
      background: scheme.primaryContainer,
      foreground: scheme.onPrimaryContainer,
    );
  }

  static String _formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

class _StatusStyle {
  const _StatusStyle({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;
}

extension on AgentTurnRecord {
  String get totalTokensOrDash {
    final tokens = (inputTokens ?? 0) + (outputTokens ?? 0);
    return tokens > 0 ? ' · ${tokens} tokens' : '';
  }
}

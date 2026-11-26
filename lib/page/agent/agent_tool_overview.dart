import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/agent/agent_tool_spec.dart';
import 'package:gstore/core/design/design_tokens.dart';

/// 工具子页面底部：列出当前模型可用的全部工具与说明。
///
/// 数据来自 [AgentToolCatalog.enabled]（内置工具 + 运行时注册的 MCP 工具），
/// 与真正下发给模型的工具目录保持同一来源，避免两处描述漂移。
class AgentToolOverview extends StatefulWidget {
  const AgentToolOverview({super.key});

  static const Key sectionKey = Key('agent-tool-overview');

  @override
  State<AgentToolOverview> createState() => _AgentToolOverviewState();
}

class _AgentToolOverviewState extends State<AgentToolOverview> {
  void _refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tools = AgentToolCatalog.enabled;
    final grouped = <String, List<AgentToolSpec>>{};
    for (final tool in tools) {
      grouped.putIfAbsent(tool.group, () => <AgentToolSpec>[]).add(tool);
    }
    final groups = <String>[
      for (final group in AgentToolGroup.order)
        if (grouped.containsKey(group)) group,
      ...grouped.keys.where((g) => !AgentToolGroup.order.contains(g)),
    ];

    return Card(
      key: AgentToolOverview.sectionKey,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  child: Icon(
                    TablerIcons.tool,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '当前模型工具',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: AppTypography.weightSemiBold,
                        ),
                      ),
                      Text(
                        '每轮会按需要从这些工具中动态选择',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: AppSpacing.horizontalSM_verticalXS,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    '${tools.length} 个',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '刷新工具列表',
                  onPressed: _refresh,
                  icon: const Icon(TablerIcons.refresh),
                ),
              ],
            ),
            if (tools.isEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                '当前没有可用工具。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ] else
              for (final group in groups) ...[
                const SizedBox(height: AppSpacing.md),
                _GroupHeader(
                  group: group,
                  count: grouped[group]!.length,
                ),
                const SizedBox(height: AppSpacing.xs),
                for (var i = 0; i < grouped[group]!.length; i++) ...[
                  _ToolRow(tool: grouped[group]![i]),
                  if (i != grouped[group]!.length - 1)
                    Divider(
                      height: AppSpacing.md,
                      color: scheme.outlineVariant.withValues(alpha: 0.4),
                    ),
                ],
              ],
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group, required this.count});

  final String group;
  final int count;

  static IconData _iconFor(String group) => switch (group) {
        AgentToolGroup.discover => TablerIcons.search,
        AgentToolGroup.web => TablerIcons.world,
        AgentToolGroup.api => TablerIcons.api,
        AgentToolGroup.acquire => TablerIcons.download,
        AgentToolGroup.manage => TablerIcons.settings,
        AgentToolGroup.files => TablerIcons.folder,
        AgentToolGroup.snapshot => TablerIcons.history,
        AgentToolGroup.interact => TablerIcons.adjustments,
        AgentToolGroup.mcp => TablerIcons.plug_connected,
        AgentToolGroup.meta => TablerIcons.sparkles,
        _ => TablerIcons.tool,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      children: [
        Icon(
          _iconFor(group),
          size: AppTypography.iconSM,
          color: scheme.primary,
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          group,
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.primary,
            fontWeight: AppTypography.weightSemiBold,
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          '$count',
          style: theme.textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.tool});

  final AgentToolSpec tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                tool.name,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
              Text(
                tool.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (tool.mcp) _Badge(text: 'MCP', scheme: scheme),
              if (tool.meta) _Badge(text: '元能力', scheme: scheme),
              if (tool.readOnly) _Badge(text: '只读', scheme: scheme),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            tool.brief,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.scheme});

  final String text;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
      ),
    );
  }
}

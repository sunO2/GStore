import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';

import 'slash_commands.dart';

/// 输入框上方的斜杠命令联想面板。
class AgentSlashCommandPalette extends StatelessWidget {
  const AgentSlashCommandPalette({
    super.key,
    required this.commands,
    required this.onSelected,
    this.maxHeight = 300,
  });

  final List<AgentSlashCommand> commands;
  final ValueChanged<AgentSlashCommand> onSelected;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppBottomCapsule.horizontalMargin,
        0,
        AppBottomCapsule.horizontalMargin,
        AppSpacing.sm,
      ),
      child: Material(
        color: scheme.surfaceContainerHigh,
        elevation: 4,
        borderRadius: AppRadius.allLG,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.xs,
                ),
                child: Row(
                  children: [
                    Icon(
                      TablerIcons.terminal_2,
                      size: AppTypography.iconSM,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '快捷指令',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '输入 / 过滤',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              if (commands.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    '没有匹配的命令',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    primary: false,
                    padding: EdgeInsets.zero,
                    itemCount: commands.length,
                    itemBuilder: (context, index) {
                      final command = commands[index];
                      return ListTile(
                        key: ValueKey('agent-slash-${command.id}'),
                        dense: true,
                        leading: Icon(
                          command.icon,
                          size: AppTypography.iconMD,
                          color: scheme.primary,
                        ),
                        title: Row(
                          children: [
                            Text(
                              command.command,
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                command.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        subtitle: Text(
                          command.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        onTap: () => onSelected(command),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

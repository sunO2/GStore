import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/router/app_router.dart';

/// 弹出当前模型列表，供 `/model` 指令直接切换模型。
///
/// 与「模型管理」不同：这里只做快速选择，选中后立即生效并关闭弹层，
/// 不跳转页面。需要新增/编辑模型时仍从右上角「设置」进入。
Future<AgentModel?> showAgentModelPicker(BuildContext context) async {
  final store = await AgentModelStore.load();
  if (!context.mounted) return null;
  return AppSheet.showCustom<AgentModel>(
    context: context,
    builder: (_) => _AgentModelPickerSheet(store: store),
  );
}

class _AgentModelPickerSheet extends StatefulWidget {
  const _AgentModelPickerSheet({required this.store});

  final AgentModelStore store;

  @override
  State<_AgentModelPickerSheet> createState() => _AgentModelPickerSheetState();
}

class _AgentModelPickerSheetState extends State<_AgentModelPickerSheet> {
  bool _saving = false;

  Future<void> _select(AgentModel model) async {
    if (_saving) return;
    setState(() => _saving = true);
    await widget.store.select(model.id);
    if (!mounted) return;
    Navigator.of(context).pop(model);
  }

  void _openSettings() {
    Navigator.of(context).pop();
    appRouter.push(AppRoute.agentSettings);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final store = widget.store;
        return AppSheetScaffold(
          title: '切换模型',
          subtitle:
              store.models.isEmpty ? null : '当前共 ${store.models.length} 个模型',
          icon: const Icon(TablerIcons.brain),
          contentPadding: AppSpacing.onlyHorizontalSM,
          content: store.models.isEmpty
              ? _buildEmpty(context)
              : Material(
                  type: MaterialType.transparency,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < store.models.length; i++) ...[
                        _buildModelTile(context, store.models[i], store),
                        if (i != store.models.length - 1)
                          const Divider(height: 1),
                      ],
                    ],
                  ),
                ),
        );
      },
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            TablerIcons.brain,
            size: AppTypography.iconXXXL,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.md),
          Text('还没有配置模型', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '先到设置中添加一个模型，再回来切换。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          FilledButton.tonalIcon(
            onPressed: _openSettings,
            icon: const Icon(TablerIcons.settings),
            label: const Text('去设置添加模型'),
          ),
        ],
      ),
    );
  }

  Widget _buildModelTile(
    BuildContext context,
    AgentModel model,
    AgentModelStore store,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = store.selectedId == model.id;
    final providerLabel =
        model.provider == AgentLlmProvider.google ? 'Gemini' : 'OpenAI 兼容';

    return ListTile(
      enabled: !_saving,
      onTap: () => _select(model),
      leading: CircleAvatar(
        backgroundColor: selected ? scheme.primary : scheme.primaryContainer,
        child: Icon(
          model.provider == AgentLlmProvider.google
              ? TablerIcons.sparkles
              : TablerIcons.cloud,
          color: selected ? scheme.onPrimary : scheme.onPrimaryContainer,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              model.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: AppTypography.weightSemiBold,
              ),
            ),
          ),
          if (selected)
            Container(
              padding: AppSpacing.horizontalXS_verticalXS,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                '使用中',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onPrimary,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        '${model.effectiveModel} · $providerLabel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: selected
          ? Icon(TablerIcons.circle_check_filled, color: scheme.primary)
          : const Icon(TablerIcons.chevron_right),
    );
  }
}

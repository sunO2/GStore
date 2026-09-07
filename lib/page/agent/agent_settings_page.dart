import 'package:flutter/material.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/core.dart';

/// Agent 模型管理设置页
/// 支持：添加多个模型、选择使用哪个、编辑、删除
class AgentSettingsPage extends StatefulWidget {
  const AgentSettingsPage({super.key});

  @override
  State<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends State<AgentSettingsPage> {
  AgentModelStore? _store;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await AgentModelStore.load();
    if (mounted) {
      setState(() {
        _store = store;
        _loading = false;
      });
    }
  }

  /// 选择模型并立即生效（AgentService 监听配置变化后自动重配）
  Future<void> _selectModel(AgentModel model) async {
    await _store!.select(model.id);
    if (mounted) setState(() {});
  }

  /// 重新初始化 Agent 服务
  Future<void> _reconfigureService() async {
    final service = ModuleManager.instance.get<AgentService>();
    if (service == null) {
      // Agent 模块未启用：跳过重配（页面已显示未启用文案）
      return;
    }
    try {
      await service.reconfigure();
    } catch (e) {
      appLog.error('AgentSettings: reconfigure 失败 - $e');
    }
  }

  /// 打开添加/编辑对话框
  Future<void> _openModelDialog([AgentModel? existing]) async {
    final result = await showModalBottomSheet<AgentModel>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ModelEditSheet(
        store: _store!,
        existing: existing,
      ),
    );

    if (result != null && mounted) {
      await _reconfigureService();
      setState(() {});
    }
  }

  /// 删除模型
  Future<void> _deleteModel(AgentModel model) async {
    await _store!.remove(model.id);
    await _reconfigureService();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('模型管理'),
      ),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openModelDialog(),
              icon: const Icon(Icons.add),
              label: const Text('添加模型'),
            ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }

    // Agent 模块未启用：模型选择区显示未启用文案（禁用编辑）
    if (ModuleManager.instance.get<AgentService>() == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: AppTypography.iconXXXL,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Agent 模块未启用',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '请在模块管理中启用 Agent 助手后配置模型',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
    }

    final store = _store!;

    if (store.models.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.model_training,
              size: AppTypography.iconXXXL,
              color: AppColors.grey400,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('还没有配置模型', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '点击右下角"添加模型"按钮开始配置',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: AppSpacing.allLG,
      children: [
        // 使用提示
        Padding(
          padding: AppSpacing.onlyBottomMD,
          child: Text(
            '选择要使用的模型，当前共 ${store.models.length} 个',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
        ),

        // 模型列表
        ...store.models.map((model) {
          final isSelected = store.selectedId == model.id;
          return _buildModelTile(context, model, isSelected);
        }),

        const SizedBox(height: AppSpacing.xl),

        // 清除全部
        TextButton.icon(
          onPressed: () async {
            await _store!.clearAll();
            await _reconfigureService();
            if (mounted) setState(() {});
          },
          icon: const Icon(Icons.delete_sweep_outlined),
          label: const Text('清除所有模型'),
          style: TextButton.styleFrom(foregroundColor: AppColors.error),
        ),
      ],
    );
  }

  Widget _buildModelTile(
      BuildContext context, AgentModel model, bool isSelected) {
    final providerLabel = model.provider == AgentLlmProvider.google
        ? 'Gemini'
        : 'OpenAI 兼容';

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5),
          width: isSelected ? 2 : 1,
        ),
      ),
      margin: EdgeInsets.only(bottom: AppSpacing.md),
      child: ListTile(
        onTap: () => _selectModel(model),
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Icon(
            model.provider == AgentLlmProvider.google
                ? Icons.auto_awesome
                : Icons.cloud_outlined,
            size: AppTypography.iconMD,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                model.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: AppTypography.weightSemiBold,
                    ),
              ),
            ),
            if (isSelected)
              Container(
                padding: AppSpacing.horizontalXS_verticalXS,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  '使用中',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimary,
                      ),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${model.effectiveModel} · $providerLabel',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (model.provider == AgentLlmProvider.openai &&
                model.baseUrl.isNotEmpty)
              Text(
                model.baseUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.textSecondary,
                    ),
              ),
          ],
        ),
        isThreeLine: model.provider == AgentLlmProvider.openai &&
            model.baseUrl.isNotEmpty,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: AppTypography.iconSM),
              tooltip: '编辑',
              onPressed: () => _openModelDialog(model),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: AppTypography.iconSM),
              tooltip: '删除',
              onPressed: () => _deleteModel(model),
            ),
          ],
        ),
      ),
    );
  }
}

/// 添加/编辑模型的底部弹出表单
class _ModelEditSheet extends StatefulWidget {
  final AgentModelStore store;
  final AgentModel? existing;

  const _ModelEditSheet({required this.store, this.existing});

  @override
  State<_ModelEditSheet> createState() => _ModelEditSheetState();
}

class _ModelEditSheetState extends State<_ModelEditSheet> {
  late AgentLlmProvider _provider;
  late final TextEditingController _nameController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  late final TextEditingController _baseUrlController;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _provider = existing?.provider ?? AgentLlmProvider.openai;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _apiKeyController = TextEditingController(text: existing?.apiKey ?? '');
    _modelController = TextEditingController(text: existing?.model ?? '');
    _baseUrlController = TextEditingController(text: existing?.baseUrl ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  /// 切换 provider 时更新默认提示
  String get _modelHint {
    return _provider == AgentLlmProvider.google
        ? 'gemini-2.0-flash'
        : 'gpt-4o-mini';
  }

  String get _baseUrlHint {
    return _provider == AgentLlmProvider.google
        ? 'Gemini 官方接口（留空）'
        : 'https://api.openai.com/v1';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.existing == null ? '添加模型' : '编辑模型',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: AppTypography.weightSemiBold,
                  ),
            ),
            const SizedBox(height: AppSpacing.lg),

            // 服务商
            Text('服务商', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.sm),
            SegmentedButton<AgentLlmProvider>(
              segments: const [
                ButtonSegment(
                  value: AgentLlmProvider.google,
                  label: Text('Google Gemini'),
                  icon: Icon(Icons.auto_awesome),
                ),
                ButtonSegment(
                  value: AgentLlmProvider.openai,
                  label: Text('OpenAI 兼容'),
                  icon: Icon(Icons.cloud_outlined),
                ),
              ],
              selected: {_provider},
              onSelectionChanged: (selection) {
                setState(() => _provider = selection.first);
              },
            ),
            const SizedBox(height: AppSpacing.lg),

            // 显示名称（可选）
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '显示名称（可选）',
                hintText: '例如：Gemini Flash / DeepSeek',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // API Key
            TextField(
              controller: _apiKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Key',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.key),
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // 模型名称
            TextField(
              controller: _modelController,
              decoration: InputDecoration(
                labelText: '模型名称',
                hintText: _modelHint,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.model_training),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),

            // OpenAI 常用模型快捷选择
            if (_provider == AgentLlmProvider.openai)
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  'gpt-4o-mini',
                  'gpt-4o',
                  'deepseek-chat',
                  'qwen-plus',
                  'glm-4-flash',
                ].map((m) {
                  return ActionChip(
                    label: Text(m),
                    onPressed: () {
                      setState(() => _modelController.text = m);
                    },
                  );
                }).toList(),
              ),
            const SizedBox(height: AppSpacing.md),

            // Base URL
            TextField(
              controller: _baseUrlController,
              decoration: InputDecoration(
                labelText: 'Base URL',
                hintText: _baseUrlHint,
                helperText: _provider == AgentLlmProvider.openai
                    ? '填写 OpenAI 兼容服务的接口地址'
                    : null,
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.link),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // 保存按钮
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      AppDialogs.showError('请填写 API Key');
      return;
    }

    final existing = widget.existing;
    final model = AgentModel(
      id: existing?.id ?? generateModelId(),
      name: _nameController.text.trim(),
      provider: _provider,
      apiKey: apiKey,
      model: _modelController.text.trim(),
      baseUrl: _baseUrlController.text.trim(),
    );

    if (existing != null) {
      await widget.store.update(model);
    } else {
      await widget.store.add(model);
    }

    if (mounted) {
      Navigator.pop(context, model);
    }
  }
}

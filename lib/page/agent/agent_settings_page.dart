import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:gstore/core/agent/agent_model_store.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/openai_model_catalog.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';

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

  /// 本地推理模块是否可用（APK 内置或已下载）；不可用则不显示入口
  late final Future<bool> _llmAvailable =
      RustModuleLoader.instance.isAvailable('llm');

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
    final result = await ModelEditSheet.show(
      context,
      store: _store!,
      existing: existing,
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
        actions: [
          // 没有 llm 模块（既非内置也未下载）时不显示"本地模型"入口
          FutureBuilder<bool>(
            future: _llmAvailable,
            builder: (context, snap) {
              if (snap.data != true) return const SizedBox.shrink();
              return IconButton(
                tooltip: '本地模型',
                icon: const Icon(Icons.memory),
                onPressed: () => context.push(AppRoute.localLlm),
              );
            },
          ),
        ],
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
///
/// 走应用统一弹层骨架 [AppSheetScaffold]（拖拽条 + 标题 + 限高可滚动内容 +
/// 固定底部操作区），与「添加 F-Droid 源」等表单同一套设计；
/// 关闭用 `Navigator.pop(result)` 返回保存后的模型。
class ModelEditSheet extends StatefulWidget {
  final AgentModelStore store;
  final AgentModel? existing;

  /// 拉取模型列表的实现（默认走真实接口，测试可注入假实现）
  final Future<List<String>> Function({
    required String baseUrl,
    required String apiKey,
  })? fetchModels;

  const ModelEditSheet({
    super.key,
    required this.store,
    this.existing,
    this.fetchModels,
  });

  /// 弹出表单（统一底部弹层）；返回保存后的模型，取消返回 null
  static Future<AgentModel?> show(
    BuildContext context, {
    required AgentModelStore store,
    AgentModel? existing,
  }) {
    return AppSheet.showCustom<AgentModel>(
      context: context,
      builder: (_) => ModelEditSheet(store: store, existing: existing),
    );
  }

  @override
  State<ModelEditSheet> createState() => ModelEditSheetState();
}

class ModelEditSheetState extends State<ModelEditSheet> {
  late AgentLlmProvider _provider;
  late final TextEditingController _nameController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  late final TextEditingController _baseUrlController;
  late bool _toolsEnabled;
  late bool _showReasoning;

  /// 内置常用模型（接口不支持 /models 时的兜底预设）
  static const List<String> _presetModels = [
    'gpt-4o-mini',
    'gpt-4o',
    'deepseek-chat',
    'qwen-plus',
    'glm-4-flash',
  ];

  /// 正在拉取模型列表（按钮转圈并禁用，防连点）
  bool _loadingModels = false;

  /// 全部已缓存的模型列表（key = baseUrl，空串按默认地址归并）
  Map<String, List<String>> _catalogCache = {};

  /// 当前 Base URL 对应的可用模型；null 表示无缓存 → 显示内置预设
  List<String>? _fetchedModels;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _provider = existing?.provider ?? AgentLlmProvider.openai;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _apiKeyController = TextEditingController(text: existing?.apiKey ?? '');
    _modelController = TextEditingController(text: existing?.model ?? '');
    _baseUrlController = TextEditingController(text: existing?.baseUrl ?? '');
    _toolsEnabled = existing?.toolsEnabled ?? true;
    _showReasoning = existing?.showReasoning ?? true;
    // Base URL 改变后要换成该端点的缓存列表（否则会显示上一个端点的模型）
    _baseUrlController.addListener(_onBaseUrlChanged);
    _loadCachedModels();
  }

  @override
  void dispose() {
    _baseUrlController.removeListener(_onBaseUrlChanged);
    _nameController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  /// 载入已缓存的模型列表；下次打开表单可直接用缓存替换预设
  Future<void> _loadCachedModels() async {
    final cache = await loadModelCatalogCache();
    if (!mounted) return;
    setState(() {
      _catalogCache = cache;
      _applyCatalog();
    });
  }

  void _onBaseUrlChanged() {
    if (!mounted) return;
    setState(_applyCatalog);
  }

  /// 按当前 Base URL 选出要展示的模型列表（无缓存 → null，回落到内置预设）
  void _applyCatalog() {
    final cached = _catalogCache[modelCatalogKey(_baseUrlController.text.trim())];
    _fetchedModels = (cached == null || cached.isEmpty) ? null : cached;
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
    return AppSheetScaffold(
      title: widget.existing == null ? '添加模型' : '编辑模型',
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
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

          // Base URL（先填地址，再据此拉取/选择模型）
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
          const SizedBox(height: AppSpacing.md),

          // 模型名称（OpenAI 兼容：右侧刷新按钮拉取 /models 列表后选择）
          TextField(
            controller: _modelController,
            decoration: InputDecoration(
              labelText: '模型名称',
              hintText: _modelHint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.model_training),
              suffixIcon: _provider == AgentLlmProvider.openai
                  ? IconButton(
                      tooltip: '拉取可用模型列表',
                      onPressed: _loadingModels ? null : _refreshModels,
                      icon: _loadingModels
                          ? const AppLoading(size: AppLoadingSize.small)
                          : const Icon(Icons.sync),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),

          // 模型候选：拉取成功后整块替换为接口返回的列表，用户点选即回填；
          // 未拉取（或接口不支持 /models）时显示内置常用模型
          if (_provider == AgentLlmProvider.openai) ...[
            Text(
              _fetchedModels == null
                  ? '常用模型'
                  : '可用模型（接口返回 ${_fetchedModels!.length} 个）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                for (final m in _fetchedModels ?? _presetModels)
                  ActionChip(
                    label: Text(m),
                    onPressed: () {
                      setState(() => _modelController.text = m);
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),

          // 工具调用开关：本地小模型 tool calling 不可靠，可关闭走纯问答降级
          // （ListTile 需自带 Material：骨架的 DecoratedBox 背景会遮住 ink）
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _toolsEnabled,
              onChanged: (v) => setState(() => _toolsEnabled = v),
              title: const Text('启用工具调用'),
              subtitle: const Text('关闭后模型只做问答（本地小模型建议关闭）'),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 思考过程开关：展示模型 reasoning / think 内容（Gemini 思考、内联 think 标签）
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _showReasoning,
              onChanged: (v) => setState(() => _showReasoning = v),
              title: const Text('显示思考过程'),
              subtitle: const Text('在对话中展示模型的推理内容（可折叠）'),
            ),
          ),
        ],
      ),
      // 操作区固定在底部，不随内容滚动（统一弹层规范）
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  /// 拉取 OpenAI 兼容服务的可用模型列表（GET `{baseUrl}/models`）。
  ///
  /// 成功后**直接替换掉预设模型 chips**（不弹二级选择弹层）并写入缓存，
  /// 下次编辑同一端点时打开表单即用缓存的列表替换预设。
  Future<void> _refreshModels() async {
    final apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      AppDialogs.showError('请先填写 API Key');
      return;
    }
    final baseUrl = _baseUrlController.text.trim();
    setState(() => _loadingModels = true);
    try {
      final fetch = widget.fetchModels ?? fetchOpenAiModelIds;
      final ids = await fetch(baseUrl: baseUrl, apiKey: apiKey);
      if (!mounted) return;
      if (ids.isEmpty) {
        AppDialogs.showWarning('接口未返回任何模型，请检查 Base URL');
        return;
      }
      setState(() {
        _catalogCache = {
          ..._catalogCache,
          modelCatalogKey(baseUrl): ids,
        };
        _applyCatalog();
      });
      // 落库（失败只记日志，不影响本次选择）
      await cacheModelIds(baseUrl, ids);
    } catch (e) {
      if (mounted) AppDialogs.showError('拉取模型列表失败：$e');
    } finally {
      if (mounted) {
        setState(() => _loadingModels = false);
      }
    }
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
      toolsEnabled: _toolsEnabled,
      showReasoning: _showReasoning,
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

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/mcp/mcp_client.dart';
import 'package:gstore/core/agent/mcp/mcp_models.dart';
import 'package:gstore/core/agent/mcp/mcp_server_store.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/module/module_manager.dart';

/// 探测结果：服务器信息 + 工具列表。
class McpProbeResult {
  const McpProbeResult({required this.info, required this.tools});

  final McpServerInfo info;
  final List<McpToolInfo> tools;
}

/// 连接 MCP 服务器并拉取工具列表，结束后自动关闭连接。
Future<McpProbeResult> _probeMcpServer(McpServerConfig server) async {
  final client = McpClient(
    url: server.url,
    headers: server.headers,
    timeoutSeconds: server.timeoutSeconds,
  );
  try {
    final info = await client.connect();
    final tools = await client.listTools();
    return McpProbeResult(info: info, tools: tools);
  } finally {
    await client.close();
  }
}

/// MCP 服务器管理页（P2-2）
class McpServersPage extends StatefulWidget {
  const McpServersPage({super.key});

  @override
  State<McpServersPage> createState() => _McpServersPageState();
}

class _McpServersPageState extends State<McpServersPage> {
  McpServerStore? _store;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await McpServerStore.load();
    if (!mounted) return;
    setState(() {
      _store = store;
      _loading = false;
    });
  }

  Future<void> _reconfigureAgent() async {
    final agent = ModuleManager.instance.get<AgentService>();
    if (agent == null) return;
    try {
      await agent.reconfigure();
    } catch (e) {
      debugPrint('McpServersPage: Agent 重配失败 - $e');
    }
  }

  Future<void> _edit([McpServerConfig? existing]) async {
    final store = _store;
    if (store == null) return;
    final result = await McpServerEditSheet.show(context,
        store: store, existing: existing);
    if (result == null || !mounted) return;
    await _load();
    await _reconfigureAgent();
  }

  Future<void> _openDetail(McpServerConfig server) async {
    final action = await showMcpServerDetailSheet(context, server: server);
    if (!mounted) return;
    if (action == McpServerDetailAction.edit) {
      await _edit(server);
    }
  }

  Future<void> _toggle(McpServerConfig config, bool enabled) async {
    config.enabled = enabled;
    await _store!.update(config);
    if (mounted) setState(() {});
    await _reconfigureAgent();
  }

  Future<void> _delete(McpServerConfig config) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除 MCP 服务器',
      message: '确定删除「${config.name}」？其工具将从助手中移除。',
      isDangerous: true,
    );
    if (ok != true) return;
    await _store!.remove(config.id);
    if (mounted) setState(() {});
    await _reconfigureAgent();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP 服务器'),
        actions: [
          IconButton(
            tooltip: '添加服务器',
            onPressed: _loading ? null : () => _edit(),
            icon: const Icon(TablerIcons.plus),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: AppLoading())
          : ListView(
              padding: AppSpacing.allLG,
              children: [
                Text(
                  '仅支持远程 Streamable HTTP MCP 服务器。'
                  'MCP 工具默认按敏感操作处理，执行前会要求确认。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: AppSpacing.lg),
                if (_store!.all.isEmpty)
                  Padding(
                    padding: AppSpacing.onlyTopXL,
                    child: Column(
                      children: [
                        Icon(TablerIcons.plug_off,
                            size: 48, color: scheme.outline),
                        const SizedBox(height: AppSpacing.md),
                        Text('还没有 MCP 服务器',
                            style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '添加一个远程 MCP 端点后，助手会自动发现其工具。',
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        FilledButton.icon(
                          onPressed: () => _edit(),
                          icon: const Icon(TablerIcons.plus),
                          label: const Text('添加服务器'),
                        ),
                      ],
                    ),
                  )
                else
                  ..._store!.all.map((server) => _McpServerTile(
                        server: server,
                        onOpen: () => _openDetail(server),
                        onToggle: (v) => _toggle(server, v),
                        onEdit: () => _edit(server),
                        onDelete: () => _delete(server),
                      )),
              ],
            ),
    );
  }
}

class _McpServerTile extends StatefulWidget {
  const _McpServerTile({
    required this.server,
    required this.onOpen,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final McpServerConfig server;
  final VoidCallback onOpen;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  State<_McpServerTile> createState() => _McpServerTileState();
}

class _McpServerTileState extends State<_McpServerTile> {
  bool _expanded = false;
  bool _loading = false;
  String? _error;
  List<McpToolInfo>? _tools;

  Future<void> _toggleExpanded() async {
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() => _expanded = true);
    if (_tools == null && _error == null) {
      await _loadTools();
    }
  }

  Future<void> _loadTools() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _probeMcpServer(widget.server);
      if (!mounted) return;
      setState(() {
        _tools = result.tools;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载工具失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tools = _tools;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.allMD,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            ListTile(
              onTap: widget.onOpen,
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                child: Icon(TablerIcons.plug_connected,
                    color: scheme.onPrimaryContainer),
              ),
              title: Text(
                widget.server.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                tools == null
                    ? widget.server.url
                    : '${widget.server.url} · ${tools.length} 个工具',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                      value: widget.server.enabled, onChanged: widget.onToggle),
                  IconButton(
                    tooltip: _expanded ? '收起工具' : '展开工具',
                    onPressed: _toggleExpanded,
                    icon: AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: const Icon(TablerIcons.chevron_down),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    onSelected: (value) {
                      switch (value) {
                        case 'edit':
                          widget.onEdit();
                        case 'delete':
                          widget.onDelete();
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: _buildToolArea(context),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToolArea(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(child: AppLoading(size: AppLoadingSize.small)),
      );
    }
    if (_error != null) {
      return Row(
        children: [
          Expanded(
            child: Text(
              _error!,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.error),
            ),
          ),
          TextButton(onPressed: _loadTools, child: const Text('重试')),
        ],
      );
    }
    final tools = _tools;
    if (tools == null || tools.isEmpty) {
      return Text(
        '该服务器没有提供工具。',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    return _McpToolList(tools: tools);
  }
}

/// 共用工具列表：展开区与详情弹层都使用同一套展示。
class _McpToolList extends StatelessWidget {
  const _McpToolList({required this.tools});

  final List<McpToolInfo> tools;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < tools.length; i++) ...[
          _McpToolItem(tool: tools[i]),
          if (i != tools.length - 1) const Divider(height: AppSpacing.md),
        ],
      ],
    );
  }
}

class _McpToolItem extends StatelessWidget {
  const _McpToolItem({required this.tool});

  final McpToolInfo tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            TablerIcons.tool,
            size: AppTypography.iconSM,
            color: scheme.primary,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      tool.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: AppTypography.weightSemiBold,
                      ),
                    ),
                  ),
                  if (tool.readOnly) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Container(
                      padding: AppSpacing.horizontalXS_verticalXS,
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        '只读',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (tool.description.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  tool.description.trim(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 详情弹层返回的动作（编辑需要交给列表页处理）。
enum McpServerDetailAction { edit }

/// 点击 MCP 条目弹出的详情弹层：展示服务器信息，并可测试工具数量。
Future<McpServerDetailAction?> showMcpServerDetailSheet(
  BuildContext context, {
  required McpServerConfig server,
}) {
  return AppSheet.showCustom<McpServerDetailAction>(
    context: context,
    builder: (_) => _McpServerDetailSheet(server: server),
  );
}

class _McpServerDetailSheet extends StatefulWidget {
  const _McpServerDetailSheet({required this.server});

  final McpServerConfig server;

  @override
  State<_McpServerDetailSheet> createState() => _McpServerDetailSheetState();
}

class _McpServerDetailSheetState extends State<_McpServerDetailSheet> {
  bool _testing = false;
  McpProbeResult? _result;
  String? _error;

  Future<void> _test() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final result = await _probeMcpServer(widget.server);
      if (!mounted) return;
      setState(() {
        _result = result;
        _testing = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _error = '连接失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final server = widget.server;
    return AppSheetScaffold(
      title: server.name,
      subtitle: '远程 Streamable HTTP 端点',
      icon: const Icon(TablerIcons.plug_connected),
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InfoRow(label: '端点', value: server.url),
          _InfoRow(
            label: '状态',
            value: server.enabled ? '已启用' : '已停用',
          ),
          _InfoRow(
            label: '请求头',
            value: server.headers.isEmpty ? '无' : '${server.headers.length} 个',
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '点击测试连接可发现该服务器提供的工具数量与工具列表。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: _testing ? null : _test,
            icon: _testing
                ? const AppLoading(size: AppLoadingSize.small)
                : const Icon(TablerIcons.wifi),
            label: const Text('测试连接'),
          ),
          const SizedBox(height: AppSpacing.md),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: AppRadius.allMD,
              ),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          if (_result != null) _buildResult(context, _result!),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        OutlinedButton.icon(
          onPressed: () =>
              Navigator.of(context).pop(McpServerDetailAction.edit),
          icon: const Icon(TablerIcons.pencil),
          label: const Text('编辑'),
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context, McpProbeResult result) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final info = result.info;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: AppRadius.allMD,
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(TablerIcons.circle_check_filled,
                  size: AppTypography.iconMD, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '已连接 ${info.serverName}（${info.protocolVersion}）',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '该服务器提供 ${result.tools.length} 个工具',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.primary,
              fontWeight: AppTypography.weightSemiBold,
            ),
          ),
          if (result.tools.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.md),
            _McpToolList(tools: result.tools),
          ],
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// 添加/编辑 MCP 服务器弹层
class McpServerEditSheet extends StatefulWidget {
  const McpServerEditSheet({
    super.key,
    required this.store,
    this.existing,
  });

  final McpServerStore store;
  final McpServerConfig? existing;

  static Future<McpServerConfig?> show(
    BuildContext context, {
    required McpServerStore store,
    McpServerConfig? existing,
  }) {
    return AppSheet.showCustom<McpServerConfig>(
      context: context,
      builder: (_) => McpServerEditSheet(store: store, existing: existing),
    );
  }

  @override
  State<McpServerEditSheet> createState() => _McpServerEditSheetState();
}

class _McpServerEditSheetState extends State<McpServerEditSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _headersController;
  late bool _enabled;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameController = TextEditingController(text: existing?.name ?? '');
    _urlController = TextEditingController(text: existing?.url ?? '');
    _headersController = TextEditingController(
      text: existing == null || existing.headers.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ').convert(existing.headers),
    );
    _enabled = existing?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _headersController.dispose();
    super.dispose();
  }

  String get _url => _urlController.text.trim();

  Map<String, String>? _parseHeaders() {
    final text = _headersController.text.trim();
    if (text.isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) throw const FormatException('必须是 JSON 对象');
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (e) {
      AppDialogs.showError('请求头 JSON 无效：$e');
      return null;
    }
  }

  bool _validUrl() {
    final uri = Uri.tryParse(_url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      AppDialogs.showError('请输入 http(s) MCP 端点地址');
      return false;
    }
    return true;
  }

  Future<void> _test() async {
    final headers = _parseHeaders();
    if (headers == null || !_validUrl() || _testing) return;
    setState(() => _testing = true);
    final existing = widget.existing;
    final config = McpServerConfig(
      id: existing?.id ?? 'probe',
      name: _nameController.text.trim().isEmpty
          ? 'MCP'
          : _nameController.text.trim(),
      url: _url,
      headers: headers,
      enabled: _enabled,
      timeoutSeconds: existing?.timeoutSeconds ?? 15,
    );
    try {
      final result = await _probeMcpServer(config);
      AppDialogs.showSuccess(
        '已连接 ${result.info.serverName}（${result.info.protocolVersion}），'
        '提供 ${result.tools.length} 个工具',
        title: 'MCP 连接成功',
      );
    } catch (e) {
      AppDialogs.showError('连接失败：$e', title: 'MCP 连接失败');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final headers = _parseHeaders();
    if (headers == null || !_validUrl()) return;
    final name = _nameController.text.trim();
    final existing = widget.existing;
    final config = McpServerConfig(
      id: existing?.id ?? 'mcp-${DateTime.now().millisecondsSinceEpoch}',
      name: name.isEmpty ? 'MCP' : name,
      url: _url,
      headers: headers,
      enabled: _enabled,
      timeoutSeconds: existing?.timeoutSeconds ?? 15,
    );
    if (existing == null) {
      final created = await widget.store.add(
        name: config.name,
        url: config.url,
        headers: config.headers,
      );
      created.enabled = _enabled;
      await widget.store.update(created);
      if (mounted) Navigator.of(context).pop(created);
    } else {
      await widget.store.update(config);
      if (mounted) Navigator.of(context).pop(config);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: widget.existing == null ? '添加 MCP 服务器' : '编辑 MCP 服务器',
      subtitle: '远程 Streamable HTTP 端点',
      icon: const Icon(TablerIcons.plug_connected),
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '名称',
              hintText: '例如：Weather / Search',
              border: OutlineInputBorder(),
              prefixIcon: Icon(TablerIcons.tag),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'MCP 端点 URL',
              hintText: 'https://example.com/mcp',
              border: OutlineInputBorder(),
              prefixIcon: Icon(TablerIcons.link),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _headersController,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '请求头 JSON（可选）',
              hintText: '{"Authorization": "Bearer ..."}',
              border: OutlineInputBorder(),
              prefixIcon: Icon(TablerIcons.key),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
              title: const Text('启用'),
              subtitle: const Text('启用后助手会连接并发现工具'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          OutlinedButton.icon(
            onPressed: _testing ? null : _test,
            icon: _testing
                ? const AppLoading(size: AppLoadingSize.small)
                : const Icon(TablerIcons.wifi),
            label: const Text('测试连接'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

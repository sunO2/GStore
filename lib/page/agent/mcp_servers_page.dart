import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/mcp/mcp_client.dart';
import 'package:gstore/core/agent/mcp/mcp_models.dart';
import 'package:gstore/core/agent/mcp/mcp_server_store.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/module/module_manager.dart';

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
    final result =
        await McpServerEditSheet.show(context, store: store, existing: existing);
    if (result == null || !mounted) return;
    await _load();
    await _reconfigureAgent();
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
                        onToggle: (v) => _toggle(server, v),
                        onEdit: () => _edit(server),
                        onDelete: () => _delete(server),
                      )),
              ],
            ),
    );
  }
}

class _McpServerTile extends StatelessWidget {
  const _McpServerTile({
    required this.server,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final McpServerConfig server;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.allMD,
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          onTap: onEdit,
          leading: CircleAvatar(
            backgroundColor: scheme.primaryContainer,
            child: Icon(TablerIcons.plug_connected,
                color: scheme.onPrimaryContainer),
          ),
          title: Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            server.url,
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
              Switch(value: server.enabled, onChanged: onToggle),
              IconButton(
                tooltip: '删除',
                onPressed: onDelete,
                icon: const Icon(TablerIcons.trash),
              ),
            ],
          ),
        ),
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
    final client = McpClient(url: _url, headers: headers);
    try {
      final info = await client.connect();
      final tools = await client.listTools();
      AppDialogs.showSuccess(
        '已连接 ${info.serverName}（${info.protocolVersion}），发现 ${tools.length} 个工具',
        title: 'MCP 连接成功',
      );
    } catch (e) {
      AppDialogs.showError('连接失败：$e', title: 'MCP 连接失败');
    } finally {
      await client.close();
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

// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webview/web_userscript.dart';
import 'package:gstore/core/webview/web_userscript_store.dart';

import 'web_userscript_sheets.dart';

/// 用户脚本管理页。
class WebUserScriptsPage extends StatefulWidget {
  const WebUserScriptsPage({super.key});

  @override
  State<WebUserScriptsPage> createState() => _WebUserScriptsPageState();
}

class _WebUserScriptsPageState extends State<WebUserScriptsPage> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WebUserScriptStore.instance.load().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
    });
  }

  Future<void> _installFromUrl() async {
    final url = await showUserScriptUrlSheet(context);
    if (url == null || !mounted) return;
    AppDialogs.showLoading(message: '正在获取脚本…');
    WebUserScriptParseResult parsed;
    try {
      parsed = await WebUserScriptFetcher.fetch(url);
    } catch (error) {
      AppDialogs.dismissLoading();
      if (mounted) AppDialogs.showError('获取脚本失败：$error');
      return;
    }
    AppDialogs.dismissLoading();
    if (!mounted) return;
    if (!parsed.ok) {
      AppDialogs.showError(parsed.error ?? '不是用户脚本');
      return;
    }
    await _confirm(parsed.script!);
  }

  Future<void> _confirm(WebUserScript script) async {
    final existing = WebUserScriptStore.instance.scripts
        .where((item) => item.key == script.key);
    final update = existing.isNotEmpty;
    final ok = await showUserScriptInstallSheet(
      context,
      script,
      update: update,
    );
    if (ok != true) return;
    final result = await WebUserScriptStore.instance.upsert(script);
    if (!mounted) return;
    setState(() {});
    AppDialogs.showSuccess(
      result.updated ? '已更新：${result.script.name}' : '已安装：${result.script.name}',
    );
  }

  Future<void> _openDetail(WebUserScript script) async {
    await showUserScriptDetailSheet(
      context,
      script,
      onToggle: (enabled) async {
        await WebUserScriptStore.instance.setEnabled(script.id, enabled);
        if (mounted) setState(() {});
      },
      onViewCode: () => showUserScriptCodeSheet(context, script),
      onDelete: () => _delete(script),
    );
  }

  Future<void> _delete(WebUserScript script) async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '删除脚本',
      message: '将删除「${script.name}」及其保存的数据，不可恢复。',
      confirmText: '删除',
      isDangerous: true,
    );
    if (ok != true) return;
    await WebUserScriptStore.instance.remove(script.id);
    if (mounted) setState(() {});
  }

  Future<void> _toggle(WebUserScript script, bool enabled) async {
    await WebUserScriptStore.instance.setEnabled(script.id, enabled);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final scripts = WebUserScriptStore.instance.scripts;
    return Scaffold(
      appBar: AppBar(
        title: const Text('用户脚本'),
        actions: [
          IconButton(
            tooltip: '从链接安装',
            icon: const Icon(TablerIcons.plus),
            onPressed: _ready ? _installFromUrl : null,
          ),
        ],
      ),
      body: !_ready
          ? const Center(child: AppLoading())
          : scripts.isEmpty
              ? _EmptyState(onInstall: _installFromUrl)
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                  itemCount: scripts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final script = scripts[index];
                    return ListTile(
                      leading: UserScriptAvatar(script: script),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              script.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.xs),
                          Text(
                            'v${script.version}',
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        script.description.isNotEmpty
                            ? script.description
                            : _matchSummary(script),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Switch(
                        value: script.enabled,
                        onChanged: (value) => _toggle(script, value),
                      ),
                      onTap: () => _openDetail(script),
                    );
                  },
                ),
    );
  }

  String _matchSummary(WebUserScript script) {
    final rules = [...script.matches, ...script.includes];
    if (rules.isEmpty) return '未设置匹配规则';
    if (rules.length == 1) return rules.first;
    return '${rules.first} 等 ${rules.length} 条规则';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onInstall});

  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              TablerIcons.code,
              size: 40,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('还没有用户脚本', style: textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '在 Greasy Fork 等网站点「安装」，或者粘贴脚本地址。'
              '脚本只会注入到 @match 命中的页面。',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: onInstall,
              icon: const Icon(TablerIcons.plus),
              label: const Text('从链接安装'),
            ),
          ],
        ),
      ),
    );
  }
}

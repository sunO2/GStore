// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/editor/app_code_language.dart';
import 'package:gstore/core/webview/web_userscript.dart';
import 'package:gstore/core/webview/web_userscript_store.dart';

/// 「本页使用的脚本」面板。
///
/// 由页面导航头右上角的脚本按钮打开；列表实时反映命中当前 URL 的脚本，
/// 可以直接停用/启用，底部的「管理脚本」进入完整管理页。
Future<void> showPageUserScriptsSheet(
  BuildContext context, {
  required String url,
  required Future<void> Function() onChanged,
  required VoidCallback onManage,
}) {
  return AppSheet.showCustom<void>(
    context: context,
    builder: (_) => _PageScriptsSheet(
      url: url,
      onChanged: onChanged,
      onManage: onManage,
    ),
  );
}

class _PageScriptsSheet extends StatefulWidget {
  const _PageScriptsSheet({
    required this.url,
    required this.onChanged,
    required this.onManage,
  });

  final String url;
  final Future<void> Function() onChanged;
  final VoidCallback onManage;

  @override
  State<_PageScriptsSheet> createState() => _PageScriptsSheetState();
}

class _PageScriptsSheetState extends State<_PageScriptsSheet> {
  late List<WebUserScript> _scripts =
      WebUserScriptStore.instance.scriptsForUrl(widget.url);

  Future<void> _toggle(WebUserScript script, bool enabled) async {
    await WebUserScriptStore.instance.setEnabled(script.id, enabled);
    if (!mounted) return;
    setState(() {
      _scripts = WebUserScriptStore.instance.scriptsForUrl(widget.url);
    });
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final host = Uri.tryParse(widget.url)?.host ?? widget.url;
    return AppSheetScaffold(
      title: '本页脚本',
      subtitle: host.isEmpty ? null : host,
      icon: const Icon(TablerIcons.code),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            widget.onManage();
          },
          child: const Text('管理脚本'),
        ),
      ],
      content: _scripts.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '当前页面没有命中任何用户脚本。',
                  style: textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '在脚本网站（如 Greasy Fork）点「安装」即可添加，安装后刷新页面生效。',
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            )
          : Column(
              children: [
                for (final script in _scripts)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: script.enabled,
                    onChanged: (value) => _toggle(script, value),
                    title: Text(script.name),
                    subtitle: Text(
                      script.version.isEmpty
                          ? (script.description.isEmpty
                              ? 'v—'
                              : script.description)
                          : 'v${script.version}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
    );
  }
}

/// 安装确认。返回 true 表示用户点了「安装 / 更新」。
Future<bool?> showUserScriptInstallSheet(
  BuildContext context,
  WebUserScript script, {
  required bool update,
}) {
  return AppSheet.showCustom<bool>(
    context: context,
    builder: (_) => _InstallSheet(script: script, update: update),
  );
}

class _InstallSheet extends StatelessWidget {
  const _InstallSheet({required this.script, required this.update});

  final WebUserScript script;
  final bool update;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final rules = [...script.matches, ...script.includes];
    final grants = script.grants.where((grant) => grant != 'none').toList();
    return AppSheetScaffold(
      title: update ? '更新脚本' : '安装脚本',
      subtitle: script.name,
      icon: const Icon(TablerIcons.code),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(update ? '更新' : '安装'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UserScriptAvatar(script: script, size: 44),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(script.name, style: textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      [
                        'v${script.version}',
                        if (script.author.isNotEmpty) script.author,
                      ].join(' · '),
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (script.description.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(script.description, style: textTheme.bodyMedium),
          ],
          const SizedBox(height: AppSpacing.md),
          _LabelValue(
            label: '匹配站点',
            value: rules.isEmpty
                ? '（没有 @match，脚本不会运行）'
                : rules.take(6).join('\n') +
                    (rules.length > 6 ? '\n…共 ${rules.length} 条规则' : ''),
          ),
          if (grants.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _LabelValue(label: 'GM 权限', value: grants.join(', ')),
          ],
          if (script.sourceUrl.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _LabelValue(label: '来源', value: script.sourceUrl),
          ],
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: AppSpacing.allSM,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: AppRadius.allSM,
            ),
            child: Text(
              '用户脚本可以读取和修改这些网站的页面内容。只安装你信任的脚本。',
              style: textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 脚本详情（管理页点条目打开）。
Future<void> showUserScriptDetailSheet(
  BuildContext context,
  WebUserScript script, {
  required Future<void> Function(bool enabled) onToggle,
  required VoidCallback onViewCode,
  required VoidCallback onDelete,
}) {
  return AppSheet.showCustom<void>(
    context: context,
    builder: (_) => _DetailSheet(
      script: script,
      onToggle: onToggle,
      onViewCode: onViewCode,
      onDelete: onDelete,
    ),
  );
}

class _DetailSheet extends StatefulWidget {
  const _DetailSheet({
    required this.script,
    required this.onToggle,
    required this.onViewCode,
    required this.onDelete,
  });

  final WebUserScript script;
  final Future<void> Function(bool enabled) onToggle;
  final VoidCallback onViewCode;
  final VoidCallback onDelete;

  @override
  State<_DetailSheet> createState() => _DetailSheetState();
}

class _DetailSheetState extends State<_DetailSheet> {
  late bool _enabled = widget.script.enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final script = widget.script;
    final rules = [...script.matches, ...script.includes];
    final grants = script.grants.where((grant) => grant != 'none').toList();
    return AppSheetScaffold(
      title: script.name,
      subtitle: 'v${script.version}',
      icon: const Icon(TablerIcons.code),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            widget.onDelete();
          },
          style: TextButton.styleFrom(foregroundColor: scheme.error),
          child: const Text('删除'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (script.description.isNotEmpty) ...[
            Text(script.description, style: textTheme.bodyMedium),
            const SizedBox(height: AppSpacing.md),
          ],
          _LabelValue(
            label: '匹配站点',
            value: rules.isEmpty ? '（未设置 @match）' : rules.join('\n'),
          ),
          if (grants.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _LabelValue(label: 'GM 权限', value: grants.join(', ')),
          ],
          if (script.values.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _LabelValue(
              label: '存储',
              value: '${script.values.length} 个键',
            ),
          ],
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(TablerIcons.code, size: 20),
            title: const Text('查看代码'),
            trailing: const Icon(TablerIcons.chevron_right, size: 18),
            onTap: widget.onViewCode,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _enabled,
            title: const Text('启用'),
            subtitle: const Text('停用后不再注入到匹配的页面'),
            onChanged: (value) async {
              setState(() => _enabled = value);
              await widget.onToggle(value);
            },
          ),
        ],
      ),
    );
  }
}

/// 只读查看脚本代码。
Future<void> showUserScriptCodeSheet(
  BuildContext context,
  WebUserScript script,
) {
  return AppSheet.showCustom<void>(
    context: context,
    builder: (_) => AppSheetScaffold(
      title: script.name,
      subtitle: 'v${script.version}',
      icon: const Icon(TablerIcons.code),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
      content: SizedBox(
        height: 420,
        child: AppCodeView(
          text: script.code,
          language: AppCodeLanguage.javascript,
          wordWrap: true,
        ),
      ),
    ),
  );
}

/// 安装地址输入。
Future<String?> showUserScriptUrlSheet(BuildContext context) {
  return AppSheet.showCustom<String>(
    context: context,
    builder: (_) => const _UrlSheet(),
  );
}

class _UrlSheet extends StatefulWidget {
  const _UrlSheet();

  @override
  State<_UrlSheet> createState() => _UrlSheetState();
}

class _UrlSheetState extends State<_UrlSheet> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() => _error = '请输入脚本的 http(s) 地址');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: '从链接安装',
      subtitle: '以 .user.js 结尾的地址，例如 Greasy Fork 的安装链接',
      icon: const Icon(TablerIcons.link),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('继续')),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              hintText: 'https://example.com/script.user.js',
              errorText: _error,
            ),
          ),
        ],
      ),
    );
  }
}

class _LabelValue extends StatelessWidget {
  const _LabelValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: textTheme.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: textTheme.bodySmall,
          maxLines: 6,
        ),
      ],
    );
  }
}

/// 没有图标时的首字母色块（和主页宫格保持一致的观感）。
class UserScriptAvatar extends StatelessWidget {
  const UserScriptAvatar({super.key, required this.script, this.size = 40});

  final WebUserScript script;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = script.name.trim();
    final letter = name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

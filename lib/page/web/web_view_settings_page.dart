// 全仓库仍使用 flutter/material.dart；迁移 material_ui 单独排期。
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/webview/web_view_settings.dart';

/// 内置浏览器设置页。
///
/// 这些配置既影响新打开的页面（WebView 初始设置），也尽量实时应用到当前页面
/// （`setSettings` / 重新注入夜间模式 / 重载 UA）。后续新增浏览器能力时，
/// 在 [WebViewSettings] 加字段、在这里加一行即可。
class WebViewSettingsPage extends StatefulWidget {
  const WebViewSettingsPage({super.key});

  @override
  State<WebViewSettingsPage> createState() => _WebViewSettingsPageState();
}

class _WebViewSettingsPageState extends State<WebViewSettingsPage> {
  WebViewSettings _settings = WebViewSettings.defaults;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WebViewSettingsStore.instance.load().then((_) {
      if (!mounted) return;
      setState(() {
        _settings = WebViewSettingsStore.instance.settings;
        _ready = true;
      });
    });
  }

  Future<void> _update(WebViewSettings next) async {
    setState(() => _settings = next);
    await WebViewSettingsStore.instance.save(next);
  }

  Future<void> _pickEngine() async {
    final picked = await AppSheet.show<WebSearchEngine>(
      context: context,
      title: '默认搜索引擎',
      icon: const Icon(TablerIcons.search),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      content: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (final engine in WebSearchEngine.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(kSearchEngineLabels[engine] ?? engine.name),
                trailing: engine == _settings.searchEngine
                    ? Icon(
                        TablerIcons.check,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(engine),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _update(_settings.copyWith(searchEngine: picked));
    if (picked == WebSearchEngine.custom &&
        !_settings.customSearchTemplate.contains('%s')) {
      if (!mounted) return;
      await _editCustomTemplate();
    }
  }

  Future<void> _editCustomTemplate() async {
    final template = await AppSheet.showCustom<String>(
      context: context,
      builder: (_) => _TemplateSheet(initial: _settings.customSearchTemplate),
    );
    if (template == null) return;
    await _update(_settings.copyWith(
      customSearchTemplate: template,
      searchEngine: WebSearchEngine.custom,
    ));
  }

  Future<void> _clearData() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '清除浏览数据',
      message: '将清除所有网站的 Cookie、本地存储与缓存。'
          '所有站点（包括 AI 网页工具）都会退出登录，且不可恢复。',
      confirmText: '清除',
      isDangerous: true,
    );
    if (ok != true) return;
    await CookieManager.instance().deleteAllCookies();
    await WebStorageManager.instance().deleteAllData();
    await InAppWebViewController.clearAllCache();
    if (mounted) AppDialogs.showSuccess('浏览数据已清除');
  }

  Future<void> _reset() async {
    final ok = await AppDialogs.showConfirmSheet(
      title: '恢复默认设置',
      message: '搜索、显示、内容与隐私选项都会恢复默认值。',
      confirmText: '恢复',
    );
    if (ok != true) return;
    await WebViewSettingsStore.instance.reset();
    if (!mounted) return;
    setState(() => _settings = WebViewSettingsStore.instance.settings);
    AppDialogs.showSuccess('已恢复默认设置');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('浏览器设置')),
      body: !_ready
          ? const Center(child: AppLoading())
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.xxl,
              ),
              children: [
                _SectionCard(
                  icon: TablerIcons.search,
                  title: '搜索',
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('默认搜索引擎'),
                      subtitle: Text(
                        kSearchEngineLabels[_settings.searchEngine] ??
                            _settings.searchEngine.name,
                      ),
                      trailing: const Icon(TablerIcons.chevron_right, size: 18),
                      onTap: _pickEngine,
                    ),
                    if (_settings.searchEngine == WebSearchEngine.custom)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('自定义搜索地址'),
                        subtitle: Text(
                          _settings.customSearchTemplate.isEmpty
                              ? '未设置（暂用必应）'
                              : _settings.customSearchTemplate,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing:
                            const Icon(TablerIcons.chevron_right, size: 18),
                        onTap: _editCustomTemplate,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                _SectionCard(
                  icon: TablerIcons.palette,
                  title: '显示',
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('夜间模式'),
                      subtitle: const Text('对网页做智能反色，换页后保持'),
                      value: _settings.nightMode,
                      onChanged: (v) =>
                          _update(_settings.copyWith(nightMode: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('电脑模式'),
                      subtitle: const Text('使用桌面浏览器标识，页面按桌面版渲染'),
                      value: _settings.desktopMode,
                      onChanged: (v) =>
                          _update(_settings.copyWith(desktopMode: v)),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('字体大小'),
                      subtitle: Slider(
                        value: _settings.textZoom.toDouble(),
                        min: 70,
                        max: 200,
                        divisions: 13,
                        label: '${_settings.textZoom}%',
                        onChanged: (v) =>
                            _update(_settings.copyWith(textZoom: v.round())),
                      ),
                      trailing: Text(
                        '${_settings.textZoom}%',
                        style: textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                _SectionCard(
                  icon: TablerIcons.photo,
                  title: '内容',
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('加载图片'),
                      subtitle: const Text('关闭后进入无图模式，省流量'),
                      value: _settings.loadImages,
                      onChanged: (v) =>
                          _update(_settings.copyWith(loadImages: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('JavaScript'),
                      subtitle: const Text('关闭后部分网站无法正常显示'),
                      value: _settings.javaScriptEnabled,
                      onChanged: (v) =>
                          _update(_settings.copyWith(javaScriptEnabled: v)),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                _SectionCard(
                  icon: TablerIcons.shield,
                  title: '隐私与数据',
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('缓存'),
                      subtitle: const Text('关闭后每次都会重新下载页面资源'),
                      value: _settings.cacheEnabled,
                      onChanged: (v) =>
                          _update(_settings.copyWith(cacheEnabled: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('第三方 Cookie'),
                      subtitle: const Text('部分站点的登录/嵌入内容依赖它'),
                      value: _settings.thirdPartyCookies,
                      onChanged: (v) =>
                          _update(_settings.copyWith(thirdPartyCookies: v)),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        TablerIcons.trash,
                        color: scheme.error,
                        size: 20,
                      ),
                      title: Text(
                        '清除浏览数据',
                        style: TextStyle(color: scheme.error),
                      ),
                      subtitle: const Text('Cookie / 本地存储 / 缓存'),
                      onTap: _clearData,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                _SectionCard(
                  icon: TablerIcons.settings,
                  title: '其他',
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('恢复默认设置'),
                      subtitle: const Text('不会删除历史记录和书签'),
                      onTap: _reset,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '这些设置只影响内置浏览器，不影响 App 其他网络请求与 AI 网页工具。',
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon,
                    size: AppTypography.iconMD,
                    color: theme.colorScheme.primary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 自定义搜索模板输入（必须包含 `%s`，否则不允许保存）。
class _TemplateSheet extends StatefulWidget {
  const _TemplateSheet({required this.initial});

  final String initial;

  @override
  State<_TemplateSheet> createState() => _TemplateSheetState();
}

class _TemplateSheetState extends State<_TemplateSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (!text.contains('%s')) {
      setState(() => _error = '地址里必须包含 %s 作为关键词占位符');
      return;
    }
    final uri = Uri.tryParse(text.replaceFirst('%s', 'termux'));
    if (uri == null || uri.host.isEmpty) {
      setState(() => _error = '请输入完整的 http(s) 地址');
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return AppSheetScaffold(
      title: '自定义搜索地址',
      subtitle: '示例：https://example.com/search?q=%s',
      icon: const Icon(TablerIcons.world),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
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
              hintText: 'https://example.com/search?q=%s',
              errorText: _error,
            ),
          ),
        ],
      ),
    );
  }
}

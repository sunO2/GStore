import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/websearch/web_search_config.dart';
import 'package:gstore/core/websearch/web_search_service.dart';

/// 联网检索设置（P3-7）
///
/// 默认 Tavily keyless：不用账号即可用；填 API Key 后自动切换 keyed 模式
/// （Tavily 免费 1,000 次/月）。
class WebSearchSettingsSheet extends StatefulWidget {
  const WebSearchSettingsSheet({super.key, required this.config});

  final WebSearchConfig config;

  static Future<WebSearchConfig?> show(
    BuildContext context, {
    required WebSearchConfig config,
  }) {
    return AppSheet.showCustom<WebSearchConfig>(
      context: context,
      builder: (_) => WebSearchSettingsSheet(config: config),
    );
  }

  @override
  State<WebSearchSettingsSheet> createState() => _WebSearchSettingsSheetState();
}

class _WebSearchSettingsSheetState extends State<WebSearchSettingsSheet> {
  late bool _enabled;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _searchQuotaController;
  late final TextEditingController _fetchQuotaController;

  @override
  void initState() {
    super.initState();
    final config = widget.config;
    _enabled = config.enabled;
    _apiKeyController = TextEditingController(text: config.apiKey);
    _searchQuotaController =
        TextEditingController(text: config.dailySearchQuota.toString());
    _fetchQuotaController =
        TextEditingController(text: config.dailyFetchQuota.toString());
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _searchQuotaController.dispose();
    _fetchQuotaController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppSheetScaffold(
      title: '联网检索',
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '默认使用 Tavily keyless（无需账号，有限速）。'
            '填入 Tavily API Key 可提升额度（免费 1,000 次/月）。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
              title: const Text('启用联网检索'),
              subtitle: const Text('关闭后 webSearch / webFetch 不再下发'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _apiKeyController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Tavily API Key（可选）',
              hintText: '留空 = keyless 模式',
              helperText: 'Key 只保存在本机，用于提高配额',
              border: OutlineInputBorder(),
              prefixIcon: Icon(TablerIcons.key),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchQuotaController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '每日搜索上限',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: TextField(
                  controller: _fetchQuotaController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '每日抓取上限',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '0 = 不限制（不建议）。查询/正文都有 15 分钟缓存。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                WebSearchService.instance.clearCache();
                AppDialogs.showSuccess('已清除联网检索缓存');
              },
              icon: const Icon(TablerIcons.trash),
              label: const Text('清除缓存'),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Future<void> _save() async {
    final config = widget.config.copyWith(
      enabled: _enabled,
      apiKey: _apiKeyController.text.trim(),
      dailySearchQuota:
          int.tryParse(_searchQuotaController.text.trim()) ?? 50,
      dailyFetchQuota: int.tryParse(_fetchQuotaController.text.trim()) ?? 30,
    );
    await WebSearchService.instance.updateConfig(config);
    if (!mounted) return;
    Navigator.of(context).pop(config);
  }
}

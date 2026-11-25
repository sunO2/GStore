import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/agent/agent_service.dart';
import 'package:gstore/core/agent/genkit_read_only_shadow.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/module/module_manager.dart';

/// Genkit 只读 Shadow 对比页。
///
/// 同一问题分别走“现有 Loop 的只读副本”和 `defineCustomAgent`：
/// - 只开放 searchApp/getAppInfo；
/// - 不写入当前会话；
/// - 仅用于开发期质量和延迟对比。
class GenkitShadowComparePage extends StatefulWidget {
  const GenkitShadowComparePage({super.key});

  @override
  State<GenkitShadowComparePage> createState() =>
      _GenkitShadowComparePageState();
}

class _GenkitShadowComparePageState extends State<GenkitShadowComparePage> {
  final TextEditingController _prompt = TextEditingController();
  bool _running = false;
  String? _error;
  ({ShadowAgentResult legacy, ShadowAgentResult shadow})? _result;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final text = _prompt.text.trim();
    if (text.isEmpty || _running) return;

    final agent = ModuleManager.instance.get<AgentService>();
    if (agent == null) {
      setState(() => _error = 'Agent 模块未启用');
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });

    try {
      final result = await agent.debugRunReadOnlyComparison(text);
      if (!mounted) return;
      setState(() {
        _result = result;
        if (result == null) {
          _error =
              'Shadow 未启用或模型未初始化。请使用 --dart-define=GSTORE_GENKIT_READ_ONLY_SHADOW=true 启动。';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '对比运行失败：$error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Genkit 对比实验')),
      body: ListView(
        padding: AppSpacing.allLG,
        children: [
          _noticeCard(context),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _prompt,
            minLines: 2,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              labelText: '测试问题',
              hintText: '例如：帮我找一个开源截图工具',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const AppLoading(size: AppLoadingSize.small)
                : const Icon(TablerIcons.scale),
            label: Text(_running ? '运行中…' : '运行只读对比'),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _error!,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.error),
            ),
          ],
          if (_result != null) ...[
            const SizedBox(height: AppSpacing.lg),
            _resultCard(
              context,
              title: '现有 Loop（只读副本）',
              subtitle: 'returnToolRequests + 手动执行',
              result: _result!.legacy,
            ),
            const SizedBox(height: AppSpacing.md),
            _resultCard(
              context,
              title: 'defineCustomAgent',
              subtitle: 'Genkit 原生 Agent + 内置工具循环',
              result: _result!.shadow,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '两项按顺序运行，第二次可能命中 Provider 提示缓存；耗时不代表严格基准。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _noticeCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: AppSpacing.allMD,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(TablerIcons.info_circle, color: scheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                '仅开放 searchApp 和 getAppInfo，不写入当前会话，不会下载或安装应用。',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required ShadowAgentResult result,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = result.isSuccess ? scheme.primary : scheme.error;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: statusColor.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: AppSpacing.allMD,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  result.isSuccess
                      ? TablerIcons.circle_check
                      : TablerIcons.alert_triangle,
                  color: statusColor,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context).textTheme.titleSmall),
                      Text(
                        subtitle,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                _metric(context, '耗时', '${result.duration.inMilliseconds} ms'),
                _metric(context, '工具', '${result.toolRequests} 次'),
                _metric(context, 'Token', _tokenText(result)),
              ],
            ),
            if (result.error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                '错误：${result.error}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ],
            if (result.text.trim().isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              SelectableText(
                result.text,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        '$label $value',
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }

  String _tokenText(ShadowAgentResult result) {
    if (result.totalTokens == null) return '未知';
    return '${result.inputTokens ?? 0}→${result.outputTokens ?? 0}'
        '（${result.totalTokens}）';
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:a2ui_core/a2ui_core.dart';
import 'package:a2ui_flutter/a2ui_flutter.dart';
import 'package:a2ui_flutter/basic_catalog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';
import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_sheet.dart';
import 'package:gstore/core/design/app_spacing.dart';

/// A2UI 实验室（阶段 C：独立 Canvas）
///
/// 不接 Agent，只加载本地静态 A2UI 消息，用 `a2ui_flutter` 的
/// basic catalog 渲染，验证：
/// - GStore 主题下的视觉效果
/// - 中文文本 / 表单 / 列表
/// - action 回传的数据结构
/// - 非法消息的错误处理
///
/// 这是实验页面，后续工具式/内联方案会复用这里的 surface 生命周期处理。
class A2uiLabPage extends StatefulWidget {
  const A2uiLabPage({super.key, this.loadSample});

  /// 测试接缝：按 asset 路径加载 A2UI JSON；为空时走 rootBundle。
  final Future<String> Function(String asset)? loadSample;

  @override
  State<A2uiLabPage> createState() => _A2uiLabPageState();
}

typedef _Sample = ({String id, String title, String description, String asset});

const List<_Sample> _samples = [
  (
    id: 'app-card',
    title: '应用卡片',
    description: '结果卡片 + 主/次操作按钮，演示 data binding',
    asset: 'assets/a2ui/app_card.json',
  ),
  (
    id: 'filter-form',
    title: '筛选表单',
    description: '输入框 / 多选 / 勾选，演示双向绑定与 action context',
    asset: 'assets/a2ui/filter_form.json',
  ),
  (
    id: 'results-list',
    title: '结果列表',
    description: 'List 模板按 data model 生成子项，演示列表性能',
    asset: 'assets/a2ui/results_list.json',
  ),
];

class _A2uiLabPageState extends State<A2uiLabPage> {
  int _selected = 0;
  bool _loading = true;
  A2uiError? _error;
  MessageProcessor<ComponentImplementation>? _processor;
  final List<SurfaceModel<ComponentImplementation>> _surfaces = [];
  final List<A2uiRendererAction> _actions = [];
  int _loadToken = 0;

  _Sample get _sample => _samples[_selected];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _disposeProcessor();
    super.dispose();
  }

  void _disposeProcessor() {
    _processor?.dispose();
    _processor = null;
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    _disposeProcessor();
    setState(() {
      _loading = true;
      _error = null;
      _surfaces.clear();
      _actions.clear();
    });

    final processor = MessageProcessor<ComponentImplementation>(
      catalogs: [basicCatalog(locale: 'zh-CN')],
      unifiedOutbound: true,
      outboundListener: (_) {},
    );
    processor.model.onSurfaceCreated.subscribe((surface) {
      if (!mounted || token != _loadToken) return;
      setState(() => _surfaces.add(surface));
    });
    processor.model.onSurfaceDeleted.subscribe((surfaceId) {
      if (!mounted || token != _loadToken) return;
      setState(() => _surfaces.removeWhere((s) => s.id == surfaceId));
    });
    processor.model.onAction.subscribe((action) {
      if (!mounted || token != _loadToken) return;
      setState(() => _actions.insert(0, action));
    });
    _processor = processor;

    try {
      final raw = await (widget.loadSample ?? rootBundle.loadString)(
        _sample.asset,
      );
      final messages = jsonDecode(raw);
      processor.processMessages(messages);
      if (!mounted || token != _loadToken) return;
      setState(() => _loading = false);
    } on A2uiError catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    } catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = A2uiError('加载示例失败：$error', code: 'LOAD_ERROR');
      });
    }
  }

  void _selectSample(int index) {
    if (index == _selected) return;
    setState(() => _selected = index);
    unawaited(_load());
  }

  Future<void> _showAction(A2uiRendererAction action) {
    final json = const JsonEncoder.withIndent('  ').convert(action.toJson());
    return AppSheet.show<void>(
      context: context,
      title: 'A2UI Action',
      subtitle: action.name,
      icon: const Icon(TablerIcons.bolt),
      content: SelectableText(
        json,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
            ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('A2UI 实验室'),
        actions: [
          IconButton(
            tooltip: '重新加载',
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(TablerIcons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        children: [
          _buildHeader(scheme),
          const SizedBox(height: AppSpacing.md),
          _buildSampleSelector(),
          const SizedBox(height: AppSpacing.md),
          _buildSurfaceArea(scheme),
          const SizedBox(height: AppSpacing.lg),
          _buildActions(scheme),
        ],
      ),
    );
  }

  Widget _buildHeader(ColorScheme scheme) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(TablerIcons.flask, color: scheme.primary, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '生成式界面 PoC',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '这里渲染的是本地静态 A2UI 消息，没有接 Agent。'
            '按钮产生的 action 会记录在下方，用来验证后续回传链路。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _sample.description,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.primary),
          ),
        ],
      ),
    );
  }

  Widget _buildSampleSelector() {
    return AppSegmentedButton<String>(
      value: _sample.id,
      segments: [
        for (final sample in _samples)
          AppSegment<String>(value: sample.id, label: sample.title),
      ],
      onChanged: (id) {
        final index = _samples.indexWhere((s) => s.id == id);
        if (index >= 0) _selectSample(index);
      },
    );
  }

  Widget _buildSurfaceArea(ColorScheme scheme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: AppLoading()),
      );
    }
    final error = _error;
    if (error != null) {
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(TablerIcons.alert_circle, color: scheme.error, size: 20),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'A2UI 渲染失败',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: scheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            SelectableText(
              '${error.code}: ${error.message}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                text: '重试',
                style: AppButtonStyle.secondary,
                size: AppButtonSize.small,
                onPressed: () => unawaited(_load()),
              ),
            ),
          ],
        ),
      );
    }
    if (_surfaces.isEmpty) {
      return AppCard(
        child: Text(
          '没有 surface。检查示例 JSON 是否包含 createSurface。',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final surface in _surfaces)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: A2uiSurface(
              key: ObjectKey(surface),
              surface: surface,
            ),
          ),
      ],
    );
  }

  Widget _buildActions(ColorScheme scheme) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(TablerIcons.bolt, color: scheme.primary, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Action 日志',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const Spacer(),
              Text(
                '${_actions.length} 条',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          if (_actions.isEmpty)
            Text(
              '点击上面的按钮 / 提交表单，这里会记录 action 名称和 context。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            )
          else
            for (final action in _actions.take(5))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(TablerIcons.pointer, size: 18, color: scheme.primary),
                title: Text(action.name),
                subtitle: Text(
                  jsonEncode(action.context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(TablerIcons.chevron_right, size: 18),
                onTap: () => unawaited(_showAction(action)),
              ),
        ],
      ),
    );
  }
}

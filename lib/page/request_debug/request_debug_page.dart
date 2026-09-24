import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/design/app_components.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/design/app_typography.dart';
import 'package:gstore/core/request_debug/request_debug.dart';

/// 「请求调试」工作台分区（plan todo 30）。
enum RequestDebugSection {
  /// 集合（收藏的请求 / 文件夹树）。todo 31 深化。
  collections,

  /// 历史（发送记录）。todo 32 深化。
  history,

  /// 环境（`{{var}}` 变量表）。todo 33 深化。
  environments,

  /// 改写规则（Rust 引擎捕获改写）。todo 34 深化。
  rules,
}

/// 「请求调试」原生工作台页（Postman-like，非 it-tools WebView 内）。
///
/// 本页（plan todo 30）只搭骨架：顶部 [AppSegmentedButton] 4 分区
/// `集合 / 历史 / 环境 / 改写规则` + 各分区空态 / 极简列表；分区内容由
/// todos 31-34 深化。门面经构造函数注入（[facade] 默认
/// [DefaultRequestDebugFacade.production]），测试注入假 store / 端口，
/// 不触碰原生 FFI。
///
/// 设计约束：全部取主题令牌（[Theme.of]），颜色 / 字号零硬编码；空态图标用
/// [ColoredAliIcon] 染色以适配夜间模式。
class RequestDebugPage extends StatefulWidget {
  const RequestDebugPage({super.key, this.facade});

  /// 窄门面（测试可注入；为空时用生产组合）。
  final RequestDebugFacade? facade;

  @override
  State<RequestDebugPage> createState() => _RequestDebugPageState();
}

class _RequestDebugPageState extends State<RequestDebugPage> {
  late final RequestDebugFacade _facade;

  RequestDebugSection _section = RequestDebugSection.collections;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _facade = widget.facade ?? DefaultRequestDebugFacade.production();
    unawaited(_load());
  }

  Future<void> _load() async {
    // store 语义：损坏降级为空、不抛；页面仅需完成后重绘。
    await _facade.load();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('请求调试')),
      body: Column(
        children: [
          _buildSectionSwitch(context),
          const Divider(height: 1),
          Expanded(child: _buildSectionBody(context)),
        ],
      ),
    );
  }

  /// 顶部 4 分区切换（复用设计系统 [AppSegmentedButton]/[AppSegment]）。
  Widget _buildSectionSwitch(BuildContext context) {
    return Padding(
      padding: AppSpacing.allLG,
      child: Align(
        alignment: Alignment.centerLeft,
        // 窄屏可横向滚动，避免 4 分区在手机上溢出。
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: AppSegmentedButton<RequestDebugSection>(
            key: const Key('request-debug-section-switch'),
            value: _section,
            density: AppSegmentedButton.mediumDensity,
            segments: const <AppSegment<RequestDebugSection>>[
              AppSegment(
                value: RequestDebugSection.collections,
                label: '集合',
                key: Key('request-debug-segment-collections'),
              ),
              AppSegment(
                value: RequestDebugSection.history,
                label: '历史',
                key: Key('request-debug-segment-history'),
              ),
              AppSegment(
                value: RequestDebugSection.environments,
                label: '环境',
                key: Key('request-debug-segment-environments'),
              ),
              AppSegment(
                value: RequestDebugSection.rules,
                label: '改写规则',
                key: Key('request-debug-segment-rules'),
              ),
            ],
            onChanged: (section) => setState(() => _section = section),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionBody(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }
    final store = _facade.store;
    switch (_section) {
      case RequestDebugSection.collections:
        if (store.collections.isEmpty) {
          return _empty(
            context,
            icon: TablerIcons.folder,
            title: '暂无集合',
            message: '还没有请求集合，导入 cURL 或新建集合开始。',
          );
        }
        return ListView.builder(
          padding: AppSpacing.onlyVerticalSM,
          itemCount: store.collections.length,
          itemBuilder: (context, index) {
            final c = store.collections[index];
            return _sectionTile(
              context,
              icon: TablerIcons.folder,
              title: c.name,
              subtitle: '${c.requests.length} 个请求',
              key: ValueKey<String>('request-debug-collection-${c.id}'),
            );
          },
        );

      case RequestDebugSection.history:
        if (store.history.isEmpty) {
          return _empty(
            context,
            icon: TablerIcons.history,
            title: '暂无历史',
            message: '发送请求后，历史记录会出现在这里。',
          );
        }
        return ListView.builder(
          padding: AppSpacing.onlyVerticalSM,
          itemCount: store.history.length,
          itemBuilder: (context, index) {
            final h = store.history[index];
            return _sectionTile(
              context,
              icon: TablerIcons.history,
              title: '${h.request.method} ${h.request.url}',
              subtitle: h.responseSummary.error ??
                  (h.responseSummary.statusCode?.toString() ?? ''),
              key: ValueKey<String>('request-debug-history-${h.id}'),
            );
          },
        );

      case RequestDebugSection.environments:
        if (store.environments.isEmpty) {
          return _empty(
            context,
            icon: TablerIcons.variable,
            title: '暂无环境',
            message: '创建环境后可集中管理 {{变量}}。',
          );
        }
        return ListView.builder(
          padding: AppSpacing.onlyVerticalSM,
          itemCount: store.environments.length,
          itemBuilder: (context, index) {
            final e = store.environments[index];
            return _sectionTile(
              context,
              icon: TablerIcons.variable,
              title: e.name,
              subtitle: '${e.vars.length} 个变量',
              key: ValueKey<String>('request-debug-environment-${e.id}'),
            );
          },
        );

      case RequestDebugSection.rules:
        if (store.rules.isEmpty) {
          return _empty(
            context,
            icon: TablerIcons.replace,
            title: '暂无改写规则',
            message: '添加改写规则以修改匹配请求的响应。',
          );
        }
        return ListView.builder(
          padding: AppSpacing.onlyVerticalSM,
          itemCount: store.rules.length,
          itemBuilder: (context, index) {
            final r = store.rules[index];
            return _sectionTile(
              context,
              icon: TablerIcons.replace,
              title: r.url,
              subtitle: r.remark ?? (r.enabled ? '已启用' : '未启用'),
              key: ValueKey<String>('request-debug-rule-${r.id}'),
            );
          },
        );
    }
  }

  /// 分区内极简列表行（分割线由 ListView 默认绘制；图标染色适配夜间模式）。
  Widget _sectionTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    Key? key,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: key,
      leading: ColoredAliIcon(
        icon: icon,
        size: AppTypography.iconMD,
        color: scheme.primary,
      ),
      title: Text(title),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
    );
  }

  /// 空态（store 为空时各分区展示）。
  Widget _empty(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String message,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: AppSpacing.allXL,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredAliIcon(
              icon: icon,
              size: AppTypography.iconXXXL,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

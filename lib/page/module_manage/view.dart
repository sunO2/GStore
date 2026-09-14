import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';

import 'logic.dart';
import 'state.dart';

/// 模块管理页（Riverpod）
///
/// 9 个可开关业务模块（SwitchListTile，切换经 toggle 持久化 + 运行时上下线）
/// + 8 个系统模块置灰（Switch 禁用，不可关闭）。
/// 订阅 [ModuleManager.onChange] 实时刷新。
class ModuleManagePage extends ConsumerWidget {
  const ModuleManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(moduleManageProvider);

    final business = state.entries.where((e) => e.togglable).toList();
    final system = state.entries.where((e) => !e.togglable).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('模块管理'),
      ),
      body: state.loading
          ? const Center(child: AppLoading(size: AppLoadingSize.medium))
          : ListView(
              children: [
                _buildSectionHeader(context, '业务模块'),
                Card(
                  margin: AppSpacing.allLG,
                  child: Column(
                    children: [
                      for (var i = 0; i < business.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _buildBusinessTile(context, ref, business[i]),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                _buildSectionHeader(context, '系统模块'),
                Card(
                  margin: AppSpacing.allLG,
                  child: Column(
                    children: [
                      for (var i = 0; i < system.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        _buildSystemTile(context, system[i]),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                _buildRustSectionHeader(context, ref),
                _buildRustPluginsCard(context, ref),
              ],
            ),
    );
  }

  /// 原生插件（Rust）分组标题 + 刷新
  Widget _buildRustSectionHeader(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Row(
        children: [
          Expanded(
            child: Text(
              '原生插件 (Rust)',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: AppTypography.weightMedium,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: AppTypography.iconSM),
            tooltip: '刷新状态',
            onPressed: () => ref.invalidate(rustPluginStatusProvider),
          ),
        ],
      ),
    );
  }

  /// 原生插件（Rust）只读状态卡片：产物来源 + 是否已加载
  Widget _buildRustPluginsCard(BuildContext context, WidgetRef ref) {
    final async = ref.watch(rustPluginStatusProvider);
    return Card(
      margin: AppSpacing.allLG,
      child: async.when(
        // 加载态用静态占位（不用动画指示器，避免测试 pumpAndSettle 永不稳定）
        loading: () => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: Text('读取中…')),
        ),
        error: (e, _) => ListTile(
          leading: const Icon(Icons.error_outline),
          title: const Text('状态读取失败'),
          subtitle: Text('$e'),
        ),
        data: (statuses) => Column(
          children: [
            for (var i = 0; i < rustPlugins.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              _buildRustPluginTile(context, statuses, rustPlugins[i]),
            ],
          ],
        ),
      ),
    );
  }

  /// 单个原生插件状态行
  Widget _buildRustPluginTile(
    BuildContext context,
    List<RustModuleStatus> statuses,
    ({String name, String title, String description}) plugin,
  ) {
    RustModuleStatus? s;
    for (final item in statuses) {
      if (item.name == plugin.name) {
        s = item;
        break;
      }
    }
    final loaded = s?.loaded ?? false;
    final scheme = Theme.of(context).colorScheme;
    final localVer = s?.version;
    final loadedVer = s?.loadedVersion;

    final sourceText = s == null
        ? '状态未知'
        : '产物: ${s.sourceLabel}'
            '${localVer != null && localVer.isNotEmpty ? ' · 本地 $localVer' : ''}';

    return ListTile(
      leading: Icon(
        Icons.extension_outlined,
        size: AppTypography.iconMD,
        color: loaded ? scheme.primary : scheme.outline,
      ),
      title: Text('${plugin.title} · ${plugin.name}'),
      subtitle: Text('${plugin.description}\n$sourceText'),
      isThreeLine: true,
      trailing: _buildRustStatusChip(context, loaded, loadedVer),
    );
  }

  /// 状态徽标：已加载(带版本) / 未加载
  Widget _buildRustStatusChip(BuildContext context, bool loaded, int? version) {
    final scheme = Theme.of(context).colorScheme;
    final color = loaded ? scheme.primary : scheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.circle),
      ),
      child: Text(
        loaded ? '已加载${version != null ? ' v$version' : ''}' : '未加载',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: AppSpacing.onlyHorizontalLG,
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: AppTypography.weightMedium,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }

  /// 可开关业务模块：SwitchListTile（切换中置灰防连击）
  Widget _buildBusinessTile(
    BuildContext context,
    WidgetRef ref,
    ModuleEntry entry,
  ) {
    final notifier = ref.read(moduleManageProvider.notifier);
    final toggling = ref.watch(
      moduleManageProvider.select((s) => s.toggling.contains(entry.name)),
    );
    return SwitchListTile(
      secondary: Icon(
        _iconOf(entry.name),
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(entry.title),
      subtitle: Text(_subtitleOf(entry)),
      value: entry.enabled,
      onChanged:
          toggling ? null : (value) => notifier.toggle(entry.name, value),
    );
  }

  /// 系统模块：Switch 禁用置灰（不可关）
  Widget _buildSystemTile(BuildContext context, ModuleEntry entry) {
    return SwitchListTile(
      secondary: Icon(
        Icons.lock_outline,
        size: AppTypography.iconMD,
        color: Theme.of(context).colorScheme.outline,
      ),
      title: Text(entry.title),
      subtitle: Text('${entry.description} · ${entry.note}'),
      value: entry.enabled,
      onChanged: null, // 系统模块不可关
    );
  }

  /// 描述 + 依赖展示
  String _subtitleOf(ModuleEntry entry) {
    final deps = entry.dependencies;
    final depText = deps.isEmpty ? '' : ' · 依赖: ${deps.join(', ')}';
    return '${entry.description}$depText';
  }

  /// 模块名 → 图标
  IconData _iconOf(String name) => switch (name) {
        'channel' => Icons.storage,
        'download' => Icons.download,
        'backup' => Icons.backup,
        'webdav' => Icons.cloud,
        'fdroid' => Icons.source,
        'theme' => Icons.palette_outlined,
        'install' => Icons.system_update_alt,
        'aggregate' => Icons.apps,
        'agent_tools' => Icons.smart_toy_outlined,
        _ => Icons.extension,
      };
}

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
            onPressed: () => ref.read(rustPluginsProvider.notifier).refresh(),
          ),
        ],
      ),
    );
  }

  /// 原生插件（Rust）状态卡片：来源/版本 + 下载/更新 + 回退到内置
  Widget _buildRustPluginsCard(BuildContext context, WidgetRef ref) {
    final state = ref.watch(rustPluginsProvider);
    return Card(
      margin: AppSpacing.allLG,
      child: state.loading
          // 加载态用静态占位（不用动画指示器，避免测试 pumpAndSettle 永不稳定）
          ? const Padding(
              padding: AppSpacing.allXXL,
              child: Center(child: Text('读取中…')),
            )
          : Column(
              children: [
                for (var i = 0; i < rustPlugins.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _buildRustPluginTile(context, ref, state, rustPlugins[i]),
                ],
              ],
            ),
    );
  }

  /// 单个原生插件状态行（版本 + 操作）
  Widget _buildRustPluginTile(
    BuildContext context,
    WidgetRef ref,
    RustPluginsState state,
    ({String name, String title, String description}) plugin,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = state.statusOf(plugin.name);
    final loaded = status?.loaded ?? false;
    final localVer = status?.version;
    final loadedVer = status?.loadedVersion;
    final remoteVer = status?.remoteVersion;
    final hasDownloaded = status?.hasDownloaded ?? false;
    final quarantined = status?.quarantined ?? false;
    // 下载目录有产物但无有效项（隔离或 .meta/哈希校验失败）→ 不可当作可用下载。
    final downloadedBlocked =
        hasDownloaded && (status?.source == 'none');
    final busy = state.isBusy(plugin.name);
    final progress = state.progressOf(plugin.name);
    final opError = state.errorOf(plugin.name);

    final sourceText = status == null
        ? '状态未知'
        : '产物: ${status.sourceLabel}'
            '${localVer != null && localVer.isNotEmpty ? ' · 本地 $localVer' : ''}'
            '${remoteVer != null && remoteVer.isNotEmpty ? ' · 远端 $remoteVer' : ''}';

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.extension_outlined,
                size: AppTypography.iconMD,
                color: loaded ? scheme.primary : scheme.outline,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${plugin.title} · ${plugin.name}',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '${plugin.description}\n$sourceText',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _buildRustStatusChip(context, loaded, loadedVer),
            ],
          ),
          if (downloadedBlocked) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              quarantined
                  ? '该模块的已下载文件已被隔离（挂载校验未通过），当前不可用。'
                      '可回退到内置或清除后重试。'
                  : '该模块的已下载文件无效（缺少或校验未通过的 .meta），当前不可用。'
                      '可回退到内置或清除后重试。',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (busy)
                const AppLoading(size: AppLoadingSize.small)
              else
                _buildDownloadAction(
                  ref,
                  plugin.name,
                  status,
                  downloadedBlocked,
                ),
              _buildRollbackAction(context, ref, plugin.name, hasDownloaded, busy),
            ],
          ),
          // 内部下载进度（不进用户下载管线）：下载中显示确定进度条 + 百分比。
          if (busy && progress != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _buildInternalProgress(context, progress),
          ],
          // 内部下载/更新错误：页面可见提示（不走系统通知/下载中心）。
          if (opError != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _buildErrorLine(context, opError),
          ],
        ],
      ),
    );
  }

  /// 内部下载进度条 + 百分比（`AppLoading` 仍在按钮区表示 busy）。
  Widget _buildInternalProgress(
    BuildContext context,
    ModuleDownloadProgress progress,
  ) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: AppRadius.allSM,
          child: LinearProgressIndicator(value: progress.fraction),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '下载中 ${progress.percent}%',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// 内部下载/更新错误行（主题 error 色，页面可见）。
  Widget _buildErrorLine(BuildContext context, String message) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.error_outline,
          size: AppTypography.iconSM,
          color: theme.colorScheme.error,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }

  /// 「下载 / 更新」按钮：有可解析远端版本且未被隔离/无效产物阻塞时可用。
  Widget _buildDownloadAction(
    WidgetRef ref,
    String name,
    RustModuleStatus? status,
    bool downloadedBlocked,
  ) {
    final remoteVer = status?.remoteVersion;
    final canDownload = !downloadedBlocked &&
        remoteVer != null &&
        remoteVer.isNotEmpty;
    final hasUpdate = status?.updateAvailable ?? false;
    return FilledButton.tonal(
      onPressed: canDownload
          ? () => ref.read(rustPluginsProvider.notifier).download(name)
          : null,
      child: Text(hasUpdate ? '更新' : '下载'),
    );
  }

  /// 「回退到内置 / 清除已下载」按钮：存在下载产物时可用。
  Widget _buildRollbackAction(
    BuildContext context,
    WidgetRef ref,
    String name,
    bool hasDownloaded,
    bool busy,
  ) {
    return OutlinedButton(
      onPressed: (!busy && hasDownloaded)
          ? () => _confirmRollback(context, ref, name)
          : null,
      child: const Text('回退到内置'),
    );
  }

  /// 危险操作确认：统一底部弹层（`showConfirmSheet(isDangerous: true)`）。
  Future<void> _confirmRollback(
    BuildContext context,
    WidgetRef ref,
    String name,
  ) async {
    final confirmed = await AppDialogs.showConfirmSheet(
      title: '回退到内置',
      message: '将清除模块 $name 的已下载文件并回退到应用内置版本，确定继续吗？',
      confirmText: '回退',
      isDangerous: true,
    );
    if (confirmed != true) return;
    if (!context.mounted) return;
    await ref.read(rustPluginsProvider.notifier).rollback(name);
  }

  /// 状态徽标：已加载(带版本) / 未加载
  Widget _buildRustStatusChip(BuildContext context, bool loaded, int? version) {
    final scheme = Theme.of(context).colorScheme;
    final color = loaded ? scheme.primary : scheme.outline;
    return Container(
      padding: AppSpacing.horizontalSM_verticalXS,
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

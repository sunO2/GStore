/// F-Droid 仓库管理页面 UI
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/page/fdroid_repo/logic.dart';
import 'package:gstore/page/fdroid_repo/state.dart';

/// F-Droid 仓库管理页面
class FdroidRepoPage extends ConsumerStatefulWidget {
  const FdroidRepoPage({super.key});

  @override
  ConsumerState<FdroidRepoPage> createState() => _FdroidRepoPageState();
}

class _FdroidRepoPageState extends ConsumerState<FdroidRepoPage> {
  /// 页面控制器与状态（build 时从 ref 取，供各构建子方法使用）
  FdroidRepoNotifier get notifier => ref.read(fdroidRepoProvider.notifier);
  FdroidRepoState get state => ref.watch(fdroidRepoProvider);

  @override
  void initState() {
    super.initState();
    // 首次挂载初始化（等价原 GetX onInit；幂等，重复调用自动跳过）
    Future.microtask(
      () => ref.read(fdroidRepoProvider.notifier).start(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('F-Droid 仓库管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearchDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: state.isLoading ? null : notifier.checkAndUpdate,
          ),
        ],
      ),
      body: state.isLoading && state.loadingProgress < 100
          ? _buildLoadingView(state)
          : _buildContentView(context),
    );
  }

  /// 构建加载视图
  Widget _buildLoadingView(FdroidRepoState state) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const AppLoading(size: AppLoadingSize.medium),
          SizedBox(height: AppSpacing.lg),
          Text('加载中... ${state.loadingProgress.toInt()}%'),
        ],
      ),
    );
  }

  /// 构建内容视图
  Widget _buildContentView(BuildContext context) {
    final state = this.state;
    return RefreshIndicator(
      onRefresh: notifier.checkAndUpdate,
      child: ListView(
        padding: AppSpacing.allLG,
        children: [
          // 当前源卡片
          _buildCurrentSourceCard(context, state),

          SizedBox(height: AppSpacing.lg),

          // 统计信息卡片
          _buildStatisticsCard(state),

          SizedBox(height: AppSpacing.lg),

          // 更新信息卡片
          _buildUpdateCard(state),

          SizedBox(height: AppSpacing.lg),

          // 操作按钮
          _buildActionButtons(context, state),

          SizedBox(height: AppSpacing.lg),

          // 源列表
          _buildSourcesList(context, state),

          SizedBox(height: AppSpacing.lg),

          // 搜索结果
          if (state.searchResults.isNotEmpty)
            _buildSearchResults(context, state),
        ],
      ),
    );
  }

  /// 构建当前源卡片
  Widget _buildCurrentSourceCard(BuildContext context, FdroidRepoState state) {
    final currentSource = state.currentSource;

    return Card(
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '当前源',
                  style: TextStyle(fontSize: AppTypography.sizeLG, fontWeight: AppTypography.weightBold),
                ),
                if (state.hasUpdate)
                  Container(
                    padding: AppSpacing.horizontalSM_verticalXS,
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      borderRadius: AppRadius.allMD,
                    ),
                    child: const Text(
                      '有更新',
                      style: TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
              ],
            ),
            SizedBox(height: AppSpacing.sm),
            if (currentSource != null) ...[
              Text(
                currentSource.name,
                style: TextStyle(fontSize: AppTypography.sizeMD, fontWeight: AppTypography.weightMedium),
              ),
              SizedBox(height: AppSpacing.xs),
              Text(
                currentSource.repoUrl,
                style: TextStyle(fontSize: AppTypography.sizeXS, color: AppColors.grey600),
              ),
              // 索引声明的元信息（名称/镜像数/完整性校验）——由模块 get_repo_meta 回填
              if (state.repoMeta != null) ...[
                SizedBox(height: AppSpacing.xs),
                Text(
                  _repoMetaLine(state.repoMeta!),
                  style: TextStyle(fontSize: AppTypography.sizeXS, color: AppColors.grey600),
                ),
              ],
            ] else ...[
              const Text('未选择源', style: TextStyle(color: Colors.grey)),
            ],
          ],
        ),
      ),
    );
  }

  /// 构建统计信息卡片
  Widget _buildStatisticsCard(FdroidRepoState state) {
    final apps = state.statistics['apps'] ?? 0;
    final packages = state.statistics['packages'] ?? 0;

    return Card(
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '数据库统计',
              style: TextStyle(fontSize: AppTypography.sizeLG, fontWeight: AppTypography.weightBold),
            ),
            SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem('应用', apps),
                _buildStatItem('包', packages),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 构建统计项
  Widget _buildStatItem(String label, int value) {
    return Column(
      children: [
        Text(
          value.toString(),
          style: TextStyle(fontSize: AppTypography.sizeXXL, fontWeight: AppTypography.weightBold),
        ),
        Text(
          label,
          style: TextStyle(fontSize: AppTypography.sizeXS, color: AppColors.grey600),
        ),
      ],
    );
  }

  /// 构建更新信息卡片
  Widget _buildUpdateCard(FdroidRepoState state) {
    if (!state.hasUpdate) {
      return const SizedBox.shrink();
    }

    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '发现新版本',
                  style: TextStyle(fontSize: AppTypography.sizeMD, fontWeight: AppTypography.weightSemiBold),
                ),
                Text(
                  'v${state.currentVersion} → v${state.latestVersion}',
                  style: TextStyle(color: AppColors.warning, fontWeight: AppTypography.weightMedium),
                ),
              ],
            ),
            SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: notifier.checkAndUpdate,
              child: const Text('立即更新'),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建操作按钮
  Widget _buildActionButtons(BuildContext context, FdroidRepoState state) {
    return Card(
      child: Padding(
        padding: AppSpacing.allLG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.download),
              label: const Text('加载/重新加载数据'),
              onPressed: state.isLoading ? null : notifier.loadAllSources,
            ),
            SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: const Text('清空数据'),
              onPressed: state.isLoading ? null : notifier.clearData,
            ),
          ],
        ),
      ),
    );
  }

  /// 构建源列表
  Widget _buildSourcesList(BuildContext context, FdroidRepoState state) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: AppSpacing.allLG,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '可用源',
                  style: TextStyle(fontSize: AppTypography.sizeLG, fontWeight: AppTypography.weightBold),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => notifier.addSource(context),
                  tooltip: '添加自定义源',
                ),
              ],
            ),
          ),
          Divider(height: 1),
          ...state.sources.map((source) {
            final isSelected = state.currentSource?.id == source.id;
            // 副标题展示地址 + （有则）镜像数/已固定指纹：第三方源的身份与可用性一眼可见
            final meta = <String>[
              source.repoUrl,
              if (source.mirrors.isNotEmpty) '镜像 ${source.mirrors.length}',
              if (source.fingerprint != null && source.fingerprint!.isNotEmpty)
                '指纹已固定 ${_shortFingerprint(source.fingerprint!)}',
            ].join(' · ');
            return ListTile(
              title: Text(source.name),
              subtitle: Text(meta),
              isThreeLine: source.fingerprint != null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 多源：勾选 = 是否启用（可同时启用多个），不再单选
                  Checkbox(
                    value: source.enabled,
                    onChanged: (v) => notifier.setSourceEnabled(source, v ?? false),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    onSelected: (v) {
                      if (v == 'mirrors') {
                        notifier.configureMirrors(context, source);
                      } else if (v == 'edit') {
                        notifier.editSource(context, source);
                      } else if (v == 'delete') {
                        notifier.deleteSource(context, source);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'mirrors', child: Text('配置镜像')),
                      PopupMenuItem(value: 'edit', child: Text('编辑源')),
                      PopupMenuItem(value: 'delete', child: Text('删除源')),
                    ],
                  ),
                ],
              ),
              onTap: () => notifier.switchSource(source),
            );
          }).toList(),
        ],
      ),
    );
  }

  /// 构建搜索结果
  Widget _buildSearchResults(BuildContext context, FdroidRepoState state) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: AppSpacing.allLG,
            child: Text(
              '搜索结果 (${state.searchResults.length})',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          if (notifier.availableCategories.isNotEmpty ||
              notifier.onlyCompatible ||
              notifier.hideAntiFeature ||
              notifier.categoryFilter != null)
            Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
              child: Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  FilterChip(
                    label: const Text('仅兼容本机'),
                    selected: notifier.onlyCompatible,
                    onSelected: notifier.setOnlyCompatible,
                  ),
                  FilterChip(
                    label: const Text('隐藏含抗特性'),
                    selected: notifier.hideAntiFeature,
                    onSelected: notifier.setHideAntiFeature,
                  ),
                  for (final c in notifier.availableCategories)
                    FilterChip(
                      label: Text(c),
                      selected: notifier.categoryFilter == c,
                      onSelected: (on) =>
                          notifier.setCategoryFilter(on ? c : null),
                    ),
                ],
              ),
            ),
          Divider(height: 1),
          ...state.searchResults.map((app) {
            return ListTile(
              title: Text(app.name),
              subtitle: Text(app.packageName),
              trailing: Text(app.summary, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => notifier.openAppDetail(app),
            );
          }).toList(),
        ],
      ),
    );
  }

  /// 显示搜索弹层（统一底部 sheet 风格）
  void _showSearchDialog(BuildContext context) {
    AppSheet.show<void>(
      context: context,
      title: '搜索应用',
      contentPadding: AppSpacing.onlyHorizontalXL,
      content: TextField(
        controller: notifier.searchController,
        decoration: const InputDecoration(
          hintText: '输入应用名称或包名',
          prefixIcon: Icon(Icons.search),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            notifier.searchApps(notifier.searchController.text);
            Navigator.of(context).pop();
          },
          child: const Text('搜索'),
        ),
      ],
    );
  }

  /// 指纹短展示（完整值在「添加源」对话框里核对；此处只做身份提示）
  String _shortFingerprint(String fp) {
    final clean = fp.replaceAll(':', '').toUpperCase();
    if (clean.length <= 16) return clean;
    return '${clean.substring(0, 8)}…${clean.substring(clean.length - 8)}';
  }

  /// 索引声明的仓库元信息一行文案（无可用字段时返回空串，由调用方折叠）
  String _repoMetaLine(Map<String, dynamic> meta) {
    final parts = <String>[];
    final name = (meta['name'] as String?) ?? '';
    if (name.isNotEmpty) parts.add('索引名称 $name');
    final mirrors = meta['mirrors'];
    if (mirrors is List && mirrors.isNotEmpty) parts.add('镜像 ${mirrors.length}');
    final resolved = (meta['resolved_url'] as String?) ?? '';
    final declared = (meta['declared_url'] as String?) ?? '';
    if (resolved.isNotEmpty && declared.isNotEmpty && resolved != declared) {
      parts.add('实际地址 $resolved');
    }
    parts.add(meta['verified'] == true ? 'SHA-256 已校验' : '未校验');
    final fails = (meta['fail_count'] as num?)?.toInt() ?? 0;
    if (fails > 0) parts.add('连续失败 $fails 次');
    return parts.join(' · ');
  }
}
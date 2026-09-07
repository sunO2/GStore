import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// SDK 分析页：LibChecker 式分组展示 APK 内嵌第三方 SDK 检测结果。
///
/// 进入页面即并行发起三路分析（原生 .so / DEX 类名 / Manifest 组件），
/// 完成后按分析类型分组以列表展示，替代原先的对话框方案。
class SdkAnalysisPage extends StatefulWidget {
  const SdkAnalysisPage({
    super.key,
    required this.app,
    required this.sourceDir,
  });

  /// 被分析的应用
  final installed.AppInfo app;

  /// 应用 APK 路径（sourceDir）
  final String sourceDir;

  @override
  State<SdkAnalysisPage> createState() => _SdkAnalysisPageState();
}

class _SdkAnalysisPageState extends State<SdkAnalysisPage> {
  bool _loading = true;
  List<NativeLibraryHit> _nativeHits = const [];
  List<DexLibraryHit> _dexHits = const [];
  List<ComponentLibraryHit> _componentHits = const [];

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  /// 三路并行分析；分析器内部优雅降级为空列表，不会抛给调用方。
  Future<void> _analyze() async {
    final results = await (
      ApkLibraryAnalyzer.instance.analyzeNativeLibraries(widget.sourceDir),
      ApkLibraryAnalyzer.instance.analyzeDexLibraries(widget.sourceDir),
      ApkLibraryAnalyzer.instance.analyzeComponents(widget.sourceDir),
    ).wait;
    if (!mounted) return;
    setState(() {
      _nativeHits = results.$1;
      _dexHits = results.$2;
      _componentHits = results.$3;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SDK 分析')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 应用信息头部（名称 + 包名）
        Padding(
          padding: AppSpacing.onlyHorizontalMD,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.app.name,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: AppTypography.weightSemiBold,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                widget.app.packageName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(child: _buildResultArea(context)),
      ],
    );
  }

  Widget _buildResultArea(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }

    final groups = _buildGroups();
    if (groups.isEmpty) {
      return Center(
        child: Text(
          '未检测到已知 SDK',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: groups,
    );
  }

  /// 依次构建三路分组；空分组跳过，全空时返回空列表。
  List<Widget> _buildGroups() {
    final groups = <Widget>[];
    if (_nativeHits.isNotEmpty) {
      groups.add(
        _buildGroup(
          icon: Icons.memory,
          title: '原生库 (.so)',
          count: _nativeHits.length,
          items: [
            for (final hit in _nativeHits)
              _buildItem(hit, icon: Icons.memory, matchedName: hit.soFileName),
          ],
        ),
      );
    }
    if (_dexHits.isNotEmpty) {
      groups.add(
        _buildGroup(
          icon: Icons.code,
          title: 'DEX 类名',
          count: _dexHits.length,
          items: [
            for (final hit in _dexHits)
              _buildItem(
                hit,
                icon: Icons.code,
                matchedName: hit.matchedClassName,
              ),
          ],
        ),
      );
    }
    if (_componentHits.isNotEmpty) {
      groups.add(
        _buildGroup(
          icon: Icons.view_module,
          title: '组件',
          count: _componentHits.length,
          items: [
            for (final hit in _componentHits)
              _buildItem(
                hit,
                icon: Icons.view_module,
                matchedName: hit.componentName,
              ),
          ],
        ),
      );
    }
    return groups;
  }

  /// 分组：头部（图标 + 标题 + 数量徽标）+ 命中项列表
  Widget _buildGroup({
    required IconData icon,
    required String title,
    required int count,
    required List<Widget> items,
  }) {
    return Padding(
      padding: AppSpacing.onlyBottomLG,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildGroupHeader(icon: icon, title: title, count: count),
          const SizedBox(height: AppSpacing.xs),
          ...items,
        ],
      ),
    );
  }

  Widget _buildGroupHeader({
    required IconData icon,
    required String title,
    required int count,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: AppSpacing.onlyHorizontalMD,
      child: Row(
        children: [
          Icon(icon, size: AppTypography.iconMD, color: colorScheme.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              title,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: AppTypography.weightSemiBold,
              ),
            ),
          ),
          Container(
            padding: AppSpacing.chipPadding,
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(AppRadius.circle),
            ),
            child: Text(
              '$count',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 单个命中项：图标 + label（标题行）+ 匹配名（等宽副标题）+ 正则标签
  Widget _buildItem(
    LibraryHit hit, {
    required IconData icon,
    required String matchedName,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: AppSpacing.horizontalLG_verticalSM,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: AppSpacing.onlyTopXS,
            child: Icon(
              icon,
              size: AppTypography.iconSM,
              color: hit.isRegex ? colorScheme.tertiary : colorScheme.primary,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        hit.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium,
                      ),
                    ),
                    if (hit.isRegex) ...[
                      const SizedBox(width: AppSpacing.xs),
                      _buildRegexTag(context),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  matchedName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 「正则」小标签（secondaryContainer 药丸）
  Widget _buildRegexTag(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        '正则',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSecondaryContainer,
            ),
      ),
    );
  }
}

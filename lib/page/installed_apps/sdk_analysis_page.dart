import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// SDK 分析页：LibChecker 式分组展示 APK 内嵌第三方 SDK 检测结果。
///
/// 进入页面即并行发起三路分析（原生 .so / DEX 类名 / Manifest 组件）与
/// 应用详细信息收集（权限 / ABI / minSdk / targetSdk），
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

  /// 声明的权限列表（获取失败为空列表）
  List<String> _permissions = const [];

  /// 原生库 ABI 架构列表（获取失败为空列表）
  List<String> _abis = const [];

  /// minSdk（Rust 解析失败为空字符串，渲染为「未知」）
  String _minSdk = '';

  /// targetSdk（Rust 解析失败为空字符串，渲染为「未知」）
  String _targetSdk = '';

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  /// 三路并行分析 + 应用详情收集；分析器内部优雅降级为空，不会抛给调用方。
  Future<void> _analyze() async {
    // Rust 通道不可用时解析失败 → 降级为空字符串，绝不抛给调用方。
    final sdkF = () async {
      try {
        final components =
            await FdroidRustRepoManager.parseComponents(widget.sourceDir);
        return (components.minSdk, components.targetSdk);
      } catch (e) {
        appLog.error('SdkAnalysisPage: 解析 SDK 版本失败（降级为空） - $e');
        return ('', '');
      }
    }();

    final results = await (
      ApkLibraryAnalyzer.instance.analyzeNativeLibraries(widget.sourceDir),
      ApkLibraryAnalyzer.instance.analyzeDexLibraries(widget.sourceDir),
      ApkLibraryAnalyzer.instance.analyzeComponents(widget.sourceDir),
      ApkSourceService.instance.getPermissions(widget.app.packageName),
      ApkLibraryAnalyzer.instance.listNativeAbis(widget.sourceDir),
      sdkF,
    ).wait;
    if (!mounted) return;
    setState(() {
      _nativeHits = results.$1;
      _dexHits = results.$2;
      _componentHits = results.$3;
      _permissions = results.$4;
      _abis = results.$5;
      _minSdk = results.$6.$1;
      _targetSdk = results.$6.$2;
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
    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        _buildDetailsSection(context),
        if (groups.isEmpty)
          Padding(
            padding: AppSpacing.onlyHorizontalMD,
            child: Text(
              '未检测到已知 SDK',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          )
        else
          ...groups,
      ],
    );
  }

  /// 应用详细信息区：键值行 + ABI chips + 权限 chips。
  /// 数据缺失/为空时降级展示（路径与 SDK 版本「未知」、权限「无权限声明」）。
  Widget _buildDetailsSection(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    final rows = <(String, String)>[
      ('包名', widget.app.packageName),
      ('版本', '${widget.app.versionName} (${widget.app.versionCode})'),
      ('安装路径', widget.sourceDir),
      ('minSdk', _minSdk.isEmpty ? '未知' : _minSdk),
      ('targetSdk', _targetSdk.isEmpty ? '未知' : _targetSdk),
    ];

    final labelStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final valueStyle = textTheme.bodySmall;

    return Padding(
      padding: AppSpacing.onlyHorizontalMD,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(label, style: labelStyle),
                  ),
                  Expanded(
                    child: Text(
                      value,
                      style: valueStyle,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (_abis.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text('ABI 架构', style: labelStyle),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final abi in _abis)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(abi, style: textTheme.labelMedium),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Text('权限（${_permissions.length}）', style: labelStyle),
          const SizedBox(height: AppSpacing.xs),
          if (_permissions.isEmpty)
            Text('无权限声明', style: textTheme.bodySmall)
          else
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final permission in _permissions)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      permission,
                      style: textTheme.labelSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
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

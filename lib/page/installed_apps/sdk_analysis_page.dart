import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// SDK 分析页：LibChecker 式多 Tab 分类展示 APK 内嵌第三方 SDK 检测结果。
///
/// 进入页面即并行发起三路分析（原生 .so / DEX 类名 / Manifest 组件）与
/// 应用详细信息收集（权限 / ABI / minSdk / targetSdk），
/// 完成后按 概览 / 原生库 / DEX 类名 / 组件 / 权限 五个 Tab 分类展示
/// （参考 LibChecker 的 tab 分类形式；组件进一步按 LibType 分组）。
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

  /// 组件类型展示名（对齐 LibChecker LibType：SERVICE=1 / ACTIVITY=2 /
  /// RECEIVER=3 / PROVIDER=4，参考 ComponentAnalysisFragment 的按类型分组）。
  static const Map<int, String> _componentTypeLabels = {
    1: 'Service',
    2: 'Activity',
    3: 'Receiver',
    4: 'Provider',
  };

  /// 组件命中按 componentType 分组（顺序 Service→Activity→Receiver→Provider，
  /// 空类型跳过）。UI 与测试共用同一分组逻辑。
  @visibleForTesting
  static List<({int type, String label, List<ComponentLibraryHit> items})>
      groupComponentsByType(List<ComponentLibraryHit> hits) {
    final groups =
        <({int type, String label, List<ComponentLibraryHit> items})>[];
    for (final type in const [1, 2, 3, 4]) {
      final items = [
        for (final hit in hits)
          if (hit.componentType == type) hit,
      ];
      if (items.isEmpty) continue;
      groups.add((
        type: type,
        label: _componentTypeLabels[type] ?? '$type',
        items: items,
      ));
    }
    return groups;
  }

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

  /// 结果区：加载中显示 loading；加载完成后以五个 Tab 分类展示。
  Widget _buildResultArea(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }

    return DefaultTabController(
      length: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              _buildTab(Icons.info_outline, '概览'),
              _buildTab(Icons.memory, '原生库'),
              _buildTab(Icons.code, 'DEX 类名'),
              _buildTab(Icons.view_module, '组件'),
              _buildTab(Icons.lock_outline, '权限'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _buildOverviewTab(context),
                _buildNativeTab(),
                _buildDexTab(),
                _buildComponentTab(),
                _buildPermissionTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tab 标签：图标 + 文字（横向紧凑排布）。
  Widget _buildTab(IconData icon, String label) {
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: AppTypography.iconSM),
          const SizedBox(width: AppSpacing.xs),
          Text(label),
        ],
      ),
    );
  }

  /// 概览：应用关键信息键值行 + ABI chips（权限已移至独立 Tab）。
  Widget _buildOverviewTab(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    final labelStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );
    final valueStyle = textTheme.bodySmall;

    final rows = <(String, String)>[
      ('包名', widget.app.packageName),
      ('版本', '${widget.app.versionName} (${widget.app.versionCode})'),
      ('安装路径', widget.sourceDir),
      ('minSdk', _minSdk.isEmpty ? '未知' : _minSdk),
      ('targetSdk', _targetSdk.isEmpty ? '未知' : _targetSdk),
    ];

    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        Padding(
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
            ],
          ),
        ),
      ],
    );
  }

  /// 原生库（.so）命中列表；为空时展示居中空态。
  Widget _buildNativeTab() {
    if (_nativeHits.isEmpty) return _buildEmptyState('未检测到原生库');
    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        _buildGroupHeader(
          icon: Icons.memory,
          title: '原生库 (.so)',
          count: _nativeHits.length,
        ),
        const SizedBox(height: AppSpacing.xs),
        for (final hit in _nativeHits)
          _buildItem(hit, icon: Icons.memory, matchedName: hit.soFileName),
        const SizedBox(height: AppSpacing.md),
      ],
    );
  }

  /// DEX 类名命中列表；为空时展示居中空态。
  Widget _buildDexTab() {
    if (_dexHits.isEmpty) return _buildEmptyState('未检测到 DEX 类名');
    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        _buildGroupHeader(
          icon: Icons.code,
          title: 'DEX 类名',
          count: _dexHits.length,
        ),
        const SizedBox(height: AppSpacing.xs),
        for (final hit in _dexHits)
          _buildItem(hit, icon: Icons.code, matchedName: hit.matchedClassName),
        const SizedBox(height: AppSpacing.md),
      ],
    );
  }

  /// 组件命中：按 componentType 分组（Service/Activity/Receiver/Provider）。
  Widget _buildComponentTab() {
    final groups = SdkAnalysisPage.groupComponentsByType(_componentHits);
    if (groups.isEmpty) return _buildEmptyState('未检测到组件');
    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        for (final group in groups) ...[
          _buildGroupHeader(
            icon: Icons.view_module,
            title: group.label,
            count: group.items.length,
          ),
          const SizedBox(height: AppSpacing.xs),
          for (final hit in group.items)
            _buildItem(
              hit,
              icon: Icons.view_module,
              matchedName: hit.componentName,
            ),
          const SizedBox(height: AppSpacing.md),
        ],
      ],
    );
  }

  /// 权限 chips；为空时展示「无权限声明」。
  Widget _buildPermissionTab() {
    if (_permissions.isEmpty) return _buildEmptyState('无权限声明');
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        Padding(
          padding: AppSpacing.onlyHorizontalMD,
          child: Wrap(
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
        ),
      ],
    );
  }

  /// 居中空态文案。
  Widget _buildEmptyState(String message) {
    return Center(
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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

import 'package:flutter/material.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';
import 'package:gstore/core/rust/generated/components.dart' show ApkComponents;
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// SDK 分析页：LibChecker 式多 Tab 分类展示 APK 内嵌第三方 SDK 检测结果。
///
/// 进入页面即并行发起多路分析（原生 .so 规则命中 / 全量 .so 按 ABI 枚举 /
/// DEX 类名 / Manifest 组件命中与全量组件清单）与应用详细信息收集
/// （权限 / ABI / 签名 / meta-data / 主 Activity / 安装信息 / minSdk / targetSdk），
/// 完成后按 概览 / 原生库 / DEX 类名 / 组件 / 权限 / 签名 / meta 数据
/// 七个 Tab 分类展示（参考 LibChecker 的分类形式；组件进一步按 LibType 分组）。
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

  /// 测试用：注入合成 Manifest 组件解析结果，跳过 Rust FFI 调用。
  /// 传 null 恢复真实解析。
  static ApkComponents? _debugComponentsOverride;

  /// 测试用：设置合成的 Manifest 组件解析结果（null 恢复真实解析）。
  @visibleForTesting
  static void debugSetComponents(ApkComponents? components) {
    _debugComponentsOverride = components;
  }

  /// Rust 通道不可用时解析失败 → 全空的降级实例。
  static const ApkComponents _emptyComponents = ApkComponents(
    packageName: '',
    minSdk: '',
    targetSdk: '',
    services: [],
    activities: [],
    receivers: [],
    providers: [],
  );

  @override
  State<SdkAnalysisPage> createState() => _SdkAnalysisPageState();
}

/// Manifest 全量组件分组（「全部组件」区段按类型展示）
typedef _FullComponentGroup = ({String label, int count, List<String> items});

class _SdkAnalysisPageState extends State<SdkAnalysisPage> {
  bool _loading = true;
  List<NativeLibraryHit> _nativeHits = const [];
  List<DexLibraryHit> _dexHits = const [];
  List<ComponentLibraryHit> _componentHits = const [];

  /// 声明的权限列表（获取失败为空列表）
  List<String> _permissions = const [];

  /// 原生库 ABI 架构列表（获取失败为空列表）
  List<String> _abis = const [];

  /// minSdk（Rust 解析失败为空字符串，渲染时回退详情 fallback /「未知」）
  String _minSdk = '';

  /// targetSdk（Rust 解析失败为空字符串，渲染时回退详情 fallback /「未知」）
  String _targetSdk = '';

  /// 全量原生库（按 ABI 分组，LibChecker 风格；获取失败为空列表）
  List<NativeAbiLibs> _fullNativeLibs = const [];

  /// 已安装应用详情（签名 / meta-data / 主 Activity / 安装信息 / APK 大小，
  /// 获取失败为默认空实例）
  InstalledAppDetail _detail = const InstalledAppDetail();

  /// Manifest 组件全量清单（Rust 解析失败为 null → 组件页仅展示规则命中）
  ApkComponents? _components;

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  /// 多路并行分析 + 应用详情收集；各分析器内部优雅降级为空，不会抛给调用方。
  Future<void> _analyze() async {
    // Rust 通道不可用时解析失败 → 降级为全空实例，绝不抛给调用方。
    final sdkF = () async {
      final override = SdkAnalysisPage._debugComponentsOverride;
      if (override != null) return override;
      try {
        return await FdroidRustRepoManager.parseComponents(widget.sourceDir);
      } catch (e) {
        appLog.error('SdkAnalysisPage: 解析 SDK 版本失败（降级为空） - $e');
        return SdkAnalysisPage._emptyComponents;
      }
    }();

    final results = await (
      ApkLibraryAnalyzer.instance.analyzeNativeLibraries(widget.sourceDir),
      ApkLibraryAnalyzer.instance.analyzeDexLibraries(widget.sourceDir),
      ApkLibraryAnalyzer.instance.analyzeComponents(widget.sourceDir),
      ApkSourceService.instance.getPermissions(widget.app.packageName),
      ApkLibraryAnalyzer.instance.listNativeAbis(widget.sourceDir),
      sdkF,
      ApkLibraryAnalyzer.instance.analyzeNativeLibsFull(widget.sourceDir),
      ApkSourceService.instance.getInstalledAppDetail(widget.app.packageName),
    ).wait;
    if (!mounted) return;
    setState(() {
      _nativeHits = results.$1;
      _dexHits = results.$2;
      _componentHits = results.$3;
      _permissions = results.$4;
      _abis = results.$5;
      final components = results.$6;
      _components = components;
      _minSdk = components.minSdk;
      _targetSdk = components.targetSdk;
      _fullNativeLibs = results.$7;
      _detail = results.$8;
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

  /// 结果区：加载中显示 loading；加载完成后以七个 Tab 分类展示。
  Widget _buildResultArea(BuildContext context) {
    if (_loading) {
      return const Center(child: AppLoading(size: AppLoadingSize.medium));
    }

    return DefaultTabController(
      length: 7,
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
              _buildTab(Icons.verified_user, '签名'),
              _buildTab(Icons.tune, 'meta 数据'),
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
                _buildSignatureTab(),
                _buildMetaTab(),
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
      (
        '主 Activity',
        _detail.mainActivity.isEmpty ? '未知' : _detail.mainActivity,
      ),
      ('APK 大小', _detail.apkSize > 0 ? _formatBytes(_detail.apkSize) : '未知'),
      ('安装时间', _formatInstallTime(_detail.firstInstallTime)),
      ('最近更新', _formatInstallTime(_detail.lastUpdateTime)),
      (
        'minSdk',
        _minSdk.isNotEmpty ? _minSdk : (_detail.minSdk?.toString() ?? '未知'),
      ),
      (
        'targetSdk',
        _targetSdk.isNotEmpty
            ? _targetSdk
            : (_detail.targetSdk?.toString() ?? '未知'),
      ),
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
                _buildKeyValueRow(
                  label: label,
                  value: value,
                  labelStyle: labelStyle,
                  valueStyle: valueStyle,
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

  /// 原生库（.so）：按 ABI 分组展示 APK 内**全部** .so，命中规则的
  /// 行以 SDK 标签 + 匹配名高亮（`_buildItem`），未命中的行平铺展示。
  /// 每行行尾展示该 .so 的文件大小（zip 解压后字节数）。
  /// 为空时展示居中空态。
  Widget _buildNativeTab() {
    if (_fullNativeLibs.isEmpty) return _buildEmptyState('未检测到原生库');

    final hitBySo = <String, NativeLibraryHit>{
      for (final hit in _nativeHits) hit.soFileName: hit,
    };

    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        for (final abiLibs in _fullNativeLibs) ...[
          _buildGroupHeader(
            icon: Icons.memory,
            title: abiLibs.abi,
            count: abiLibs.soFiles.length,
          ),
          const SizedBox(height: AppSpacing.xs),
          for (final so in abiLibs.soFiles)
            if (hitBySo[so.name] case final hit?)
              _buildItem(
                hit,
                icon: Icons.memory,
                matchedName: so.name,
                trailing: _formatBytes(so.size),
              )
            else
              _buildPlainRow(
                icon: Icons.memory,
                title: so.name,
                subtitle: '未匹配规则',
                trailing: _formatBytes(so.size),
              ),
          const SizedBox(height: AppSpacing.md),
        ],
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

  /// 组件：规则命中按 componentType 分组（Service/Activity/Receiver/Provider）
  /// 优先展示；随后为「全部组件」区段，列出 Manifest 全量组件并按同类型分组。
  Widget _buildComponentTab() {
    final matchGroups = SdkAnalysisPage.groupComponentsByType(_componentHits);
    final fullGroups = _groupFullComponents();
    if (matchGroups.isEmpty && fullGroups.isEmpty) {
      return _buildEmptyState('未检测到组件');
    }

    final fullTotal = fullGroups.fold<int>(0, (n, g) => n + g.count);
    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        for (final group in matchGroups) ...[
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
        if (fullGroups.isNotEmpty) ...[
          _buildGroupHeader(
            icon: Icons.view_module,
            title: '全部组件',
            count: fullTotal,
          ),
          const SizedBox(height: AppSpacing.xs),
          for (final group in fullGroups) ...[
            _buildSubGroupHeader(
              title: group.label,
              count: group.count,
            ),
            for (final name in group.items)
              _buildPlainRow(icon: Icons.view_module, title: name),
          ],
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

  /// 签名：列出每张证书的 subject DN、SHA-256/SHA-1 指纹与签名算法。
  /// 为空时展示「无签名信息」。
  Widget _buildSignatureTab() {
    if (_detail.signatures.isEmpty) return _buildEmptyState('无签名信息');
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final fingerprintStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontFamily: 'monospace',
    );

    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        _buildGroupHeader(
          icon: Icons.verified_user,
          title: '签名',
          count: _detail.signatures.length,
        ),
        const SizedBox(height: AppSpacing.xs),
        for (final sig in _detail.signatures)
          Padding(
            padding: AppSpacing.horizontalLG_verticalSM,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: AppSpacing.onlyTopXS,
                  child: Icon(
                    Icons.verified_user,
                    size: AppTypography.iconSM,
                    color: colorScheme.primary,
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
                              sig.subject.isEmpty ? '未知主题' : sig.subject,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodyMedium,
                            ),
                          ),
                          if (sig.algorithm.isNotEmpty) ...[
                            const SizedBox(width: AppSpacing.xs),
                            _buildSmallTag(sig.algorithm),
                          ],
                        ],
                      ),
                      if (sig.sha256.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text('SHA-256 ${sig.sha256}', style: fingerprintStyle),
                      ],
                      if (sig.sha1.isNotEmpty) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Text('SHA-1 ${sig.sha1}', style: fingerprintStyle),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.md),
      ],
    );
  }

  /// meta 数据：Manifest <meta-data> 键值行（键排序展示）。
  /// 为空时展示「无 meta-data」。
  Widget _buildMetaTab() {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    if (_detail.metaData.isEmpty) return _buildEmptyState('无 meta-data');

    final entries = _detail.metaData.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final labelStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        _buildGroupHeader(
          icon: Icons.tune,
          title: 'meta 数据',
          count: entries.length,
        ),
        const SizedBox(height: AppSpacing.xs),
        Padding(
          padding: AppSpacing.onlyHorizontalMD,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final entry in entries)
                _buildKeyValueRow(
                  label: entry.key,
                  value: entry.value,
                  labelStyle: labelStyle,
                  valueStyle: textTheme.bodySmall,
                  valueMaxLines: 1,
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
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

  /// 紧凑二级分组头（图标 + 标题 + 计数徽标），用于「全部组件」内的类型分组。
  Widget _buildSubGroupHeader({
    required String title,
    required int count,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: AppSpacing.horizontalLG_verticalSM,
      child: Row(
        children: [
          Icon(
            Icons.view_module,
            size: AppTypography.iconSM,
            color: colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              title,
              style: textTheme.labelLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            padding: AppSpacing.chipPadding,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.circle),
            ),
            child: Text(
              '$count',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 单个命中项：图标 + label（标题行）+ 匹配名（等宽副标题）+ 正则标签；
  /// 可选的 [trailing] 右对齐展示在行尾（如 .so 文件大小）。
  Widget _buildItem(
    LibraryHit hit, {
    required IconData icon,
    required String matchedName,
    String? trailing,
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
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.xs),
            Text(
              trailing,
              maxLines: 1,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 未命中规则的普通列表行：onSurfaceVariant 图标 + 标题（+ 副标题）；
  /// 可选的 [trailing] 右对齐展示在行尾（如 .so 文件大小）。
  Widget _buildPlainRow({
    required IconData icon,
    required String title,
    String? subtitle,
    String? trailing,
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
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.xs),
            Text(
              trailing,
              maxLines: 1,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 概览 / meta 数据共用的键值行（label 固定宽度 84，值最多三行省略）。
  Widget _buildKeyValueRow({
    required String label,
    required String value,
    required TextStyle? labelStyle,
    required TextStyle? valueStyle,
    int valueMaxLines = 3,
  }) {
    return Padding(
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
              maxLines: valueMaxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 「正则」小标签（secondaryContainer 药丸）
  Widget _buildRegexTag(BuildContext context) {
    return _buildSmallTag('正则');
  }

  /// 通用药丸小标签（secondaryContainer）
  Widget _buildSmallTag(String text) {
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
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSecondaryContainer,
            ),
      ),
    );
  }

  /// Manifest 全量组件按类型分组（仅显示非空类型）。
  List<_FullComponentGroup> _groupFullComponents() {
    final components = _components;
    if (components == null) return const [];
    final all = [
      (label: SdkAnalysisPage._componentTypeLabels[1] ?? 'Service', items: components.services),
      (label: SdkAnalysisPage._componentTypeLabels[2] ?? 'Activity', items: components.activities),
      (label: SdkAnalysisPage._componentTypeLabels[3] ?? 'Receiver', items: components.receivers),
      (label: SdkAnalysisPage._componentTypeLabels[4] ?? 'Provider', items: components.providers),
    ];
    return [
      for (final group in all)
        if (group.items.isNotEmpty)
          (
            label: group.label,
            count: group.items.length,
            items: group.items,
          ),
    ];
  }

  /// 字节数格式化：B / KB / MB / GB（如 12.5 MB）。
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
  }

  /// 毫秒时间戳 → 'yyyy-MM-dd'；0 或负值返回「未知」。
  static String _formatInstallTime(int milliseconds) {
    if (milliseconds <= 0) return '未知';
    final d = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }
}
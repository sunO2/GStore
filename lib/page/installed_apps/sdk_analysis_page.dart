import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/design/app_borders.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart';
import 'package:gstore/core/rust/generated/components.dart' show ApkComponents;
import 'package:gstore/core/rust/generated/elf.dart'
    show ApkElfScanResult, ElfSoInfo;
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:installed_apps/app_info.dart' as installed;

/// 应用分析页：LibChecker 式多 Tab 分类展示 APK 内嵌第三方 SDK 检测结果。
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

  /// 测试用：注入合成 ELF 页对齐扫描结果，跳过 Rust FFI 调用。
  /// 传 null 恢复真实扫描。
  static ApkElfScanResult? _debugElfScanOverride;

  /// 测试用：设置合成的 ELF 页对齐扫描结果（null 恢复真实扫描）。
  @visibleForTesting
  static void debugSetElfScan(ApkElfScanResult? result) {
    _debugElfScanOverride = result;
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

  /// Rust 通道不可用时扫描失败 → 全空的降级实例（原生库行不展示徽标）。
  static const ApkElfScanResult _emptyElfScan = ApkElfScanResult(soFiles: []);

  @override
  State<SdkAnalysisPage> createState() => _SdkAnalysisPageState();
}

/// Manifest 全量组件分组（「全部组件」区段按类型展示）
typedef _FullComponentGroup = ({String label, int count, List<String> items});

/// 11 元记录并行等待（dart:async 内建 `.wait` 仅支持到 9 元）。
extension _FutureRecord11Ext<T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11>
    on (Future<T1>, Future<T2>, Future<T3>, Future<T4>, Future<T5>,
        Future<T6>, Future<T7>, Future<T8>, Future<T9>, Future<T10>,
        Future<T11>) {
  Future<(T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11)> get wait async => (
        await $1,
        await $2,
        await $3,
        await $4,
        await $5,
        await $6,
        await $7,
        await $8,
        await $9,
        await $10,
        await $11,
      );
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

  /// minSdk（Rust 解析失败为空字符串，渲染时回退详情 fallback /「未知」）
  String _minSdk = '';

  /// targetSdk（Rust 解析失败为空字符串，渲染时回退详情 fallback /「未知」）
  String _targetSdk = '';

  /// 全量原生库（按 ABI 分组，LibChecker 风格；获取失败为空列表）
  List<NativeAbiLibs> _fullNativeLibs = const [];

  /// 已安装应用详情（签名 / meta-data / 主 Activity / 安装信息 / APK 大小，
  /// 获取失败为默认空实例）
  InstalledAppDetail _detail = const InstalledAppDetail();

  /// 全量 DEX 文件（文件名 + 大小，LibChecker 风格；获取失败为空列表）
  List<DexFile> _dexFiles = const [];

  /// Manifest 组件全量清单（Rust 解析失败为 null → 组件页仅展示规则命中）
  ApkComponents? _components;

  /// 构建版本检测结果（Kotlin / Gradle / Java，检测失败为默认空实例 → 「未知」）
  BuildVersionInfo _buildInfo = const BuildVersionInfo();

  /// ELF 页对齐扫描结果（.so → 16KB 对齐；Rust 不可用/失败为空 → 不展示徽标）
  ApkElfScanResult _elfScan = const ApkElfScanResult(soFiles: []);

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

    // Rust 通道不可用时解析失败 → 降级为全空实例，绝不抛给调用方。
    final elfF = () async {
      final override = SdkAnalysisPage._debugElfScanOverride;
      if (override != null) return override;
      try {
        return await FdroidRustRepoManager.scanElfPageSizes(widget.sourceDir);
      } catch (e) {
        appLog.error('SdkAnalysisPage: 扫描 ELF 16KB 对齐失败（降级为空） - $e');
        return SdkAnalysisPage._emptyElfScan;
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
      ApkLibraryAnalyzer.instance.analyzeDexFilesFull(widget.sourceDir),
      ApkLibraryAnalyzer.instance.detectBuildVersions(widget.sourceDir),
      elfF,
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
      _dexFiles = results.$9;
      _buildInfo = results.$10;
      _elfScan = results.$11;
      _loading = false;
    });
  }

  /// 复制文本到剪贴板并弹出统一 SnackBar 提示（'已复制 …'，超长截断）。
  /// 长按复制全页数据统一走此入口。
  void _copyText(BuildContext context, String text, {String? label}) {
    Clipboard.setData(ClipboardData(text: text));
    final full = '已复制 ${label ?? text}';
    final msg = full.length > 40 ? '${full.substring(0, 40)}…' : full;
    AppDialogs.showSnackbar(msg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('应用分析')),
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

    // 构建版本行（Kotlin/Gradle/Java，检测缺失字段 → 「未知」降级，恒展示）
    final buildRows = <(String, String)>[
      (
        'Kotlin',
        _buildInfo.kotlinVersion.isEmpty ? '未知' : _buildInfo.kotlinVersion,
      ),
      (
        'Gradle',
        _buildInfo.gradleVersion.isEmpty ? '未知' : _buildInfo.gradleVersion,
      ),
      ('Java', _buildInfo.javaVersion.isEmpty ? '未知' : _buildInfo.javaVersion),
      ('16KB 对齐', _elfSummaryText()),
    ];

    // 系统信息行（detail 缺失字段 → 「未知」/「否」降级，恒展示）
    final systemRows = <(String, String)>[
      ('UID', _detail.uid > 0 ? '${_detail.uid}' : '未知'),
      (
        '共享 UID',
        _detail.sharedUserId.isEmpty ? '未知' : _detail.sharedUserId,
      ),
      ('安装来源', _detail.installer.isEmpty ? '未知' : _detail.installer),
      ('是否系统应用', _detail.isSystemApp ? '是' : '否'),
      ('是否调试', _detail.isDebuggable ? '是' : '否'),
      ('数据目录', _detail.dataDir.isEmpty ? '未知' : _detail.dataDir),
    ];

    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        _buildSectionCard(
          child: Padding(
            padding: AppSpacing.cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (label, value) in rows)
                  _buildKeyValueRow(
                    label: label,
                    value: value,
                    labelStyle: labelStyle,
                    valueStyle: valueStyle,
                    onLongPress: () => _copyText(context, value, label: label),
                  ),
                const Divider(height: AppSpacing.lg),
                for (final (label, value) in buildRows)
                  _buildKeyValueRow(
                    label: label,
                    value: value,
                    labelStyle: labelStyle,
                    valueStyle: valueStyle,
                    onLongPress: () => _copyText(context, value, label: label),
                  ),
                const Divider(height: AppSpacing.lg),
                for (final (label, value) in systemRows)
                  _buildKeyValueRow(
                    label: label,
                    value: value,
                    labelStyle: labelStyle,
                    valueStyle: valueStyle,
                    onLongPress: () => _copyText(context, value, label: label),
                  ),
                if (_abis.isNotEmpty) ...[
                  const Divider(height: AppSpacing.lg),
                  Text(
                    'ABI 架构',
                    style: textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
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
              ],
            ),
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
    final elfBySo = <String, ElfSoInfo>{
      for (final f in _elfScan.soFiles) f.soName: f,
    };

    // 16KB 对齐标记：仅当 ELF 数据存在且该 .so 为 16KB 对齐时展示胶囊「16KB」。
    bool show16Kb(String soName) {
      final f = elfBySo[soName];
      if (f == null) return false;
      return f.aligned16Kb;
    }

    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        for (final abiLibs in _fullNativeLibs)
          _buildSectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildGroupHeader(
                  icon: Icons.memory,
                  title: abiLibs.abi,
                  count: abiLibs.soFiles.length,
                ),
                Divider(height: AppSpacing.md),
                for (final so in abiLibs.soFiles)
                  if (hitBySo[so.name] case final hit?)
                    _buildItem(
                      hit,
                      icon: Icons.memory,
                      matchedName: so.name,
                      trailing: _formatBytes(so.size),
                      show16Kb: show16Kb(so.name),
                      onLongPress: () =>
                          _copyText(context, so.name, label: so.name),
                    )
                  else
                    _buildPlainRow(
                      icon: Icons.memory,
                      title: so.name,
                      subtitle: '未匹配规则',
                      trailing: _formatBytes(so.size),
                      show16Kb: show16Kb(so.name),
                      onLongPress: () =>
                          _copyText(context, so.name, label: so.name),
                    ),
              ],
            ),
          ),
      ],
    );
  }

  /// DEX 类名命中列表 + 全量 DEX 文件（名称 + 大小）；
  /// 两者皆空时展示居中空态。
  Widget _buildDexTab() {
    if (_dexHits.isEmpty && _dexFiles.isEmpty) {
      return _buildEmptyState('未检测到 DEX 类名');
    }
    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        if (_dexHits.isNotEmpty)
          _buildSectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildGroupHeader(
                  icon: Icons.code,
                  title: 'DEX 类名',
                  count: _dexHits.length,
                ),
                Divider(height: AppSpacing.md),
                for (final hit in _dexHits)
                  _buildItem(hit, icon: Icons.code, matchedName: hit.matchedClassName),
              ],
            ),
          ),
        if (_dexFiles.isNotEmpty)
          _buildSectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildGroupHeader(
                  icon: Icons.code,
                  title: 'DEX 文件',
                  count: _dexFiles.length,
                ),
                const Divider(height: AppSpacing.md),
                for (final f in _dexFiles)
                  _buildPlainRow(
                    icon: Icons.code,
                    title: f.name,
                    trailing: _formatBytes(f.size),
                    onLongPress: () => _copyText(context, f.name, label: f.name),
                  ),
              ],
            ),
          ),
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
        if (matchGroups.isNotEmpty)
          _buildSectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, group) in matchGroups.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  _buildGroupHeader(
                    icon: Icons.view_module,
                    title: group.label,
                    count: group.items.length,
                  ),
                  for (final hit in group.items)
                    _buildItem(
                      hit,
                      matchedName: hit.componentName,
                      onLongPress: () => _copyText(
                        context,
                        hit.componentName,
                        label: hit.componentName,
                      ),
                    ),
                ],
              ],
            ),
          ),
        if (fullGroups.isNotEmpty)
          _buildSectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildGroupHeader(
                  icon: Icons.view_module,
                  title: '全部组件',
                  count: fullTotal,
                ),
                Divider(height: AppSpacing.md),
                for (final (i, group) in fullGroups.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  _buildSubGroupHeader(
                    title: group.label,
                    count: group.count,
                  ),
                  for (final name in group.items)
                    _buildPlainRow(
                      title: name,
                      wrapTitle: true,
                      onLongPress: () => _copyText(context, name, label: name),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// 权限药丸列表（可换行）；为空时展示「无权限声明」。
  Widget _buildPermissionTab() {
    if (_permissions.isEmpty) return _buildEmptyState('无权限声明');
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        _buildSectionCard(
          child: Padding(
            padding: AppSpacing.cardPadding,
            child: Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final permission in _permissions)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPress: () => _copyText(
                      context,
                      permission,
                      label: permission,
                    ),
                    child: Container(
                      padding: AppSpacing.chipPadding,
                      decoration: BoxDecoration(
                        color: colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        permission,
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 签名：列出每张证书的 subject DN（完整换行不截断）、SHA-256/SHA-1
  /// 指纹与签名算法；点击卡片打开签名详情弹窗，长按复制完整证书信息。
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
        for (final sig in _detail.signatures)
          _buildSectionCard(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showSignatureDetail(context, sig),
              onLongPress: () =>
                  _copyText(context, _signatureCopyText(sig), label: '签名信息'),
              child: Padding(
                padding: AppSpacing.cardPadding,
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
                          // 证书主题：独立整行、完整换行（不再截断）
                          Text(
                            sig.subject.isEmpty ? '未知主题' : sig.subject,
                            style: textTheme.bodyMedium,
                          ),
                          if (sig.algorithm.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [_buildSmallTag(sig.algorithm)],
                            ),
                          ],
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
            ),
          ),
      ],
    );
  }

  /// 打开签名详情弹窗：subject / 算法 / SHA-256 / SHA-1 全字段，每行可长按复制。
  void _showSignatureDetail(BuildContext context, SignatureInfo sig) {
    AppDialogs.showDialog(
      title: '签名详情',
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDialogCopyRow(
                context,
                '主题',
                sig.subject.isEmpty ? '未知主题' : sig.subject,
              ),
              if (sig.algorithm.isNotEmpty)
                _buildDialogCopyRow(context, '算法', sig.algorithm),
              if (sig.sha256.isNotEmpty)
                _buildDialogCopyRow(context, 'SHA-256', sig.sha256),
              if (sig.sha1.isNotEmpty)
                _buildDialogCopyRow(context, 'SHA-1', sig.sha1),
            ],
          ),
        ),
      ),
      confirmText: '关闭',
      cancelText: null,
    );
  }

  /// 签名详情弹窗内可复制行：label（onSurfaceVariant）+ 等宽 value，长按复制。
  Widget _buildDialogCopyRow(BuildContext context, String label, String value) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: () => _copyText(context, value, label: label),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              value,
              style: textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }

  /// 完整证书信息（算法/主题/SHA-256/SHA-1 拼接，长按复制用）。
  static String _signatureCopyText(SignatureInfo sig) => [
        if (sig.algorithm.isNotEmpty) '算法: ${sig.algorithm}',
        if (sig.subject.isNotEmpty) '主题: ${sig.subject}',
        if (sig.sha256.isNotEmpty) 'SHA-256: ${sig.sha256}',
        if (sig.sha1.isNotEmpty) 'SHA-1: ${sig.sha1}',
      ].join('\n');

  /// meta 数据：Manifest <meta-data> 键值行（键排序展示）。
  /// 为空时展示「无 meta-data」。
  Widget _buildMetaTab() {
    final textTheme = Theme.of(context).textTheme;
    if (_detail.metaData.isEmpty) return _buildEmptyState('无 meta-data');

    final entries = _detail.metaData.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return ListView(
      padding: AppSpacing.onlyVerticalMD,
      children: [
        _buildSectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildGroupHeader(
                icon: Icons.tune,
                title: 'meta 数据',
                count: entries.length,
              ),
              Divider(height: AppSpacing.md),
              Padding(
                padding: AppSpacing.cardPadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, entry) in entries.indexed) ...[
                      if (i > 0) const SizedBox(height: AppSpacing.sm),
                      // 键药丸在上、值全文在下：长键可完整换行，值也不被截断。
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildMetaKeyPill(
                            entry.key,
                            onLongPress: () =>
                                _copyText(context, entry.key, label: entry.key),
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onLongPress: () => _copyText(
                              context,
                              entry.value,
                              label: entry.value,
                            ),
                            child: Text(
                              entry.value,
                              style: textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// meta 数据键药丸（secondaryContainer 底色 + 等宽 bodySmall，完整换行），
  /// 与 [Text] 值形成「键 + 值」两级层次。
  Widget _buildMetaKeyPill(String key, {VoidCallback? onLongPress}) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final pill = Container(
      padding: AppSpacing.chipPadding,
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        key,
        style: textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          color: colorScheme.onSecondaryContainer,
        ),
      ),
    );
    if (onLongPress == null) return pill;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: pill,
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

  /// 分组区块卡片：圆角 + 主题边框（镜像 view.dart `_buildAppTile` 卡片样式），
  /// 横向外边距与底部间距统一（AppSpacing.onlyHorizontalMD + bottom）。
  Widget _buildSectionCard({required Widget child}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        bottom: AppSpacing.md,
      ),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: AppBorders.sideOf(context, color: colorScheme.outlineVariant),
      ),
      child: child,
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
      padding: AppSpacing.horizontalMD_verticalSM,
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

  /// 单个命中项：可选图标 + label（标题行）+ 匹配名（等宽副标题）+ 正则标签；
  /// 可选的 [trailing] 右对齐展示在行尾（如 .so 文件大小）；
  /// [show16Kb] 为 true 时在副标题行尾渲染「16KB」胶囊标记（仅对齐时展示）。
  /// [icon] 为 null 时不渲染前导图标（组件 tab 行无需图标）。
  Widget _buildItem(
    LibraryHit hit, {
    IconData? icon,
    required String matchedName,
    String? trailing,
    bool show16Kb = false,
    VoidCallback? onLongPress,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final row = Padding(
      padding: AppSpacing.horizontalLG_verticalSM,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: AppSpacing.onlyTopXS,
              child: Icon(
                icon,
                size: AppTypography.iconSM,
                color: hit.isRegex ? colorScheme.tertiary : colorScheme.primary,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
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
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Flexible(
                      child: Text(
                        matchedName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    if (show16Kb) ...[
                      const SizedBox(width: AppSpacing.xs),
                      _build16KbCapsule(context),
                    ],
                  ],
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
    if (onLongPress == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: row,
    );
  }

  /// 未命中规则的普通列表行：可选 onSurfaceVariant 图标 + 标题（+ 副标题）；
  /// 可选的 [trailing] 右对齐展示在行尾（如 .so 文件大小）；
  /// [show16Kb] 为 true 时在副标题行尾渲染「16KB」胶囊标记（仅对齐时展示）。
  /// [icon] 为 null 时不渲染前导图标；[wrapTitle] 为 true 时标题完整换行
  /// （组件全量行等无尾随尺寸的文本），否则单行省略。
  Widget _buildPlainRow({
    IconData? icon,
    required String title,
    String? subtitle,
    String? trailing,
    bool show16Kb = false,
    bool wrapTitle = false,
    VoidCallback? onLongPress,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final row = Padding(
      padding: AppSpacing.horizontalLG_verticalSM,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Padding(
              padding: AppSpacing.onlyTopXS,
              child: Icon(
                icon,
                size: AppTypography.iconSM,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: wrapTitle ? null : 1,
                  overflow: wrapTitle ? null : TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (show16Kb) ...[
                        const SizedBox(width: AppSpacing.xs),
                        _build16KbCapsule(context),
                      ],
                    ],
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
    if (onLongPress == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: row,
    );
  }

  /// 「16KB」对齐胶囊标记（secondaryContainer 底色小圆角，仅对齐时展示）。
  Widget _build16KbCapsule(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.circle),
      ),
      child: Text(
        '16KB',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colorScheme.onSecondaryContainer,
              fontWeight: AppTypography.weightSemiBold,
            ),
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
    VoidCallback? onLongPress,
  }) {
    final row = Padding(
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
    if (onLongPress == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: row,
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

  /// 16KB 对齐汇总文案：无数据 → 「未知」；全部兼容 → 「兼容（n 个 .so）」；
  /// 存在不兼容 → 「n 个不兼容 / 总数 个」。
  String _elfSummaryText() {
    final files = _elfScan.soFiles;
    if (files.isEmpty) return '未知';
    final bad = files.where((f) => !f.aligned16Kb).length;
    if (bad == 0) return '兼容（${files.length} 个 .so）';
    return '$bad 个不兼容 / ${files.length} 个';
  }
}
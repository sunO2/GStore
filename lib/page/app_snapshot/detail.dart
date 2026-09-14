import 'package:flutter/material.dart';
import 'package:gstore/core/design/app_spacing.dart';
import 'package:gstore/core/snapshot/snapshot_diff_engine.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';
import 'package:gstore/page/app_snapshot/compare.dart';
import 'package:gstore/page/app_snapshot/widgets.dart';

/// 单份快照的完整内容（分节展示）
///
/// [previous] 不为空时，导航头提供「与上一快照对比」入口。
class AppSnapshotDetailPage extends StatelessWidget {
  const AppSnapshotDetailPage({
    super.key,
    required this.record,
    this.previous,
  });

  final SnapshotRecord record;
  final SnapshotRecord? previous;

  @override
  Widget build(BuildContext context) {
    final p = record.payload;
    final prev = previous;
    return Scaffold(
      appBar: AppBar(
        title: const Text('快照详情'),
        actions: [
          if (prev != null)
            IconButton(
              tooltip: '与上一快照对比',
              icon: const Icon(Icons.compare_arrows),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      AppSnapshotComparePage(oldRecord: prev, newRecord: record),
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: AppSpacing.onlyVerticalSM,
        children: [
          _header(context),
          _appSection(p),
          _structureSection(p),
          _signatureSection(p),
          _permissionSection(p),
          _componentSection(p),
          _nativeSection(p),
          _dexSection(p),
          _assetsSection(p),
          _arscSection(p),
          _featureSection(p),
          _metaSection(p),
          _ruleHitSection(p),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return SnapshotSectionCard(
      title: record.appLabel.isEmpty ? record.packageName : record.appLabel,
      subtitle: 'v${record.versionName} (${record.versionCode}) · '
          '采集于 ${formatTime(record.createdAt)}'
          '${record.note.isEmpty ? '' : ' · ${record.note}'}',
      child: Wrap(
        children: [
          SnapshotTag(text: '载荷 v${record.payloadVersion}'),
          SnapshotTag(text: formatBytes(record.summary.apkSize)),
          if (record.summary.deepLinks > 0)
            SnapshotTag(text: '深链 ${record.summary.deepLinks}'),
        ],
      ),
    );
  }

  Widget _appSection(SnapshotPayload p) {
    final a = p.app;
    return SnapshotSectionCard(
      title: '应用信息',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SnapshotInfoRow(label: '包名', value: a.packageName, mono: true),
          SnapshotInfoRow(label: '版本', value: '${a.versionName} (${a.versionCode})'),
          SnapshotInfoRow(label: 'APK 大小', value: formatBytes(a.apkSize)),
          SnapshotInfoRow(label: 'UID', value: a.uid.toString()),
          SnapshotInfoRow(label: 'minSdk', value: a.minSdk),
          SnapshotInfoRow(label: 'targetSdk', value: a.targetSdk),
          SnapshotInfoRow(label: 'compileSdk', value: a.compileSdk),
          SnapshotInfoRow(label: 'sharedUserId', value: a.sharedUserId, mono: true),
          SnapshotInfoRow(label: '安装器', value: a.installer),
          SnapshotInfoRow(label: '主 Activity', value: a.mainActivity, mono: true),
          SnapshotInfoRow(label: '数据目录', value: a.dataDir, mono: true),
          SnapshotInfoRow(label: '首次安装', value: formatTime(a.firstInstallTime)),
          SnapshotInfoRow(label: '最近更新', value: formatTime(a.lastUpdateTime)),
          SnapshotInfoRow(
            label: 'ABI',
            value: a.abis.isEmpty ? '—' : a.abis.join('、'),
          ),
          SnapshotInfoRow(
            label: '标记',
            value: [
              if (a.isSystemApp) '系统应用',
              if (a.isDebuggable) '可调试',
            ].join(' · '),
          ),
        ],
      ),
    );
  }

  /// 包结构（zip 中央目录口径：条目数 / 解压总量 / STORED 数）
  Widget _structureSection(SnapshotPayload p) {
    final st = p.structure;
    final ratio = st.totalUncompressed > 0
        ? '${(st.storedEntryCount * 100 / (st.entryCount == 0 ? 1 : st.entryCount)).toStringAsFixed(1)}%'
        : '—';
    return SnapshotSectionCard(
      title: '包结构',
      collapsible: true,
      initiallyExpanded: false,
      count: st.entryCount,
      subtitle: 'zip 条目总量与压缩情况',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SnapshotInfoRow(label: '条目总数', value: '${st.entryCount}'),
          SnapshotInfoRow(
            label: '解压总量',
            value: formatBytes(st.totalUncompressed),
          ),
          SnapshotInfoRow(
            label: 'STORED',
            value: '${st.storedEntryCount} 个（$ratio）',
          ),
        ],
      ),
    );
  }

  /// assets 清单（P0：文件名/大小/压缩后/内容指纹/存放方式）
  Widget _assetsSection(SnapshotPayload p) {
    final assets = p.assets;
    final total = assets.fold<int>(0, (n, a) => n + a.size);
    // 大包 assets 可上千条：按体积倒序只列前 [_maxAssetRows] 条，其余提示到对比页看差异
    const maxRows = 50;
    final sorted = [...assets]..sort((a, b) => b.size.compareTo(a.size));
    final shown = sorted.take(maxRows).toList();
    return SnapshotSectionCard(
      title: 'assets 资源',
      collapsible: true,
      initiallyExpanded: false,
      count: assets.length,
      subtitle: assets.isEmpty
          ? '无 assets 资源'
          : '${assets.length} 个 · 共 ${formatBytes(total)}'
              '${assets.length > maxRows ? '（按体积列前 $maxRows）' : ''}',
      child: assets.isEmpty
          ? const SnapshotEmptyHint(text: '该 APK 没有 assets 资源')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in shown)
                  SnapshotTextRow(
                    text: a.name,
                    subtitle: '${formatBytes(a.size)}'
                        '${a.compressedSize > 0 ? ' · 压缩后 ${formatBytes(a.compressedSize)}' : ''}',
                    tags: [
                      if (a.stored) 'STORED',
                      if (a.crc32 != 0) _crc32Label(a.crc32),
                    ],
                  ),
              ],
            ),
    );
  }

  /// resources.arsc（P0：存在性/大小/压缩后/存放方式/内容指纹）
  Widget _arscSection(SnapshotPayload p) {
    final arsc = p.arsc;
    return SnapshotSectionCard(
      title: 'resources.arsc',
      collapsible: true,
      initiallyExpanded: false,
      subtitle: arsc.present ? '资源表条目' : '该 APK 没有 resources.arsc',
      child: arsc.present
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SnapshotInfoRow(label: '大小', value: formatBytes(arsc.size)),
                SnapshotInfoRow(
                  label: '压缩后',
                  value: formatBytes(arsc.compressedSize),
                ),
                SnapshotInfoRow(
                  label: '存放方式',
                  value: arsc.stored ? 'STORED（未压缩）' : 'DEFLATE',
                ),
                SnapshotInfoRow(
                  label: '内容指纹',
                  value: _crc32Label(arsc.crc32),
                  mono: true,
                ),
              ],
            )
          : const SnapshotEmptyHint(text: '未找到 resources.arsc'),
    );
  }

  /// CRC32 → 8 位 hex（与对比页展示口径一致）
  static String _crc32Label(int crc32) =>
      'crc32:${crc32.toUnsigned(32).toRadixString(16).padLeft(8, '0')}';

  Widget _signatureSection(SnapshotPayload p) {
    final s = p.signature;
    return SnapshotSectionCard(
      title: '签名',
      collapsible: true,
      initiallyExpanded: false,
      subtitle: s.certificates.isEmpty ? '无证书信息' : '${s.certificates.length} 张证书',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SnapshotInfoRow(
            label: '签名方案',
            value: s.schemes.isEmpty ? '—' : s.schemes.join(' · '),
          ),
          SnapshotInfoRow(label: '签名形态', value: s.signingShape),
          for (final c in s.certificates) ...[
            const Divider(height: AppSpacing.lg),
            SnapshotTextRow(
              text: c.subject.isEmpty ? '(无主题)' : c.subject,
              subtitle: [
                if (c.kind.isNotEmpty) _signatureKindLabel(c.kind),
                c.algorithm,
              ].where((e) => e.isNotEmpty).join(' · '),
              tags: [if (c.sha256.isNotEmpty) c.sha256.substring(0, 16)],
            ),
          ],
        ],
      ),
    );
  }

  static String _signatureKindLabel(String kind) => switch (kind) {
        'current' => '当前证书',
        'history' => '历史证书',
        'signer' => '并列签名者',
        _ => kind,
      };

  Widget _permissionSection(SnapshotPayload p) {
    return SnapshotSectionCard(
      title: '权限',
      collapsible: true,
      initiallyExpanded: false,
      subtitle: '${p.permissions.length} 项',
      child: p.permissions.isEmpty
          ? const SnapshotEmptyHint(text: '未声明权限')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final perm in p.permissions)
                  SnapshotTextRow(
                    text: perm.name,
                    tags: [
                      if (perm.maxSdkVersion.isNotEmpty)
                        'maxSdk ${perm.maxSdkVersion}',
                      if (perm.granted) '已授权',
                      if (perm.neverForLocation) '不用于定位',
                    ],
                  ),
              ],
            ),
    );
  }

  Widget _componentSection(SnapshotPayload p) {
    final byKind = <String, List<SnapshotComponent>>{};
    for (final c in p.components) {
      byKind.putIfAbsent(c.kind, () => []).add(c);
    }
    return SnapshotSectionCard(
      title: '组件',
      collapsible: true,
      initiallyExpanded: false,
      subtitle: '${p.components.length} 个'
          '${byKind.isEmpty ? '' : '（${byKind.entries.map((e) => '${e.key} ${e.value.length}').join(' · ')}）'}',
      child: p.components.isEmpty
          ? const SnapshotEmptyHint(text: '未声明组件')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in byKind.entries) ...[
                  Text(
                    entry.key,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                  ),
                  for (final c in entry.value)
                    SnapshotTextRow(
                      text: c.name,
                      mono: true,
                      tags: [
                        if (c.exported == 'true') 'exported',
                        if (c.enabled == 'true') 'enabled',
                        if (c.enabled == 'false') 'disabled',
                        if (c.processName.isNotEmpty) '进程 ${c.processName}',
                      ],
                      subtitle: [
                        if (c.actions.isNotEmpty)
                          'actions: ${c.actions.map(_shortAction).join(', ')}',
                        if (c.deepLinks.isNotEmpty)
                          '深链: ${c.deepLinks.join(', ')}',
                      ].join('\n'),
                    ),
                ],
              ],
            ),
    );
  }

  static String _shortAction(String action) =>
      action.replaceFirst('android.intent.action.', '');

  Widget _nativeSection(SnapshotPayload p) {
    final elfByKey = {
      for (final e in p.elfFiles) '${e.abi}|${e.soName}': e,
    };
    // 体积口径：解压后 total 与压缩后 total 都给，装包大小变化才看得出来
    final totalSize = p.nativeLibs.fold<int>(0, (n, l) => n + l.size);
    final totalCompressed =
        p.nativeLibs.fold<int>(0, (n, l) => n + l.compressedSize);
    final totalNote = p.nativeLibs.isEmpty
        ? ''
        : ' · 共 ${formatBytes(totalSize)}'
            '${totalCompressed > 0 ? '（压缩后 ${formatBytes(totalCompressed)}）' : ''}';
    return SnapshotSectionCard(
      title: '原生库',
      collapsible: true,
      initiallyExpanded: false,
      subtitle: '${p.nativeLibs.length} 个 · 命中 ${p.nativeHits.length} 个第三方库'
          '$totalNote',
      child: p.nativeLibs.isEmpty
          ? const SnapshotEmptyHint(text: '无原生库')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final lib in p.nativeLibs)
                  SnapshotTextRow(
                    text: '${lib.abi} / ${lib.name}',
                    mono: true,
                    subtitle: [
                      // 大小 / 压缩后（装包体积）/ 内容指纹，一行给全
                      formatBytes(lib.size),
                      if (lib.compressedSize > 0)
                        '压缩后 ${formatBytes(lib.compressedSize)}',
                      if (lib.crc32 != 0) _crc32Label(lib.crc32),
                      if (lib.stored) 'STORED',
                      _elfSubtitle(elfByKey['${lib.abi}|${lib.name}']) ?? '',
                    ].where((e) => e.isNotEmpty).join(' · '),
                    tags: const [],
                  ),
              ],
            ),
    );
  }

  static String? _elfSubtitle(SnapshotElfInfo? elf) {
    if (elf == null) return null;
    return [
      '页对齐 ${elf.minPageSize}',
      elf.aligned16Kb ? '16KB 兼容' : '16KB 不兼容',
      if (elf.zipAlignment > 0) 'zip 对齐 ${elf.zipAlignment}',
      if (elf.elfType >= 0) 'ELF type ${elf.elfType}',
      if (elf.stripped) '已剥离',
      if (elf.needed.isNotEmpty) '依赖 ${elf.needed.length}',
      if (elf.jniEntryPoints.isNotEmpty) 'JNI ${elf.jniEntryPoints.length}',
    ].join(' · ');
  }

  Widget _dexSection(SnapshotPayload p) {
    return SnapshotSectionCard(
      title: 'DEX',
      collapsible: true,
      initiallyExpanded: false,
      subtitle: '${p.dexFiles.length} 个文件 · '
          '${p.dexFiles.fold<int>(0, (n, d) => n + d.classCount)} 个类 · '
          '命中 ${p.dexHits.length} 个库',
      child: p.dexFiles.isEmpty
          ? const SnapshotEmptyHint(text: '无 DEX')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final d in p.dexFiles)
                  SnapshotTextRow(
                    text: d.name,
                    mono: true,
                    tags: [formatBytes(d.size), if (d.classCount > 0) '${d.classCount} 类'],
                  ),
              ],
            ),
    );
  }

  Widget _featureSection(SnapshotPayload p) {
    final f = p.features;
    final b = p.buildVersions;
    final labels = <String>[
      if (f.kotlinUsed) 'Kotlin',
      if (f.jetpackCompose) 'Jetpack Compose',
      if (f.kmp) 'KMP',
      if (f.xposedModule) 'Xposed',
      if (f.playSigning) 'Play 签名',
      if (f.pwa) 'PWA',
      if (f.liveUpdateNotification) '实时更新通知',
    ];
    return SnapshotSectionCard(
      title: '特征与构建版本',
      collapsible: true,
      initiallyExpanded: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (labels.isEmpty)
            const SnapshotEmptyHint(text: '未识别到特征')
          else
            Wrap(children: [for (final l in labels) SnapshotTag(text: l)]),
          const SizedBox(height: AppSpacing.xs),
          SnapshotInfoRow(label: 'AGP', value: b.agpVersion),
          SnapshotInfoRow(label: 'Kotlin', value: b.kotlinVersion),
          SnapshotInfoRow(label: 'Gradle', value: b.gradleVersion),
          SnapshotInfoRow(label: 'Java', value: b.javaVersion),
          SnapshotInfoRow(label: 'Compose', value: b.composeVersion),
        ],
      ),
    );
  }

  Widget _metaSection(SnapshotPayload p) {
    return SnapshotSectionCard(
      title: 'meta-data',
      collapsible: true,
      initiallyExpanded: false,
      subtitle: '${p.metaData.length} 项',
      child: p.metaData.isEmpty
          ? const SnapshotEmptyHint(text: '无 meta-data')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in p.metaData)
                  SnapshotTextRow(text: m.value, subtitle: m.name),
              ],
            ),
    );
  }

  Widget _ruleHitSection(SnapshotPayload p) {
    final groups = <String, List<SnapshotRuleHit>>{
      '原生库': p.nativeHits,
      'DEX': p.dexHits,
      '组件库': p.componentHits,
      '静态库': p.staticLibraries,
      'action': p.actionHits,
    };
    final total = groups.values.fold<int>(0, (n, l) => n + l.length);
    return SnapshotSectionCard(
      title: '命中的第三方库',
      collapsible: true,
      initiallyExpanded: false,
      subtitle: '共 $total 项',
      child: total == 0
          ? const SnapshotEmptyHint(text: '未命中任何规则')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final g in groups.entries)
                  if (g.value.isNotEmpty) ...[
                    Text(
                      '${g.key}（${g.value.length}）',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 12),
                    ),
                    Wrap(
                      children: [
                        for (final hit in g.value)
                          SnapshotTag(text: hit.label, emphasized: true),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                  ],
              ],
            ),
    );
  }
}

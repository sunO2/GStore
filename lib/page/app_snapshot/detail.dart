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
          _signatureSection(p),
          _permissionSection(p),
          _componentSection(p),
          _nativeSection(p),
          _dexSection(p),
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

  Widget _signatureSection(SnapshotPayload p) {
    final s = p.signature;
    return SnapshotSectionCard(
      title: '签名',
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
    return SnapshotSectionCard(
      title: '原生库',
      subtitle: '${p.nativeLibs.length} 个 · 命中 ${p.nativeHits.length} 个第三方库',
      child: p.nativeLibs.isEmpty
          ? const SnapshotEmptyHint(text: '无原生库')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final lib in p.nativeLibs)
                  SnapshotTextRow(
                    text: '${lib.abi} / ${lib.name}',
                    mono: true,
                    subtitle: _elfSubtitle(elfByKey['${lib.abi}|${lib.name}']),
                    tags: [formatBytes(lib.size)],
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

import 'snapshot_models.dart';

/// 差异类型
enum SnapshotDiffKind { removed, added, changed }

/// 单条差异
class SnapshotDiffEntry {
  const SnapshotDiffEntry({
    required this.kind,
    required this.key,
    this.oldValue,
    this.newValue,
    this.fieldChanges = const [],
    this.uncertain = false,
    this.sameContent,
    this.contentIdentity = '',
  });

  final SnapshotDiffKind kind;

  /// 条目标识（组件全类名 / `.so` 名 / 权限名 / 字段名 / 规则 label）
  final String key;

  /// 变化前（removed / changed 有值）
  final String? oldValue;

  /// 变化后（added / changed 有值）
  final String? newValue;

  /// 字段级变化（仅 changed 且为「键控集合」时非空）
  final List<({String field, String from, String to})> fieldChanges;

  /// 两次快照载荷版本不同时，新增/移除可能只是「采集能力变化」，标记待确认
  final bool uncertain;

  /// 内容指纹判定（针对有指纹的条目，如 .so 的 CRC32、dex 的头 SHA-1）：
  /// `true` = 指纹一致 → **是同一个文件**；`false` = 指纹不同 → 同名但内容已变；
  /// `null` = 无可比指纹（旧快照 / 该源没提供）。
  final bool? sameContent;

  /// 该条目的内容指纹（.so 的 CRC32/SHA-256、dex 的头 SHA-1 …）
  final String contentIdentity;

  /// 展示用单行描述
  String get description {
    switch (kind) {
      case SnapshotDiffKind.added:
        return newValue ?? key;
      case SnapshotDiffKind.removed:
        return oldValue ?? key;
      case SnapshotDiffKind.changed:
        if (fieldChanges.isEmpty) {
          return '${oldValue ?? '—'} → ${newValue ?? '—'}';
        }
        return fieldChanges.map((f) => '${f.field}: ${f.from} → ${f.to}').join('\n');
    }
  }
}

/// 一个对比分节
class SnapshotDiffSection {
  const SnapshotDiffSection({
    required this.title,
    this.entries = const [],
    this.comparable = true,
  });

  final String title;
  final List<SnapshotDiffEntry> entries;

  /// 该节在新旧快照间是否具备可比字段（false 时不出条目）
  final bool comparable;

  int countOf(SnapshotDiffKind kind) =>
      entries.where((e) => e.kind == kind).length;

  int get added => countOf(SnapshotDiffKind.added);
  int get removed => countOf(SnapshotDiffKind.removed);
  int get changed => countOf(SnapshotDiffKind.changed);
  int get total => entries.length;
  bool get hasDiff => entries.isNotEmpty;
}

/// 完整对比结果
class SnapshotDiff {
  const SnapshotDiff({
    required this.oldRecord,
    required this.newRecord,
    this.sections = const [],
    this.payloadVersionMismatch = false,
    this.verdict = const SnapshotChangeVerdict(),
  });

  final SnapshotRecord oldRecord;
  final SnapshotRecord newRecord;
  final List<SnapshotDiffSection> sections;

  /// 两次快照的载荷 schema 版本不同（差异可能来自采集能力变化）
  final bool payloadVersionMismatch;

  /// 结论性摘要（"重构建 / 仅资源更新 / 仅原生更新 / 重新签名"）
  ///
  /// 单看某一节的变化很难下判断；把各节指纹汇总成一句话，
  /// 回答"这个包到底是变了什么"。
  final SnapshotChangeVerdict verdict;

  Iterable<SnapshotDiffSection> get changedSections =>
      sections.where((s) => s.hasDiff);

  int get added =>
      changedSections.fold(0, (n, s) => n + s.added);
  int get removed =>
      changedSections.fold(0, (n, s) => n + s.removed);
  int get changed =>
      changedSections.fold(0, (n, s) => n + s.changed);

  int get total => added + removed + changed;
  bool get hasDiff => total > 0;
}

/// 变化结论：把各节指纹汇总成一句判断
class SnapshotChangeVerdict {
  const SnapshotChangeVerdict({
    this.title = '',
    this.signatureSame = true,
    this.dexSame = true,
    this.nativeSame = true,
    this.assetsSame = true,
    this.arscSame = true,
    this.labels = const [],
  });

  /// 结论文案
  final String title;
  final bool signatureSame;
  final bool dexSame;
  final bool nativeSame;
  final bool assetsSame;
  final bool arscSame;

  /// 发生变化的类别标签（如「DEX 变更」「原生库变更」）
  final List<String> labels;

  bool get hasChange => labels.isNotEmpty;
}

/// 快照对比引擎（纯函数，便于单测）
///
/// 设计取舍：LibChecker 存的是「每类一整段 JSON」，对比时只能对字符串做集合差；
/// 我们手里是**结构化对象**，因此做键控集合 + **字段级变化**，
/// 能回答「这个 .so 变大了多少 / 这个组件从导出变成不导出 / 权限上限从 33 降到 29」。
class SnapshotDiffEngine {
  const SnapshotDiffEngine._();

  static SnapshotDiff compare(SnapshotRecord oldRecord, SnapshotRecord newRecord) {
    final old = oldRecord.payload;
    final newP = newRecord.payload;
    final mismatch = old.payloadVersion != newP.payloadVersion;
    // v2 才采集的字段（内容指纹 / 压缩信息 / assets / arsc / 包结构）只在**两侧都是 v2+**
    // 时参与对比；否则会把"旧快照没有该字段"误报成"值变了"（0 → 真值）。
    final rich = old.payloadVersion >= kSnapshotPayloadVersion &&
        newP.payloadVersion >= kSnapshotPayloadVersion;

    final sections = <SnapshotDiffSection>[
      _scalarSection('应用信息', [
        ('应用名', old.app.label, newP.app.label),
        ('版本名', old.app.versionName, newP.app.versionName),
        ('版本号', old.app.versionCode, newP.app.versionCode),
        ('APK 大小', formatBytes(old.app.apkSize), formatBytes(newP.app.apkSize)),
        ('UID', '${old.app.uid}', '${newP.app.uid}'),
        ('是否为系统应用', _bool(old.app.isSystemApp), _bool(newP.app.isSystemApp)),
        ('是否可调试', _bool(old.app.isDebuggable), _bool(newP.app.isDebuggable)),
        ('数据目录', old.app.dataDir, newP.app.dataDir),
        ('安装来源', old.app.installer, newP.app.installer),
        ('主 Activity', old.app.mainActivity, newP.app.mainActivity),
        ('minSdk', old.app.minSdk, newP.app.minSdk),
        ('targetSdk', old.app.targetSdk, newP.app.targetSdk),
        ('compileSdk', old.app.compileSdk, newP.app.compileSdk),
        ('sharedUserId', old.app.sharedUserId, newP.app.sharedUserId),
        ('首次安装', formatTime(old.app.firstInstallTime),
            formatTime(newP.app.firstInstallTime)),
        ('最近更新', formatTime(old.app.lastUpdateTime),
            formatTime(newP.app.lastUpdateTime)),
      ]),
      _setSection('ABI 架构', old.app.abis.toSet(), newP.app.abis.toSet(),
          uncertain: mismatch),
      _scalarSection('签名方案', [
        ('签名形态', old.signature.signingShape, newP.signature.signingShape),
        ('启用的方案', old.signature.schemes.join(' · '),
            newP.signature.schemes.join(' · ')),
      ]),
      _keyedSection(
        '签名证书',
        {for (final c in old.signature.certificates) c.sha256: c},
        {for (final c in newP.signature.certificates) c.sha256: c},
        labelOf: (c) => c.subject.isEmpty ? c.sha256 : c.subject,
        fieldsOf: (c) => [
          ('主题', c.subject),
          ('算法', c.algorithm),
          ('角色', c.kind),
          ('SHA-1', c.sha1),
        ],
        uncertain: mismatch,
      ),
      _keyedSection(
        '权限',
        {for (final p in old.permissions) p.name: p},
        {for (final p in newP.permissions) p.name: p},
        labelOf: (p) => p.name.replaceFirst('android.permission.', ''),
        fieldsOf: (p) => [
          ('maxSdkVersion', p.maxSdkVersion.isEmpty ? '—' : p.maxSdkVersion),
          ('已授权', _bool(p.granted)),
          ('不用于定位', _bool(p.neverForLocation)),
        ],
        uncertain: mismatch,
      ),
      _keyedSection(
        '组件',
        {for (final c in old.components) '${c.kind}|${c.name}': c},
        {for (final c in newP.components) '${c.kind}|${c.name}': c},
        labelOf: (c) => '${c.kind} ${c.name}',
        fieldsOf: (c) => [
          ('exported', c.exported.isEmpty ? '—' : c.exported),
          ('enabled', c.enabled.isEmpty ? '—' : c.enabled),
          ('process', c.processName.isEmpty ? '—' : c.processName),
          ('actions', c.actions.isEmpty ? '—' : c.actions.join(', ')),
          ('深链', c.deepLinks.isEmpty ? '—' : c.deepLinks.join(', ')),
        ],
        uncertain: mismatch,
      ),
      _setSection(
        '快捷启动（深链）',
        {for (final c in old.components) ...c.deepLinks.map((u) => '$u ← ${c.name}')},
        {for (final c in newP.components) ...c.deepLinks.map((u) => '$u ← ${c.name}')},
        uncertain: mismatch,
      ),
      _keyedSection(
        '原生库文件',
        {for (final l in old.nativeLibs) '${l.abi}|${l.name}': l},
        {for (final l in newP.nativeLibs) '${l.abi}|${l.name}': l},
        labelOf: (l) => '${l.name} (${l.abi})',
        fieldsOf: (l) => [
          ('大小', formatBytes(l.size)),
          if (rich) ('压缩后', formatBytes(l.compressedSize)),
          if (rich) ('存放方式', _storedLabel(l.stored, l.zipAlignment)),
          // 指纹字段用于"一眼看出内容是否相同"；判定结论另见 sameContent
          if (rich) ('内容指纹', _fpLabel(l.crc32)),
          if (rich && l.path.isNotEmpty) ('路径', l.path),
        ],
        identityOf:
            rich ? (SnapshotNativeLib l) => l.crc32 == 0 ? '' : '${l.crc32}' : null,
        // 文件类条目固定列出大小：内容变了但体积没变时也要看得到
        alwaysFields: const ['大小'],
        uncertain: mismatch,
      ),
      _keyedSection(
        'ELF 元数据',
        {for (final e in old.elfFiles) '${e.abi}|${e.soName}': e},
        {for (final e in newP.elfFiles) '${e.abi}|${e.soName}': e},
        labelOf: (e) => '${e.soName} (${e.abi})',
        fieldsOf: (e) => [
          ('最小页对齐', '${e.minPageSize}'),
          ('16KB 对齐', _bool(e.aligned16Kb)),
          ('zip 对齐', '${e.zipAlignment}'),
          ('ELF 类型', '${e.elfType}'),
          ('动态依赖', e.needed.isEmpty ? '—' : e.needed.join(', ')),
          ('JNI 入口', e.jniEntryPoints.isEmpty
              ? '—'
              : e.jniEntryPoints.join(', ')),
          ('符号表', e.stripped ? '已剥离' : '未剥离'),
          if (e.sha256.isNotEmpty) ('SHA-256', 'sha256:${e.sha256}'),
          if (e.buildId.isNotEmpty) ('build-id', e.buildId),
        ],
        // SHA-256 是强指纹：同名 .so 是否"同一个文件"由它判定；
        // build-id 相同但 sha256 不同 → 同一构建重新链接过
        identityOf: (SnapshotElfInfo e) => e.sha256,
        // 依赖与 JNI 入口是**集合**：单独给出增删，而不是把整串当"值变了"
        listFieldsOf: (e) => [
          ('动态依赖变化', e.needed),
          ('JNI 入口变化', e.jniEntryPoints),
        ],
        uncertain: mismatch,
      ),
      _setSection(
        '命中的第三方库（原生）',
        {for (final h in old.nativeHits) '${h.label}|${h.matched}'},
        {for (final h in newP.nativeHits) '${h.label}|${h.matched}'},
        uncertain: mismatch,
      ),
      ..._dexSections(old, newP, rich: rich, mismatch: mismatch),
      _keyedSection(
        'DEX 文件（明细）',
        {for (final d in old.dexFiles) d.name: d},
        {for (final d in newP.dexFiles) d.name: d},
        labelOf: (d) => d.name,
        fieldsOf: (d) => [
          ('大小', formatBytes(d.size)),
          if (rich) ('压缩后', formatBytes(d.compressedSize)),
          ('类数量', '${d.classCount}'),
          if (rich) ('方法数', '${d.methodCount}'),
          if (rich) ('字段数', '${d.fieldCount}'),
          if (rich) ('字符串数', '${d.stringCount}'),
          ('CRC32', '${d.crc32}'),
          if (rich && d.hasHeaderFingerprint) ('头指纹', 'sha1:${d.headerSha1}'),
        ],
        // 头 SHA-1 是编译期算好的整包内容指纹 → "同名 dex 是否同一个"的直接依据
        identityOf: rich
            ? (SnapshotDexFile d) => d.hasHeaderFingerprint
                ? d.headerSha1
                : (d.crc32 == 0 ? '' : '${d.crc32}')
            : null,
        alwaysFields: const ['大小'],
        uncertain: mismatch,
      ),
      SnapshotDiffSection(
        title: '包结构',
        comparable: rich,
        entries: rich
            ? _scalarSection('包结构', [
                ('zip 条目总数', '${old.structure.entryCount}',
                    '${newP.structure.entryCount}'),
                ('解压后总量', formatBytes(old.structure.totalUncompressed),
                    formatBytes(newP.structure.totalUncompressed)),
                ('STORED 条目数', '${old.structure.storedEntryCount}',
                    '${newP.structure.storedEntryCount}'),
              ]).entries
            : const [],
      ),
      _keyedSection(
        'assets 文件',
        {for (final a in old.assets) a.name: a},
        {for (final a in newP.assets) a.name: a},
        labelOf: (a) => a.name,
        fieldsOf: (a) => [
          ('大小', formatBytes(a.size)),
          ('压缩后', formatBytes(a.compressedSize)),
          ('存放方式', a.stored ? 'STORED' : 'DEFLATE'),
          ('内容指纹', _fpLabel(a.crc32)),
        ],
        identityOf: (a) => a.crc32 == 0 ? '' : '${a.crc32}',
        alwaysFields: const ['大小'],
        uncertain: mismatch,
        comparable: rich,
      ),
      SnapshotDiffSection(
        title: 'resources.arsc',
        comparable: rich,
        entries: rich
            ? [
                ..._scalarSection('resources.arsc', [
                  ('是否存在', _bool(old.arsc.present), _bool(newP.arsc.present)),
                  ('大小', formatBytes(old.arsc.size),
                      formatBytes(newP.arsc.size)),
                  ('压缩后', formatBytes(old.arsc.compressedSize),
                      formatBytes(newP.arsc.compressedSize)),
                  ('存放方式', old.arsc.stored ? 'STORED' : 'DEFLATE',
                      newP.arsc.stored ? 'STORED' : 'DEFLATE'),
                  ('内容指纹', _fpLabel(old.arsc.crc32),
                      _fpLabel(newP.arsc.crc32)),
                  // 浅解析维度（解析失败时为空串，不产生假差异）
                  ('包名', old.arsc.packageNames.join(', '),
                      newP.arsc.packageNames.join(', ')),
                  ('资源类型数', '${old.arsc.typeNames.length}',
                      '${newP.arsc.typeNames.length}'),
                  ('全局字符串数', '${old.arsc.globalStringCount}',
                      '${newP.arsc.globalStringCount}'),
                  ('资源名数', '${old.arsc.keyCount}', '${newP.arsc.keyCount}'),
                  ('类型条目数', '${old.arsc.entryInstances}',
                      '${newP.arsc.entryInstances}'),
                ]).entries,
                // 语言/地区集合：新增或移除语言单独列出
                ..._setSection(
                  'resources.arsc 语言',
                  old.arsc.configs.toSet(),
                  newP.arsc.configs.toSet(),
                ).entries.map(
                      (e) => SnapshotDiffEntry(
                        kind: e.kind,
                        key: '语言 ${e.key}',
                        oldValue: e.oldValue,
                        newValue: e.newValue,
                      ),
                    ),
              ]
            : const [],
      ),
      SnapshotDiffSection(
        title: 'resources.arsc 资源',
        comparable: rich,
        entries: rich
            ? _keyedSection(
                'resources.arsc 资源',
                {for (final r in old.arsc.resources) '${r.id}': r},
                {for (final r in newP.arsc.resources) '${r.id}': r},
                labelOf: (r) => r.label,
                fieldsOf: (r) => [
                  ('类型', r.typeName),
                  ('资源名', r.key),
                  ('值类型', r.valueKind),
                  ('值', r.value),
                ],
              ).entries
            : const [],
      ),
      _setSection(
        '命中的第三方库（DEX）',
        {for (final h in old.dexHits) '${h.label}|${h.matched}'},
        {for (final h in newP.dexHits) '${h.label}|${h.matched}'},
        uncertain: mismatch,
      ),
      _setSection(
        '特征',
        old.features.labels.toSet(),
        newP.features.labels.toSet(),
        uncertain: mismatch,
      ),
      _scalarSection('构建版本', [
        ('Kotlin', old.buildVersions.kotlinVersion, newP.buildVersions.kotlinVersion),
        ('Gradle', old.buildVersions.gradleVersion, newP.buildVersions.gradleVersion),
        ('Java', old.buildVersions.javaVersion, newP.buildVersions.javaVersion),
        ('Compose', old.buildVersions.composeVersion, newP.buildVersions.composeVersion),
        ('AGP', old.buildVersions.agpVersion, newP.buildVersions.agpVersion),
      ]),
      _keyedSection(
        'meta-data',
        {for (final m in old.metaData) m.name: m},
        {for (final m in newP.metaData) m.name: m},
        labelOf: (m) => m.name,
        fieldsOf: (m) => [('值', m.value)],
        uncertain: mismatch,
      ),
      _setSection(
        '命中的静态库',
        {for (final h in old.staticLibraries) '${h.label}|${h.matched}'},
        {for (final h in newP.staticLibraries) '${h.label}|${h.matched}'},
        uncertain: mismatch,
      ),
      _setSection(
        '命中的 action',
        {for (final h in old.actionHits) '${h.label}|${h.matched}'},
        {for (final h in newP.actionHits) '${h.label}|${h.matched}'},
        uncertain: mismatch,
      ),
      _setSection(
        '命中的组件库',
        {for (final h in old.componentHits) '${h.label}|${h.matched}'},
        {for (final h in newP.componentHits) '${h.label}|${h.matched}'},
        uncertain: mismatch,
      ),
    ];

    return SnapshotDiff(
      oldRecord: oldRecord,
      newRecord: newRecord,
      sections: sections,
      payloadVersionMismatch: mismatch,
      verdict: _verdict(old, newP),
    );
  }

  /// DEX 两个分区：① 类集合搬迁（multidex 分包变化）② 文件级明细
  ///
  /// 类搬迁用**每份 dex 的类集合指纹**判断：指纹相同的一组类，
  /// 从 `classes.dex` 出现在 `classes3.dex`，就是分包/搬迁，
  /// 而无需落库上万个类名（单包 5 个 dex 的类名清单原文约 1MB）。
  static List<SnapshotDiffSection> _dexSections(
    SnapshotPayload old,
    SnapshotPayload newP, {
    required bool rich,
    required bool mismatch,
  }) {
    final before = <String, String>{
      for (final d in old.dexFiles)
        if (d.classDigest.isNotEmpty) d.classDigest: d.name,
    };
    final after = <String, String>{
      for (final d in newP.dexFiles)
        if (d.classDigest.isNotEmpty) d.classDigest: d.name,
    };
    final entries = <SnapshotDiffEntry>[];
    for (final e in before.entries) {
      final nowAt = after[e.key];
      if (nowAt == null) {
        entries.add(
          SnapshotDiffEntry(
            kind: SnapshotDiffKind.removed,
            key: '${e.value} 的类集合',
            oldValue: e.value,
            uncertain: mismatch,
          ),
        );
      } else if (nowAt != e.value) {
        entries.add(
          SnapshotDiffEntry(
            kind: SnapshotDiffKind.changed,
            key: '类集合搬迁：${e.value} → $nowAt',
            oldValue: e.value,
            newValue: nowAt,
            fieldChanges: [(field: '所在 dex', from: e.value, to: nowAt)],
            sameContent: true,
            uncertain: mismatch,
          ),
        );
      }
    }
    for (final e in after.entries) {
      if (before.containsKey(e.key)) continue;
      entries.add(
        SnapshotDiffEntry(
          kind: SnapshotDiffKind.added,
          key: '${e.value} 的类集合',
          newValue: e.value,
          uncertain: mismatch,
        ),
      );
    }
    return [
      SnapshotDiffSection(
        title: 'DEX 类集合搬迁',
        comparable: rich,
        entries: rich ? entries : const [],
      ),
    ];
  }

  /// 结论摘要：按"签名 / DEX / 原生库 / 资源"四类指纹各自判断是否变过
  static SnapshotChangeVerdict _verdict(
    SnapshotPayload old,
    SnapshotPayload newP,
  ) {
    bool sameSet<T>(List<T> a, List<T> b, String Function(T) id) {
      if (a.length != b.length) return false;
      final before = {for (final e in a) id(e)};
      final after = {for (final e in b) id(e)};
      return before.length == after.length &&
          before.containsAll(after) &&
          after.containsAll(before);
    }

    final sigSame = sameSet(
      old.signature.certificates,
      newP.signature.certificates,
      (c) => c.sha256,
    );
    final dexSame = sameSet(
      old.dexFiles,
      newP.dexFiles,
      (d) => '${d.name}|${d.crc32}|${d.headerSha1}',
    );
    final soSame = sameSet(
      old.nativeLibs,
      newP.nativeLibs,
      (l) => '${l.abi}|${l.name}|${l.crc32}',
    );
    final assetsSame = sameSet(old.assets, newP.assets, (a) => '${a.name}|${a.crc32}');
    final arscSame = old.arsc.crc32 == newP.arsc.crc32 &&
        old.arsc.present == newP.arsc.present;

    final labels = <String>[];
    if (!sigSame) labels.add('签名变更');
    if (!dexSame) labels.add('DEX 变更');
    if (!soSame) labels.add('原生库变更');
    if (!assetsSame) labels.add('assets 变更');
    if (!arscSame) labels.add('资源表变更');

    String title;
    if (labels.isEmpty) {
      title = '未检出内容变化（可能仅版本号/元数据变化）';
    } else if (!sigSame) {
      title = '签名已变 —— 可能被重新签名或非同一来源发布';
    } else if (dexSame && soSame && (labels.length == 1)) {
      final only = labels.first.replaceAll(' 变更', '');
      title = '仅 $only 变化（代码与签名均未变）';
    } else if (!dexSame && !soSame) {
      title = '代码整体重新构建（DEX 与原生库都变）';
    } else if (!dexSame) {
      title = '仅代码（DEX）变化，签名与原生库未变';
    } else if (!soSame) {
      title = '仅原生库变化，签名与 DEX 未变';
    } else {
      title = '资源内容更新（代码与签名未变）';
    }
    return SnapshotChangeVerdict(
      title: title,
      signatureSame: sigSame,
      dexSame: dexSame,
      nativeSame: soSame,
      assetsSame: assetsSame,
      arscSame: arscSame,
      labels: labels,
    );
  }

  /// CRC32 → 8 位 hex（带前缀，便于肉眼比对）
  static String _fpLabel(int crc32) =>
      crc32 == 0 ? '—' : 'crc32:${crc32.toUnsigned(32).toRadixString(16).padLeft(8, '0')}';

  /// 存放方式：STORED(+对齐) / DEFLATE
  static String _storedLabel(bool stored, int alignment) {
    if (!stored) return 'DEFLATE';
    return alignment > 0 ? 'STORED · ${alignment}B 对齐' : 'STORED';
  }

  /// 标量字段对比：仅保留取值不同的字段，一条一条列出来
  static SnapshotDiffSection _scalarSection(
    String title,
    List<(String, String, String)> fields,
  ) {
    final entries = <SnapshotDiffEntry>[];
    for (final (name, before, after) in fields) {
      if (before == after) continue;
      entries.add(
        SnapshotDiffEntry(
          kind: SnapshotDiffKind.changed,
          key: name,
          oldValue: before,
          newValue: after,
        ),
      );
    }
    return SnapshotDiffSection(title: title, entries: entries);
  }

  /// 纯集合对比（只有新增/移除）
  static SnapshotDiffSection _setSection(
    String title,
    Set<String> before,
    Set<String> after, {
    bool uncertain = false,
  }) {
    final entries = <SnapshotDiffEntry>[
      for (final v in before.difference(after))
        SnapshotDiffEntry(
          kind: SnapshotDiffKind.removed,
          key: v,
          oldValue: v,
          uncertain: uncertain,
        ),
      for (final v in after.difference(before))
        SnapshotDiffEntry(
          kind: SnapshotDiffKind.added,
          key: v,
          newValue: v,
          uncertain: uncertain,
        ),
    ]..sort(_byKindThenKey);
    return SnapshotDiffSection(title: title, entries: entries);
  }

  /// 键控集合对比：新增 / 移除 / **字段级变化** / **内容指纹判定**
  ///
  /// - [identityOf]：给出条目的**内容指纹**（.so 的 CRC32、dex 的头 SHA-1）。
  ///   两侧都有指纹时，据此给出「是否同一个文件」的明确结论（[SnapshotDiffEntry.sameContent]），
  ///   而不是让人从一串 hex 里去比。
  /// - [listFieldsOf]：值本身是**集合**的字段（如 ELF 的动态依赖 / JNI 入口）。
  ///   单独给出「+ 新增 / − 移除」，避免整串拼接被当成"值变了"而看不出增删了哪条。
  /// - [comparable]：载荷版本不支持该节字段时置 false，明确告知"不可比"，
  ///   而不是把缺失当变化。
  /// - [alwaysFields]：**无论是否变化都列出**的字段名（文件类条目固定列「大小」）。
  ///   值未变时按单行给出，不重复 `−`/`+`；且**单独的值未变不会把条目误报成 changed**。
  static SnapshotDiffSection _keyedSection<T>(
    String title,
    Map<String, T> before,
    Map<String, T> after, {
    required String Function(T) labelOf,
    required List<(String, String)> Function(T) fieldsOf,
    String Function(T)? identityOf,
    List<(String, List<String>)> Function(T)? listFieldsOf,
    List<String> alwaysFields = const [],
    bool uncertain = false,
    bool comparable = true,
  }) {
    if (!comparable) {
      return SnapshotDiffSection(title: title, comparable: false);
    }
    final entries = <SnapshotDiffEntry>[];

    for (final e in before.entries) {
      final b = e.value;
      final a = after[e.key];
      if (a == null) {
        entries.add(
          SnapshotDiffEntry(
            kind: SnapshotDiffKind.removed,
            key: labelOf(b),
            oldValue: labelOf(b),
            fieldChanges: _itemFields(
              b,
              fieldsOf: fieldsOf,
              listFieldsOf: listFieldsOf,
              added: false,
            ),
            uncertain: uncertain,
            contentIdentity: identityOf?.call(b) ?? '',
          ),
        );
        continue;
      }
      // [changes] 只放**真正的差异**（用于判定该条目是否算变化）；
      // [shown] 是最终输出的字段列表，额外带上 [alwaysFields] 中未变的字段（如文件大小），
      // 按 fieldsOf 的声明顺序排列，保证「大小」始终在最前。
      final changes = <({String field, String from, String to})>[];
      final shown = <({String field, String from, String to})>[];
      final beforeFields = {for (final f in fieldsOf(b)) f.$1: f.$2};
      final afterFields = {for (final f in fieldsOf(a)) f.$1: f.$2};
      for (final field in beforeFields.entries) {
        final afterValue = afterFields[field.key];
        if (afterValue == null) continue;
        if (field.value != afterValue) {
          final change = (field: field.key, from: field.value, to: afterValue);
          changes.add(change);
          shown.add(change);
        } else if (alwaysFields.contains(field.key) &&
            field.value.isNotEmpty &&
            field.value != '—') {
          shown.add((field: field.key, from: field.value, to: afterValue));
        }
      }

      // 集合型字段（ELF 依赖 / JNI 入口）：只列真正增删的条目
      if (listFieldsOf != null) {
        final beforeLists = {for (final f in listFieldsOf(b)) f.$1: f.$2.toSet()};
        final afterLists = {for (final f in listFieldsOf(a)) f.$1: f.$2.toSet()};
        for (final field in beforeLists.entries) {
          final afterList = afterLists[field.key];
          if (afterList == null) continue;
          final gone = field.value.difference(afterList).toList()..sort();
          final fresh = afterList.difference(field.value).toList()..sort();
          if (gone.isEmpty && fresh.isEmpty) continue;
          final change = (
            field: field.key,
            from: gone.isEmpty ? '—' : '−${gone.join(', −')}',
            to: fresh.isEmpty ? '—' : '+${fresh.join(', +')}',
          );
          changes.add(change);
          shown.add(change);
        }
      }

      // 内容指纹：给出"是否同一个文件"的明确结论
      bool? sameContent;
      if (identityOf != null) {
        final idBefore = identityOf(b);
        final idAfter = identityOf(a);
        if (idBefore.isNotEmpty && idAfter.isNotEmpty) {
          sameContent = idBefore == idAfter;
        }
      }

      if (changes.isNotEmpty || sameContent == false) {
        entries.add(
          SnapshotDiffEntry(
            kind: SnapshotDiffKind.changed,
            key: labelOf(a),
            oldValue: labelOf(b),
            newValue: labelOf(a),
            fieldChanges: shown,
            uncertain: uncertain,
            sameContent: sameContent,
            contentIdentity: identityOf?.call(a) ?? '',
          ),
        );
      }
    }

    for (final e in after.entries) {
      if (before.containsKey(e.key)) continue;
      entries.add(
        SnapshotDiffEntry(
          kind: SnapshotDiffKind.added,
          key: labelOf(e.value),
          newValue: labelOf(e.value),
          fieldChanges: _itemFields(
            e.value,
            fieldsOf: fieldsOf,
            listFieldsOf: listFieldsOf,
            added: true,
          ),
          uncertain: uncertain,
          contentIdentity: identityOf?.call(e.value) ?? '',
        ),
      );
    }

    // 改名 / 移动检测：**内容指纹一致但名字不同** → 合并成一条「疑似改名」，
    // 而不是报成"删一个、加一个"（.so/.dex/asset 改名或换目录时最有用）。
    if (identityOf != null) {
      final removed = entries
          .where((e) =>
              e.kind == SnapshotDiffKind.removed &&
              e.contentIdentity.isNotEmpty)
          .toList();
      final added = entries
          .where((e) =>
              e.kind == SnapshotDiffKind.added && e.contentIdentity.isNotEmpty)
          .toList();
      for (final r in removed) {
        SnapshotDiffEntry? match;
        for (final a in added) {
          if (identical(a, r)) continue;
          if (a.contentIdentity == r.contentIdentity) {
            match = a;
            break;
          }
        }
        if (match == null) continue;
        final a = match;
        entries.remove(r);
        entries.remove(a);
        entries.add(
          SnapshotDiffEntry(
            kind: SnapshotDiffKind.changed,
            key: '疑似改名/移动：${r.key} → ${a.key}',
            oldValue: r.key,
            newValue: a.key,
            fieldChanges: [(field: '名称', from: r.key, to: a.key)],
            sameContent: true,
            contentIdentity: r.contentIdentity,
          ),
        );
      }
      entries.sort(_byKindThenKey);
    }

    entries.sort(_byKindThenKey);
    return SnapshotDiffSection(title: title, entries: entries);
  }

  /// 新增 / 移除条目也要带上**条目自身的字段**（大小 / 压缩后 / 指纹…）。
  ///
  /// 只给一个名字（[labelOf]）会让「新增了一个 .so」看不到体积——而体积恰恰是
  /// 快照对比最关心的问题。缺失的一侧用 `—` 占位（与字段级变化同一约定），
  /// 由渲染层隐藏；值为空或其本身就是 `—` 的字段直接跳过，避免只剩一个字段名。
  static List<({String field, String from, String to})> _itemFields<T>(
    T item, {
    required List<(String, String)> Function(T) fieldsOf,
    List<(String, List<String>)> Function(T)? listFieldsOf,
    required bool added,
  }) {
    final fields = <({String field, String from, String to})>[];
    for (final f in fieldsOf(item)) {
      final value = f.$2;
      if (value.isEmpty || value == '—') continue;
      fields.add(
        added
            ? (field: f.$1, from: '—', to: value)
            : (field: f.$1, from: value, to: '—'),
      );
    }
    if (listFieldsOf != null) {
      for (final f in listFieldsOf(item)) {
        if (f.$2.isEmpty) continue;
        fields.add(
          added
              ? (field: f.$1, from: '—', to: '+${f.$2.join(', +')}')
              : (field: f.$1, from: '−${f.$2.join(', −')}', to: '—'),
        );
      }
    }
    return fields;
  }

  static int _byKindThenKey(SnapshotDiffEntry a, SnapshotDiffEntry b) {
    final byKind = a.kind.index.compareTo(b.kind.index);
    if (byKind != 0) return byKind;
    return a.key.compareTo(b.key);
  }
}

String _bool(bool value) => value ? '是' : '否';

/// 字节数格式化（1.0 KB / 1.5 MB）
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// `formatBytes` 的逆解析：`1.5 MB` → 1572864。
///
/// 对比页用它把"前后两个体积"还原成数值，直接给出**体积差**，
/// 而不是让人自己拿两个数字做减法。必须带单位（B/KB/MB/GB）才认，
/// 避免把"类数量 3"这种计数误当成 3 字节。
int? tryParseBytes(String text) {
  final m = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*(B|KB|MB|GB)$').firstMatch(text.trim());
  if (m == null) return null;
  final value = double.tryParse(m.group(1)!);
  if (value == null) return null;
  final unit = switch (m.group(2)!) {
    'B' => 1,
    'KB' => 1024,
    'MB' => 1024 * 1024,
    _ => 1024 * 1024 * 1024,
  };
  return (value * unit).round();
}

/// 带符号的体积差（`+2.2 MB` / `−1.0 KB`）；无法解析或相等时返回 null
String? formatBytesDelta(String before, String after) {
  final a = tryParseBytes(before);
  final b = tryParseBytes(after);
  if (a == null || b == null || a == b) return null;
  final diff = b - a;
  return '${diff > 0 ? '+' : '−'}${formatBytes(diff.abs())}';
}

/// 时间戳格式化（yyyy-MM-dd HH:mm）
String formatTime(int millis) {
  if (millis <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}

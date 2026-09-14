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
  });

  final SnapshotRecord oldRecord;
  final SnapshotRecord newRecord;
  final List<SnapshotDiffSection> sections;

  /// 两次快照的载荷 schema 版本不同（差异可能来自采集能力变化）
  final bool payloadVersionMismatch;

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
        fieldsOf: (l) => [('大小', formatBytes(l.size))],
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
              : '${e.jniEntryPoints.length} 个'),
          ('符号表', e.stripped ? '已剥离' : '未剥离'),
        ],
        uncertain: mismatch,
      ),
      _setSection(
        '命中的第三方库（原生）',
        {for (final h in old.nativeHits) '${h.label}|${h.matched}'},
        {for (final h in newP.nativeHits) '${h.label}|${h.matched}'},
        uncertain: mismatch,
      ),
      _keyedSection(
        'DEX 文件',
        {for (final d in old.dexFiles) d.name: d},
        {for (final d in newP.dexFiles) d.name: d},
        labelOf: (d) => d.name,
        fieldsOf: (d) => [
          ('大小', formatBytes(d.size)),
          ('类数量', '${d.classCount}'),
          ('CRC32', '${d.crc32}'),
        ],
        uncertain: mismatch,
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
    );
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

  /// 键控集合对比：新增 / 移除 / **字段级变化**
  static SnapshotDiffSection _keyedSection<T>(
    String title,
    Map<String, T> before,
    Map<String, T> after, {
    required String Function(T) labelOf,
    required List<(String, String)> Function(T) fieldsOf,
    bool uncertain = false,
  }) {
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
            uncertain: uncertain,
          ),
        );
        continue;
      }
      final changes = <({String field, String from, String to})>[];
      final beforeFields = {for (final f in fieldsOf(b)) f.$1: f.$2};
      final afterFields = {for (final f in fieldsOf(a)) f.$1: f.$2};
      for (final field in beforeFields.entries) {
        final afterValue = afterFields[field.key];
        if (afterValue == null) continue;
        if (field.value != afterValue) {
          changes.add((field: field.key, from: field.value, to: afterValue));
        }
      }
      if (changes.isNotEmpty) {
        entries.add(
          SnapshotDiffEntry(
            kind: SnapshotDiffKind.changed,
            key: labelOf(a),
            oldValue: labelOf(b),
            newValue: labelOf(a),
            fieldChanges: changes,
            uncertain: uncertain,
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
          uncertain: uncertain,
        ),
      );
    }

    entries.sort(_byKindThenKey);
    return SnapshotDiffSection(title: title, entries: entries);
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

/// 时间戳格式化（yyyy-MM-dd HH:mm）
String formatTime(int millis) {
  if (millis <= 0) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}';
}

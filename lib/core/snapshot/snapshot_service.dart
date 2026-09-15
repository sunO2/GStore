/// 应用快照服务：采集 / 查询 / 对比 / 文本化
///
/// UI（快照页）与 Agent 工具共用的入口，避免两条创建路径各自实现一遍。
/// 职责边界：
/// - [create]：解析安装包路径 → 采集 → 落库（版本/名称一律取真实来源，见 SnapshotCollector）
/// - [compare] / [compareLatest]：调用纯函数 [SnapshotDiffEngine] 产出结构化差异
/// - [renderDiff] / [renderDetail] / [renderAppList]：把结构化结果**渲染成文本**给模型阅读
library;

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:gstore/core/snapshot/app_snapshot_store.dart';
import 'package:gstore/core/snapshot/snapshot_collector.dart';
import 'package:gstore/core/snapshot/snapshot_diff_engine.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';

/// 创建快照的结果
class SnapshotCreateResult {
  const SnapshotCreateResult({
    required this.success,
    required this.message,
    this.record,
    this.warnings = const [],
  });

  final bool success;
  final String message;
  final SnapshotRecord? record;

  /// 采集降级信息（某节缺失），非致命
  final List<String> warnings;
}

/// 应用快照服务（单例）
class AppSnapshotService {
  AppSnapshotService._();

  static final AppSnapshotService instance = AppSnapshotService._();

  AppSnapshotStore get _store => AppSnapshotStore.instance;

  /// 创建一份快照。
  ///
  /// [sourceDir] 可省略：省略时按包名现取已安装 APK 路径（应用已卸载则失败）。
  /// 快照的版本/名称**不采用调用方传值**，由采集器从真实 APK/系统读取。
  Future<SnapshotCreateResult> create({
    required String packageName,
    String appLabel = '',
    String? sourceDir,
    List<String>? sourceDirs,
    String note = '',
  }) async {
    if (packageName.isEmpty) {
      return const SnapshotCreateResult(success: false, message: '需要 packageName');
    }

    var dir = sourceDir ?? '';
    var dirs = sourceDirs;
    if (dir.isEmpty) {
      try {
        dir = await ApkSourceService.instance.getSourceDir(packageName) ?? '';
        if (dir.isNotEmpty && dirs == null) {
          dirs = await ApkSourceService.instance.getSourceDirs(packageName);
        }
      } catch (e) {
        appLog.error('AppSnapshotService: 取安装包路径失败 - $packageName - $e');
      }
    }
    if (dir.isEmpty) {
      return const SnapshotCreateResult(
        success: false,
        message: '未找到该应用的安装包（可能未安装），无法创建快照',
      );
    }
    if (dirs != null && dirs.isEmpty) dirs = null;

    try {
      final result = await SnapshotCollector.instance.capture(
        packageName: packageName,
        appLabel: appLabel,
        sourceDir: dir,
        sourceDirs: dirs,
      );
      // 记录页的应用名同样取真实来源（采集到的 label 优先）
      final realLabel = result.payload.app.label.isNotEmpty
          ? result.payload.app.label
          : appLabel;
      final record = SnapshotCollector.instance.toRecord(
        result,
        packageName: packageName,
        appLabel: realLabel,
        capturedAt: DateTime.now().millisecondsSinceEpoch,
        note: note,
      );
      final id = await _store.insert(record);
      if (id == null) {
        return const SnapshotCreateResult(success: false, message: '快照写入失败');
      }
      final saved = record.copyWith(id: id);
      final warnings = result.warnings;
      return SnapshotCreateResult(
        success: true,
        message: '快照已创建（id=$id，版本 ${saved.versionName}，'
            '规则命中 ${saved.summary.ruleHits} 项'
            '${warnings.isEmpty ? '' : '，${warnings.length} 处数据缺失'}）',
        record: saved,
        warnings: warnings,
      );
    } catch (e) {
      appLog.error('AppSnapshotService: 创建快照失败 - $e');
      return SnapshotCreateResult(success: false, message: '创建快照失败: $e');
    }
  }

  /// 某应用的快照（时间倒序，最新在前）
  Future<List<SnapshotRecord>> listByApp(String packageName) =>
      _store.listByApp(packageName);

  /// 全部已有快照的应用（按最近采集时间倒序）
  Future<List<SnapshotAppEntry>> listApps() => _store.listApps();

  /// 按 id 取单份
  Future<SnapshotRecord?> getById(int id) => _store.getById(id);

  /// 删除单份快照
  Future<bool> delete(int id) => _store.delete(id);

  /// 按包名删除全部快照
  Future<int> deleteByApp(String packageName) => _store.deleteByApp(packageName);

  /// 对比两份快照。
  ///
  /// [oldId]/[newId] 省略时取该应用**最近两份**（时间上早的为 old）。
  /// 指定时按采集时间自动纠正方向，保证 old 早于 new。
  Future<SnapshotDiff?> compare({
    required String packageName,
    int? oldId,
    int? newId,
  }) async {
    SnapshotRecord? oldR;
    SnapshotRecord? newR;

    if (oldId != null && newId != null) {
      oldR = await _store.getById(oldId);
      newR = await _store.getById(newId);
    } else {
      final records = await _store.listByApp(packageName);
      if (records.length < 2) return null;
      newR = records[0];
      oldR = records[1];
    }
    if (oldR == null || newR == null) return null;
    // 方向纠正：始终 old（早） → new（晚）
    if (oldR.createdAt > newR.createdAt) {
      final t = oldR;
      oldR = newR;
      newR = t;
    }
    return SnapshotDiffEngine.compare(oldR, newR);
  }

  // ==================== 文本化（供模型阅读） ====================

  /// 渲染应用列表
  String renderAppList(List<SnapshotAppEntry> apps) {
    if (apps.isEmpty) {
      return '暂无任何应用快照。可先用 appSnapshot(action=create, packageName=...) 创建。';
    }
    final buf = StringBuffer('已有快照的应用 ${apps.length} 个：\n');
    for (final a in apps) {
      buf.writeln('• ${a.displayName}（${a.packageName}）'
          '${a.latestVersionName.isEmpty ? '' : ' v${a.latestVersionName}'}'
          ' · ${a.count} 份 · 最近 ${formatTime(a.latestAt)}');
    }
    return buf.toString().trimRight();
  }

  /// 渲染某应用的快照列表（含 id，便于指定对比）
  String renderRecordList(String packageName, List<SnapshotRecord> records) {
    if (records.isEmpty) {
      return '$packageName 还没有快照。可用 appSnapshot(action=create) 创建。';
    }
    final buf = StringBuffer('$packageName 共 ${records.length} 份快照（新→旧）：\n');
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      buf.writeln('• id=${r.id} v${r.versionName}(${r.versionCode}) '
          '${formatTime(r.createdAt)}'
          '${r.note.isEmpty ? '' : ' [${r.note}]'}'
          ' · 原生库 ${r.summary.nativeLibs} · DEX ${r.summary.dexFiles} · '
          '组件 ${r.summary.components} · 权限 ${r.summary.permissions} · '
          '大小 ${formatBytes(r.summary.apkSize)}');
    }
    return buf.toString().trimRight();
  }

  /// 渲染单份快照概览
  String renderDetail(SnapshotRecord r) {
    final p = r.payload;
    final a = p.app;
    final buf = StringBuffer()
      ..writeln('快照 id=${r.id}｜${a.label.isEmpty ? r.packageName : a.label}'
          '（${r.packageName}）')
      ..writeln('版本：${a.versionName}(${a.versionCode})'
          '${r.note.isEmpty ? '' : '　备注：${r.note}'}')
      ..writeln('采集时间：${formatTime(r.createdAt)}　载荷版本：v${r.payloadVersion}')
      ..writeln('APK 大小：${formatBytes(a.apkSize)}　'
          'zip 条目 ${p.structure.entryCount}　'
          '解压总量 ${formatBytes(p.structure.totalUncompressed)}')
      ..writeln('签名：${p.signature.signingShape}'
          '${p.signature.schemes.isEmpty ? '' : ' · ${p.signature.schemes.join('/')}'}'
          ' · ${p.signature.certificates.length} 张证书')
      ..writeln('原生库 ${p.nativeLibs.length} 个 · ELF ${p.elfFiles.length} 个 · '
          'DEX ${p.dexFiles.length} 个 · assets ${p.assets.length} 个 · '
          '组件 ${p.components.length} 个 · 权限 ${p.permissions.length} 项 · '
          '深链 ${p.deepLinks.length} 条')
      ..writeln('minSdk ${a.minSdk} / targetSdk ${a.targetSdk} / compileSdk ${a.compileSdk}'
          '　ABI：${a.abis.isEmpty ? '—' : a.abis.join('、')}');
    final features = p.features.labels;
    if (features.isNotEmpty) buf.writeln('特征：${features.join('、')}');
    final hits = <String>[
      ...p.nativeHits.map((h) => '原生·${h.label}'),
      ...p.dexHits.map((h) => 'DEX·${h.label}'),
      ...p.componentHits.map((h) => '组件·${h.label}'),
      ...p.staticLibraries.map((h) => '静态库·${h.label}'),
      ...p.actionHits.map((h) => 'action·${h.label}'),
    ];
    if (hits.isNotEmpty) buf.writeln('命中第三方库：${hits.toSet().join('、')}');
    return buf.toString().trimRight();
  }

  /// 渲染完整对比结果（结论 + 逐节明细 + 字段级 from→to）
  ///
  /// [maxEntriesPerSection] 限制每节条目数，避免超长包（上万 assets/dex）撑爆上下文。
  String renderDiff(
    SnapshotDiff diff, {
    int maxEntriesPerSection = 40,
  }) {
    final oldR = diff.oldRecord;
    final newR = diff.newRecord;
    final buf = StringBuffer()
      ..writeln('=== 快照对比 ===')
      ..writeln('应用：${newR.appLabel.isEmpty ? newR.packageName : newR.appLabel}'
          '（${newR.packageName}）')
      ..writeln('基准(旧)：id=${oldR.id} v${oldR.versionName}(${oldR.versionCode}) '
          '${formatTime(oldR.createdAt)}')
      ..writeln('目标(新)：id=${newR.id} v${newR.versionName}(${newR.versionCode}) '
          '${formatTime(newR.createdAt)}');

    final v = diff.verdict;
    buf.writeln();
    buf.writeln('【结论】${v.title}');
    buf.writeln('变化类别：${v.labels.isEmpty ? '无' : v.labels.join('、')}');
    buf.writeln('指纹判定：签名${v.signatureSame ? '一致' : '已变'} · '
        'DEX${v.dexSame ? '一致' : '已变'} · '
        '原生库${v.nativeSame ? '一致' : '已变'} · '
        'assets${v.assetsSame ? '一致' : '已变'} · '
        '资源表${v.arscSame ? '一致' : '已变'}');
    buf.writeln('差异总计：新增 ${diff.added} · 移除 ${diff.removed} · 变化 ${diff.changed}');
    // 体积差（用户不必自己相减）
    final sizeDelta = formatBytesDelta(
      formatBytes(oldR.payload.app.apkSize),
      formatBytes(newR.payload.app.apkSize),
    );
    buf.writeln('APK 体积变化：${sizeDelta ?? '无变化'}');

    if (diff.payloadVersionMismatch) {
      buf.writeln();
      buf.writeln('⚠ 两份快照的载荷版本不同（v${oldR.payloadVersion} → '
          'v${newR.payloadVersion}），部分差异可能来自采集能力变化，'
          '标记为「待确认」的条目请谨慎解读。');
    }

    final changed = diff.changedSections.toList();
    if (changed.isEmpty) {
      buf.writeln();
      buf.writeln('未检出任何内容差异（可能仅版本号变化，或两份快照为同一构建）。');
      return buf.toString().trimRight();
    }

    buf.writeln();
    buf.writeln('=== 变化明细（按分节） ===');
    for (final s in changed) {
      buf.writeln();
      buf.writeln('▸ ${s.title}（+${s.added} / -${s.removed} / ~${s.changed}）');
      final shown = s.entries.take(maxEntriesPerSection).toList();
      for (final e in shown) {
        buf.write(_renderEntry(e));
      }
      if (s.entries.length > shown.length) {
        buf.writeln('  … 其余 ${s.entries.length - shown.length} 条已省略');
      }
    }
    // 明确告知"不可比"的分节（载荷版本不足）
    final incomparable =
        diff.sections.where((s) => !s.comparable).map((s) => s.title).toList();
    if (incomparable.isNotEmpty) {
      buf.writeln();
      buf.writeln('不可比分节（旧快照载荷版本不足）：${incomparable.join('、')}');
    }
    return buf.toString().trimRight();
  }

  /// 单条差异（多行：字段名一行、旧值/新值各一行）
  String _renderEntry(SnapshotDiffEntry e) {
    final buf = StringBuffer();
    final mark = switch (e.kind) {
      SnapshotDiffKind.added => '+',
      SnapshotDiffKind.removed => '-',
      SnapshotDiffKind.changed => '~',
    };
    final uncertain = e.uncertain ? '（待确认）' : '';
    if (e.fieldChanges.isNotEmpty) {
      buf.writeln('  $mark ${e.key}$uncertain');
      if (e.kind == SnapshotDiffKind.changed) {
        if (e.sameContent == true) {
          buf.writeln('     内容指纹一致（同一文件，仅元信息变化）');
        } else if (e.sameContent == false) {
          buf.writeln('     内容指纹不同（同名但内容已变）');
        }
      }
      for (final f in e.fieldChanges) {
        buf.writeln('     ${f.field}');
        // 值未变的常列字段（文件类条目的「大小」）只给一次值
        if (f.from == f.to && f.from.isNotEmpty && f.from != '—') {
          buf.writeln('       = ${f.from}');
          continue;
        }
        // 新增/移除条目缺失的一侧是 `—`，不打印空行
        if (f.from.isNotEmpty && f.from != '—') buf.writeln('       − ${f.from}');
        if (f.to.isNotEmpty && f.to != '—') buf.writeln('       + ${f.to}');
      }
      return buf.toString();
    }
    if (e.kind == SnapshotDiffKind.changed) {
      buf.writeln('  $mark ${e.key}$uncertain');
      buf.writeln('       − ${e.oldValue ?? '—'}');
      buf.writeln('       + ${e.newValue ?? '—'}');
      return buf.toString();
    }
    final value = e.kind == SnapshotDiffKind.added ? e.newValue : e.oldValue;
    buf.writeln('  $mark ${value ?? e.key}$uncertain');
    return buf.toString();
  }
}

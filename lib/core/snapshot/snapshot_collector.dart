import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/AnalyzerRustDecoder.dart';
import 'package:gstore/core/rust/contract/ModuleTypes.dart';
import 'package:gstore/core/service/apk_library_analyzer.dart';
import 'package:gstore/core/service/apk_native_service.dart';
import 'package:gstore/core/service/apk_source_service.dart';
import 'package:gstore/core/snapshot/deep_link_utils.dart';
import 'package:gstore/core/snapshot/snapshot_models.dart';

/// 一次采集的产物：载荷 + 诊断信息
class SnapshotCaptureResult {
  const SnapshotCaptureResult({
    required this.payload,
    this.warnings = const [],
  });

  final SnapshotPayload payload;

  /// 采集过程中的降级信息（某节缺失等），用于 UI 提示「快照不完整」
  final List<String> warnings;

  bool get isComplete => warnings.isEmpty;
}

/// 应用快照采集器。
///
/// **一次**调用模块聚合入口 `scan_apk_report`（内部只打开一次 APK、manifest 与 DEX
/// 各只解析一遍），再补上来自 Android PackageManager 的「运行时」信息
/// （签名证书、权限授权状态、组件启用/导出状态、安装信息），组装成 [SnapshotPayload]。
///
/// 关键设计：**逐节降级**——聚合报告缺哪节就少哪节，其余照常产出；
/// 任何异常都不抛出，最差返回一个只有应用基础信息的快照（并带上 warnings）。
class SnapshotCollector {
  const SnapshotCollector._();

  static const SnapshotCollector instance = SnapshotCollector._();

  /// 采集指定应用。
  ///
  /// [sourceDir] 为主 APK 路径；[sourceDirs] 覆盖 split 分发（多源目录）。
  /// [appLabel] 仅作**兜底**：名称/版本一律取真实来源（见下），避免上游页面
  /// 传进来的值（可能来自应用列表缓存）被写进快照，导致版本号与实际 APK 不一致。
  ///
  /// 真实来源优先级：
  /// 1. `PackageManager.getPackageArchiveInfo(sourceDir)`——直接读**当前安装的 APK 文件**；
  /// 2. 模块解析 APK 内 AndroidManifest 得到的 `versionName/versionCode`；
  /// 3. 都没有时留空（快照照常生成并记 warning），绝不用调用方传值。
  Future<SnapshotCaptureResult> capture({
    required String packageName,
    required String appLabel,
    required String sourceDir,
    List<String>? sourceDirs,
  }) async {
    final warnings = <String>[];

    // ===== 1. 平台侧（与模块解析互相独立，各自降级）=====
    final detailF = _guard(
      () => ApkSourceService.instance.getInstalledAppDetail(packageName),
      warnings,
      '安装信息',
    );
    final permissionsF = _guard(
      () => ApkSourceService.instance.getPermissions(packageName),
      warnings,
      '权限声明',
    );
    final componentStateF = _guard(
      () => ApkSourceService.instance.getComponentsDetail(packageName),
      warnings,
      '组件状态',
    );
    final apkInfoF = _guard(
      () => ApkNativeService.instance.parseApk(sourceDir),
      warnings,
      'APK 版本信息',
    );
    final abisF = _guard(
      () => ApkLibraryAnalyzer.instance.listNativeAbis(sourceDir),
      warnings,
      'ABI 列表',
    );
    final buildF = _guard(
      () => ApkLibraryAnalyzer.instance.detectBuildVersions(sourceDir),
      warnings,
      '构建版本',
    );

    // ===== 2. 模块侧：一次打开 APK 产出全部节 =====
    final rulesJson = await _mergedRulesJson(warnings);
    ApkReport? report;
    try {
      report = await AnalyzerRustDecoder.scanApkReport(sourceDir, rulesJson);
    } catch (e) {
      warnings.add('聚合报告: $e');
    }
    if (report == null) {
      warnings.add('聚合报告不可用（模块缺失或解析失败）');
    }
    for (final err in report?.errors ?? const <String>[]) {
      warnings.add(err);
    }

    final detail = await detailF ?? const InstalledAppDetail();
    final permissions = await permissionsF ?? const <String>[];
    final componentState = await componentStateF;
    final abis = await abisF ?? const <String>[];
    final build = await buildF ?? const BuildVersionInfo();

    final manifest = report?.manifest;
    final structure = report?.structure;
    final dexStats = report?.dexStats;
    final elf = report?.elf;
    final features = report?.features ?? const ApkFeatures();
    final matches = report?.matches;
    final apkInfo = await apkInfoF;

    // 版本/名称：真实来源 > 兜底，绝不采用调用方传入的版本
    final realVersionName = _firstNonEmpty([
      apkInfo?.versionName ?? '',
      manifest?.versionName ?? '',
    ]);
    final realVersionCode = _firstNonEmpty([
      (apkInfo != null && apkInfo.versionCode > 0) ? '${apkInfo.versionCode}' : '',
      manifest?.versionCode ?? '',
    ]);
    final realLabel = _firstNonEmpty([
      apkInfo?.appName ?? '',
      appLabel,
    ]);

    // ===== 3. 组装载荷 =====
    final payload = SnapshotPayload(
      app: SnapshotAppInfo(
        packageName: packageName,
        label: realLabel,
        versionName: realVersionName,
        versionCode: realVersionCode,
        apkSize: (structure != null && structure.fileSize > 0)
            ? structure.fileSize
            : detail.apkSize,
        uid: detail.uid,
        isSystemApp: detail.isSystemApp,
        isDebuggable: detail.isDebuggable,
        dataDir: detail.dataDir,
        installer: detail.installer,
        mainActivity: _firstNonEmpty([detail.mainActivity, manifest?.mainActivity]),
        firstInstallTime: detail.firstInstallTime,
        lastUpdateTime: detail.lastUpdateTime,
        minSdk: _firstNonEmpty([manifest?.minSdk, detail.minSdk?.toString()]),
        targetSdk:
            _firstNonEmpty([manifest?.targetSdk, detail.targetSdk?.toString()]),
        compileSdk: manifest?.compileSdk ?? '',
        sharedUserId:
            _firstNonEmpty([manifest?.sharedUserId, detail.sharedUserId]),
        abis: abis,
      ),
      signature: SnapshotSignatureInfo(
        signingShape: detail.signingShape,
        schemes: report?.signature?.schemes ?? const [],
        certificates: [
          for (final c in detail.signatures)
            SnapshotCertificate(
              subject: c.subject,
              algorithm: c.algorithm,
              sha256: c.sha256,
              sha1: c.sha1,
              kind: c.kind,
            ),
        ],
      ),
      permissions: _buildPermissions(permissions, manifest, componentState),
      components: _buildComponents(manifest, componentState),
      nativeLibs: [
        for (final group in structure?.abis ?? const <ApkAbiLibs>[])
          for (final lib in group.libs)
            SnapshotNativeLib(
              abi: group.abi,
              name: lib.name,
              size: lib.size,
              // ★ 之前这些字段被丢掉，导致"原生库文件"只能比大小
              compressedSize: lib.compressedSize,
              crc32: lib.crc32,
              stored: lib.stored,
              zipAlignment: lib.zipAlignment,
              path: lib.path,
            ),
      ],
      nativeHits: _ruleHits(matches, (h) => h.kind == 'native'),
      elfFiles: [
        for (final so in elf?.soFiles ?? const <ElfSoInfo>[])
          SnapshotElfInfo(
            abi: so.abi,
            soName: so.soName,
            minPageSize: so.minPageSize,
            aligned16Kb: so.aligned16Kb,
            zipAlignment: so.zipAlignment,
            elfType: so.elfType,
            needed: so.needed,
            jniEntryPoints: so.jniEntryPoints,
            stripped: so.stripped,
            sha256: so.sha256,
            buildId: so.buildId,
          ),
      ],
      dexFiles: [
        for (final dex in dexStats?.dexFiles ?? const <ApkDexStat>[])
          SnapshotDexFile(
            name: dex.name,
            size: dex.size,
            compressedSize: dex.compressedSize,
            classCount: dex.classCount,
            crc32: dex.crc32,
            // 头部指纹（编译期算好）与各类 id 数量
            headerSha1: dex.headerSha1,
            checksum: dex.checksum,
            stringCount: dex.stringIds,
            typeCount: dex.typeIds,
            protoCount: dex.protoIds,
            fieldCount: dex.fieldIds,
            methodCount: dex.methodIds,
            classDigest: dex.classDigest,
          ),
      ],
      assets: [
        for (final a in structure?.assets ?? const <ApkAssetEntry>[])
          SnapshotAsset(
            name: a.name,
            path: a.path,
            size: a.size,
            compressedSize: a.compressedSize,
            crc32: a.crc32,
            stored: a.stored,
          ),
      ],
      arsc: SnapshotArscInfo(
        present: (structure?.resourcesArscSize ?? 0) > 0,
        size: structure?.resourcesArscSize ?? 0,
        compressedSize: structure?.resourcesArscCompressedSize ?? 0,
        crc32: structure?.resourcesArscCrc32 ?? 0,
        stored: structure?.resourcesArscStored ?? false,
        parsed: structure?.arsc.parsed ?? false,
        packageNames: structure?.arsc.packageNames ?? const [],
        typeNames: structure?.arsc.typeNames ?? const [],
        globalStringCount: structure?.arsc.globalStringCount ?? 0,
        keyCount: structure?.arsc.keyCount ?? 0,
        entryInstances: structure?.arsc.entryInstances ?? 0,
        configs: structure?.arsc.configs ?? const [],
        resources: [
          for (final r in structure?.arsc.resources ?? const <ApkArscResource>[])
            SnapshotArscResource(
              id: r.id,
              typeName: r.typeName,
              key: r.key,
              valueKind: r.valueKind,
              value: r.value,
            ),
        ],
        resourcesTruncated: structure?.arsc.resourcesTruncated ?? false,
      ),
      structure: SnapshotStructureInfo(
        entryCount: structure?.entryCount ?? 0,
        totalUncompressed: structure?.totalUncompressed ?? 0,
        storedEntryCount: structure?.storedEntryCount ?? 0,
      ),
      dexHits: _ruleHits(matches, (h) => h.kind == 'dex'),
      features: SnapshotFeatures(
        kotlinUsed: features.kotlinUsed,
        jetpackCompose: features.jetpackCompose,
        kmp: features.kmp,
        xposedModule: features.xposedModule,
        playSigning: features.playSigning,
        pwa: features.pwa,
        liveUpdateNotification: features.liveUpdateNotification,
        agpVersion: features.agpVersion,
      ),
      buildVersions: SnapshotBuildVersions(
        kotlinVersion: build.kotlinVersion,
        gradleVersion: build.gradleVersion,
        javaVersion: build.javaVersion,
        composeVersion: build.composeVersion,
        agpVersion: build.agpVersion,
      ),
      metaData: _buildMetaData(manifest, detail),
      staticLibraries: _ruleHits(matches, (h) => h.kind == 'static'),
      actionHits: _ruleHits(matches, (h) => h.kind == 'action'),
      componentHits: _ruleHits(matches, (h) => h.kind == 'component'),
    );

    appLog.info(
      'SnapshotCollector: $packageName 采集完成 '
      '(规则命中 ${payload.summary.ruleHits} / 组件 ${payload.summary.components} / '
      '原生库 ${payload.summary.nativeLibs} / 警告 ${warnings.length})',
    );

    return SnapshotCaptureResult(payload: payload, warnings: warnings);
  }

  /// 组装待落库的快照记录（采集时间由调用方决定，便于测试注入）
  SnapshotRecord toRecord(
    SnapshotCaptureResult result, {
    required String packageName,
    required String appLabel,
    required int capturedAt,
    String note = '',
  }) =>
      SnapshotRecord(
        packageName: packageName,
        appLabel: appLabel,
        versionName: result.payload.app.versionName,
        versionCode: result.payload.app.versionCode,
        createdAt: capturedAt,
        note: note,
        payloadVersion: result.payload.payloadVersion,
        summary: result.payload.summary,
        payload: result.payload,
      );

  // ===== 组装辅助 =====

  List<SnapshotPermission> _buildPermissions(
    List<String> declared,
    ApkManifestInfo? manifest,
    ({List<ComponentStateDetail> components, List<PermissionStateDetail> permissions})?
        componentState,
  ) {
    final maxSdkByName = {
      for (final p in manifest?.permissions ?? const <ManifestPermission>[])
        p.name: p.maxSdkVersion,
    };
    final stateByName = {
      for (final s
          in componentState?.permissions ?? const <PermissionStateDetail>[])
        s.name: s,
    };
    // 以「声明侧并集」为基准：manifest 与平台任一有值都保留
    final names = <String>{...declared, ...maxSdkByName.keys};
    final out = [
      for (final name in names)
        SnapshotPermission(
          name: name,
          maxSdkVersion: maxSdkByName[name] ?? '',
          granted: stateByName[name]?.granted ?? false,
          neverForLocation: stateByName[name]?.neverForLocation ?? false,
        ),
    ];
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  List<SnapshotComponent> _buildComponents(
    ApkManifestInfo? manifest,
    ({List<ComponentStateDetail> components, List<PermissionStateDetail> permissions})?
        componentState,
  ) {
    final stateByKey = {
      for (final s
          in componentState?.components ?? const <ComponentStateDetail>[])
        '${s.type.toUpperCase()}:${s.name}': s,
    };
    final out = <SnapshotComponent>[];
    for (final c in manifest?.components ?? const <ManifestComponent>[]) {
      final state = stateByKey['${c.kind.toUpperCase()}:${c.name}'];
      out.add(
        SnapshotComponent(
          kind: c.kind,
          name: c.name,
          exported: c.exported,
          enabled: state == null ? '' : (state.enabled ? 'true' : 'false'),
          processName:
              c.process.isNotEmpty ? c.process : (state?.processName ?? ''),
          actions: c.actions,
          deepLinks: componentDeepLinks(c),
        ),
      );
    }
    out.sort((a, b) {
      final byKind = a.kind.compareTo(b.kind);
      return byKind != 0 ? byKind : a.name.compareTo(b.name);
    });
    return out;
  }

  static List<SnapshotRuleHit> _ruleHits(
    RuleMatchResult? matches,
    bool Function(RuleHit) keep,
  ) =>
      [
        for (final h in matches?.hits ?? const <RuleHit>[])
          if (keep(h))
            SnapshotRuleHit(
              label: h.label,
              ruleName: h.ruleName,
              matched: h.matched,
              kind: h.kind,
              isRegex: h.isRegex,
            ),
      ]..sort((a, b) {
          final byLabel = a.label.compareTo(b.label);
          return byLabel != 0 ? byLabel : a.matched.compareTo(b.matched);
        });

  /// 合并规则集（native/dex/component/static/action）为单个 JSON 字符串。
  /// 复用分析器里同一份缓存，避免重复加载资产。
  Future<String> _mergedRulesJson(List<String> warnings) async {
    try {
      return await ApkLibraryAnalyzer.instance.mergedRulesJson() ?? '';
    } catch (e) {
      warnings.add('规则集加载: $e');
      return '';
    }
  }

  /// meta-data：Rust（清单原文）优先，平台值兜底（与页面同一策略）
  List<SnapshotMetaData> _buildMetaData(
    ApkManifestInfo? manifest,
    InstalledAppDetail detail,
  ) {
    final rust = manifest?.metaData ?? const <ManifestMetaData>[];
    if (rust.isNotEmpty) {
      return [
        for (final m in rust) SnapshotMetaData(name: m.name, value: m.value),
      ];
    }
    return [
      for (final e in detail.metaData.entries)
        SnapshotMetaData(name: e.key, value: e.value),
    ];
  }

  static String _firstNonEmpty(List<String?> values) {
    for (final v in values) {
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }

  /// 执行并捕获异常：失败记入 [warnings] 并返回 null（逐节降级）
  static Future<T?> _guard<T>(
    Future<T> Function() action,
    List<String> warnings,
    String section,
  ) async {
    try {
      return await action();
    } catch (e) {
      warnings.add('$section: $e');
      return null;
    }
  }
}

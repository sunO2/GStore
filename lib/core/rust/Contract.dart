import 'dart:typed_data';

import 'package:gstore/core/rust/contract/ModuleTypes.dart';

/// 模块 JSON 契约解码器：把 gstore_mod_analyzer / gstore_mod_qr 返回的 JSON
/// 还原为手写契约类型（ModuleTypes.dart，与 FRB 生成的旧类型字段一致）。

/// JSON → ApkInfo（模块 parse_apk_info 响应）
ApkInfo? decodeApkInfo(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkInfo(
    packageName: json['package_name'] as String? ?? '',
    versionName: json['version_name'] as String? ?? '',
    versionCode: json['version_code'] as String? ?? '',
    appName: json['app_name'] as String? ?? '',
    minSdk: json['min_sdk'] as String? ?? '',
    mainActivity: json['main_activity'] as String? ?? '',
  );
}

/// JSON → ApkComponents（模块 parse_components 响应）
ApkComponents? decodeApkComponents(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkComponents(
    packageName: json['package_name'] as String? ?? '',
    minSdk: json['min_sdk'] as String? ?? '',
    targetSdk: json['target_sdk'] as String? ?? '',
    services: _strList(json['services']),
    activities: _strList(json['activities']),
    receivers: _strList(json['receivers']),
    providers: _strList(json['providers']),
  );
}

/// JSON List<dynamic> → List<String>（空安全）
List<String> _strList(dynamic value) {
  if (value is! List) return const [];
  return value.map((e) => e.toString()).toList();
}

/// JSON → List<String>（模块 scan_dex_classes 响应）
List<String>? decodeDexClasses(dynamic json) {
  if (json is! List) return null;
  return json.map((e) => e.toString()).toList();
}

/// JSON → ApkStructure（模块 scan_apk_structure 响应）
ApkStructure? decodeApkStructure(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkStructure(
    fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
    entryCount: (json['entry_count'] as num?)?.toInt() ?? 0,
    totalUncompressed: (json['total_uncompressed'] as num?)?.toInt() ?? 0,
    abis: [
      for (final e in (json['abis'] as List? ?? []))
        _decodeAbiLibs(e as Map<String, dynamic>),
    ],
    assetsSo: [
      for (final e in (json['assets_so'] as List? ?? []))
        _decodeSoEntry(e as Map<String, dynamic>),
    ],
    dexFiles: [
      for (final e in (json['dex_files'] as List? ?? []))
        _decodeDexEntry(e as Map<String, dynamic>),
    ],
    resourcesArscSize: (json['resources_arsc_size'] as num?)?.toInt() ?? 0,
    hasManifest: json['has_manifest'] as bool? ?? false,
  );
}

ApkAbiLibs _decodeAbiLibs(Map<String, dynamic> m) => ApkAbiLibs(
      abi: m['abi'] as String? ?? '',
      libs: [
        for (final e in (m['libs'] as List? ?? []))
          _decodeSoEntry(e as Map<String, dynamic>),
      ],
      totalSize: (m['total_size'] as num?)?.toInt() ?? 0,
    );

ApkSoEntry _decodeSoEntry(Map<String, dynamic> m) => ApkSoEntry(
      name: m['name'] as String? ?? '',
      path: m['path'] as String? ?? '',
      size: (m['size'] as num?)?.toInt() ?? 0,
      compressedSize: (m['compressed_size'] as num?)?.toInt() ?? 0,
      crc32: (m['crc32'] as num?)?.toInt() ?? 0,
      stored: m['stored'] as bool? ?? false,
      zipAlignment: (m['zip_alignment'] as num?)?.toInt() ?? 0,
    );

ApkDexEntry _decodeDexEntry(Map<String, dynamic> m) => ApkDexEntry(
      name: m['name'] as String? ?? '',
      size: (m['size'] as num?)?.toInt() ?? 0,
      compressedSize: (m['compressed_size'] as num?)?.toInt() ?? 0,
      crc32: (m['crc32'] as num?)?.toInt() ?? 0,
    );

/// JSON → ApkElfScanResult（模块 scan_elf_page_sizes 响应）
ApkElfScanResult? decodeElfScanResult(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  final soFiles = (json['so_files'] as List? ?? [])
      .map((e) {
        final m = e as Map<String, dynamic>;
        final minPageSize = m['min_page_size'];
        return ElfSoInfo(
          abi: m['abi'] as String? ?? '',
          soName: m['so_name'] as String? ?? '',
          path: m['path'] as String? ?? '',
          size: (m['size'] as num?)?.toInt() ?? 0,
          minPageSize: (minPageSize as num?)?.toInt() ?? -1,
          zipAlignment: (m['zip_alignment'] as num?)?.toInt() ?? 0,
          aligned16Kb: m['aligned_16kb'] as bool? ?? false,
          elfType: (m['elf_type'] as num?)?.toInt() ?? -1,
          needed: _strList(m['needed']),
          jniEntryPoints: _strList(m['jni_entry_points']),
          stripped: m['stripped'] as bool? ?? false,
        );
      })
      .toList();
  return ApkElfScanResult(soFiles: soFiles);
}

/// JSON → ApkManifestInfo（模块 parse_manifest 响应）
ApkManifestInfo? decodeApkManifestInfo(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkManifestInfo(
    packageName: json['package_name'] as String? ?? '',
    versionName: json['version_name'] as String? ?? '',
    versionCode: json['version_code'] as String? ?? '',
    minSdk: json['min_sdk'] as String? ?? '',
    targetSdk: json['target_sdk'] as String? ?? '',
    compileSdk: json['compile_sdk'] as String? ?? '',
    sharedUserId: json['shared_user_id'] as String? ?? '',
    mainActivity: json['main_activity'] as String? ?? '',
    permissions: [
      for (final e in (json['permissions'] as List? ?? []))
        ManifestPermission(
          name: (e as Map<String, dynamic>)['name'] as String? ?? '',
          maxSdkVersion: e['max_sdk_version'] as String? ?? '',
        ),
    ],
    components: [
      for (final e in (json['components'] as List? ?? []))
        ManifestComponent(
          kind: (e as Map<String, dynamic>)['kind'] as String? ?? '',
          name: e['name'] as String? ?? '',
          exported: e['exported'] as String? ?? '',
          process: e['process'] as String? ?? '',
          actions: _strList(e['actions']),
          intentFilters: [
            for (final f in (e['intent_filters'] as List? ?? []))
              ManifestIntentFilter(
                actions: _strList((f as Map<String, dynamic>)['actions']),
                categories: _strList(f['categories']),
                autoVerify: f['auto_verify'] as bool? ?? false,
                data: [
                  for (final d in (f['data'] as List? ?? []))
                    ManifestIntentData(
                      scheme: (d as Map<String, dynamic>)['scheme'] as String? ?? '',
                      host: d['host'] as String? ?? '',
                      port: d['port'] as String? ?? '',
                      path: d['path'] as String? ?? '',
                      pathPrefix: d['path_prefix'] as String? ?? '',
                      pathPattern: d['path_pattern'] as String? ?? '',
                      mimeType: d['mime_type'] as String? ?? '',
                    ),
                ],
              ),
          ],
        ),
    ],
    metaData: [
      for (final e in (json['meta_data'] as List? ?? []))
        ManifestMetaData(
          name: (e as Map<String, dynamic>)['name'] as String? ?? '',
          value: e['value'] as String? ?? '',
        ),
    ],
    staticLibraries: [
      for (final e in (json['static_libraries'] as List? ?? []))
        ManifestStaticLibrary(
          name: (e as Map<String, dynamic>)['name'] as String? ?? '',
          version: e['version'] as String? ?? '',
          certDigest: e['cert_digest'] as String? ?? '',
        ),
    ],
  );
}

/// JSON → ApkDexStats（模块 scan_dex_stats 响应）
ApkDexStats? decodeApkDexStats(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkDexStats(
    dexFiles: [
      for (final e in (json['dex_files'] as List? ?? []))
        ApkDexStat(
          name: (e as Map<String, dynamic>)['name'] as String? ?? '',
          size: (e['size'] as num?)?.toInt() ?? 0,
          compressedSize: (e['compressed_size'] as num?)?.toInt() ?? 0,
          crc32: (e['crc32'] as num?)?.toInt() ?? 0,
          classCount: (e['class_count'] as num?)?.toInt() ?? -1,
        ),
    ],
    totalClassCount: (json['total_class_count'] as num?)?.toInt() ?? 0,
  );
}

/// JSON → ApkSignatureSchemes（模块 detect_signature_schemes 响应）
ApkSignatureSchemes? decodeSignatureSchemes(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkSignatureSchemes(
    hasV1: json['has_v1'] as bool? ?? false,
    hasV2: json['has_v2'] as bool? ?? false,
    hasV3: json['has_v3'] as bool? ?? false,
    hasV31: json['has_v31'] as bool? ?? false,
    hasV32: json['has_v32'] as bool? ?? false,
    hasV4: json['has_v4'] as bool? ?? false,
    schemes: _strList(json['schemes']),
    signingBlockIds: [
      for (final e in (json['signing_block_ids'] as List? ?? []))
        (e as num).toInt(),
    ],
  );
}

/// JSON → ApkFeatures（模块 scan_features 响应）
ApkFeatures? decodeApkFeatures(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkFeatures(
    kotlinUsed: json['kotlin_used'] as bool? ?? false,
    jetpackCompose: json['jetpack_compose'] as bool? ?? false,
    kmp: json['kmp'] as bool? ?? false,
    xposedModule: json['xposed_module'] as bool? ?? false,
    playSigning: json['play_signing'] as bool? ?? false,
    pwa: json['pwa'] as bool? ?? false,
    liveUpdateNotification: json['live_update_notification'] as bool? ?? false,
    agpVersion: json['agp_version'] as String? ?? '',
    evidence: _strList(json['evidence']),
  );
}

/// JSON → RuleMatchResult（模块 match_libraries 响应）
RuleMatchResult? decodeRuleMatchResult(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return RuleMatchResult(
    hits: [
      for (final e in (json['hits'] as List? ?? []))
        RuleHit(
          ruleName: (e as Map<String, dynamic>)['rule_name'] as String? ?? '',
          label: e['label'] as String? ?? '',
          kind: e['kind'] as String? ?? '',
          matched: e['matched'] as String? ?? '',
          isRegex: e['is_regex'] as bool? ?? false,
          componentType: (e['component_type'] as num?)?.toInt() ?? 0,
        ),
    ],
    skippedRegex: (json['skipped_regex'] as num?)?.toInt() ?? 0,
    dexClassCount: (json['dex_class_count'] as num?)?.toInt() ?? 0,
  );
}

/// JSON → ApkBuildVersions（模块 scan_build_versions 响应）
ApkBuildVersions? decodeApkBuildVersions(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkBuildVersions(
    kotlinVersion: json['kotlin_version'] as String? ?? '',
    gradleVersion: json['gradle_version'] as String? ?? '',
    javaVersion: json['java_version'] as String? ?? '',
    composeVersion: json['compose_version'] as String? ?? '',
    agpVersion: json['agp_version'] as String? ?? '',
  );
}

/// JSON → ApkReport（模块 scan_apk_report 响应）
///
/// 各节与单能力接口同构，直接复用对应解析器；失败节为 null 且原因在 `errors`。
ApkReport? decodeApkReport(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkReport(
    errors: _strList(json['errors']),
    structure: decodeApkStructure(json['structure']),
    manifest: decodeApkManifestInfo(json['manifest']),
    dexStats: decodeApkDexStats(json['dex_stats']),
    elf: decodeElfScanResult(json['elf']),
    signature: decodeSignatureSchemes(json['signature']),
    features: decodeApkFeatures(json['features']) ?? const ApkFeatures(),
    matches: decodeRuleMatchResult(json['matches']),
    buildVersions: decodeApkBuildVersions(json['build_versions']) ??
        const ApkBuildVersions(),
    dexClassCount: (json['dex_class_count'] as num?)?.toInt() ?? 0,
    dexPatternCount: (json['dex_pattern_count'] as num?)?.toInt() ?? 0,
  );
}

/// JSON → QrDecodeResult（模块 decode_luma 响应）
QrDecodeResult? decodeQrDecodeResult(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return QrDecodeResult(
    text: json['text'] as String? ?? '',
    format: json['format'] as String? ?? '',
    points: Float64List.fromList(
      (json['points'] as List<dynamic>? ?? []).map((e) => (e as num).toDouble()).toList(),
    ),
    rawBytes: Uint8List.fromList(
      (json['raw_bytes'] as List<dynamic>? ?? []).map((e) => e as int).toList(),
    ),
    isMirrored: json['is_mirrored'] as bool? ?? false,
    isInverted: json['is_inverted'] as bool? ?? false,
    isValid: json['is_valid'] as bool? ?? false,
    error: json['error'] as String? ?? '',
    orientation: (json['orientation'] as num?)?.toInt() ?? 0,
  );
}

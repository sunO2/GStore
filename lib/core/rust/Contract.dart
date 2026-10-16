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
    storedEntryCount: (json['stored_entry_count'] as num?)?.toInt() ?? 0,
    abis: [
      for (final e in (json['abis'] as List? ?? []))
        _decodeAbiLibs(e as Map<String, dynamic>),
    ],
    assetsSo: [
      for (final e in (json['assets_so'] as List? ?? []))
        _decodeSoEntry(e as Map<String, dynamic>),
    ],
    assets: [
      for (final e in (json['assets'] as List? ?? []))
        _decodeAssetEntry(e as Map<String, dynamic>),
    ],
    dexFiles: [
      for (final e in (json['dex_files'] as List? ?? []))
        _decodeDexEntry(e as Map<String, dynamic>),
    ],
    resourcesArscSize: (json['resources_arsc_size'] as num?)?.toInt() ?? 0,
    resourcesArscCrc32: (json['resources_arsc_crc32'] as num?)?.toInt() ?? 0,
    resourcesArscStored: json['resources_arsc_stored'] as bool? ?? false,
    arsc: _decodeArscInfo(json['arsc']),
    resourcesArscCompressedSize:
        (json['resources_arsc_compressed_size'] as num?)?.toInt() ?? 0,
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

ApkArscInfo _decodeArscInfo(dynamic json) {
  if (json is! Map<String, dynamic>) return const ApkArscInfo();
  List<String> strList(String key) => [
        for (final e in (json[key] as List? ?? [])) e.toString(),
      ];
  return ApkArscInfo(
    parsed: json['parsed'] as bool? ?? false,
    packageCount: (json['package_count'] as num?)?.toInt() ?? 0,
    packageNames: strList('package_names'),
    typeCount: (json['type_count'] as num?)?.toInt() ?? 0,
    typeNames: strList('type_names'),
    globalStringCount: (json['global_string_count'] as num?)?.toInt() ?? 0,
    keyCount: (json['key_count'] as num?)?.toInt() ?? 0,
    entryInstances: (json['entry_instances'] as num?)?.toInt() ?? 0,
    configs: strList('configs'),
    resources: [
      for (final e in (json['resources'] as List? ?? []))
        ApkArscResource(
          id: ((e as Map<String, dynamic>)['id'] as num?)?.toInt() ?? 0,
          typeName: e['type_name'] as String? ?? '',
          key: e['key'] as String? ?? '',
          valueKind: e['value_kind'] as String? ?? '',
          value: e['value'] as String? ?? '',
        ),
    ],
    resourcesTruncated: json['resources_truncated'] as bool? ?? false,
  );
}

ApkAssetEntry _decodeAssetEntry(Map<String, dynamic> m) => ApkAssetEntry(
      path: m['path'] as String? ?? '',
      name: m['name'] as String? ?? '',
      size: (m['size'] as num?)?.toInt() ?? 0,
      compressedSize: (m['compressed_size'] as num?)?.toInt() ?? 0,
      crc32: (m['crc32'] as num?)?.toInt() ?? 0,
      stored: m['stored'] as bool? ?? false,
    );

ApkDexEntry _decodeDexEntry(Map<String, dynamic> m) => ApkDexEntry(
      name: m['name'] as String? ?? '',
      size: (m['size'] as num?)?.toInt() ?? 0,
      compressedSize: (m['compressed_size'] as num?)?.toInt() ?? 0,
      crc32: (m['crc32'] as num?)?.toInt() ?? 0,
    );

/// JSON → ApkBrowseListing（模块 browse_apk_entries 响应）
ApkBrowseListing? decodeApkBrowseListing(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkBrowseListing(
    container: json['container'] as String? ?? '',
    dir: json['dir'] as String? ?? '',
    parentDir: json['parent_dir'] as String? ?? '',
    canGoUp: json['can_go_up'] as bool? ?? false,
    entries: [
      for (final e in (json['entries'] as List? ?? []))
        _decodeBrowsableEntry(e as Map<String, dynamic>),
    ],
    totalFiles: (json['total_files'] as num?)?.toInt() ?? 0,
    containerSize: (json['container_size'] as num?)?.toInt() ?? 0,
    truncated: json['truncated'] as bool? ?? false,
  );
}

ApkBrowsableEntry _decodeBrowsableEntry(Map<String, dynamic> m) => ApkBrowsableEntry(
      path: m['path'] as String? ?? '',
      name: m['name'] as String? ?? '',
      isDir: m['is_dir'] as bool? ?? false,
      size: (m['size'] as num?)?.toInt() ?? 0,
      compressedSize: (m['compressed_size'] as num?)?.toInt() ?? 0,
      crc32: (m['crc32'] as num?)?.toInt() ?? 0,
      stored: m['stored'] as bool? ?? false,
      kind: m['kind'] as String? ?? 'binary',
      browsable: m['browsable'] as bool? ?? false,
    );

/// JSON → ApkExportedEntry（模块 export_apk_entry 响应）
ApkExportedEntry? decodeApkExportedEntry(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return ApkExportedEntry(
    path: json['path'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    crc32: (json['crc32'] as num?)?.toInt() ?? 0,
    outPath: json['out_path'] as String? ?? '',
  );
}

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
          checksum: (e['checksum'] as num?)?.toInt() ?? 0,
          headerSha1: e['header_sha1'] as String? ?? '',
          headerFileSize: (e['header_file_size'] as num?)?.toInt() ?? 0,
          stringIds: (e['string_ids'] as num?)?.toInt() ?? 0,
          typeIds: (e['type_ids'] as num?)?.toInt() ?? 0,
          protoIds: (e['proto_ids'] as num?)?.toInt() ?? 0,
          fieldIds: (e['field_ids'] as num?)?.toInt() ?? 0,
          methodIds: (e['method_ids'] as num?)?.toInt() ?? 0,
          dataSize: (e['data_size'] as num?)?.toInt() ?? 0,
          classDigest: e['class_digest'] as String? ?? '',
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

/// JSON → CertInfo（模块 parse_certificate 响应）
///
/// 契约见 `.omo/plans/apk-browser-cert-preview.md`「Frozen JSON schema (CertInfo v1)」。
/// 非 Map 输入返回 null；缺失可选字段回落 schema 规定的空值。
CertInfo? decodeCertInfo(dynamic json) {
  if (json is! Map<String, dynamic>) return null;
  return CertInfo(
    status: CertInfoStatus.fromWire(json['status'] as String? ?? ''),
    format: CertFormat.fromWire(json['format'] as String? ?? ''),
    passwordProtected: json['password_protected'] as bool? ?? false,
    message: json['message'] as String? ?? '',
    certificates: [
      for (final e in (json['certificates'] as List? ?? []))
        _decodeCertEntry(e as Map<String, dynamic>),
    ],
  );
}

CertEntry _decodeCertEntry(Map<String, dynamic> m) => CertEntry(
      subject: _decodeCertName(m['subject']),
      issuer: _decodeCertName(m['issuer']),
      serialNumberHex: m['serial_number_hex'] as String? ?? '',
      notBefore: m['not_before'] as String? ?? '',
      notAfter: m['not_after'] as String? ?? '',
      signatureAlgorithm: m['signature_algorithm'] as String? ?? '',
      publicKeyAlgorithm: m['public_key_algorithm'] as String? ?? '',
      publicKeyBits: (m['public_key_bits'] as num?)?.toInt() ?? 0,
      publicKeyCurve: m['public_key_curve'] as String? ?? '',
      version: (m['version'] as num?)?.toInt() ?? 0,
      san: [
        for (final e in (m['san'] as List? ?? []))
          _decodeCertSan(e as Map<String, dynamic>),
      ],
      subjectKeyIdentifier: m['subject_key_identifier'] as String? ?? '',
      authorityKeyIdentifier: m['authority_key_identifier'] as String? ?? '',
      keyUsage: _strList(m['key_usage']),
      extendedKeyUsage: _strList(m['extended_key_usage']),
      basicConstraints: _decodeCertBasicConstraints(m['basic_constraints']),
      crlDistributionPoints: _strList(m['crl_distribution_points']),
      authorityInfoAccess: [
        for (final e in (m['authority_info_access'] as List? ?? []))
          _decodeCertAia(e as Map<String, dynamic>),
      ],
      sha256Fingerprint: m['sha256_fingerprint'] as String? ?? '',
      sha1Fingerprint: m['sha1_fingerprint'] as String? ?? '',
      pem: m['pem'] as String? ?? '',
    );

CertName _decodeCertName(dynamic json) {
  if (json is! Map<String, dynamic>) {
    return const CertName(commonName: '', full: '', fields: []);
  }
  return CertName(
    commonName: json['common_name'] as String? ?? '',
    full: json['full'] as String? ?? '',
    fields: [
      for (final e in (json['fields'] as List? ?? []))
        CertNameField(
          oid: (e as Map<String, dynamic>)['oid'] as String? ?? '',
          name: e['name'] as String? ?? '',
          value: e['value'] as String? ?? '',
        ),
    ],
  );
}

CertSan _decodeCertSan(Map<String, dynamic> m) => CertSan(
      type: m['type'] as String? ?? '',
      value: m['value'] as String? ?? '',
    );

CertBasicConstraints _decodeCertBasicConstraints(dynamic json) {
  if (json is! Map<String, dynamic>) {
    return const CertBasicConstraints(isCa: false);
  }
  return CertBasicConstraints(
    isCa: json['is_ca'] as bool? ?? false,
    pathLen: (json['path_len'] as num?)?.toInt(),
  );
}

CertAia _decodeCertAia(Map<String, dynamic> m) => CertAia(
      type: m['type'] as String? ?? '',
      url: m['url'] as String? ?? '',
    );

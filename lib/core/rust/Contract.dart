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
          minPageSize: (minPageSize as num?)?.toInt() ?? -1,
          aligned16Kb: m['aligned_16kb'] as bool? ?? false,
        );
      })
      .toList();
  return ApkElfScanResult(soFiles: soFiles);
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
  );
}

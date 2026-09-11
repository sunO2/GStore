import 'dart:typed_data';

/// 模块 JSON 契约类型（手写，供模块路由解码使用）
///
/// gstore_mod_analyzer / gstore_mod_qr 经 C ABI 返回 JSON，
/// Dart 侧解码回这些类型（与 FRB 生成的旧类型字段一致，业务层无感知）。

/// APK 元数据提取结果（模块 parse_apk_info 响应）
class ApkInfo {
  final String packageName;
  final String versionName;
  final String versionCode;
  final String appName;
  final String minSdk;
  final String mainActivity;

  const ApkInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.appName,
    required this.minSdk,
    required this.mainActivity,
  });
}

/// Manifest 组件枚举结果（模块 parse_components 响应）
class ApkComponents {
  final String packageName;
  final String minSdk;
  final String targetSdk;
  final List<String> services;
  final List<String> activities;
  final List<String> receivers;
  final List<String> providers;

  const ApkComponents({
    required this.packageName,
    required this.minSdk,
    required this.targetSdk,
    required this.services,
    required this.activities,
    required this.receivers,
    required this.providers,
  });
}

/// 单个 ELF .so 的页对齐检测结果（模块 scan_elf_page_sizes 响应元素）
class ElfSoInfo {
  final String abi;
  final String soName;
  final int minPageSize;
  final bool aligned16Kb;

  const ElfSoInfo({
    required this.abi,
    required this.soName,
    required this.minPageSize,
    required this.aligned16Kb,
  });
}

/// 整包 ELF 扫描结果（模块 scan_elf_page_sizes 响应）
class ApkElfScanResult {
  final List<ElfSoInfo> soFiles;

  const ApkElfScanResult({required this.soFiles});
}

/// 二维码单帧解码结果（模块 decode_luma 响应）
class QrDecodeResult {
  final String text;
  final String format;
  final Float64List points;
  final Uint8List rawBytes;
  final bool isMirrored;
  final bool isInverted;

  const QrDecodeResult({
    required this.text,
    required this.format,
    required this.points,
    required this.rawBytes,
    required this.isMirrored,
    required this.isInverted,
  });
}

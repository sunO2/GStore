import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/Contract.dart' show decodeApkFeatures, decodeApkReport, decodeApkBuildVersions, decodeApkInfo, decodeApkComponents, decodeApkDexStats, decodeApkManifestInfo, decodeApkStructure, decodeElfScanResult, decodeDexClasses, decodeRuleMatchResult, decodeSignatureSchemes, decodeApkBrowseListing, decodeApkExportedEntry;
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' show ModuleHandle;
import 'package:gstore/core/rust/contract/GStoreException.dart';
import 'package:gstore/core/rust/contract/ModuleTypes.dart';


/// APK 分析解码器（APK 元数据 / Manifest 组件 / DEX 类扫描 / ELF 16KB 检测）
///
/// P4 起优先走模块化路径（gstore_mod_analyzer.so → 宿主 dlopen 挂载 → JSON 契约），
/// 模块不可用时降级到宿主内置 FdroidRepoManager（旧路径）。
class AnalyzerRustDecoder {
  AnalyzerRustDecoder._();

  static ModuleHandle? _moduleHandle;
  static RustModuleInstance? _moduleInstance;
  static bool _moduleAvailable = false;
  static bool _moduleTried = false;

  /// 确保模块挂载（内置 jniLibs 或本地/远程 + create 实例）
  static Future<bool> _ensureModule() async {
    if (_moduleTried) return _moduleAvailable;
    _moduleTried = true;
    try {
      final ok = await RustModuleLoader.instance.ensureModule('analyzer');
      if (!ok) return false;
      _moduleHandle = await RustModuleManager.instance.loadModule('analyzer');
      if (_moduleHandle == null) return false;
      _moduleInstance = await RustModuleInstance.createWithContext('analyzer', _moduleHandle!);
      _moduleAvailable = _moduleInstance != null;
      return _moduleAvailable;
    } catch (e) {
      appLog.error('AnalyzerRustDecoder: 模块初始化失败 - $e');
      return false;
    }
  }

  /// 解析 APK 元数据（Rust 模块先试，失败降级宿主内置）
  static Future<ApkInfo?> parseApkInfo(String apkPath) async {
    final moduleResult = await _roundtripJson(
      'parse_apk_info',
      utf8.encode(apkPath),
      (json) => decodeApkInfo(json),
    );
    if (moduleResult != null) return moduleResult;
    return null; // 宿主已删内置实现，仅模块路径（模块失败即不可用）
  }

  /// 解析 Manifest 组件（模块先试，失败降级宿主内置）
  static Future<ApkComponents?> parseComponents(String apkPath) async {
    final moduleResult = await _roundtripJson(
      'parse_components',
      utf8.encode(apkPath),
      (json) => decodeApkComponents(json),
    );
    if (moduleResult != null) return moduleResult;
    return null; // 宿主已删内置实现，仅模块路径（模块失败即不可用）
  }

  /// 扫描 DEX 类名（模块先试，失败降级宿主内置）
  static Future<List<String>?> scanDexClasses(
    String apkPath,
    List<String> patterns,
  ) async {
    // payload: apk_path + NUL + patterns NUL 分隔
    final payload = BytesBuilder(copy: false)
      ..add(utf8.encode(apkPath))
      ..addByte(0)
      ..add(utf8.encode(patterns.join('\u0000')));
    final moduleResult = await _roundtripJson(
      'scan_dex_classes',
      payload.takeBytes(),
      (json) => decodeDexClasses(json),
    );
    if (moduleResult != null) return moduleResult;
    return null; // 宿主已删内置实现，仅模块路径（模块失败即不可用）
  }

  /// 扫描 ELF 元数据与 16KB 页对齐（模块先试，失败降级宿主内置）。
  ///
  /// [abis] 非空时只解析这些 ABI 分组（对齐 LibChecker「只解析选中 ABI」，
  /// 避免把所有 ABI 的库全部解压）；`assets` 分组始终解析。
  static Future<ApkElfScanResult?> scanElfPageSizes(
    String apkPath, {
    List<String> abis = const [],
  }) async {
    final payload = BytesBuilder(copy: false)..add(utf8.encode(apkPath));
    if (abis.isNotEmpty) {
      payload
        ..addByte(0)
        ..add(utf8.encode(abis.join(',')));
    }
    final moduleResult = await _roundtripJson(
      'scan_elf_page_sizes',
      payload.takeBytes(),
      (json) => decodeElfScanResult(json),
    );
    if (moduleResult != null) return moduleResult;
    return null; // 宿主已删内置实现，仅模块路径（模块失败即不可用）
  }

  /// Manifest 深度提取（权限含 maxSdkVersion / 组件 intent-filter / meta-data /
  /// 静态库 / compileSdk / sharedUserId）
  static Future<ApkManifestInfo?> parseManifest(String apkPath) async {
    final moduleResult = await _roundtripJson(
      'parse_manifest',
      utf8.encode(apkPath),
      (json) => decodeApkManifestInfo(json),
    );
    if (moduleResult != null) return moduleResult;
    return null;
  }

  /// DEX 统计：每文件类数量（只读 dex 头）+ CRC32 + 总量
  static Future<ApkDexStats?> scanDexStats(String apkPath) async {
    final moduleResult = await _roundtripJson(
      'scan_dex_stats',
      utf8.encode(apkPath),
      (json) => decodeApkDexStats(json),
    );
    if (moduleResult != null) return moduleResult;
    return null;
  }

  /// 签名方案检测 V1–V4（纯字节解析，不做密码学校验）
  static Future<ApkSignatureSchemes?> detectSignatureSchemes(String apkPath) async {
    final moduleResult = await _roundtripJson(
      'detect_signature_schemes',
      utf8.encode(apkPath),
      (json) => decodeSignatureSchemes(json),
    );
    if (moduleResult != null) return moduleResult;
    return null;
  }

  /// 特征识别：Kotlin / Compose / KMP / Xposed / PlaySigning / PWA / AGP 版本
  static Future<ApkFeatures?> scanFeatures(String apkPath) async {
    final moduleResult = await _roundtripJson(
      'scan_features',
      utf8.encode(apkPath),
      (json) => decodeApkFeatures(json),
    );
    if (moduleResult != null) return moduleResult;
    return null;
  }

  /// 聚合报告：**一次打开 APK** 产出全部节（快照采集专用）。
  ///
  /// 相比逐节调用多个方法，这里省掉了重复的 manifest 解析 / DEX 扫描 / 中央目录遍历
  /// 与多次 FFI 往返，并且结果是**同一时点**的一致切片（快照语义要求）。
  /// 各节独立容错：某节失败该节为 null，原因在 `ApkReport.errors`。
  ///
  /// payload = `apk_path NUL rules_json [NUL abis_csv]`（[rulesJson] 为空则跳过规则匹配）
  static Future<ApkReport?> scanApkReport(
    String apkPath,
    String rulesJson, {
    List<String> abis = const [],
  }) async {
    final payload = BytesBuilder(copy: false)
      ..add(utf8.encode(apkPath))
      ..addByte(0)
      ..add(utf8.encode(rulesJson));
    if (abis.isNotEmpty) {
      payload
        ..addByte(0)
        ..add(utf8.encode(abis.join(',')));
    }
    final moduleResult = await _roundtripJson(
      'scan_apk_report',
      payload.takeBytes(),
      (json) => decodeApkReport(json),
    );
    return moduleResult;
  }

  /// 构建版本检测（Kotlin / Gradle / Java / Compose / AGP）。
  ///
  /// 模块侧只读**中央目录 + 少量小条目**（不整包解压）。
  /// 返回 null 表示模块不可用（宿主降级为「未知」）。
  static Future<ApkBuildVersions?> detectBuildVersions(String apkPath) async {
    return _roundtripJson<ApkBuildVersions?>(
      'scan_build_versions',
      utf8.encode(apkPath),
      (json) => decodeApkBuildVersions(json),
    );
  }

  /// 规则匹配（native / dex / component / static / action）。
  /// [rulesJson] 为规则数组 JSON（多个规则文件需先合并）。
  /// 返回 null 表示模块不可用（调用方回退到宿主侧匹配实现）。
  ///
  /// 注意：快照采集请用 [scanApkReport]（一次打开覆盖全部节），不要逐节调用。
  static Future<RuleMatchResult?> matchLibraries(
    String apkPath,
    String rulesJson,
  ) async {
    final payload = BytesBuilder(copy: false)
      ..add(utf8.encode(apkPath))
      ..addByte(0)
      ..add(utf8.encode(rulesJson));
    final moduleResult = await _roundtripJson(
      'match_libraries',
      payload.takeBytes(),
      (json) => decodeRuleMatchResult(json),
    );
    if (moduleResult != null) return moduleResult;
    return null;
  }

  /// 扫描 APK 结构清单（只读 zip 中央目录、**不解压**）。
  ///
  /// 一次调用即可拿到：按 ABI 分组的原生库（名/大小/CRC32/zip 对齐）、
  /// assets 下的 .so、DEX 清单、resources.arsc 大小、条目总数与总体积。
  /// 用于替代宿主侧「整包读入内存 + 全量解压」的多次扫描。
  static Future<ApkStructure?> scanApkStructure(String apkPath) async {
    final moduleResult = await _roundtripJson(
      'scan_apk_structure',
      utf8.encode(apkPath),
      (json) => decodeApkStructure(json),
    );
    if (moduleResult != null) return moduleResult;
    return null; // 宿主已删内置实现，仅模块路径（模块失败即不可用）
  }

  /// 嵌套容器链分隔符（与 Rust `browser::CHAIN_SEP` 一致）
  static const String chainSep = '\u0001';

  /// 列一层目录（APK 内容浏览器）。
  ///
  /// [containerChain] 为嵌套容器链（[chainSep] 分隔，空串 = APK 根），
  /// [dir] 为当前容器内的目录前缀。
  /// 返回 null 表示模块不可用（调用方应提示「分析模块未就绪」）。
  static Future<ApkBrowseListing?> browseApkEntries(
    String apkPath, {
    String containerChain = '',
    String dir = '',
  }) async {
    final payload = BytesBuilder(copy: false)
      ..add(utf8.encode(apkPath))
      ..addByte(0)
      ..add(utf8.encode(containerChain))
      ..addByte(0)
      ..add(utf8.encode(dir));
    return _roundtripJson<ApkBrowseListing?>(
      'browse_apk_entries',
      payload.takeBytes(),
      (json) => decodeApkBrowseListing(json),
    );
  }

  /// 把某条内容解压到 [outPath]（宿主缓存文件），返回落地信息。
  ///
  /// 字节不跨 FFI 回传：Rust 直接写到宿主给定的文件路径，Dart 用文件消费。
  static Future<ApkExportedEntry?> exportApkEntry(
    String apkPath, {
    required String entryPath,
    required String outPath,
    String containerChain = '',
  }) async {
    final payload = BytesBuilder(copy: false)
      ..add(utf8.encode(apkPath))
      ..addByte(0)
      ..add(utf8.encode(containerChain))
      ..addByte(0)
      ..add(utf8.encode(entryPath))
      ..addByte(0)
      ..add(utf8.encode(outPath));
    return _roundtripJson<ApkExportedEntry?>(
      'export_apk_entry',
      payload.takeBytes(),
      (json) => decodeApkExportedEntry(json),
    );
  }

  /// 统一模块路径：调用 → JSON 响应 → 解码回 Dart 类型
  static Future<T?> _roundtripJson<T>(
    String method,
    Uint8List payload,
    T Function(dynamic json) decoder,
  ) async {
    if (kIsWeb) return null;
    if (!await _ensureModule()) return null;
    try {
      final resp = await _moduleInstance!.callModule(method, payload);
      if (resp.isEmpty) return null;
      final json = jsonDecode(utf8.decode(resp, allowMalformed: true));
      return decoder(json);
    } on GStoreException catch (e) {
      appLog.warning('AnalyzerRustDecoder: $method 模块失败 - ${e.status.name} ${e.errorCode}');
      return null;
    } catch (e) {
      appLog.error('AnalyzerRustDecoder: $method 模块调用失败 - $e');
      return null;
    }
  }
}

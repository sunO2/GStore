import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/Contract.dart' show decodeApkInfo, decodeApkComponents, decodeElfScanResult, decodeDexClasses;
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
      _moduleInstance = await RustModuleInstance.create('analyzer', _moduleHandle!);
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

  /// 扫描 ELF 16KB 页对齐（模块先试，失败降级宿主内置）
  static Future<ApkElfScanResult?> scanElfPageSizes(String apkPath) async {
    final moduleResult = await _roundtripJson(
      'scan_elf_page_sizes',
      utf8.encode(apkPath),
      (json) => decodeElfScanResult(json),
    );
    if (moduleResult != null) return moduleResult;
    return null; // 宿主已删内置实现，仅模块路径（模块失败即不可用）
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

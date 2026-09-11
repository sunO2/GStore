import 'dart:async';
import 'dart:convert' show jsonDecode, utf8;
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' show getApplicationDocumentsDirectory;

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleManager.dart';

/// 模块清单条目（modules.json 结构，与发布端约定）
///
/// 模块 .so 托管在 GitHub Release 附件（GStore 分发渠道），
/// 清单列出各模块的 ABI 文件名与 SHA-256，Dart 侧下载后校验再交给宿主 dlopen。
class ModuleManifestEntry {
  final String name; // 模块名（如 "qr"）
  final String version;
  final String sha256; // 该 ABI .so 的 SHA-256
  final String fileName; // 如 "libgstore_mod_qr.so"

  ModuleManifestEntry({
    required this.name,
    required this.version,
    required this.sha256,
    required this.fileName,
  });

  factory ModuleManifestEntry.fromJson(Map<String, dynamic> json) {
    return ModuleManifestEntry(
      name: json['name'] as String,
      version: json['version'] as String,
      sha256: json['sha256'] as String,
      fileName: json['file_name'] as String,
    );
  }
}

/// 模块加载器：负责模块 .so 的按需下载 → 哈希校验 → 宿主 dlopen 挂载。
///
/// 架构文档 4.4：按需注册（主路径）。模块存应用私有目录
/// `<docs>/gstore_modules/<name>/<abi>/<file>`，dlopen 绝对路径。
class RustModuleLoader {
  RustModuleLoader._();

  static RustModuleLoader? _instance;
  static RustModuleLoader get instance => _instance ??= RustModuleLoader._();

  /// 模块 .so 远端根 URL（发布端配置；空 = 禁用远程模块）
  String? remoteBaseUrl;

  /// 默认 ABI 名（与 Rust target 对应：arm64-v8a / armeabi-v7a / x86 / x86_64）
  String get currentAbi {
    // 下载/提取路径均由平台侧（MainActivity extractModule）用
    // Build.SUPPORTED_ABIS 自动匹配当前设备 ABI；此处仅为
    // 远程下载 URL 构造保留（未配置 remoteBaseUrl 时不用）。
    if (defaultTargetPlatform == TargetPlatform.android) {
      return 'arm64-v8a';
    }
    return 'x86_64'; // 桌面调试
  }

  /// 确保模块就绪：内置.jniLibs → 本地私有目录 → 远程更新，依次尝试。
  /// 返回 false = 模块不可用（调用方走降级路径）。
  Future<bool> ensureModule(String name) async {
    // 已挂载 → 直接可用
    if (await RustModuleManager.instance.isLoaded(name)) return true;

    // 1. 内置方案：jniLibs（Android nativeLibraryDir）自动检索
    final builtinSo = await _builtinSoPath(name);
    if (builtinSo != null && File(builtinSo).existsSync()) {
      appLog.info('RustModuleLoader: $name 命中内置模块 $builtinSo');
      return _mountLocal(name, builtinSo);
    }

    // 2. 本地私有目录（曾下载/缓存的模块）
    final localSo = await _localSoPath(name);
    if (localSo != null && await File(localSo).exists()) {
      // 2a. 远端已配置且清单版本更新 → 下载替换（更新链路）
      if (await _remoteHasNewerVersion(name)) {
        final remote = remoteBaseUrl;
        if (remote != null && remote.isNotEmpty) {
          return _downloadAndMount(name, remote);
        }
      }
      // 2b. 无更新 / 未配远端 → 直接使用本地
      return _mountLocal(name, localSo);
    }

    // 3. 远程下载（未配置则不可用，走降级）
    final remote = remoteBaseUrl;
    if (remote == null || remote.isEmpty) {
      appLog.info('RustModuleLoader: $name 未配置远程源，模块不可用（走降级）');
      return false;
    }
    return _downloadAndMount(name, remote);
  }

  /// 远端清单是否比本地已下载的模块版本更新（无清单信息/无本地版本 → false 不更新）
  Future<bool> _remoteHasNewerVersion(String name) async {
    final manifestEntry = await _remoteManifestEntry(name);
    if (manifestEntry == null) return false;
    final remoteVersion = manifestEntry['version'] as String?;
    if (remoteVersion == null || remoteVersion.isEmpty) return false;

    final localVersion = await _localVersion(name);
    if (localVersion == null) {
      // 本地无版本记录 → 无法对比，保守不更新（已有本地模块可用）
      return false;
    }
    final newer = _compareVersions(remoteVersion, localVersion) > 0;
    if (newer) {
      appLog.info('RustModuleLoader: $name 检测到更新 $localVersion → $remoteVersion');
    }
    return newer;
  }

  /// 读取远端清单的模块条目（version + sha256 + abi）
  Future<Map<String, dynamic>?> _remoteManifestEntry(String name) async {
    final base = remoteBaseUrl;
    if (base == null || base.isEmpty) return null;
    try {
      final manifestBytes = await _httpGetBytes('$base/modules.json');
      if (manifestBytes == null) return null;
      final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
      final modules = manifest['modules'] as Map<String, dynamic>?;
      return modules?[name] as Map<String, dynamic>?;
    } catch (e) {
      appLog.warning('RustModuleLoader: 读取远端清单失败 - $e');
      return null;
    }
  }

  /// 本地已下载模块的版本（挂载时写入 <module>/version）
  Future<String?> _localVersion(String name) async {
    final vFile = File(p.join(await _moduleDir(name), 'version'));
    if (!vFile.existsSync()) return null;
    try {
      return (await vFile.readAsString()).trim();
    } catch (_) {
      return null;
    }
  }

  /// 下载完成后记录本地版本
  Future<void> _writeLocalVersion(String name, String version) async {
    try {
      final dir = await _moduleDir(name);
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, 'version')).writeAsString(version, flush: true);
    } catch (e) {
      appLog.warning('RustModuleLoader: 记录模块版本失败 - $e');
    }
  }

  /// 点分版本号比较：返回 >0（a>b）/<0（a<b）/0（相等）
  int _compareVersions(String a, String b) {
    final sa = _parseVersion(a);
    final sb = _parseVersion(b);
    for (var i = 0; i < 3; i++) {
      if (sa[i] != sb[i]) return sa[i] - sb[i];
    }
    return 0;
  }

  List<int> _parseVersion(String v) {
    final parts = v.split('.');
    return [
      parts.isNotEmpty ? int.tryParse(parts[0]) ?? 0 : 0,
      parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
      parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0,
    ];
  }

  /// 内置模块路径：Android 上从 APK 提取 libgstore_mod_<name>.so 到私有目录
  /// （useLegacyPackaging=false 时 nativeLibraryDir 无物理文件，须显式解压后 dlopen）
  Future<String?> _builtinSoPath(String name) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      const channel = MethodChannel('gstore/apk_source');
      final path = await channel.invokeMethod<String>(
        'extractModule',
        {'module': name, 'abi': currentAbi},
      );
      if (path == null || path.isEmpty) return null;
      final f = File(path);
      return f.existsSync() ? f.path : null;
    } catch (e) {
      appLog.warning('RustModuleLoader: 提取内置模块失败 - $e');
      return null;
    }
  }

  /// 下载 → SHA-256 校验 → 宿主 dlopen 挂载
  Future<bool> _downloadAndMount(String name, String baseUrl) async {
    try {
      final dir = await _moduleDir(name);
      await Directory(dir).create(recursive: true);
      final fileName = 'libgstore_mod_$name.so';
      final file = File(p.join(dir, fileName));

      // 1. 下载
      final url = '$baseUrl/$currentAbi/$fileName';
      appLog.info('RustModuleLoader: 下载模块 $name <- $url');
      final resp = await _httpGetBytes(url);
      if (resp == null) {
        appLog.warning('RustModuleLoader: $name 下载失败');
        return false;
      }

      // 2. SHA-256 校验（清单对不上则拒绝挂载）
      final expected = await _expectedSha256(name);
      if (expected != null) {
        final actual = _sha256Hex(resp);
        if (actual != expected) {
          appLog.error('RustModuleLoader: $name SHA-256 不匹配（拒绝加载）');
          return false;
        }
      }

      // 3. 原子写入 + 版本记录 + 挂载
      await file.writeAsBytes(resp, flush: true);
      final entry = await _remoteManifestEntry(name);
      final version = entry?['version'] as String?;
      if (version != null) {
        await _writeLocalVersion(name, version);
      }
      return _mountLocal(name, file.path);
    } catch (e) {
      appLog.error('RustModuleLoader: $name 下载/挂载失败 - $e');
      return false;
    }
  }

  /// 宿主 dlopen 挂载本地 .so
  Future<bool> _mountLocal(String name, String soPath) async {
    try {
      await RustModuleManager.instance.ensureReady();
      final handle = await RustModuleManager.instance.mountFromSo(soPath);
      return handle != null;
    } catch (e) {
      appLog.error('RustModuleLoader: $name 挂载失败 - $e');
      return false;
    }
  }

  Future<String?> _localSoPath(String name) async {
    final dir = await _moduleDir(name);
    final file = File(p.join(dir, 'libgstore_mod_$name.so'));
    return file.existsSync() ? file.path : null;
  }

  Future<String> _moduleDir(String name) async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'gstore_modules', name);
  }

  /// 清单 SHA-256：从发布端 modules.json 读取（远端 URL 方案专用校验）。
  /// 内置方案（jniLibs 打包）与 APK 同信任锚，不做校验。
  Future<String?> _expectedSha256(String name) async {
    final base = remoteBaseUrl;
    if (base == null || base.isEmpty) return null;
    try {
      final manifestBytes = await _httpGetBytes('$base/modules.json');
      if (manifestBytes == null) return null;
      final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
      final modules = manifest['modules'] as Map<String, dynamic>?;
      final module = modules?[name] as Map<String, dynamic>?;
      final abi = module?['abi'] as Map<String, dynamic>?;
      final entry = abi?[currentAbi] as Map<String, dynamic>?;
      return entry?['sha256'] as String?;
    } catch (e) {
      appLog.warning('RustModuleLoader: 读取清单失败 - $e');
      return null;
    }
  }

  Future<Uint8List?> _httpGetBytes(String url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) return null;
      final builder = BytesBuilder();
      await for (final chunk in resp) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } catch (e) {
      appLog.warning('RustModuleLoader: HTTP 下载失败 - $e');
      return null;
    } finally {
      client.close();
    }
  }

  String _sha256Hex(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }
}

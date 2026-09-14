import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
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

/// 原生插件状态（只读展示：是否存在 / 来源 / 是否已加载）
class RustModuleStatus {
  final String name;

  /// 是否存在可用产物（本地产物或可远程获取）
  final bool exists;

  /// 产物来源：'builtin'（APK 内置）/ 'downloaded'（本地已下载）/ 'remote'（仅远程）/ 'none'
  final String source;

  /// 本地产物路径（若有）
  final String? soPath;

  /// 本地已下载版本（若有记录）
  final String? version;

  /// 运行时是否已挂载（宿主注册表）
  final bool loaded;

  /// 宿主回报的模块版本（已加载时）
  final int? loadedVersion;

  const RustModuleStatus({
    required this.name,
    required this.exists,
    required this.source,
    this.soPath,
    this.version,
    this.loaded = false,
    this.loadedVersion,
  });

  /// 来源中文标签
  String get sourceLabel => switch (source) {
        'builtin' => '内置',
        'downloaded' => '已下载',
        'remote' => '可远程',
        _ => '缺失',
      };
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

  /// 远端清单缓存（同一次加载流程复用，避免重复 HTTP）
  Map<String, dynamic>? _manifestCache;

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

  /// 模块是否可用（**不加载、不解压**）：APK 内置 或 已下载到本地。
  /// 供 UI 决定是否显示"本地模型"等入口。
  Future<bool> isAvailable(String name) async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        const channel = MethodChannel('gstore/apk_source');
        final has = await channel.invokeMethod<bool>(
          'hasModule',
          {'module': name, 'abi': currentAbi},
        );
        if (has == true) return true;
      } catch (_) {
        // 平台不支持则退化为只查本地文件
      }
    }
    return (await _localSoPath(name)) != null;
  }

  /// 探测模块状态（**不加载、不下载**）：
  /// 查本地产物（已下载 → 内置）与运行时是否已挂载，供 UI 只读展示。
  Future<RustModuleStatus> probe(String name) async {
    // 1) 运行时是否已挂载（宿主注册表）
    var loaded = false;
    int? loadedVersion;
    try {
      final mods = await RustModuleManager.instance.loadedModules();
      for (final m in mods) {
        if (m.name == name) {
          loaded = true;
          loadedVersion = m.version;
          break;
        }
      }
    } catch (_) {
      // Rust 未初始化/不可用 → 视为未加载
    }

    // 2) 产物存在性（不 dlopen）；平台不可用（如无 path_provider）→ 回退 none
    var source = 'none';
    String? soPath;
    String? localVersion;
    try {
      final local = await _localSoPath(name);
      if (local != null) {
        source = 'downloaded';
        soPath = local;
      } else {
        final builtin = await _builtinSoPathReadOnly(name);
        if (builtin != null && File(builtin).existsSync()) {
          source = 'builtin';
          soPath = builtin;
        } else if ((remoteBaseUrl ?? '').isNotEmpty) {
          source = 'remote';
        }
      }
      localVersion = await _localVersion(name);
    } catch (_) {
      // 平台不可用 → 保持 none
    }

    return RustModuleStatus(
      name: name,
      exists: source != 'none',
      source: source,
      soPath: soPath,
      version: localVersion,
      loaded: loaded,
      loadedVersion: loadedVersion,
    );
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

  /// 拉取并缓存远端清单
  Future<Map<String, dynamic>?> _remoteManifest() async {
    if (_manifestCache != null) return _manifestCache;
    final base = remoteBaseUrl;
    if (base == null || base.isEmpty) return null;
    try {
      final manifestBytes = await _httpGetBytes('$base/modules.json');
      if (manifestBytes == null) return null;
      _manifestCache =
          jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
      return _manifestCache;
    } catch (e) {
      appLog.warning('RustModuleLoader: 读取远端清单失败 - $e');
      return null;
    }
  }

  /// 读取远端清单的模块条目（version + sha256 + abi）
  Future<Map<String, dynamic>?> _remoteManifestEntry(String name) async {
    final manifest = await _remoteManifest();
    final modules = manifest?['modules'] as Map<String, dynamic>?;
    return modules?[name] as Map<String, dynamic>?;
  }

  /// 读取远端清单中该模块当前 ABI 的条目（sha256 + signature）
  Future<Map<String, dynamic>?> _remoteAbiEntry(String name) async {
    final entry = await _remoteManifestEntry(name);
    final abi = entry?['abi'] as Map<String, dynamic>?;
    return abi?[currentAbi] as Map<String, dynamic>?;
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

  /// 内置模块路径（**只读**）：不解压，仅查已解压文件是否存在。
  /// 供状态查询使用——解压接口会写盘，绝不能在只读诊断里触发。
  Future<String?> _builtinSoPathReadOnly(String name) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      const channel = MethodChannel('gstore/apk_source');
      final path = await channel.invokeMethod<String>(
        'moduleSoPath',
        {'module': name, 'abi': currentAbi},
      );
      if (path == null || path.isEmpty) return null;
      return path;
    } catch (e) {
      return null;
    }
  }

  /// 下载 → SHA-256 校验 → 宿主 dlopen 挂载
  Future<bool> _downloadAndMount(String name, String baseUrl) async {
    try {
      final dir = await _moduleDir(name);
      await Directory(dir).create(recursive: true);

      // 清单条目：远程文件名 / 版本 / 签名
      final entry = await _remoteAbiEntry(name);
      final signature = entry?['signature'] as String?;
      final version = (await _remoteManifestEntry(name))?['version'] as String?;
      // 远程模块强制签名：清单缺 signature 直接拒绝（fail-closed，
      // 避免仅靠同一通道的 SHA-256 形成"安全剧场"）
      if (signature == null || signature.isEmpty) {
        appLog.error('RustModuleLoader: $name 清单缺少 signature，拒绝加载');
        return false;
      }
      final remoteFileName =
          (entry?['file_name'] as String?) ?? 'libgstore_mod_$name.so';
      // 本地落到版本化文件名：mount-once 下新版本走独立路径，下次启动即加载新版
      final localFileName = (version != null && version.isNotEmpty)
          ? 'libgstore_mod_${name}_$version.so'
          : 'libgstore_mod_$name.so';
      final file = File(p.join(dir, localFileName));

      // 1. 下载
      final url = '$baseUrl/$currentAbi/$remoteFileName';
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

      // 3. 原子写入 + 版本记录 + 写签名侧车 + 挂载
      await file.writeAsBytes(resp, flush: true);
      if (version != null) {
        await _writeLocalVersion(name, version);
      }
      await _writeSidecars(name, version ?? '0.0.0', signature, file.path);
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
    try {
      // 版本化文件优先：取最近修改的一个（新版本独立文件名）
      final candidates = Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) {
            final base = p.basename(f.path);
            return base.startsWith('libgstore_mod_${name}_') &&
                base.endsWith('.so');
          })
          .toList()
        ..sort((a, b) =>
            b.statSync().modified.compareTo(a.statSync().modified));
      if (candidates.isNotEmpty) return candidates.first.path;
    } catch (_) {
      // 目录不存在/不可读 → 回退旧命名
    }
    final legacy = File(p.join(dir, 'libgstore_mod_$name.so'));
    return legacy.existsSync() ? legacy.path : null;
  }

  Future<String> _moduleDir(String name) async {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'gstore_modules', name);
  }

  /// 清单 SHA-256：从远端 modules.json 的当前 ABI 条目读取。
  /// 内置方案（jniLibs 打包）与 APK 同信任锚，不做校验。
  Future<String?> _expectedSha256(String name) async {
    final entry = await _remoteAbiEntry(name);
    return entry?['sha256'] as String?;
  }

  /// 写签名/元数据侧车文件（宿主 dlopen 前校验用；与 .so 同目录、同名前缀）
  Future<void> _writeSidecars(
    String name,
    String version,
    String signatureHex,
    String soPath,
  ) async {
    try {
      await File('$soPath.sig').writeAsString('$signatureHex\n', flush: true);
      final meta = jsonEncode({'name': name, 'version': version, 'abi': currentAbi});
      await File('$soPath.meta').writeAsString(meta, flush: true);
      appLog.info('RustModuleLoader: $name 已写入签名侧车（宿主校验后 dlopen）');
    } catch (e) {
      appLog.error('RustModuleLoader: $name 写签名侧车失败 - $e');
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

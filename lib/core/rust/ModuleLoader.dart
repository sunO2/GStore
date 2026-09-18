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
import 'package:gstore/core/rust/ModuleManifest.dart';

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

  /// 远端清单缓存（同一次加载流程复用，避免重复 HTTP）；
  /// 解析为 v2 强类型模型，旧 schema 一律拒绝。
  ModuleManifestV2? _manifestCache;

  // ---- 测试接缝（Todo 2）：生产路径未配置覆盖时行为不变 ----

  /// 可注入清单来源（生产：`ModuleManifestClient`，Todo 8）。
  ModuleManifestSource? _manifestSource;

  /// 可注入资产下载器（生产：`ModuleDownloader`，Todo 3）。
  ModuleFetcher? _downloader;

  /// 直接注入的原始清单 JSON（测试专用；优先于清单来源/网络）。
  Map<String, dynamic>? _manifestOverride;

  /// 模块私有目录基址覆盖（测试专用；不触发 path_provider）。
  String? _supportDirOverride;

  /// `isLoaded` 覆盖（测试专用；默认 → `RustModuleManager.isLoaded`）。
  Future<bool> Function(String name)? _isLoadedOverride;

  /// 挂载覆盖（测试专用；默认 → `RustModuleManager.mountFromSo`）。
  Future<bool> Function(String soPath)? _mountOverride;

  /// 时间源覆盖（测试专用；缓存 TTL 判定用）。
  DateTime Function()? _clockOverride;

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

  /// Rust 模块支持的 ABI 集合（与 Rust target 对应）
  static const Set<String> _supportedAbis = {
    'arm64-v8a',
    'armeabi-v7a',
    'x86',
    'x86_64',
  };

  /// 设备 ABI 内存缓存（首次解析后复用，避免重复通道往返）
  String? _deviceAbiCache;

  /// 真实设备 ABI：Android 经 `gstore/apk_source` 通道读取
  /// `Build.SUPPORTED_ABIS` 首选值；非 Android 返回桌面值。
  /// 通道异常/返回 null/返回不支持的 ABI 一律回退现有逻辑（Android=arm64-v8a），
  /// **绝不抛异常**。结果内存缓存，第二次调用不再触发通道。
  Future<String> deviceAbi() async {
    final cached = _deviceAbiCache;
    if (cached != null) return cached;

    var resolved = currentAbi; // 回退：Android=arm64-v8a / 桌面=x86_64
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        const channel = MethodChannel('gstore/apk_source');
        final abi = await channel.invokeMethod<String>('currentAbi');
        if (abi != null && _supportedAbis.contains(abi)) {
          resolved = abi;
        }
      } catch (_) {
        // 通道不可用/报错 → 回退，不抛
      }
    }
    _deviceAbiCache = resolved;
    return resolved;
  }

  /// 清除设备 ABI 缓存（测试注入通道后需重新解析）
  @visibleForTesting
  void resetDeviceAbiCache() {
    _deviceAbiCache = null;
  }

  /// 触发内置模块提取通道调用，供测试断言其 ABI 参数（测试专用）
  @visibleForTesting
  Future<String?> debugBuiltinSoPath(String name) => _builtinSoPath(name);

  /// 配置测试接缝：清单来源/下载器/清单覆盖/支持目录/isLoaded/挂载/时钟。
  ///
  /// 未配置的项保持生产行为；配置后 `ensureModule` 可在**无 FFI、无网络**下运行。
  @visibleForTesting
  void debugConfigure({
    ModuleManifestSource? manifestSource,
    ModuleFetcher? downloader,
    Map<String, dynamic>? manifestOverride,
    String? supportDir,
    Future<bool> Function(String name)? isLoadedOverride,
    Future<bool> Function(String soPath)? mountOverride,
    DateTime Function()? clock,
  }) {
    _manifestSource = manifestSource;
    _downloader = downloader;
    _manifestOverride = manifestOverride;
    _supportDirOverride = supportDir;
    _isLoadedOverride = isLoadedOverride;
    _mountOverride = mountOverride;
    _clockOverride = clock;
    // 清单可能变化，清缓存避免跨测试泄漏。
    _manifestCache = null;
  }

  /// 还原生产行为（清空全部测试覆盖与缓存）。
  @visibleForTesting
  void debugReset() {
    _manifestSource = null;
    _downloader = null;
    _manifestOverride = null;
    _supportDirOverride = null;
    _isLoadedOverride = null;
    _mountOverride = null;
    _clockOverride = null;
    _manifestCache = null;
    _deviceAbiCache = null;
  }

  /// 是否配置了任一测试覆盖（供测试断言 [debugReset] 生效）。
  @visibleForTesting
  bool get debugSeamActive =>
      _manifestSource != null ||
      _downloader != null ||
      _manifestOverride != null ||
      _supportDirOverride != null ||
      _isLoadedOverride != null ||
      _mountOverride != null ||
      _clockOverride != null;

  /// 读取清单（测试专用；覆盖生效时不触发真实网络）。
  @visibleForTesting
  Future<ModuleManifestV2?> debugLoadManifest() => _remoteManifest();

  /// 注入的时钟（测试专用；未配置 → null）。
  @visibleForTesting
  DateTime Function()? get debugClock => _clockOverride;

  /// `isLoaded`：优先注入覆盖，否则走宿主导航注册表。
  Future<bool> _isLoaded(String name) async {
    final override = _isLoadedOverride;
    if (override != null) return override(name);
    return RustModuleManager.instance.isLoaded(name);
  }

  /// 确保模块就绪：内置.jniLibs → 本地私有目录 → 远程更新，依次尝试。
  /// 返回 false = 模块不可用（调用方走降级路径）。
  Future<bool> ensureModule(String name) async {
    // 已挂载 → 直接可用
    if (await _isLoaded(name)) return true;

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
          {'module': name, 'abi': await deviceAbi()},
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
    final remoteVersion = manifestEntry.version;
    if (remoteVersion.isEmpty) return false;

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

  /// 拉取并缓存远端清单（强类型 v2）；旧 schema 显式拒绝并安全降级为 null。
  Future<ModuleManifestV2?> _remoteManifest() async {
    final cached = _manifestCache;
    if (cached != null) return cached;

    // 1) 测试覆盖直接注入原始 JSON
    final override = _manifestOverride;
    if (override != null) {
      final parsed = _parseManifestSafe(override);
      if (parsed != null) _manifestCache = parsed;
      return parsed;
    }

    // 2) 可注入清单来源（生产：ModuleManifestClient，Todo 8）
    final source = _manifestSource;
    if (source != null) {
      try {
        final loaded = await source.load();
        if (loaded != null) _manifestCache = loaded;
        return loaded;
      } catch (e) {
        appLog.warning('RustModuleLoader: 清单源加载失败 - $e');
        return null;
      }
    }

    // 3) 生产网络路径
    final base = remoteBaseUrl;
    if (base == null || base.isEmpty) return null;
    try {
      final manifestBytes = await _httpGetBytes('$base/modules.json');
      if (manifestBytes == null) return null;
      final raw = jsonDecode(utf8.decode(manifestBytes));
      if (raw is! Map<String, dynamic>) {
        appLog.warning('RustModuleLoader: 远端清单不是对象');
        return null;
      }
      final parsed = _parseManifestSafe(raw);
      if (parsed != null) _manifestCache = parsed;
      return parsed;
    } catch (e) {
      appLog.warning('RustModuleLoader: 读取远端清单失败 - $e');
      return null;
    }
  }

  /// 防御式解析清单：旧 schema/结构非法 → 记录并返回 null（绝不崩溃）。
  ModuleManifestV2? _parseManifestSafe(Map<String, dynamic> raw) {
    try {
      return ModuleManifestV2.fromJson(raw);
    } on ModuleManifestFormatException catch (e) {
      appLog.warning('RustModuleLoader: 清单格式不支持 - ${e.message}');
      return null;
    } catch (e) {
      appLog.warning('RustModuleLoader: 清单解析失败 - $e');
      return null;
    }
  }

  /// 读取远端清单的模块条目（version + abi）
  Future<ModuleEntryV2?> _remoteManifestEntry(String name) async {
    final manifest = await _remoteManifest();
    return manifest?.entry(name);
  }

  /// 读取远端清单中该模块当前 ABI 的资产（asset + sha256 + size + signature）
  Future<ModuleAbiAsset?> _remoteAbiEntry(String name) async {
    final entry = await _remoteManifestEntry(name);
    if (entry == null) return null;
    return entry.forAbi(await deviceAbi());
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
        {'module': name, 'abi': await deviceAbi()},
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
        {'module': name, 'abi': await deviceAbi()},
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

      // 清单条目：远程资产名 / 版本 / 签名
      final entry = await _remoteAbiEntry(name);
      final signature = entry?.signature;
      final version = (await _remoteManifestEntry(name))?.version;
      // 远程模块强制签名：清单缺 signature 直接拒绝（fail-closed，
      // 避免仅靠同一通道的 SHA-256 形成"安全剧场"）
      if (signature == null || signature.isEmpty) {
        appLog.error('RustModuleLoader: $name 清单缺少 signature，拒绝加载');
        return false;
      }
      final remoteFileName = entry?.asset ?? 'libgstore_mod_$name.so';
      // 本地落到版本化文件名：mount-once 下新版本走独立路径，下次启动即加载新版
      final localFileName = (version != null && version.isNotEmpty)
          ? 'libgstore_mod_${name}_$version.so'
          : 'libgstore_mod_$name.so';
      final file = File(p.join(dir, localFileName));

      // 1. 下载（优先注入下载器，测试/后续 Todo 3 复用）
      final url = '$baseUrl/${await deviceAbi()}/$remoteFileName';
      appLog.info('RustModuleLoader: 下载模块 $name <- $url');
      final resp = await _fetchBytes(url);
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
    // 测试接缝：注入挂载覆盖时完全绕过真实 FFI。
    final override = _mountOverride;
    if (override != null) {
      try {
        return await override(soPath);
      } catch (e) {
        appLog.error('RustModuleLoader: $name 注入挂载失败 - $e');
        return false;
      }
    }
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
    // 测试接缝：注入支持目录时完全绕过 path_provider。
    final override = _supportDirOverride;
    if (override != null) {
      return p.join(override, 'gstore_modules', name);
    }
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'gstore_modules', name);
  }

  /// 清单 SHA-256：从远端 modules.json 的当前 ABI 条目读取。
  /// 内置方案（jniLibs 打包）与 APK 同信任锚，不做校验。
  Future<String?> _expectedSha256(String name) async {
    final entry = await _remoteAbiEntry(name);
    return entry?.sha256;
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
      final meta = jsonEncode(
        {'name': name, 'version': version, 'abi': await deviceAbi()},
      );
      await File('$soPath.meta').writeAsString(meta, flush: true);
      appLog.info('RustModuleLoader: $name 已写入签名侧车（宿主校验后 dlopen）');
    } catch (e) {
      appLog.error('RustModuleLoader: $name 写签名侧车失败 - $e');
    }
  }

  /// 获取资产字节：优先注入的 [ModuleFetcher]（测试/Todo 3 下载器），
  /// 否则走生产 `HttpClient`。
  Future<Uint8List?> _fetchBytes(String url, {int? maxBytes}) async {
    final fetcher = _downloader;
    if (fetcher != null) {
      try {
        return await fetcher.fetch(url, maxBytes: maxBytes);
      } catch (e) {
        appLog.warning('RustModuleLoader: 注入下载器失败 - $e');
        return null;
      }
    }
    return _httpGetBytes(url);
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

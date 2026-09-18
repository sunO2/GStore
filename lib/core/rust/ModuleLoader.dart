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

  /// 是否要求签名（Phase 1 默认 `false`）。
  ///
  /// * `true`：清单条目缺非空 `signature` → **拒绝安装**（fail-closed），
  ///   安装成功时写入非空 `${finalSo}.sig`。
  /// * `false`：**绝不**写 `.sig`，并删除同名遗留 `${finalSo}.sig`
  ///   （否则宿主会走签名分支并用空公钥拒绝加载）。
  bool requireSignature = false;

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

  /// `.meta` 写入前钩子（测试专用；用于证明「先 `.so` 后 `.meta`」的顺序）。
  void Function(String name, String soPath)? _beforeMetaWriteHook;

  /// 启动清理遗留 `.tmp` 是否已执行（每个进程/测试配置后恰好一次）。
  bool _tempCleanupDone = false;

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
    void Function(String name, String soPath)? beforeMetaWrite,
  }) {
    _manifestSource = manifestSource;
    _downloader = downloader;
    _manifestOverride = manifestOverride;
    _supportDirOverride = supportDir;
    _isLoadedOverride = isLoadedOverride;
    _mountOverride = mountOverride;
    _clockOverride = clock;
    _beforeMetaWriteHook = beforeMetaWrite;
    // 清单可能变化，清缓存避免跨测试泄漏。
    _manifestCache = null;
    // 新配置 ⇒ 允许重新执行一次启动 `.tmp` 清理。
    _tempCleanupDone = false;
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
    _beforeMetaWriteHook = null;
    _tempCleanupDone = false;
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
      _clockOverride != null ||
      _beforeMetaWriteHook != null;

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

    // 启动清理：删除下载目录中上次中断遗留的 `.tmp`（恰好一次）。
    await _cleanupTempOnce();

    // 1. 内置方案：jniLibs（Android nativeLibraryDir）自动检索
    final builtinSo = await _builtinSoPath(name);
    if (builtinSo != null && File(builtinSo).existsSync()) {
      appLog.info('RustModuleLoader: $name 命中内置模块 $builtinSo');
      return _mountLocal(name, builtinSo);
    }

    // 2. 本地私有目录（曾下载/缓存的模块）；fail-closed：缺 `.meta` 或
    //    sha256 复核不通过者一律不挂载。
    final localSo = await _verifiedLocalSoPath(name);
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
    return (await _verifiedLocalSoPath(name)) != null;
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
      final local = await _verifiedLocalSoPath(name);
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

  /// 解析为三段 `major.minor.patch`（缺失段补 0；`+build`/预发布后缀忽略）。
  /// 非法版本 → `[0,0,0]`（保守视为最低，绝不抛异常）。
  List<int> _parseVersion(String v) {
    final sanitized = _sanitizeVersion(v);
    if (sanitized == null) return const [0, 0, 0];
    final parts = sanitized.split('.');
    return [int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2])];
  }

  /// 归一化为宿主可解析的三段纯数字版本（`major.minor.patch`）：
  /// 剥离 `+build` 与 `-pre.release`，缺失段补 0，超过三段截断。
  ///
  /// 任一段非数字/负数 → 返回 `null`（调用方拒绝安装，fail-closed）。
  String? _sanitizeVersion(String raw) {
    var core = raw.trim();
    if (core.isEmpty) return null;
    final plus = core.indexOf('+');
    if (plus >= 0) core = core.substring(0, plus);
    final dash = core.indexOf('-');
    if (dash >= 0) core = core.substring(0, dash);
    if (core.isEmpty) return null;

    final parts = core.split('.');
    final nums = <int>[];
    for (var i = 0; i < parts.length && nums.length < 3; i++) {
      final n = int.tryParse(parts[i]);
      if (n == null || n < 0) return null;
      nums.add(n);
    }
    if (nums.isEmpty) return null;
    while (nums.length < 3) {
      nums.add(0);
    }
    return '${nums[0]}.${nums[1]}.${nums[2]}';
  }

  /// 测试专用：暴露版本归一化结果（bad version 对抗用例）。
  @visibleForTesting
  String? debugSanitizeVersion(String raw) => _sanitizeVersion(raw);

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

  /// 下载 → SHA-256 校验 → **原子配对安装**（`.tmp` → `.so` → `.meta`）→ 挂载。
  ///
  /// 顺序不可交换（见 `.omo/plans/remote-plugin-download.md` Todo 4）：
  /// 1. 下载到 `<support>/gstore_modules/<name>/<finalSo>.tmp`；
  /// 2. 校验清单 SHA-256（不符 → 删 `.tmp`，无最终产物）；
  /// 3. **先** rename `.tmp` → `libgstore_mod_<name>_<major.minor.patch>.so`；
  /// 4. **后** 写 `.meta`（`{name, version, abi, sha256, source:'remote'}`）作为提交标记；
  /// 5. 仅 `requireSignature=true` 时写非空 `.sig`；`false` 时删除同名遗留 `.sig`。
  ///
  /// 任一步失败只留下可被启动清理的 `.tmp`，绝不产生「有 `.so` 无 `.meta`」以外的
  /// 半写提交（后者由挂载期 fail-closed 拦截）。
  Future<bool> _downloadAndMount(String name, String baseUrl) async {
    try {
      final entry = await _remoteAbiEntry(name);
      final version = (await _remoteManifestEntry(name))?.version;
      if (entry == null || version == null || version.isEmpty) {
        appLog.error('RustModuleLoader: $name 清单缺少当前 ABI 资产/版本，拒绝安装');
        return false;
      }

      // 签名开关：仅 true 时要求清单提供非空 signature（fail-closed）。
      final signature = entry.signature;
      if (requireSignature && (signature == null || signature.isEmpty)) {
        appLog.error(
            'RustModuleLoader: $name requireSignature=true 但清单缺少 signature，拒绝安装');
        return false;
      }

      // 本地文件名恒为三段纯数字版本（剥离 +build / 预发布）。
      final sanitizedVersion = _sanitizeVersion(version);
      if (sanitizedVersion == null) {
        appLog.error('RustModuleLoader: $name 版本号非法（$version），拒绝安装');
        return false;
      }
      final dir = await _moduleDir(name);
      await Directory(dir).create(recursive: true);

      final finalSo = File(p.join(dir, 'libgstore_mod_${name}_$sanitizedVersion.so'));
      final metaFile = File('${finalSo.path}.meta');
      final sigFile = File('${finalSo.path}.sig');
      final tmpFile = File('${finalSo.path}.tmp');

      // 1. 下载到 `<finalSo>.tmp`（注入下载器优先；测试无网络）。
      final url = '$baseUrl/${await deviceAbi()}/${entry.asset}';
      appLog.info('RustModuleLoader: 下载模块 $name <- $url');
      final resp = await _fetchBytes(url);
      if (resp == null) {
        appLog.warning('RustModuleLoader: $name 下载失败');
        await _deleteQuietly(tmpFile);
        return false;
      }
      await tmpFile.writeAsBytes(resp, flush: true);

      // 2. 校验清单 SHA-256：不符 → 删除 `.tmp`，无最终 `.so`/`.meta`。
      final actual = _sha256Hex(resp);
      if (actual != entry.sha256.toLowerCase()) {
        appLog.error('RustModuleLoader: $name SHA-256 不匹配（拒绝安装）');
        await _deleteQuietly(tmpFile);
        return false;
      }

      // 3. **先**提交 `.so`：`.tmp` → 三段式最终文件名。
      await _renameOver(tmpFile, finalSo);

      // 测试接缝：在写 `.meta` 前回调，用于证明「.so 已存在」的顺序。
      _beforeMetaWriteHook?.call(name, finalSo.path);

      // 4. **后**写 `.meta` 作为提交标记（原子：`.meta.tmp` → `.meta`）。
      final meta = jsonEncode(<String, dynamic>{
        'name': name,
        'version': version,
        'abi': await deviceAbi(),
        'sha256': actual,
        'source': 'remote',
      });
      await _atomicWrite(metaFile, meta);

      // 5. 签名侧车：true 写非空 `.sig`；false 删除同名遗留 `.sig`。
      if (requireSignature) {
        await _atomicWrite(sigFile, '${signature!}\n');
      } else {
        await _deleteQuietly(sigFile);
      }

      // 真实版本另记录到 `version`（兼容既有读取路径）。
      await _writeLocalVersion(name, version);

      // 清理本次可能产生的 `.meta.tmp`/`.sig.tmp` 残留。
      await _deleteQuietly(File('${metaFile.path}.tmp'));
      await _deleteQuietly(File('${sigFile.path}.tmp'));

      return _mountLocal(name, finalSo.path);
    } catch (e) {
      appLog.error('RustModuleLoader: $name 下载/挂载失败 - $e');
      return false;
    }
  }

  /// 宿主 dlopen 挂载本地 .so
  Future<bool> _mountLocal(String name, String soPath) async {
    // `.sig` 卫生（单点）：`requireSignature=false` 时，**任何**本地 .so 挂载前
    // 都必须删除同名遗留 `.sig`。宿主 `trust.rs` 在未钉死公钥（Phase 1
    // `MODULE_SIGNING_PUBKEY_HEX=""`）下会拒绝带 `.sig` 的模块
    // （"module is signed but no pinned public key is configured"）。
    // 覆盖两条到达本方法的路径：`_downloadAndMount`（安装）与 `ensureModule` 2b
    // （直接挂载已验证的本地产物）。`requireSignature=true` 时保留真实签名
    // （Phase 2 迁移由 Todo 6 负责）。
    if (!requireSignature) {
      await _deleteQuietly(File('$soPath.sig'));
    }

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

  /// 本地已下载模块的 .so 路径（**fail-closed**）。
  ///
  /// 「已下载」以**目录位置**判定（`<support>/gstore_modules/<name>/`），而非
  /// `.meta` 存在与否；但挂载要求同目录存在**合法 `.meta` 且 sha256 复核通过**。
  /// 缺 `.meta`、`.meta` 非法、字节被篡改的 `.so` 一律返回 `null`（不挂载）。
  Future<String?> _verifiedLocalSoPath(String name) async {
    final dir = await _moduleDir(name);
    final candidates = <File>[];
    try {
      for (final entity in Directory(dir).listSync()) {
        if (entity is! File) continue;
        final base = p.basename(entity.path);
        final matches = base == 'libgstore_mod_$name.so' ||
            (base.startsWith('libgstore_mod_${name}_') &&
                base.endsWith('.so'));
        if (matches) candidates.add(entity);
      }
    } catch (_) {
      // 目录不存在/不可读 → 视为无本地产物
      return null;
    }
    // 最近修改优先（新版本独立文件名）；再逐个做 `.meta` + sha256 复核。
    candidates.sort((a, b) {
      try {
        return b.statSync().modified.compareTo(a.statSync().modified);
      } catch (_) {
        return 0;
      }
    });
    for (final candidate in candidates) {
      if (await _verifyMeta(name, candidate.path)) return candidate.path;
    }
    return null;
  }

  /// 复核 `<soPath>.meta`：存在、name 匹配、sha256 与 `.so` 字节一致。
  Future<bool> _verifyMeta(String name, String soPath) async {
    try {
      final metaFile = File('$soPath.meta');
      if (!await metaFile.exists()) {
        appLog.warning('RustModuleLoader: $name 本地产物缺少 .meta，拒绝挂载 ($soPath)');
        return false;
      }
      final decoded = jsonDecode(await metaFile.readAsString());
      if (decoded is! Map) return false;
      if (decoded['name'] != name) return false;
      final expected = decoded['sha256'];
      if (expected is! String || expected.isEmpty) return false;
      final actual = _sha256Hex(await File(soPath).readAsBytes());
      if (actual != expected.toLowerCase()) {
        appLog.error('RustModuleLoader: $name 本地产物 sha256 复核失败，拒绝挂载 ($soPath)');
        return false;
      }
      return true;
    } catch (e) {
      appLog.warning('RustModuleLoader: $name 读取 .meta 失败 - $e');
      return false;
    }
  }

  /// 模块私有目录基址（<support> 根）。
  ///
  /// 生产基线仍为 `getApplicationDocumentsDirectory()`（Todo 5 迁移到
  /// `getApplicationSupportDirectory()`）；测试经 [debugConfigure] 覆盖。
  Future<String> _supportDir() async {
    final override = _supportDirOverride;
    if (override != null) return override;
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  Future<String> _moduleDir(String name) async {
    return p.join(await _supportDir(), 'gstore_modules', name);
  }

  /// 删除下载目录中上次中断遗留的 `.tmp`（启动清理，幂等）。
  ///
  /// 覆盖：下载 `.tmp`、`.meta.tmp`、`.sig.tmp`。**不**触碰 `.so`/`.meta`/`.sig`。
  @visibleForTesting
  Future<void> cleanupLeftoverTemp() async {
    try {
      final root = Directory(p.join(await _supportDir(), 'gstore_modules'));
      if (!await root.exists()) return;
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.endsWith('.tmp')) {
          await _deleteQuietly(entity);
        }
      }
    } catch (e) {
      appLog.warning('RustModuleLoader: 清理遗留 .tmp 失败 - $e');
    }
  }

  /// 启动清理只执行一次（每次 [debugConfigure]/[debugReset] 后重置）。
  Future<void> _cleanupTempOnce() async {
    if (_tempCleanupDone) return;
    _tempCleanupDone = true;
    await cleanupLeftoverTemp();
  }

  /// `.tmp` → 最终文件：同目录 rename 原子替换；目标已存在时先删再 rename。
  Future<void> _renameOver(File src, File dest) async {
    try {
      await src.rename(dest.path);
    } on FileSystemException {
      await _deleteQuietly(dest);
      await src.rename(dest.path);
    }
  }

  /// 原子写文本：先写 `<target>.tmp` 再 rename（崩溃只留 `.tmp`）。
  Future<void> _atomicWrite(File target, String content) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await _renameOver(tmp, target);
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 清理失败不影响结果
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

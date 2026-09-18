import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;

import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart' show ModuleManifestClient;

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

  /// 远端清单可解析到的可用版本（无远端来源/不可解析 → null）。
  final String? remoteVersion;

  /// 远端版本高于当前本地/内置基线 → 有更新可下载。
  final bool updateAvailable;

  /// 下载目录存在产物但无有效项，且被 `quarantine.json` 标记隔离。
  final bool quarantined;

  /// 下载目录内是否存在任一模块 `.so` 产物（含无效/被隔离者）。
  final bool hasDownloaded;

  const RustModuleStatus({
    required this.name,
    required this.exists,
    required this.source,
    this.soPath,
    this.version,
    this.loaded = false,
    this.loadedVersion,
    this.remoteVersion,
    this.updateAvailable = false,
    this.quarantined = false,
    this.hasDownloaded = false,
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

  /// 内置清单（`assets/app/modules_builtin.json`）覆盖（测试专用）。
  Map<String, dynamic>? _builtinManifestOverride;

  /// 内置 `.so` 路径覆盖（测试专用；桌面测试模拟 Kotlin `extractModule`）。
  Future<String?> Function(String name)? _builtinSoPathOverride;

  /// `probe` 整体覆盖（测试专用；返回注入状态，绕过真实探测）。
  Future<RustModuleStatus> Function(String name)? _probeOverride;

  /// `rollbackToBuiltin` 覆盖（测试专用；用于断言回退被真实调用）。
  Future<bool> Function(String name)? _rollbackOverride;

  /// `downloadAndInstall` 覆盖（测试专用；用于无网络/FFI 的下载交互测试）。
  Future<bool> Function(String name)? _downloadOverride;

  /// 内置清单缓存（每处只读一次；`debugReset` 清空）。
  Map<String, dynamic>? _builtinManifestCache;

  /// 后台安装并发去重（同一模块同一时刻只跑一个后台更新）。
  final Set<String> _bgInFlight = {};

  /// 启动清理遗留 `.tmp` 是否已执行（每个进程/测试配置后恰好一次）。
  bool _tempCleanupDone = false;

  /// Phase 2 无签名下载产物迁移是否已执行（每个进程/测试配置后恰好一次）。
  bool _signatureMigrationDone = false;

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

  /// 下载内核模块名：**禁止**经同步远程路径自举（存在本地/内置后可后台更新）。
  static const String _downloadModuleName = 'download';

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
    Map<String, dynamic>? builtinManifestOverride,
    String? supportDir,
    Future<bool> Function(String name)? isLoadedOverride,
    Future<bool> Function(String soPath)? mountOverride,
    Future<String?> Function(String name)? builtinSoPathOverride,
    Future<RustModuleStatus> Function(String name)? probeOverride,
    Future<bool> Function(String name)? rollbackOverride,
    Future<bool> Function(String name)? downloadOverride,
    DateTime Function()? clock,
    void Function(String name, String soPath)? beforeMetaWrite,
  }) {
    _manifestSource = manifestSource;
    _downloader = downloader;
    _manifestOverride = manifestOverride;
    _builtinManifestOverride = builtinManifestOverride;
    _supportDirOverride = supportDir;
    _isLoadedOverride = isLoadedOverride;
    _mountOverride = mountOverride;
    _builtinSoPathOverride = builtinSoPathOverride;
    _probeOverride = probeOverride;
    _rollbackOverride = rollbackOverride;
    _downloadOverride = downloadOverride;
    _clockOverride = clock;
    _beforeMetaWriteHook = beforeMetaWrite;
    // 清单/内置清单可能变化，清缓存避免跨测试泄漏。
    _manifestCache = null;
    _builtinManifestCache = null;
    _bgInFlight.clear();
    // 新配置 ⇒ 允许重新执行一次启动 `.tmp` 清理与签名迁移。
    _tempCleanupDone = false;
    _signatureMigrationDone = false;
  }

  /// 还原生产行为（清空全部测试覆盖与缓存）。
  @visibleForTesting
  void debugReset() {
    _manifestSource = null;
    _downloader = null;
    _manifestOverride = null;
    _builtinManifestOverride = null;
    _supportDirOverride = null;
    _isLoadedOverride = null;
    _mountOverride = null;
    _builtinSoPathOverride = null;
    _probeOverride = null;
    _rollbackOverride = null;
    _downloadOverride = null;
    _clockOverride = null;
    _beforeMetaWriteHook = null;
    _tempCleanupDone = false;
    _signatureMigrationDone = false;
    _manifestCache = null;
    _builtinManifestCache = null;
    _bgInFlight.clear();
    _deviceAbiCache = null;
  }

  /// 是否配置了任一测试覆盖（供测试断言 [debugReset] 生效）。
  @visibleForTesting
  bool get debugSeamActive =>
      _manifestSource != null ||
      _downloader != null ||
      _manifestOverride != null ||
      _builtinManifestOverride != null ||
      _supportDirOverride != null ||
      _isLoadedOverride != null ||
      _mountOverride != null ||
      _builtinSoPathOverride != null ||
      _probeOverride != null ||
      _rollbackOverride != null ||
      _downloadOverride != null ||
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

  /// 下载目录候选 `.so` 文件名解析（版本段）。`libgstore_mod_<name>.so`
  /// （无版本，视为 0.0.0）与 `libgstore_mod_<name>_<major.minor.patch>.so`；
  /// 不匹配 / 版本非法 → null（调用方跳过，绝不用 mtime 猜测）。
  List<int>? _candidateVersion(String base, String name) {
    if (base == 'libgstore_mod_$name.so') return const [0, 0, 0];
    final prefix = 'libgstore_mod_${name}_';
    if (!base.startsWith(prefix) || !base.endsWith('.so')) return null;
    final core = base.substring(prefix.length, base.length - 3);
    final sanitized = _sanitizeVersion(core);
    if (sanitized == null) return null;
    return _parseVersion(sanitized);
  }

  /// 「已下载」以**目录位置**判定（`<support>/gstore_modules/<name>/`）。
  Future<bool> _hasDownloadedArtifact(String name) async {
    final dir = await _moduleDir(name);
    try {
      if (!await Directory(dir).exists()) return false;
      for (final entity in Directory(dir).listSync()) {
        if (entity is! File) continue;
        if (_candidateVersion(p.basename(entity.path), name) != null) {
          return true;
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// 内置产物/声明是否存在（内置清单声明 = 随包发布）。
  Future<bool> _hasBuiltin(String name) async {
    if (await _builtinVersion(name) != null) return true;
    final path = await _builtinSoPath(name);
    return path != null && File(path).existsSync();
  }

  /// 选择最高三段 semver 的**有效**已下载产物（**先过滤、后排序**）。
  ///
  /// 过滤条件（须全部满足）：位于下载目录、版本段可解析、未被隔离、
  /// `.meta` 合法且 `.meta.sha256` 与字节复核通过。这样「最高版本无效」
  /// 时仍会命中有效低版本，而不会因排序选到无效文件后放弃。
  Future<String?> _resolveLocalSo(String name) async {
    final dir = await _moduleDir(name);
    final quarantined = await _readQuarantineKeys(name);

    final valid = <({String path, List<int> version})>[];
    try {
      for (final entity in Directory(dir).listSync()) {
        if (entity is! File) continue;
        final base = p.basename(entity.path);
        final version = _candidateVersion(base, name);
        if (version == null) continue;
        if (quarantined.contains(base) ||
            quarantined.contains(_renderVersion(version))) {
          appLog.warning('RustModuleLoader: $name 已隔离版本被跳过（$base）');
          continue;
        }
        if (!await _verifyMeta(name, entity.path)) continue;
        valid.add((path: entity.path, version: version));
      }
    } catch (_) {
      // 目录不存在/不可读 → 视为无本地产物
      return null;
    }

    if (valid.isEmpty) return null;
    valid.sort((a, b) => _compareVersionLists(b.version, a.version));
    return valid.first.path;
  }

  /// 确保模块就绪（**同步路径零网络**）：
  /// 已挂载 → 已下载有效产物（最高三段 semver）→ 内置解压
  /// → 仅当两者皆无时做一次有界远程下载安装并挂载 → 否则 false。
  Future<bool> ensureModule(String name) async {
    // Phase 2 迁移（启动恰好一次，`requireSignature=false` 时零副作用）：
    // **必须**先于本地产物解析完成——宿主 `trust.rs` 会把「无 `.sig`」的模块
    // 当作内置（随包信任）直接放行，若放任 Phase 1 无签名下载产物参与解析，
    // 它们会被当作内置模块挂载。
    await _migrateSignaturesOnce();

    // 已挂载 → 直接可用（零网络）。
    if (await _isLoaded(name)) return true;

    // 启动清理：删除下载目录中上次中断遗留的 `.tmp`（恰好一次）。
    await _cleanupTempOnce();

    // 1. 已下载产物优先：先过滤（目录/.meta/未隔离/sha256 复核）再取最高三段 semver。
    final localSo = await _resolveLocalSo(name);
    if (localSo != null && await File(localSo).exists()) {
      if (await _mountLocal(name, localSo)) return true;
      // 挂载/握手失败 → `_mountLocal` 已写 quarantine；继续回退内置。
    }

    // 2. 内置（必要时 Kotlin `extractModule` 解压）→ 挂载。
    final builtinSo = await _builtinSoPath(name);
    final builtinSoExists = builtinSo != null && File(builtinSo).existsSync();
    if (builtinSoExists) {
      appLog.info('RustModuleLoader: $name 命中内置模块 $builtinSo');
      if (await _mountLocal(name, builtinSo)) return true;
    }

    // 3. 仅当既无内置也无已下载产物时，才做一次有界远程下载安装并挂载。
    final hasBuiltin = builtinSoExists || await _builtinVersion(name) != null;
    final hasDownloaded = await _hasDownloadedArtifact(name);
    if (hasBuiltin || hasDownloaded) {
      appLog.info('RustModuleLoader: $name 本地产物不可用，走降级');
      return false;
    }
    // `download` 内核不得经本路径自举（存在本地/内置后可由后台更新）。
    if (name == _downloadModuleName) {
      appLog.info('RustModuleLoader: $name 禁止自举下载，走降级');
      return false;
    }
    final remote = remoteBaseUrl;
    final source = _manifestSource;
    if ((remote == null || remote.isEmpty) &&
        source is! ModuleManifestClient) {
      appLog.info('RustModuleLoader: $name 未配置远程源，模块不可用（走降级）');
      return false;
    }
    return _downloadAndInstall(name, mount: true);
  }

  /// 模块是否可用（**不加载、不解压**）：内置恒为 true；已下载则要求
  /// `.meta` 合法、sha256 复核通过且未被隔离。
  Future<bool> isAvailable(String name) async {
    // Android：平台内置探测优先（真实 .so 存在；保留既有通道契约）。
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        const channel = MethodChannel('gstore/apk_source');
        final has = await channel.invokeMethod<bool>(
          'hasModule',
          {'module': name, 'abi': await deviceAbi()},
        );
        if (has == true) return true;
      } catch (_) {
        // 平台不支持则退化为清单/本地文件判定
      }
    }
    // 已下载有效产物（fail-closed）。
    if ((await _resolveLocalSo(name)) != null) return true;
    // 内置随包发布：清单声明即视为可用。
    if (await _builtinVersion(name) != null) return true;
    return false;
  }

  /// 探测模块状态（**不加载、不下载**）：内置恒为 true 来源；否则已下载
  /// （有效 `.meta`/sha256 复核/未隔离）→ 远程可更新 → none。
  ///
  /// 与解析顺序语义一致：先过滤（目录/`.meta`/未隔离/sha256 复核）再取有效项；
  /// **quarantine-aware**——下载目录存在产物但无有效项（被隔离或 `.meta`/哈希
  /// 校验失败）时，**绝不**把它展示为可下载的远程源，而是视为不可用。
  ///
  /// [withRemote] 为 true 时额外解析远端清单的可用版本（可解析时），供管理页
  /// 展示「下载 / 更新」。远端不可解析/未配置来源时静默为 null，绝不抛异常。
  Future<RustModuleStatus> probe(String name, {bool withRemote = false}) async {
    // 测试接缝：整体覆盖（无 FFI/网络）。
    final probeOverride = _probeOverride;
    if (probeOverride != null) return probeOverride(name);

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
    String? version;
    var hasDownloaded = false;
    var quarantined = false;
    String? remoteVersion;
    try {
      final local = await _resolveLocalSo(name);
      hasDownloaded = await _hasDownloadedArtifact(name);

      if (local != null) {
        source = 'downloaded';
        soPath = local;
        final meta = await _readMetaMap(local);
        final metaVersion = meta?['version'];
        version = metaVersion is String && metaVersion.isNotEmpty
            ? metaVersion
            : await _localVersion(name);
      } else {
        final builtinVersion = await _builtinVersion(name);
        if (builtinVersion != null) {
          source = 'builtin';
          version = builtinVersion;
        } else {
          final builtin = await _builtinSoPathReadOnly(name);
          if (builtin != null && File(builtin).existsSync()) {
            source = 'builtin';
            soPath = builtin;
          }
        }
      }

      // 下载目录存在产物但无有效项（隔离/无效）→ 不得当作可用下载源。
      final downloadedBlocked = hasDownloaded && local == null;
      if (downloadedBlocked) {
        final keys = await _readQuarantineKeys(name);
        quarantined = keys.isNotEmpty;
      }

      // 无有效本地产物且未被下载态阻塞时，才可能展示为「可远程」。
      if (source == 'none' && !downloadedBlocked) {
        if ((remoteBaseUrl ?? '').isNotEmpty ||
            _manifestSource != null ||
            _manifestOverride != null) {
          source = 'remote';
        }
      }

      // 3) 远端可用版本（可解析时）；隔离/无效下载态不展示为可下载。
      if (withRemote && !downloadedBlocked) {
        final entry = await _remoteManifestEntry(name);
        final remote = entry?.version;
        if (remote != null && remote.isNotEmpty) {
          remoteVersion = remote;
        }
      }
    } catch (_) {
      // 平台不可用 → 保持 none
    }

    // 有更新：远端版本高于当前可用基线（本地有效版本或内置版本）。
    final baseline = version;
    final updateAvailable = remoteVersion != null &&
        baseline != null &&
        baseline.isNotEmpty &&
        _compareVersions(remoteVersion, baseline) > 0;

    return RustModuleStatus(
      name: name,
      exists: source != 'none',
      source: source,
      soPath: soPath,
      version: version,
      loaded: loaded,
      loadedVersion: loadedVersion,
      remoteVersion: remoteVersion,
      updateAvailable: updateAvailable,
      quarantined: quarantined,
      hasDownloaded: hasDownloaded,
    );
  }

  /// 后台更新：**只下载 + 安装，绝不挂载**（下次启动生效）。
  ///
  /// 触发条件：无有效本地产物，**或**远端版本更高，**或**版本相同但清单
  /// sha256 与本地 `.meta.sha256` 不同。完成后失效 [_manifestCache]。
  /// 返回 true 表示完成了一次安装。
  Future<bool> downloadAndInstall(String name) async {
    if (!_bgInFlight.add(name)) return false;
    try {
      // 测试接缝：注入下载结果（无网络/FFI）。
      final override = _downloadOverride;
      if (override != null) return override(name);

      // `download` 内核仅在已存在本地/内置产物后允许后台更新（禁止自举）。
      if (name == _downloadModuleName && !await _hasLocalOrBuiltin(name)) {
        return false;
      }
      final target = await _remoteTarget(name, forceRefresh: true);
      if (target == null) return false;

      // 基线：本地 `.meta` 优先；无已下载产物时用内置版本（远程 vs 内置比较）。
      final localMeta = await _localMetaInfo(name);
      final baselineVersion =
          localMeta?.version ?? await _builtinVersion(name);
      final needed = baselineVersion == null ||
          _compareVersions(target.version, baselineVersion) > 0 ||
          (localMeta != null &&
              _compareVersions(target.version, localMeta.version) == 0 &&
              target.sha256.toLowerCase() != localMeta.sha256.toLowerCase());
      if (!needed) return false;

      final ok = await _downloadAndInstall(name, mount: false, target: target);
      // 后台刷新后失效清单缓存：下次解析/展示拿到最新清单。
      _manifestCache = null;
      return ok;
    } catch (e) {
      appLog.warning('RustModuleLoader: $name 后台更新失败 - $e');
      return false;
    } finally {
      _bgInFlight.remove(name);
    }
  }

  /// 回退内置：删除全部已下载产物（含隔离标记）后尝试挂载内置模块。
  Future<bool> rollbackToBuiltin(String name) async {
    // 测试接缝：注入回退结果（无 FFI）。生产路径未配置时行为不变。
    final override = _rollbackOverride;
    if (override != null) return override(name);

    await clearDownloadedModule(name);
    final builtinSo = await _builtinSoPath(name);
    if (builtinSo != null && File(builtinSo).existsSync()) {
      return _mountLocal(name, builtinSo);
    }
    return false;
  }

  /// 清除某模块的全部已下载产物（`.so`/`.meta`/`.sig`/`quarantine.json`）。
  Future<void> clearDownloadedModule(String name) async {
    try {
      final dir = Directory(await _moduleDir(name));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      appLog.warning('RustModuleLoader: 清除 $name 已下载产物失败 - $e');
    }
  }

  Future<bool> _hasLocalOrBuiltin(String name) async {
    if (await _hasBuiltin(name)) return true;
    return _hasDownloadedArtifact(name);
  }

  /// 本地有效产物记录的版本 + `.meta.sha256`（无有效产物 → null）。
  Future<({String version, String sha256})?> _localMetaInfo(String name) async {
    final soPath = await _resolveLocalSo(name);
    if (soPath == null) return null;
    final meta = await _readMetaMap(soPath);
    if (meta == null) return null;
    final version = meta['version'];
    final sha = meta['sha256'];
    if (version is! String || version.isEmpty) return null;
    if (sha is! String || sha.isEmpty) return null;
    return (version: version, sha256: sha);
  }

  /// 解析远端安装目标（URL + sha256 + 真实版本 + 可选签名）。
  ///
  /// 生产优先经 Todo 8 [ModuleManifestClient]（真实 Release
  /// `browser_download_url`）；测试/旧路径回退 `remoteBaseUrl` 拼接。
  Future<_RemoteTarget?> _remoteTarget(
    String name, {
    bool forceRefresh = false,
  }) async {
    final source = _manifestSource;
    if (source is ModuleManifestClient) {
      final loc = await source.locateModuleAsset(
        name,
        forceRefresh: forceRefresh,
      );
      if (loc != null) {
        return _RemoteTarget(
          url: loc.url,
          sha256: loc.sha256,
          version: loc.version,
          signature: null,
        );
      }
    }
    final base = remoteBaseUrl;
    if (base == null || base.isEmpty) return null;
    final entry = await _remoteManifestEntry(name, forceRefresh: forceRefresh);
    if (entry == null || entry.version.isEmpty) return null;
    final abi = await deviceAbi();
    final abiAsset = entry.forAbi(abi);
    if (abiAsset == null) return null;
    return _RemoteTarget(
      url: '$base/$abi/${abiAsset.asset}',
      sha256: abiAsset.sha256,
      version: entry.version,
      signature: abiAsset.signature,
    );
  }


  /// 拉取并缓存远端清单（强类型 v2）；旧 schema 显式拒绝并安全降级为 null。
  ///
  /// [forceRefresh] 为 true 时先失效内存缓存，并请求来源强制刷新（后台更新用）。
  Future<ModuleManifestV2?> _remoteManifest({bool forceRefresh = false}) async {
    if (forceRefresh) {
      _manifestCache = null;
    } else {
      final cached = _manifestCache;
      if (cached != null) return cached;
    }

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
        final loaded = await source.load(forceRefresh: forceRefresh);
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
  Future<ModuleEntryV2?> _remoteManifestEntry(
    String name, {
    bool forceRefresh = false,
  }) async {
    final manifest = await _remoteManifest(forceRefresh: forceRefresh);
    return manifest?.entry(name);
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
    final override = _builtinSoPathOverride;
    if (override != null) return override(name);
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

  /// 下载 → SHA-256 校验 → **原子配对安装**（`.tmp` → `.so` → `.meta`）；
  /// [mount] 为 true 时安装后挂载，false 时（后台更新）**绝不挂载**。
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
  Future<bool> _downloadAndInstall(
    String name, {
    required bool mount,
    _RemoteTarget? target,
  }) async {
    try {
      final resolved = target ?? await _remoteTarget(name);
      if (resolved == null || resolved.version.isEmpty) {
        appLog.error('RustModuleLoader: $name 清单缺少当前 ABI 资产/版本，拒绝安装');
        return false;
      }

      // 签名开关：仅 true 时要求清单提供非空 signature（fail-closed）。
      final signature = resolved.signature;
      if (requireSignature && (signature == null || signature.isEmpty)) {
        appLog.error(
            'RustModuleLoader: $name requireSignature=true 但清单缺少 signature，拒绝安装');
        return false;
      }

      // 本地文件名恒为三段纯数字版本（剥离 +build / 预发布）。
      final sanitizedVersion = _sanitizeVersion(resolved.version);
      if (sanitizedVersion == null) {
        appLog.error(
            'RustModuleLoader: $name 版本号非法（${resolved.version}），拒绝安装');
        return false;
      }
      final dir = await _moduleDir(name);
      await Directory(dir).create(recursive: true);

      final finalSo = File(p.join(dir, 'libgstore_mod_${name}_$sanitizedVersion.so'));
      final metaFile = File('${finalSo.path}.meta');
      final sigFile = File('${finalSo.path}.sig');
      final tmpFile = File('${finalSo.path}.tmp');

      // 1. 下载到 `<finalSo>.tmp`（注入下载器优先；测试无网络）。
      appLog.info('RustModuleLoader: 下载模块 $name <- ${resolved.url}');
      final resp = await _fetchBytes(resolved.url);
      if (resp == null) {
        appLog.warning('RustModuleLoader: $name 下载失败');
        await _deleteQuietly(tmpFile);
        return false;
      }
      await tmpFile.writeAsBytes(resp, flush: true);

      // 2. 校验清单 SHA-256：不符 → 删除 `.tmp`，无最终 `.so`/`.meta`。
      final actual = _sha256Hex(resp);
      if (actual != resolved.sha256.toLowerCase()) {
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
        'version': resolved.version,
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
      await _writeLocalVersion(name, resolved.version);

      // 清理本次可能产生的 `.meta.tmp`/`.sig.tmp` 残留。
      await _deleteQuietly(File('${metaFile.path}.tmp'));
      await _deleteQuietly(File('${sigFile.path}.tmp'));

      if (!mount) {
        // 后台路径：只安装，绝不挂载（下次启动生效）。
        return true;
      }
      return _mountLocal(name, finalSo.path);
    } catch (e) {
      appLog.error('RustModuleLoader: $name 下载/安装失败 - $e');
      return false;
    }
  }

  /// 宿主 dlopen 挂载本地 .so。
  ///
  /// 挂载/握手失败时写 `<moduleDir>/quarantine.json`（解析期跳过该版本）。
  Future<bool> _mountLocal(String name, String soPath) async {
    // `.sig` 卫生（单点）：`requireSignature=false` 时，**任何**本地 .so 挂载前
    // 都必须删除同名遗留 `.sig`。宿主 `trust.rs` 在未钉死公钥（Phase 1
    // `MODULE_SIGNING_PUBKEY_HEX=""`）下会拒绝带 `.sig` 的模块
    // （"module is signed but no pinned public key is configured"）。
    // `requireSignature=true` 时保留真实签名（Phase 2 迁移由 Todo 6 负责）。
    if (!requireSignature) {
      await _deleteQuietly(File('$soPath.sig'));
    }

    // 测试接缝：注入挂载覆盖时完全绕过真实 FFI。
    final override = _mountOverride;
    if (override != null) {
      try {
        final ok = await override(soPath);
        if (!ok) await _recordQuarantine(name, soPath, 'mount_override_false');
        return ok;
      } catch (e) {
        appLog.error('RustModuleLoader: $name 注入挂载失败 - $e');
        await _recordQuarantine(name, soPath, 'mount_override_error');
        return false;
      }
    }
    try {
      await RustModuleManager.instance.ensureReady();
      final handle = await RustModuleManager.instance.mountFromSo(soPath);
      if (handle == null) {
        await _recordQuarantine(name, soPath, 'mount_failed');
        return false;
      }
      return true;
    } catch (e) {
      appLog.error('RustModuleLoader: $name 挂载失败 - $e');
      await _recordQuarantine(name, soPath, 'mount_error');
      return false;
    }
  }

  /// 读取 `<soPath>.meta` 为 Map（缺失/非法 → null）。
  Future<Map<String, dynamic>?> _readMetaMap(String soPath) async {
    try {
      final metaFile = File('$soPath.meta');
      if (!await metaFile.exists()) return null;
      final decoded = jsonDecode(await metaFile.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 复核 `<soPath>.meta`：存在、name 匹配、sha256 与 `.so` 字节一致。
  Future<bool> _verifyMeta(String name, String soPath) async {
    try {
      final decoded = await _readMetaMap(soPath);
      if (decoded == null) {
        appLog.warning('RustModuleLoader: $name 本地产物缺少/非法 .meta，拒绝挂载 ($soPath)');
        return false;
      }
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

  /// 内置清单（`assets/app/modules_builtin.json`，随包发布；读一次缓存）。
  Future<Map<String, dynamic>?> _builtinManifest() async {
    final cached = _builtinManifestCache;
    if (cached != null) return cached;
    final override = _builtinManifestOverride;
    if (override != null) {
      _builtinManifestCache = override;
      return override;
    }
    try {
      final raw =
          await rootBundle.loadString('assets/app/modules_builtin.json');
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _builtinManifestCache = decoded;
        return decoded;
      }
    } catch (e) {
      appLog.warning('RustModuleLoader: 读取内置清单失败 - $e');
    }
    return null;
  }

  /// 内置清单声明的模块版本（未声明 → null）。
  Future<String?> _builtinVersion(String name) async {
    final manifest = await _builtinManifest();
    final entry = manifest?[name];
    if (entry is Map) {
      final v = entry['version'];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  /// 写 `<moduleDir>/quarantine.json`（合并已有条目）：挂载/握手失败后
  /// 该版本在解析期被跳过。仅对下载目录内的产物生效（内置不回退隔离）。
  Future<void> _recordQuarantine(
    String name,
    String soPath,
    String reason,
  ) async {
    try {
      final dir = await _moduleDir(name);
      if (p.dirname(soPath) != dir) return; // 仅下载产物
      final base = p.basename(soPath);
      final version = _renderVersion(
        _candidateVersion(base, name) ?? const [0, 0, 0],
      );
      final file = File(p.join(dir, 'quarantine.json'));
      final existing = await _readQuarantineRaw(Directory(dir));
      existing[version] = <String, dynamic>{
        'version': version,
        'file': base,
        'reason': reason,
        'at': DateTime.now().toIso8601String(),
      };
      await file.writeAsString(jsonEncode(existing), flush: true);
      appLog.warning('RustModuleLoader: $name 版本 $version 已隔离（$reason）');
    } catch (e) {
      appLog.warning('RustModuleLoader: 写 $name quarantine 失败 - $e');
    }
  }

  Future<Map<String, dynamic>> _readQuarantineRaw(Directory dir) async {
    try {
      final file = File(p.join(dir.path, 'quarantine.json'));
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 读取隔离键集合（版本号与 `.so` 文件名，任一命中即跳过）。
  /// 兼容多种形态，损坏/缺失 → 空集合（绝不因隔离文件损坏而拒挂全部）。
  Future<Set<String>> _readQuarantineKeys(String name) async {
    try {
      final dir = Directory(await _moduleDir(name));
      final decoded = await _readQuarantineRaw(dir);
      final keys = <String>{};
      void addEntry(Object? item) {
        if (item is String && item.isNotEmpty) keys.add(item);
        if (item is Map) {
          final v = item['version'];
          if (v is String && v.isNotEmpty) keys.add(v);
          final f = item['file'];
          if (f is String && f.isNotEmpty) keys.add(p.basename(f));
        }
      }

      for (final value in decoded.values) {
        addEntry(value);
      }
      for (final key in const ['quarantined', 'versions', 'version']) {
        final value = decoded[key];
        if (value is List) {
          value.forEach(addEntry);
        } else if (value is String) {
          keys.add(value);
        }
      }
      return keys;
    } catch (_) {
      return const {};
    }
  }

  /// Phase 2 迁移：清理 Phase 1 无签名下载产物（启动一次性）。
  ///
  /// 背景：宿主 `trust.rs` 将「无 `.sig`」的模块视为内置模块（随包信任）
  /// **直接放行**。因此启用签名前（[requireSignature] = true）必须把下载目录中
  /// 缺**有效** `.sig` 的产物隔离；否则 Phase 1 的无签名产物会被当作内置挂载
  /// （架构决策 ⑥）。
  ///
  /// 规则：
  /// * 仅扫描 `<support>/gstore_modules/<name>/` 下**带 `.meta`** 的 `.so`，
  ///   即 downloaded-module set（`.meta` 是远程安装的提交标记）。
  /// * `.sig` 缺失/空白/非 128 位十六进制 → 写 `<moduleDir>/quarantine.json`
  ///   标记隔离（复用 Todo 5 机制），下次解析跳过并回退内置或重新下载。
  /// * **不删除**任何产物；内置解压产物无 `.meta`，不在扫描集合，绝不触碰。
  /// * `download` 模块遵循同一规则（其远程更新在存在本地/内置后允许）。
  ///
  /// `requireSignature == false` → 立即返回，**零副作用**（不扫描、不写、不删）。
  /// 方法本身幂等：已隔离条目重复调用时跳过，不会重复写入或损坏 `quarantine.json`。
  /// 返回本次**新增**隔离的条目数。
  Future<int> migrateUnsignedDownloadedModules() async {
    if (!requireSignature) return 0;

    var migrated = 0;
    try {
      final root = Directory(p.join(await _supportDir(), 'gstore_modules'));
      if (!await root.exists()) return 0;

      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = p.basename(entity.path);
        if (name.isEmpty) continue;

        List<FileSystemEntity> entries;
        try {
          entries = entity.listSync();
        } catch (_) {
          continue; // 目录不可读 → 跳过，绝不因单个目录失败中断迁移
        }
        final quarantined = await _readQuarantineKeys(name);

        for (final f in entries) {
          if (f is! File) continue;
          final base = p.basename(f.path);
          // 仅识别「本地落盘命名的模块 .so」；`.meta/.sig/.tmp/version` → null。
          final version = _candidateVersion(base, name);
          if (version == null) continue;
          // downloaded-module set 判定：带 `.meta`（内置解压产物无 `.meta`）。
          if (!await File('${f.path}.meta').exists()) continue;

          final versionStr = _renderVersion(version);
          if (quarantined.contains(base) ||
              quarantined.contains(versionStr)) {
            continue; // 幂等：已隔离不重复迁移
          }
          if (await _hasValidSignature(f.path)) continue;

          await _recordQuarantine(name, f.path, 'unsigned_migration');
          migrated++;
        }
      }
    } catch (e) {
      appLog.warning('RustModuleLoader: 无签名下载产物迁移失败 - $e');
    }
    return migrated;
  }

  /// 启动一次性包装：仅 [requireSignature] = true 时加锁执行迁移。
  ///
  /// `requireSignature=false` 时**不设锁**——保持零副作用语义，并允许进程内
  /// 稍后开启签名时仍能迁移一次。
  Future<void> _migrateSignaturesOnce() async {
    if (_signatureMigrationDone || !requireSignature) return;
    _signatureMigrationDone = true;
    await migrateUnsignedDownloadedModules();
  }

  /// `.sig` 是否为**有效** Ed25519 侧车：存在且去空白后为 128 位十六进制。
  ///
  /// Dart 侧不持有钉死公钥（密码学校验由 Rust 信任门完成），故此处做结构校验；
  /// 缺失/空白/畸形一律视为无签名，交由迁移隔离（fail-closed）。
  Future<bool> _hasValidSignature(String soPath) async {
    try {
      final sig = File('$soPath.sig');
      if (!await sig.exists()) return false;
      final content = (await sig.readAsString()).trim();
      if (content.length != 128) return false;
      return RegExp(r'^[0-9a-fA-F]{128}$').hasMatch(content);
    } catch (_) {
      return false;
    }
  }

  String _renderVersion(List<int> v) => '${v[0]}.${v[1]}.${v[2]}';

  int _compareVersionLists(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
  }

  /// 模块私有目录基址（<support> 根）。
  ///
  /// 统一下载目录与缓存于 `getApplicationSupportDirectory()/gstore_modules/**`
  /// （自 `getApplicationDocumentsDirectory()` 迁移）；测试经 [debugConfigure] 覆盖。
  Future<String> _supportDir() async {
    final override = _supportDirOverride;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    return support.path;
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

/// 远端安装目标：URL + 清单 sha256 + 真实版本 + 可选签名（Phase 2）。
class _RemoteTarget {
  final String url;
  final String sha256;
  final String version;
  final String? signature;

  const _RemoteTarget({
    required this.url,
    required this.sha256,
    required this.version,
    this.signature,
  });
}

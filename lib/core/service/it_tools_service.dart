import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/rust/ModuleDownloader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';
import 'package:gstore/core/rust/ModuleManifestClient.dart';

/// IT Tools 离线包的落地、远端更新与解压。
///
/// 离线包以 zip 形式随宿主资产分发（`assets/it_tools/it-tools.zip`），
/// 也可独立于 APK 从 `sunO2/GStore` 的 Release 更新（`it_tools.json` +
/// `it-tools.zip`，经 [ModuleManifestClient] 的**未代理、校验证书**通道解析）。
///
/// 落地目录布局（均位于应用私有文档目录下）：
///
/// ```
/// it_tools/       当前使用中的目录（内含 .it_tools_marker）
/// it_tools.new/   解压中的暂存目录（成功后原子换名为 it_tools）
/// it_tools.prev/  上一份可用目录（回滚来源）
/// ```
///
/// 标记文件 `<目录>/.it_tools_marker` 记录 `{contentHash, source}`：
/// `contentHash` 为 zip 字节的 SHA-256，`source` 为 `remote` / `asset`。
/// **绝不再用应用版本号做标记**——离线包内容变更由内容哈希自然区分。
///
/// 更新流程（[updateFromRemote]）：解析远端 `it_tools.json` → 用 Todo 3 的
/// 内部下载器取 zip → 校验 `size` + `contentHash` → 解压到 `it_tools.new` →
/// 原子换名（旧目录保留为 `it_tools.prev`，`.new` 提升为当前）→ 写标记。
/// 任何失败都不触碰当前目录与标记（fail-closed）。
///
/// 回退链（[ensureExtracted]）：当前目录 → `it_tools.prev`（上次可用远端）→
/// 随包资产（`source=asset`）。远端更新始终在后台/按需进行，绝不在
/// `ensureExtracted` 的同步返回路径上阻塞。
///
/// `file://` + ES module 的真机白屏兜底（改用 `InAppLocalhostServer` 托管）
/// 详见 `document/development/12-开发者工具箱-IT-Tools离线内嵌.md` §8；
/// 该条件分支不在本服务的默认路径内。
class ItToolsService {
  ItToolsService._();

  /// 宿主资产中的离线包（由 it-tools 仓库的 `pnpm build:embed` 产出）
  static const String assetZipPath = 'assets/it_tools/it-tools.zip';

  /// 离线包入口文件
  static const String entryFile = 'index.html';

  /// 解压目标目录名（位于应用私有文档目录下）
  static const String _dirName = 'it_tools';

  /// 解压暂存目录名：成功后原子换名为当前目录
  static const String stagingDirName = 'it_tools.new';

  /// 上一份可用目录名：原子换名前，旧当前目录改名到此，作为回滚来源
  static const String previousDirName = 'it_tools.prev';

  /// 标记文件名（位于目录内部），内容为 `{contentHash, source}`。
  ///
  /// **不是**应用版本号：离线包变更由 zip 内容哈希区分。
  static const String markerFileName = '.it_tools_marker';

  /// 清理时的临时后缀：先把目录同步换名为 `<dir>.trash` 再异步递归删除，
  /// 使「摘除活动目录」成为无 await 的原子操作。
  static const String _trashSuffix = '.trash';

  /// 标记 `source`：来自 Release 的远端包
  static const String sourceRemote = 'remote';

  /// 标记 `source`：随包资产
  static const String sourceAsset = 'asset';

  /// SHA-256 十六进制小写格式校验
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  /// 在途远端更新（并发去重：同一时刻只跑一次）
  static Future<ItToolsUpdateResult>? _inFlight;

  /// 当前正在使用离线包的页面/WebView 数量（存活保护）。
  ///
  /// 页面进入时 [beginUse]，退出时 [endUse]；可重入。大于 0 时
  /// [clearExtracted] 拒绝删除当前目录，改为延迟到最后一个使用者释放后执行。
  static int _activeUsers = 0;

  /// 存活期间收到的清理请求（延迟到最后一个使用者释放后兑现）。
  static bool _cleanupPending = false;

  // ---------------------------------------------------------------------------
  // 对外主入口
  // ---------------------------------------------------------------------------

  /// 确保离线包已落地到本地，返回**当前使用目录**。
  ///
  /// 同步返回路径**不联网**：优先复用当前目录；当前不可用时回滚
  /// `it_tools.prev`；仍无则解压随包资产。远端更新在后台进行
  /// （用 [debugDisableAutoUpdate] 可在测试中关闭）。
  static Future<Directory> ensureExtracted() async {
    final docs = await _docsDir();
    final current = Directory(p.join(docs.path, _dirName));

    // 1) 当前目录可用 → 直接使用
    if (await _isUsable(current)) {
      _scheduleBackgroundUpdate();
      return current;
    }

    // 2) 当前不可用，但上一份可用远端存在 → 回滚（保留随包兜底为最后手段）
    final prev = Directory(p.join(docs.path, previousDirName));
    if (await _isUsable(prev)) {
      try {
        await _promotePrevious(prev, current);
        debugPrint('ItToolsService: 已回滚到上一份可用离线包 ${current.path}');
        _scheduleBackgroundUpdate();
        return current;
      } catch (e) {
        debugPrint('ItToolsService: 回滚上一份离线包失败 - $e');
      }
    }

    // 3) 随包资产兜底
    await _installAsset(current);
    _scheduleBackgroundUpdate();
    return current;
  }

  /// 按需触发一次远端更新。返回结构化结果，**绝不抛异常**。
  ///
  /// [forceRefresh] 为 true 时忽略「已是最新」判断强制重新下载。并发调用
  /// 共享同一个 Future，不会重复请求。
  static Future<ItToolsUpdateResult> updateFromRemote({
    bool forceRefresh = false,
  }) {
    final existing = _inFlight;
    if (existing != null) return existing;

    final future = _updateFromRemote(forceRefresh: forceRefresh)
        .whenComplete(() => _inFlight = null);
    _inFlight = future;
    return future;
  }

  /// 把 zip 字节解压到 [targetDir]。
  ///
  /// 公开以便单测直接调用（`compute` 需要顶层函数，见 [_extractZipTo]）。
  @visibleForTesting
  static Future<void> extractTo(Uint8List bytes, String targetDir) async {
    final archive = ZipDecoder().decodeBytes(bytes);

    for (final entry in archive.files) {
      if (!entry.isFile) continue;

      // zip-slip 防护：拒绝绝对路径与跳出目标目录的条目
      final normalized = p.normalize(entry.name.replaceAll('\\', '/'));
      if (p.isAbsolute(normalized) || normalized.startsWith('..')) {
        debugPrint('ItToolsService: 跳过可疑条目 ${entry.name}');
        continue;
      }

      final target = File(p.join(targetDir, normalized));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(entry.content as List<int>);
    }
  }

  /// 解压目标目录（不保证已存在）。
  ///
  /// 供「缓存管理」等外部方统计占用 / 清理复用，避免离线包路径散落多处。
  static Future<Directory> extractedDir() => _targetDir();

  /// 服务管理的全部落地目录：当前目录 + `.prev`（回滚来源）+ `.new`（暂存）。
  ///
  /// 「缓存管理」统计占用与清理都以此为唯一事实来源，避免离线包路径散落
  /// 多处后出现漏统计 / 漏清理。
  static Future<List<Directory>> managedDirs() async => [
        await _targetDir(),
        await _previousDir(),
        await _stagingDir(),
      ];

  /// 标记「离线包正在被使用」。页面/WebView 存活期间调用；可重入，
  /// 与 [endUse] 成对出现。
  static void beginUse() {
    _activeUsers++;
  }

  /// 释放一次使用（可重入）。当计数归零且期间收到过清理请求时，兑现延迟清理。
  ///
  /// 若兑现期间又有新页面进入（[beginUse]），[clearManagedDirs] 会**重新延迟**，
  /// 绝不删除新页面正在使用的目录。**绝不抛异常**：延迟清理失败只记录日志，
  /// 避免页面退出路径被文件 IO 打断。
  static Future<void> endUse() async {
    if (_activeUsers > 0) _activeUsers--;
    if (_activeUsers > 0 || !_cleanupPending) return;
    try {
      await clearManagedDirs();
    } catch (e) {
      debugPrint('ItToolsService: 延迟清理失败 - $e');
    }
  }

  /// 当前是否有页面/WebView 正在使用离线包。
  static bool get isInUse => _activeUsers > 0;

  /// 当前目录的标记（不可解析/不存在 → null）。
  @visibleForTesting
  static Future<ItToolsMarker?> readCurrentMarker() async =>
      _readMarker(await _targetDir());

  /// 清理已落地的离线资源（当前目录 + `.prev` + `.new`，连同标记一起删）。
  ///
  /// 清理后 [ensureExtracted] 找不到可用目录，下次进入页面会重新从资产解压。
  /// 返回是否真的删除了内容（三者都不存在或清理被延迟时为 false）。
  ///
  /// **存活保护**：当 [isInUse] 为 true 时，正在使用的当前目录**绝不删除**，
  /// 本次清理被延迟；待 [endUse] 使计数归零后自动兑现。
  ///
  /// 需要区分「延迟」与「本就为空」的调用方请用 [clearManagedDirs]。
  static Future<bool> clearExtracted() async =>
      (await clearManagedDirs()) == ItToolsClearOutcome.cleared;

  /// 与 [clearExtracted] 相同的唯一清理实现，但返回可区分的结果：
  /// [ItToolsClearOutcome.cleared] / [ItToolsClearOutcome.empty] /
  /// [ItToolsClearOutcome.deferred]（使用中，已延迟）。
  ///
  /// **竞态安全**：检查存活与「换名摘除」活动目录构成一段**无 await 的同步
  /// 临界区**。解析目录（可能有 await）后立即重新校验 [isInUse]；一旦有页面
  /// 进入就把待清理重新挂起并如实返回 [ItToolsClearOutcome.deferred]。
  /// 目录先被同步换名为 `.trash`（与活动路径解耦），随后的递归删除只作用于
  /// trash，即使期间有新页面进入并重建当前目录也不会被误删。
  static Future<ItToolsClearOutcome> clearManagedDirs() async {
    if (isInUse) {
      _cleanupPending = true;
      debugPrint('ItToolsService: 离线包使用中，清理延迟到页面退出后执行');
      return ItToolsClearOutcome.deferred;
    }

    final dirs = await managedDirs();

    // 清理上一轮可能残留的 `.trash`（非活动目录，可在临界区外进行）。
    for (final dir in dirs) {
      final trash = Directory('${dir.path}$_trashSuffix');
      if (await trash.exists()) {
        try {
          await trash.delete(recursive: true);
        } catch (_) {
          // 残留清理失败不影响本次
        }
      }
    }

    // 测试注入的竞态窗口：在最终校验前允许模拟「新页面进入」。
    debugBeforeClearDelete?.call();

    // ===== 同步临界区（不得有任何 await） =====
    // 重新校验：解析目录期间可能有新页面进入；有则重新挂起，绝不摘除活动目录。
    if (isInUse) {
      _cleanupPending = true;
      debugPrint('ItToolsService: 离线包使用中，清理延迟到页面退出后执行');
      return ItToolsClearOutcome.deferred;
    }
    _cleanupPending = false;

    // 同步换名把活动目录摘除，避免「检查后删除」之间的竞态。
    final trashed = <Directory>[];
    for (final dir in dirs) {
      if (!dir.existsSync()) continue;
      final trash = Directory('${dir.path}$_trashSuffix');
      try {
        dir.renameSync(trash.path);
        trashed.add(trash);
      } catch (e) {
        debugPrint('ItToolsService: 清理换名失败 ${dir.path} - $e');
      }
    }
    // ===== 临界区结束 =====

    // 破坏性递归删除只针对已换名的 trash，不再触碰可能重建的当前目录。
    for (final trash in trashed) {
      try {
        await trash.delete(recursive: true);
      } catch (e) {
        debugPrint('ItToolsService: 清理残留失败 ${trash.path} - $e');
      }
    }

    if (trashed.isEmpty) return ItToolsClearOutcome.empty;
    debugPrint('ItToolsService: 已清理离线资源');
    return ItToolsClearOutcome.cleared;
  }

  // ---------------------------------------------------------------------------
  // 远端更新
  // ---------------------------------------------------------------------------

  static Future<ItToolsUpdateResult> _updateFromRemote({
    required bool forceRefresh,
  }) async {
    final staging = await _stagingDir();
    try {
      final remote = await _resolveRemote(forceRefresh: forceRefresh);
      if (remote == null) {
        return const ItToolsUpdateResult.offline();
      }

      final current = await _targetDir();
      if (!forceRefresh && await _matchesCurrent(current, remote)) {
        return ItToolsUpdateResult.upToDate(remote.contentHash);
      }

      final bytes = await _fetchRemote(remote);
      if (bytes == null) {
        return const ItToolsUpdateResult.failure('download-failed');
      }
      // 先校 size，再校 contentHash；任一不符都不得触碰当前目录/标记。
      if (bytes.length != remote.size) {
        return const ItToolsUpdateResult.failure('size-mismatch');
      }
      final actualHash = _sha256Hex(bytes);
      if (actualHash != remote.contentHash.toLowerCase()) {
        return const ItToolsUpdateResult.failure('hash-mismatch');
      }

      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      await staging.create(recursive: true);
      await compute(_extractZipTo, _ExtractRequest(bytes, staging.path));
      if (!await _isUsable(staging)) {
        return const ItToolsUpdateResult.failure('missing-entry');
      }

      // 原子换名：旧当前目录 → .prev，.new → 当前；随后写标记。
      await _swap(staging, current);
      await _writeMarker(
        current,
        ItToolsMarker(
          contentHash: remote.contentHash.toLowerCase(),
          source: sourceRemote,
        ),
      );
      debugPrint(
        'ItToolsService: 远端离线包已更新到 ${current.path} '
        '(${remote.contentHash.substring(0, 12)}…)',
      );
      return ItToolsUpdateResult.success(remote.contentHash.toLowerCase());
    } catch (e) {
      debugPrint('ItToolsService: 远端更新失败 - $e');
      return const ItToolsUpdateResult.failure('error');
    } finally {
      // 清理未被消费的 `.new`（成功时已被换名为当前目录）。
      try {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } catch (_) {
        // 清理失败不影响本次结果
      }
    }
  }

  /// 解析同 Release 的 `it_tools.json` 与 zip 资产 URL（未代理、校验证书）。
  static Future<ItToolsRemotePackage?> _resolveRemote({
    required bool forceRefresh,
  }) async {
    try {
      final client =
          (debugManifestClientFactory ?? ModuleManifestClient.new)();
      final location = await client.locateItToolsAsset(
        forceRefresh: forceRefresh,
      );
      if (location == null) return null;

      final hash = location.contentHash.toLowerCase();
      if (!_sha256Pattern.hasMatch(hash)) {
        debugPrint('ItToolsService: 远端 contentHash 非法，拒绝更新');
        return null;
      }
      if (location.size <= 0) {
        debugPrint('ItToolsService: 远端 size 非法，拒绝更新');
        return null;
      }
      return ItToolsRemotePackage(
        url: location.url,
        contentHash: hash,
        size: location.size,
      );
    } catch (e) {
      debugPrint('ItToolsService: 解析远端清单失败 - $e');
      return null;
    }
  }

  /// 用 Todo 3 的内部下载器取 zip 字节；失败 → null。
  static Future<Uint8List?> _fetchRemote(ItToolsRemotePackage remote) async {
    final fetcher = debugFetcher ?? ModuleDownloader();
    try {
      return await fetcher.fetch(remote.url, maxBytes: remote.size);
    } catch (e) {
      debugPrint('ItToolsService: 下载远端离线包失败 - $e');
      return null;
    }
  }

  /// 当前目录是否已是指定的远端内容（标记 + 入口均匹配）。
  static Future<bool> _matchesCurrent(
    Directory current,
    ItToolsRemotePackage remote,
  ) async {
    if (!await _isUsable(current)) return false;
    final marker = await _readMarker(current);
    if (marker == null) return false;
    return marker.source == sourceRemote &&
        marker.contentHash.toLowerCase() == remote.contentHash.toLowerCase();
  }

  // ---------------------------------------------------------------------------
  // 随包资产兜底
  // ---------------------------------------------------------------------------

  /// 解压随包资产到暂存目录，原子换名到 [current]，标记 `source=asset`。
  static Future<void> _installAsset(Directory current) async {
    final bytes = await (debugAssetLoader ?? _loadAssetBytes)();

    final staging = await _stagingDir();
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    await staging.create(recursive: true);

    var promoted = false;
    try {
      await compute(_extractZipTo, _ExtractRequest(bytes, staging.path));
      if (!await _isUsable(staging)) {
        throw StateError('随包离线包缺少 $entryFile');
      }
      await _swap(staging, current);
      promoted = true;
      await _writeMarker(
        current,
        ItToolsMarker(
          contentHash: _sha256Hex(bytes),
          source: sourceAsset,
        ),
      );
      debugPrint('ItToolsService: 已从随包资产解压到 ${current.path}');
    } finally {
      if (!promoted) {
        try {
          if (await staging.exists()) {
            await staging.delete(recursive: true);
          }
        } catch (_) {
          // 清理失败不影响本次结果
        }
      }
    }
  }

  static Future<Uint8List> _loadAssetBytes() async {
    final data = await rootBundle.load(assetZipPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  // ---------------------------------------------------------------------------
  // 原子换名 / 回滚 / 标记
  // ---------------------------------------------------------------------------

  /// `.new` → 当前：旧当前目录保留为 `.prev`（回滚来源）。
  ///
  /// 若换名到当前失败，尝试把刚移走的 `.prev` 换回当前，避免出现
  /// 「既无当前、又把上一份丢在 .prev」的半写态。
  static Future<void> _swap(Directory staging, Directory current) async {
    final prev = await _previousDir();
    if (await prev.exists()) {
      await prev.delete(recursive: true);
    }

    final hadCurrent = await current.exists();
    if (hadCurrent) {
      await current.rename(prev.path);
    }

    try {
      await staging.rename(current.path);
    } catch (_) {
      if (hadCurrent && await prev.exists()) {
        try {
          await prev.rename(current.path);
        } catch (_) {
          // 回滚失败只能上报，不再掩盖原始异常
        }
      }
      rethrow;
    }
  }

  /// `.prev` → 当前：把上次可用远端提升为当前（当前不可用时才调用）。
  ///
  /// 不可用的当前目录先改名为 `.new`（暂存位）再删除，随后 `.prev` 换名进来。
  static Future<void> _promotePrevious(
    Directory prev,
    Directory current,
  ) async {
    final scratch = await _stagingDir();
    if (await scratch.exists()) {
      await scratch.delete(recursive: true);
    }
    if (await current.exists()) {
      await current.rename(scratch.path);
    }
    await prev.rename(current.path);
    if (await scratch.exists()) {
      await scratch.delete(recursive: true);
    }
  }

  static Future<ItToolsMarker?> _readMarker(Directory dir) async {
    try {
      final file = File(p.join(dir.path, markerFileName));
      if (!await file.exists()) return null;
      return ItToolsMarker.tryFromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  /// 写标记（先写 `.tmp` 再换名，避免半写标记）。
  static Future<void> _writeMarker(
    Directory dir,
    ItToolsMarker marker,
  ) async {
    final tmp = File(p.join(dir.path, '$markerFileName.tmp'));
    await tmp.writeAsString(jsonEncode(marker.toJson()), flush: true);
    await tmp.rename(p.join(dir.path, markerFileName));
  }

  // ---------------------------------------------------------------------------
  // 目录 / 工具
  // ---------------------------------------------------------------------------

  static Future<bool> _isUsable(Directory dir) async {
    if (!await dir.exists()) return false;
    return File(p.join(dir.path, entryFile)).exists();
  }

  static void _scheduleBackgroundUpdate() {
    if (debugDisableAutoUpdate) return;
    // updateFromRemote 内部已兜住所有异常，这里是真正的「后台、不阻塞」。
    unawaited(updateFromRemote());
  }

  static String _sha256Hex(List<int> bytes) =>
      crypto.sha256.convert(bytes).toString();

  static Future<Directory> _docsDir() async {
    // 测试注入：避免依赖 path_provider 平台通道（与 CacheManageService 同套路）
    if (debugDocsDir != null) return debugDocsDir!;
    return getApplicationDocumentsDirectory();
  }

  static Future<Directory> _targetDir() async {
    final docs = await _docsDir();
    return Directory(p.join(docs.path, _dirName));
  }

  static Future<Directory> _stagingDir() async {
    final docs = await _docsDir();
    return Directory(p.join(docs.path, stagingDirName));
  }

  static Future<Directory> _previousDir() async {
    final docs = await _docsDir();
    return Directory(p.join(docs.path, previousDirName));
  }

  // ---------------------------------------------------------------------------
  // 测试注入
  // ---------------------------------------------------------------------------

  /// 测试注入：应用文档目录替身
  @visibleForTesting
  static Directory? debugDocsDir;

  /// 测试注入：清单信任锚工厂（默认新建 [ModuleManifestClient]）
  @visibleForTesting
  static ModuleManifestClient Function()? debugManifestClientFactory;

  /// 测试注入：资产下载器（默认新建 [ModuleDownloader]）
  @visibleForTesting
  static ModuleFetcher? debugFetcher;

  /// 测试注入：随包资产加载（默认 `rootBundle.load`）
  @visibleForTesting
  static Future<Uint8List> Function()? debugAssetLoader;

  /// 测试注入：关闭 `ensureExtracted` 自动触发的后台远端更新
  @visibleForTesting
  static bool debugDisableAutoUpdate = false;

  /// 测试注入：在 [clearManagedDirs] 完成目录解析后、同步临界区最终校验前调用。
  ///
  /// 用于确定性复现「延迟清理的 await 窗口内新页面进入」这一竞态：注入的回调
  /// 内调用 [beginUse]，临界区的重新校验必须捕获并重新延迟。
  @visibleForTesting
  static void Function()? debugBeforeClearDelete;

  /// 复位全部测试注入点
  @visibleForTesting
  static void debugReset() {
    debugDocsDir = null;
    debugManifestClientFactory = null;
    debugFetcher = null;
    debugAssetLoader = null;
    debugDisableAutoUpdate = false;
    debugBeforeClearDelete = null;
    _inFlight = null;
    _activeUsers = 0;
    _cleanupPending = false;
  }
}

/// 离线资源清理结果（区别于既有 [ItToolsService.clearExtracted] 的 bool）。
enum ItToolsClearOutcome {
  /// 至少清理了一个目录
  cleared,

  /// 本就没有可清理的目录
  empty,

  /// 页面/WebView 使用中，清理已延迟
  deferred,
}

/// 本地标记：`{contentHash, source}`。
///
/// 防御式解析：字段缺失/类型错误/`source` 非法 → null，绝不抛异常。
class ItToolsMarker {
  /// zip 字节的 SHA-256（十六进制小写）
  final String contentHash;

  /// 来源：`remote`（Release）或 `asset`（随包资产）
  final String source;

  const ItToolsMarker({required this.contentHash, required this.source});

  static ItToolsMarker? tryFromJson(Object? json) {
    if (json is! Map) return null;

    final contentHash = json['contentHash'];
    final source = json['source'];
    if (contentHash is! String || contentHash.isEmpty) return null;
    if (source != ItToolsService.sourceRemote &&
        source != ItToolsService.sourceAsset) {
      return null;
    }
    return ItToolsMarker(contentHash: contentHash, source: source as String);
  }

  Map<String, Object?> toJson() => {
        'contentHash': contentHash,
        'source': source,
      };
}

/// 远端 IT-Tools 包描述（zip URL + 完整性元数据）。
class ItToolsRemotePackage {
  final String url;
  final String contentHash;
  final int size;

  const ItToolsRemotePackage({
    required this.url,
    required this.contentHash,
    required this.size,
  });
}

/// 远端更新结果。
class ItToolsUpdateResult {
  /// 是否真的发生了原子替换
  final bool updated;

  /// 未更新/失败原因：`up-to-date` / `remote-unavailable` /
  /// `download-failed` / `size-mismatch` / `hash-mismatch` /
  /// `missing-entry` / `error`
  final String? reason;

  /// 本次（或当前）来源；失败时为 null
  final String? source;

  /// 本次更新后的 contentHash；失败时为 null
  final String? contentHash;

  const ItToolsUpdateResult._({
    required this.updated,
    this.reason,
    this.source,
    this.contentHash,
  });

  const ItToolsUpdateResult.success(String contentHash)
      : this._(
          updated: true,
          source: ItToolsService.sourceRemote,
          contentHash: contentHash,
        );

  const ItToolsUpdateResult.upToDate(String contentHash)
      : this._(
          updated: false,
          reason: 'up-to-date',
          source: ItToolsService.sourceRemote,
          contentHash: contentHash,
        );

  const ItToolsUpdateResult.offline()
      : this._(updated: false, reason: 'remote-unavailable');

  const ItToolsUpdateResult.failure(String reason)
      : this._(updated: false, reason: reason);
}

/// isolate 解压任务入参（需可跨 isolate 传递）
class _ExtractRequest {
  const _ExtractRequest(this.bytes, this.targetDir);

  final Uint8List bytes;
  final String targetDir;
}

/// compute 要求顶层函数
Future<void> _extractZipTo(_ExtractRequest req) =>
    ItToolsService.extractTo(req.bytes, req.targetDir);

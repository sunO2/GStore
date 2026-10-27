import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/migration/cutover_paths.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';

/// Typed failure for the Rust script-pack lane.
///
/// The Dart side never writes a legacy zip when this is thrown: the pack is
/// staged to a temp file, handed to the Rust `ScriptApi`, and the temp file is
/// removed in a `finally`. A failure therefore leaves the legacy channel
/// directory untouched and surfaces one stable code to the settings UI.
class ScriptChannelImportException implements Exception {
  const ScriptChannelImportException(this.message, {this.cause});

  /// Stable machine code.
  static const String code = 'CORE_E_CHANNEL_SCRIPT_IMPORT_FAILED';

  /// Human-readable detail.
  final String message;

  /// Underlying Rust/transport error, if any.
  final Object? cause;

  /// Instance access to the stable code.
  String get errorCode => code;

  @override
  String toString() =>
      cause == null ? '$code: $message' : '$code: $message ($cause)';
}

/// Resolves the `(data, files, cache)` triple handed to `ScriptApi.init`.
typedef ScriptCoreDirs = Future<(String, String, String)> Function();

/// Guarantees the FRB runtime exists before the opaque `ScriptApi` handle is
/// constructed; injectable so pure-Dart tests never touch FFI.
typedef ScriptRustInit = Future<void> Function();

/// Production owner of the Rust-hosted script-channel pack store.
///
/// This is the missing production consumer of `ScriptApi`: the app's startup
/// load (`ChannelLoader.loadAndRegister` from `ChannelIntegration.initialize`)
/// and the settings import action both go through here once
/// `CoreFlags.jsChannel` is on. While the flag is off this class is never
/// reached, so the legacy Dart `JsChannel` lane keeps owning packs.
///
/// Invariants:
/// * `init` is single-flight and safe to call again (Rust opens the same DB and
///   `import` upserts by key, so a re-run never duplicates a pack);
/// * every import is staged to a temp file first and that file is always
///   deleted, so a failure cannot leave a half-written pack in the legacy
///   channel directory;
/// * a failure is a [ScriptChannelImportException], never a silent skip.
class ScriptChannelService {
  ScriptChannelService({
    ScriptApi? api,
    ScriptCoreDirs? coreDirs,
    ScriptRustInit? ensureRust,
  })  : _apiOverride = api,
        _coreDirs = coreDirs ?? CutoverPaths.defaultCoreDirs,
        _ensureRust = ensureRust ?? RustBridge.ensureInitialized;

  /// Process-wide production instance.
  static ScriptChannelService instance = ScriptChannelService();

  /// Replaces the process-wide service. Tests only.
  @visibleForTesting
  static void installForTest(ScriptChannelService service) {
    instance = service;
  }

  /// Restores the production service. Tests only.
  @visibleForTesting
  static void resetForTest() {
    instance = ScriptChannelService();
  }

  final ScriptApi? _apiOverride;
  final ScriptCoreDirs _coreDirs;
  final ScriptRustInit _ensureRust;

  bool _ready = false;
  Future<void>? _pending;

  ScriptApi get _api => _apiOverride ?? ScriptApi.instance;

  /// Opens the Rust pack store once (single-flight, concurrency-safe).
  Future<void> ensureInitialized() {
    if (_ready) return Future<void>.value();
    return _pending ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _ensureRust();
      final (dataDir, filesDir, cacheDir) = await _coreDirs();
      await _api.init(
        dataDir: dataDir,
        filesDir: filesDir,
        cacheDir: cacheDir,
      );
      _ready = true;
    } finally {
      _pending = null;
    }
  }

  /// Imports every `<directory>/*.zip` pack into the Rust lane.
  ///
  /// This is the startup load path: `ChannelLoader.loadAndRegister` calls it
  /// while `CoreFlags.jsChannel` is on instead of building Dart `JsChannel`s.
  /// A single bad pack is logged and skipped, matching the legacy loader's
  /// "one bad pack never blocks the rest" contract. Re-running is idempotent
  /// because `ScriptApi.import` upserts by channel key.
  Future<List<rust_pack.ScriptPackInfo>> syncInstalledPacks(
    Directory directory,
  ) async {
    final imported = <rust_pack.ScriptPackInfo>[];
    if (!await directory.exists()) {
      appLog.info('ScriptChannelService: 渠道包目录不存在，跳过: ${directory.path}');
      return imported;
    }

    final files = (await directory.list().toList())
        .whereType<File>()
        .where((file) => file.path.endsWith('.zip'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) {
      appLog.info('ScriptChannelService: 渠道包目录为空: ${directory.path}');
      return imported;
    }

    await ensureInitialized();
    for (final file in files) {
      final key = channelKeyFromFileName(file.uri.pathSegments.last);
      if (key == null) {
        appLog.warning(
            'ScriptChannelService: 跳过非法文件名（非合法标识符）: ${file.path}');
        continue;
      }
      try {
        imported.add(
          await importPack(channelKey: key, zipBytes: await file.readAsBytes()),
        );
        appLog.info('ScriptChannelService: 渠道包 $key 已导入 Rust 脚本通道');
      } catch (error) {
        appLog.error('ScriptChannelService: 渠道包 $key 导入失败，跳过: $error');
      }
    }
    return imported;
  }

  /// Imports one zip pack into the Rust lane.
  ///
  /// The bytes are staged to a temp file and read back before the real
  /// `ScriptApi.import` call so the same code path serves a file-picked import
  /// and a stored `.zip`; the temp directory is always removed.
  Future<rust_pack.ScriptPackInfo> importPack({
    required String channelKey,
    required Uint8List zipBytes,
  }) async {
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(channelKey)) {
      throw ArgumentError.value(
        channelKey,
        'channelKey',
        '非法渠道标识（需字母/下划线开头，仅含字母数字下划线）',
      );
    }
    await ensureInitialized();

    final holder =
        await Directory.systemTemp.createTemp('gstore_script_import_');
    final staged = File('${holder.path}/${_stem(channelKey)}.zip');
    try {
      await staged.writeAsBytes(zipBytes, flush: true);
      final stagedBytes = await staged.readAsBytes();
      return await _api.import_(
        packZipBytes: stagedBytes,
        expectedKey: channelKey,
      );
    } catch (error) {
      if (error is ArgumentError) rethrow;
      throw ScriptChannelImportException(
        '渠道包 $channelKey 导入 Rust 脚本通道失败',
        cause: error,
      );
    } finally {
      try {
        if (await holder.exists()) await holder.delete(recursive: true);
      } catch (error) {
        appLog.warning('ScriptChannelService: 清理临时导入文件失败: $error');
      }
    }
  }

  /// Removes one installed pack. Missing packs are a no-op (idempotent).
  Future<void> removePack(String channelKey) async {
    await ensureInitialized();
    try {
      await _api.remove(key: channelKey);
    } catch (error) {
      if (error.toString().contains('pack_not_found')) return;
      throw ScriptChannelImportException(
        '渠道包 $channelKey 从 Rust 脚本通道移除失败',
        cause: error,
      );
    }
  }

  /// `文件名.zip` → `js_<stem>`; mirrors `ChannelLoader`'s filename contract so
  /// a stored pack round-trips to the same key (`js_vivo`, never `js_js_vivo`).
  @visibleForTesting
  static String? channelKeyFromFileName(String fileName) {
    final stem = fileName.endsWith('.zip')
        ? fileName.substring(0, fileName.length - 4)
        : fileName;
    if (stem.isEmpty) return null;
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(stem)) return null;
    return 'js_$stem';
  }

  static String _stem(String channelKey) =>
      channelKey.startsWith('js_') ? channelKey.substring(3) : channelKey;
}

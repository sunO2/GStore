import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;

/// Raised when a [ScriptApi] entry point is called while
/// `CoreFlags.jsChannel` is off.
///
/// The flag is the only authority: the Rust lane owns script packs once it is
/// on, and while it is off the Dart JS writers keep owning them. This is a
/// typed refusal, never a silent fallback.
class ScriptApiDisabledException implements Exception {
  static const String code = 'CORE_E_SCRIPT_JS_CHANNEL_DISABLED';

  const ScriptApiDisabledException();

  /// Instance access to the stable code (tests and callers).
  String get errorCode => code;

  @override
  String toString() => '$code: ScriptApi requires CoreFlags.jsChannel';
}

/// Backend seam for [ScriptApi]; production is [FrbScriptApiBackend].
///
/// Keeping the seam explicit lets the Dart tests prove that the flag gate never
/// touches FFI and that every method delegates with the documented shape.
abstract class ScriptApiBackend {
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  });

  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  });

  Future<void> remove({required String key});

  Future<rust_pack.ScriptPackInfo> refresh({required String key});

  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  });

  Future<Map<String, String>> getEnv({required String key});

  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  });

  Future<List<rust_pack.ScriptPackInfo>> list();

  Future<String> storedApps({required String key});

  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  });

  Future<void> releaseDetail({
    required String key,
    required String appId,
  });
}

/// Production backend: lazily initialises the generated FRB [rust.ScriptApi].
class FrbScriptApiBackend implements ScriptApiBackend {
  rust.ScriptApi? _api;

  rust.ScriptApi get _instance {
    final api = _api;
    if (api == null) {
      throw StateError('ScriptApi.init() must be awaited before use');
    }
    return api;
  }

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    _api = await rust.ScriptApi.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) =>
      _instance.import_(
        packZipBytes: packZipBytes,
        expectedKey: expectedKey,
      );

  @override
  Future<void> remove({required String key}) => _instance.remove(key: key);

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) =>
      _instance.refresh(key: key);

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) =>
      _instance.setEnv(key: key, env: env);

  @override
  Future<Map<String, String>> getEnv({required String key}) async {
    final raw = await _instance.env(key: key);
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) =>
      _instance.setConfig(key: key, config: config);

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() => _instance.list();

  @override
  Future<String> storedApps({required String key}) =>
      _instance.storedApps(key: key);

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) =>
      _instance.addApp(key: key, app: app);

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) =>
      _instance.releaseDetail(key: key, appId: appId);
}

/// Dart facade over the Rust-hosted JS channel lane, gated by
/// `CoreFlags.jsChannel`.
///
/// This is a **pack-lifecycle** facade only (import/remove/refresh/list/env/
/// storedApps/addApp/releaseDetail). It no longer runs a pack's `main`: the JS
/// **data** path reads channel data through `ChannelApi` / [RustChannelFacade],
/// whose JS runtime authority is the host's `ChannelApiInner.script_drivers`
/// (+ the per-call `ScriptDetail`).
///
/// Every entry point refuses with [ScriptApiDisabledException] while the flag is
/// off, before the backend is touched, so no production caller can reach the
/// Rust pack store through this facade on the old lane. The facade never flips
/// a flag and never writes the `js_channel` marker.
class ScriptApi {
  ScriptApi({ScriptApiBackend? backend})
      : _backend = backend ?? FrbScriptApiBackend();

  static ScriptApi _instance = ScriptApi();

  /// Process-wide facade (production).
  static ScriptApi get instance => _instance;

  /// Replaces the process-wide backend. Tests only.
  @visibleForTesting
  static void installBackend(ScriptApiBackend backend) {
    _instance = ScriptApi(backend: backend);
  }

  /// Restores the production backend. Tests only.
  @visibleForTesting
  static void resetBackend() {
    _instance = ScriptApi();
  }

  final ScriptApiBackend _backend;

  void _ensureEnabled() {
    if (!CoreFlags.jsChannel) {
      throw const ScriptApiDisabledException();
    }
  }

  /// Opens the core database and binds the pack store.
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    _ensureEnabled();
    await _backend.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  /// Installs one pack from zip bytes (`expected_key` is `js_<stem>`).
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async {
    _ensureEnabled();
    return _backend.import_(
      packZipBytes: packZipBytes,
      expectedKey: expectedKey,
    );
  }

  /// Removes an installed pack, its runtimes, and its channel env.
  Future<void> remove({required String key}) async {
    _ensureEnabled();
    await _backend.remove(key: key);
  }

  /// Reloads a pack from its installed directory.
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async {
    _ensureEnabled();
    return _backend.refresh(key: key);
  }

  /// Replaces the channel env snapshot and hot-updates live runtimes.
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async {
    _ensureEnabled();
    await _backend.setEnv(key: key, env: env);
  }

  /// Returns the persisted channel env snapshot for [key].
  ///
  /// The read counterpart of [setEnv]: it reads the same Rust store the script's
  /// `host.env.get` sees, so sensitive names are resolved from the Rust secret
  /// store and are never mirrored into the Flutter `ConfigStore`. An unknown or
  /// never-saved key yields an empty map.
  Future<Map<String, String>> getEnv({required String key}) async {
    _ensureEnabled();
    return _backend.getEnv(key: key);
  }

  /// Replaces the channel config snapshot read by `host.config.get`.
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async {
    _ensureEnabled();
    await _backend.setConfig(key: key, config: config);
  }

  /// Lists installed packs in deterministic key order.
  Future<List<rust_pack.ScriptPackInfo>> list() async {
    _ensureEnabled();
    return _backend.list();
  }

  /// Returns the saved `channel_apps` rows for `key` as a JSON array string.
  Future<String> storedApps({required String key}) async {
    _ensureEnabled();
    return _backend.storedApps(key: key);
  }

  /// Inserts one app into `key`'s saved `channel_apps` rows.
  ///
  /// This is the script-lane counterpart to `ChannelApi.addApp`: it writes the
  /// script domain's rows (the same rows [storedApps] reads), so a `js_*` pack
  /// never has to be registered as a channels-domain channel. `key` must name an
  /// installed pack; the Rust lane rejects an unknown key or an empty `appId`.
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {
    _ensureEnabled();
    await _backend.addApp(key: key, app: app);
  }

  /// Releases the `detail.js` runtime bound to `(key, app_id)`.
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async {
    _ensureEnabled();
    await _backend.releaseDetail(key: key, appId: appId);
  }
}

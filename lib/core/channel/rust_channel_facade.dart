/// Thin Dart facade over the FRB `ChannelApi` (Todo 13).
///
/// The facade owns no channel policy: every method forwards to the injected
/// [ChannelApiBackend]. Production installs [FrbChannelApiBackend], which lazily
/// initialises `RustBridge` and the generated `ChannelApi`; tests inject a fake
/// backend so no native library is required.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Typed channel failure carried across the Dart/Rust boundary.
class ChannelApiException implements Exception {
  const ChannelApiException(this.code, this.message);

  /// Stable machine code (`not_found`, `invalid_argument`, `pack_not_found`, ...).
  final String code;

  /// Human-readable detail.
  final String message;

  /// Parses the stable `code: message` shape emitted by `gstore_host`.
  static ChannelApiException? tryParse(Object error) {
    final text = error.toString();
    final match = RegExp(
      r'(not_found|invalid_argument|conflict|io|network|unauthorized|forbidden|'
      r'rate_limited|serialization|unsupported|internal|pack_[a-z_]+): ',
    ).firstMatch(text);
    if (match == null) return null;
    return ChannelApiException(
      match.group(1)!,
      text.substring(match.end).replaceAll(RegExp(r'\)+$'), ''),
    );
  }

  @override
  String toString() => '$code: $message';
}

/// Injectable transport seam. Production = [FrbChannelApiBackend].
abstract class ChannelApiBackend {
  Future<List<rust.ChannelEntry>> list();

  Future<rust.ChannelEntry> get({required String key});

  Future<rust.ChannelEntry> register(
      {required rust.ChannelRegistration registration});

  Future<void> unregister({required String key});

  Future<rust.ChannelEntry> enable({required String key});

  Future<rust.ChannelEntry> disable({required String key});

  Future<rust.ChannelPackInfo> importPack({required String path});

  Future<BigInt> exportPack({required String key, required String path});

  Future<bool> removePack({required String key});

  Future<String?> envGet({required String key, required String name});

  Future<void> envSet({
    required String key,
    required String name,
    required String value,
  });

  Future<bool> envRemove({required String key, required String name});

  Future<bool> refresh({required String key});

  Future<List<rust.ChannelAppInfo>> listApps({
    required String key,
    required bool forceRefresh,
  });

  Future<bool> checkUpdate({required String key});

  Future<List<rust.ChannelAppInfo>> search({
    required String key,
    required String keyword,
    required bool forceRefresh,
  });

  Future<rust.ChannelAppInfo> getAppInfo({
    required String key,
    required String appId,
    required bool forceRefresh,
  });

  Future<rust.ChannelAppDetailInfo> getAppDetail({
    required String key,
    required String appId,
    required bool forceRefresh,
  });

  /// Runs a pack's `detail.js` `versionOptions({appId, env?, currentVersion?})`.
  ///
  /// `null` when the pack answers JSON null (unimplemented / `{ok:false}` /
  /// JS throw); an unknown/uninstalled pack is a typed `not_found`.
  Future<rust.ScriptVersionOptions?> scriptVersionOptions({
    required String key,
    required String appId,
    String? env,
    String? currentVersion,
  });

  /// Runs a pack's `detail.js` `switchVersion({appId, env, version, build?})`.
  Future<rust.ChannelAppDetailInfo?> scriptSwitchVersion({
    required String key,
    required String appId,
    required String env,
    required String version,
    String? buildJson,
  });

  /// Runs a pack's `detail.js` `buildHistory({appId, version, env})`.
  Future<List<rust.ScriptBuild>> scriptBuildHistory({
    required String key,
    required String appId,
    required String env,
    required String version,
  });

  /// Runs a pack's `detail.js` `detailMenu(appId)`.
  Future<List<rust.ChannelDetailAction>> scriptDetailMenu({
    required String key,
    required String appId,
  });

  /// Runs one page-scoped pack `jscall` (e.g. `jsswitchUA`) on a fresh
  /// per-call `ScriptDetail`.
  ///
  /// The pack drives the UI itself (e.g. `host.ui.call('showUAPicker')`); the
  /// action's own result is not surfaced. Because it runs on a NEW runtime, a
  /// parked round-trip cannot contend on the entry's `op` guard.
  Future<void> scriptDetailAction({
    required String key,
    required String appId,
    required String jscall,
  });

  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  });

  Future<void> removeApp({required String key, required String appId});

  Future<List<rust.ChannelAppInfo>> searchByCategory({
    required String key,
    required String categoryId,
    required bool forceRefresh,
  });

  Future<List<rust.ChannelCategoryInfo>> getAllCategories({
    required String key,
    required bool forceRefresh,
  });

  Future<String> canonicalAppId({
    required String key,
    required rust.ChannelAppInfo app,
  });

  Future<rust.ChannelConfigInfo?> getConfig({
    required String key,
    required bool forceRefresh,
  });

  Future<void> setFdroidSources({required List<String> sources});

  /// Returns the unified library facade backed by the SAME `ChannelApi`
  /// (one database handle + one driver set) as every other channel call.
  ///
  /// Callers that need `rust.LibraryApi` (added-apps reads/writes, the home
  /// page read model) must obtain it here — never by initialising a second
  /// `ChannelApi`.
  Future<rust.LibraryApi> library();
}

/// Production backend: lazily initialises the generated `ChannelApi`.
class FrbChannelApiBackend implements ChannelApiBackend {
  FrbChannelApiBackend({this.dataDir, this.filesDir, this.cacheDir});

  /// Optional explicit directories; when omitted, app support subdirectories
  /// are used (same shape as `CoreApi.init`).
  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;

  rust.ChannelApi? _api;
  Future<rust.ChannelApi>? _pending;

  /// The single `rust.LibraryApi` derived from [_api]; cached so every caller
  /// shares one instance (same DB handle and driver set).
  rust.LibraryApi? _library;
  Future<rust.LibraryApi>? _libraryPending;

  Future<rust.ChannelApi> _ensureApi() {
    final existing = _api;
    if (existing != null) return Future.value(existing);
    return _pending ??= _create();
  }

  Future<rust.ChannelApi> _create() async {
    try {
      await RustBridge.ensureInitialized();
      final dirs = await _resolveDirs();
      final api = await rust.ChannelApi.init(
        dataDir: dirs.$1,
        filesDir: dirs.$2,
        cacheDir: dirs.$3,
      );
      _api = api;
      return api;
    } finally {
      _pending = null;
    }
  }

  Future<(String, String, String)> _resolveDirs() async {
    if (dataDir != null && filesDir != null && cacheDir != null) {
      return (dataDir!, filesDir!, cacheDir!);
    }
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    return ('$root/data', '$root/files', '$root/cache');
  }

  Future<T> _call<T>(Future<T> Function(rust.ChannelApi api) action) async {
    final api = await _ensureApi();
    try {
      return await action(api);
    } catch (error) {
      final typed = ChannelApiException.tryParse(error);
      if (typed != null) throw typed;
      rethrow;
    }
  }

  /// Caches the one `rust.LibraryApi` derived from [_ensureApi].
  Future<rust.LibraryApi> _ensureLibrary() {
    final existing = _library;
    if (existing != null) return Future.value(existing);
    return _libraryPending ??= _createLibrary();
  }

  Future<rust.LibraryApi> _createLibrary() async {
    try {
      final api = await _ensureApi();
      final library = await api.library_();
      _library = library;
      return library;
    } finally {
      _libraryPending = null;
    }
  }

  @override
  Future<rust.LibraryApi> library() async {
    try {
      return await _ensureLibrary();
    } catch (error) {
      final typed = ChannelApiException.tryParse(error);
      if (typed != null) throw typed;
      rethrow;
    }
  }

  @override
  Future<List<rust.ChannelEntry>> list() => _call((api) => api.list());

  @override
  Future<rust.ChannelEntry> get({required String key}) =>
      _call((api) => api.get_(key: key));

  @override
  Future<rust.ChannelEntry> register(
          {required rust.ChannelRegistration registration}) =>
      _call((api) => api.register(registration: registration));

  @override
  Future<void> unregister({required String key}) =>
      _call((api) => api.unregister(key: key));

  @override
  Future<rust.ChannelEntry> enable({required String key}) =>
      _call((api) => api.enable(key: key));

  @override
  Future<rust.ChannelEntry> disable({required String key}) =>
      _call((api) => api.disable(key: key));

  @override
  Future<rust.ChannelPackInfo> importPack({required String path}) =>
      _call((api) => api.importPack(path: path));

  @override
  Future<BigInt> exportPack({required String key, required String path}) =>
      _call((api) => api.exportPack(key: key, path: path));

  @override
  Future<bool> removePack({required String key}) =>
      _call((api) => api.removePack(key: key));

  @override
  Future<String?> envGet({required String key, required String name}) =>
      _call((api) => api.envGet(key: key, name: name));

  @override
  Future<void> envSet({
    required String key,
    required String name,
    required String value,
  }) =>
      _call((api) => api.envSet(key: key, name: name, value: value));

  @override
  Future<bool> envRemove({required String key, required String name}) =>
      _call((api) => api.envRemove(key: key, name: name));

  @override
  Future<bool> refresh({required String key}) =>
      _call((api) => api.refresh(key: key));

  @override
  Future<List<rust.ChannelAppInfo>> listApps({
    required String key,
    required bool forceRefresh,
  }) =>
      _call((api) => api.listApps(key: key, forceRefresh: forceRefresh));

  @override
  Future<bool> checkUpdate({required String key}) =>
      _call((api) => api.checkUpdate(key: key));

  @override
  Future<List<rust.ChannelAppInfo>> search({
    required String key,
    required String keyword,
    required bool forceRefresh,
  }) =>
      _call((api) => api.search(
            key: key,
            keyword: keyword,
            forceRefresh: forceRefresh,
          ));

  @override
  Future<rust.ChannelAppInfo> getAppInfo({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) =>
      _call((api) => api.getAppInfo(
            key: key,
            appId: appId,
            forceRefresh: forceRefresh,
          ));

  @override
  Future<rust.ChannelAppDetailInfo> getAppDetail({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) =>
      _call((api) => api.getAppDetail(
            key: key,
            appId: appId,
            forceRefresh: forceRefresh,
          ));

  @override
  Future<rust.ScriptVersionOptions?> scriptVersionOptions({
    required String key,
    required String appId,
    String? env,
    String? currentVersion,
  }) =>
      _call((api) => api.scriptVersionOptions(
            key: key,
            appId: appId,
            env: env,
            currentVersion: currentVersion,
          ));

  @override
  Future<rust.ChannelAppDetailInfo?> scriptSwitchVersion({
    required String key,
    required String appId,
    required String env,
    required String version,
    String? buildJson,
  }) =>
      _call((api) => api.scriptSwitchVersion(
            key: key,
            appId: appId,
            env: env,
            version: version,
            buildJson: buildJson,
          ));

  @override
  Future<List<rust.ScriptBuild>> scriptBuildHistory({
    required String key,
    required String appId,
    required String env,
    required String version,
  }) =>
      _call((api) => api.scriptBuildHistory(
            key: key,
            appId: appId,
            env: env,
            version: version,
          ));

  @override
  Future<List<rust.ChannelDetailAction>> scriptDetailMenu({
    required String key,
    required String appId,
  }) =>
      _call((api) => api.scriptDetailMenu(key: key, appId: appId));

  @override
  Future<void> scriptDetailAction({
    required String key,
    required String appId,
    required String jscall,
  }) =>
      _call((api) => api.scriptDetailAction(
            key: key,
            appId: appId,
            jscall: jscall,
          ));

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) =>
      _call((api) => api.addApp(key: key, app: app));

  @override
  Future<void> removeApp({required String key, required String appId}) =>
      _call((api) => api.removeApp(key: key, appId: appId));

  @override
  Future<List<rust.ChannelAppInfo>> searchByCategory({
    required String key,
    required String categoryId,
    required bool forceRefresh,
  }) =>
      _call((api) => api.searchByCategory(
            key: key,
            categoryId: categoryId,
            forceRefresh: forceRefresh,
          ));

  @override
  Future<List<rust.ChannelCategoryInfo>> getAllCategories({
    required String key,
    required bool forceRefresh,
  }) =>
      _call((api) => api.getAllCategories(
            key: key,
            forceRefresh: forceRefresh,
          ));

  @override
  Future<String> canonicalAppId({
    required String key,
    required rust.ChannelAppInfo app,
  }) =>
      _call((api) => api.canonicalAppId(key: key, app: app));

  @override
  Future<rust.ChannelConfigInfo?> getConfig({
    required String key,
    required bool forceRefresh,
  }) =>
      _call((api) => api.getConfig(key: key, forceRefresh: forceRefresh));

  @override
  Future<void> setFdroidSources({required List<String> sources}) =>
      _call((api) => api.setFdroidSources(sources: sources));
}

/// Singleton facade with a replaceable backend.
class RustChannelFacade {
  RustChannelFacade({ChannelApiBackend? backend})
      : _backend = backend ?? FrbChannelApiBackend();

  static RustChannelFacade _instance = RustChannelFacade();

  /// Current facade (production unless a test installs a backend).
  static RustChannelFacade get instance => _instance;

  final ChannelApiBackend _backend;

  /// Backend seam (diagnostics/tests).
  ChannelApiBackend get backend => _backend;

  /// Replaces the process-wide backend. Tests only.
  @visibleForTesting
  static void installBackend(ChannelApiBackend backend) {
    _instance = RustChannelFacade(backend: backend);
  }

  /// Restores the production backend. Tests only.
  @visibleForTesting
  static void resetBackend() {
    _instance = RustChannelFacade();
  }

  Future<List<rust.ChannelEntry>> list() => _backend.list();

  Future<rust.ChannelEntry> get({required String key}) =>
      _backend.get(key: key);

  Future<rust.ChannelEntry> register(
          {required rust.ChannelRegistration registration}) =>
      _backend.register(registration: registration);

  Future<void> unregister({required String key}) =>
      _backend.unregister(key: key);

  Future<rust.ChannelEntry> enable({required String key}) =>
      _backend.enable(key: key);

  Future<rust.ChannelEntry> disable({required String key}) =>
      _backend.disable(key: key);

  Future<rust.ChannelPackInfo> importPack({required String path}) =>
      _backend.importPack(path: path);

  Future<BigInt> exportPack({required String key, required String path}) =>
      _backend.exportPack(key: key, path: path);

  Future<bool> removePack({required String key}) =>
      _backend.removePack(key: key);

  Future<String?> envGet({required String key, required String name}) =>
      _backend.envGet(key: key, name: name);

  Future<void> envSet({
    required String key,
    required String name,
    required String value,
  }) =>
      _backend.envSet(key: key, name: name, value: value);

  Future<bool> envRemove({required String key, required String name}) =>
      _backend.envRemove(key: key, name: name);

  Future<bool> refresh({required String key}) => _backend.refresh(key: key);

  Future<List<rust.ChannelAppInfo>> getAllApps({
    required String key,
    required bool forceRefresh,
  }) =>
      _backend.listApps(key: key, forceRefresh: forceRefresh);

  Future<bool> checkUpdate({required String key}) =>
      _backend.checkUpdate(key: key);

  Future<List<rust.ChannelAppInfo>> search({
    required String key,
    required String keyword,
    required bool forceRefresh,
  }) =>
      _backend.search(key: key, keyword: keyword, forceRefresh: forceRefresh);

  Future<rust.ChannelAppInfo> getAppInfo({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) =>
      _backend.getAppInfo(
        key: key,
        appId: appId,
        forceRefresh: forceRefresh,
      );

  Future<rust.ChannelAppDetailInfo> getAppDetail({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) =>
      _backend.getAppDetail(
        key: key,
        appId: appId,
        forceRefresh: forceRefresh,
      );

  /// Runs a pack's `detail.js` `versionOptions`; see
  /// [ChannelApiBackend.scriptVersionOptions].
  Future<rust.ScriptVersionOptions?> scriptVersionOptions({
    required String key,
    required String appId,
    String? env,
    String? currentVersion,
  }) =>
      _backend.scriptVersionOptions(
        key: key,
        appId: appId,
        env: env,
        currentVersion: currentVersion,
      );

  /// Runs a pack's `detail.js` `switchVersion`; see
  /// [ChannelApiBackend.scriptSwitchVersion].
  Future<rust.ChannelAppDetailInfo?> scriptSwitchVersion({
    required String key,
    required String appId,
    required String env,
    required String version,
    String? buildJson,
  }) =>
      _backend.scriptSwitchVersion(
        key: key,
        appId: appId,
        env: env,
        version: version,
        buildJson: buildJson,
      );

  /// Runs a pack's `detail.js` `buildHistory`; see
  /// [ChannelApiBackend.scriptBuildHistory].
  Future<List<rust.ScriptBuild>> scriptBuildHistory({
    required String key,
    required String appId,
    required String env,
    required String version,
  }) =>
      _backend.scriptBuildHistory(
        key: key,
        appId: appId,
        env: env,
        version: version,
      );

  /// Runs a pack's `detail.js` `detailMenu`; see
  /// [ChannelApiBackend.scriptDetailMenu].
  Future<List<rust.ChannelDetailAction>> scriptDetailMenu({
    required String key,
    required String appId,
  }) =>
      _backend.scriptDetailMenu(key: key, appId: appId);

  /// Runs one page-scoped pack `jscall`; see
  /// [ChannelApiBackend.scriptDetailAction].
  Future<void> scriptDetailAction({
    required String key,
    required String appId,
    required String jscall,
  }) =>
      _backend.scriptDetailAction(key: key, appId: appId, jscall: jscall);

  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) =>
      _backend.addApp(key: key, app: app);

  Future<void> removeApp({required String key, required String appId}) =>
      _backend.removeApp(key: key, appId: appId);

  Future<List<rust.ChannelAppInfo>> searchByCategory({
    required String key,
    required String categoryId,
    required bool forceRefresh,
  }) =>
      _backend.searchByCategory(
        key: key,
        categoryId: categoryId,
        forceRefresh: forceRefresh,
      );

  /// A channel that does not model categories (e.g. a JS pack) reports a typed
  /// `unsupported`; the UI's "no categories" state is the same as an empty list,
  /// so it is degraded here rather than surfaced as an error.
  Future<List<rust.ChannelCategoryInfo>> getAllCategories({
    required String key,
    required bool forceRefresh,
  }) async {
    try {
      return await _backend.getAllCategories(key: key, forceRefresh: forceRefresh);
    } on ChannelApiException catch (error) {
      if (error.code == 'unsupported') {
        return const <rust.ChannelCategoryInfo>[];
      }
      rethrow;
    }
  }

  Future<String> canonicalAppId({
    required String key,
    required rust.ChannelAppInfo app,
  }) =>
      _backend.canonicalAppId(key: key, app: app);

  Future<rust.ChannelConfigInfo?> getConfig({
    required String key,
    required bool forceRefresh,
  }) =>
      _backend.getConfig(key: key, forceRefresh: forceRefresh);

  /// Pushes the active F-Droid source URLs into the Rust core so its F-Droid
  /// driver can resolve versions from the repository index.
  Future<void> setFdroidSources({required List<String> sources}) =>
      _backend.setFdroidSources(sources: sources);

  /// Returns the shared `rust.LibraryApi` for this facade.
  ///
  /// This is the single accessor for the unified library read/write model:
  /// `AddedAppsFacade` and the home page read use it, so both talk to the same
  /// `ChannelApi` (one database handle, one driver set). No second
  /// `ChannelApi` is created.
  Future<rust.LibraryApi> library() => _backend.library();
}

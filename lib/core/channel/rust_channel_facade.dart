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

  Future<List<rust.ChannelCategoryInfo>> getAllCategories({
    required String key,
    required bool forceRefresh,
  }) =>
      _backend.getAllCategories(key: key, forceRefresh: forceRefresh);

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
}

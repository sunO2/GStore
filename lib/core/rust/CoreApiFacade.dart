// ignore_for_file: file_names

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'generated/bridge.dart';
import 'RustBridge.dart';
import '../service/legacy_write_guard.dart';

/// Thin FRB facade: guarantees RustLib is initialised exactly once before
/// constructing the opaque [CoreApi] handle.
///
/// The handle is memoised per `(dataDir, filesDir, cacheDir)`: the core keeps a
/// single shared writer, and a second handle over the same database would split
/// its write serialisation. Callers that need `importFile` (APK import) can
/// therefore reuse the bootstrap handle instead of opening the DB again.
class CoreApiFacade {
  CoreApiFacade._();

  static CoreApi? _api;
  static Future<CoreApi>? _pending;
  static String? _dirsKey;

  static Future<CoreApi> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) {
    final key = '$dataDir\u0000$filesDir\u0000$cacheDir';
    final cached = _api;
    if (cached != null && _dirsKey == key) return Future<CoreApi>.value(cached);
    final pending = _pending;
    if (pending != null && _dirsKey == key) return pending;
    _dirsKey = key;
    return _pending = _create(dataDir, filesDir, cacheDir);
  }

  static Future<CoreApi> _create(
    String dataDir,
    String filesDir,
    String cacheDir,
  ) async {
    try {
      await RustBridge.ensureInitialized();
      final api = await CoreApi.init(
        dataDir: dataDir,
        filesDir: filesDir,
        cacheDir: cacheDir,
      );
      // Legacy writers are only blocked once CoreFlags.coreWrites is armed; the
      // guard needs the live handle to probe the native marker table.
      LegacyWriteGuard.bind(api);
      // Flag mirrors stay all-false until a caller runs `CoreFlags.refresh()`
      // (or invokes a flag-gated facade, which refreshes before routing).
      _api = api;
      return api;
    } finally {
      _pending = null;
    }
  }

  /// Test-only: drops the memoised handle.
  @visibleForTesting
  static void resetForTest() {
    _api = null;
    _pending = null;
    _dirsKey = null;
  }
}

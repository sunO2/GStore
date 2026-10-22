// ignore_for_file: file_names

import 'generated/bridge.dart';
import 'RustBridge.dart';
import '../service/legacy_write_guard.dart';

/// Thin FRB facade: guarantees RustLib is initialised exactly once before
/// constructing the opaque [CoreApi] handle.
class CoreApiFacade {
  CoreApiFacade._();

  static Future<CoreApi> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
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
    return api;
  }
}

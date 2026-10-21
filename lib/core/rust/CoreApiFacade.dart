import 'generated/bridge.dart';
import 'RustBridge.dart';

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
    return CoreApi.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }
}

/// Process-wide shared request-debug facade.
///
/// The UI provider wraps the same store/sender with the page-layer capture
/// rules port; the agent tool uses this instance directly. Sharing one store
/// avoids the "two facades overwrite each other on save" defect documented in
/// `request_debug_facade_provider.dart`.
library;

import 'package:gstore/core/http/unified_cookie_jar.dart';

import 'request_debug_facade.dart';

class RequestDebugShared {
  RequestDebugShared._();

  static RequestDebugFacade? _instance;

  /// Shared production facade (stored in the app's documents directory with
  /// the same secure storage as the Request Debug page).
  static RequestDebugFacade get instance =>
      _instance ??= DefaultRequestDebugFacade.production(
        cookieJar: UnifiedCookieJar.instance,
      );

  /// Loads the on-disk document once. A store already loaded by the UI is left
  /// untouched so agent/UI edits are not discarded.
  static Future<void> ensureLoaded() async {
    final facade = instance;
    if (!facade.store.loaded) {
      await facade.store.load();
    }
  }

  /// Test/host reset. The next access creates a fresh facade.
  static void reset() {
    _instance = null;
  }
}

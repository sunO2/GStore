import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../rust/generated/bridge.dart';

/// Probes whether a write domain is already owned by the Rust core.
typedef CoreWriteProbe = Future<bool> Function(String domain);

/// Thrown by [LegacyWriteGuard] when a legacy Dart writer attempts a write
/// after the Rust core has taken ownership of that domain.
class LegacyWriteBlocked implements Exception {
  LegacyWriteBlocked(this.domain);

  final String domain;

  @override
  String toString() => 'LegacyWriteBlocked($domain): CORE_E_WRITE_BLOCKED';
}

/// Fails legacy Dart writes closed once the Rust core owns a domain.
///
/// The authoritative signal is the **per-domain marker** in the core's
/// `core_writes` table (written by the first post-cutover mutation of that
/// domain), not the global `CoreFlags.coreWrites` mirror. A domain marker
/// blocks the legacy writer even while the global flag is still false: the flag
/// is a routing hint, the marker is the ownership fact.
///
/// Contract:
/// * No client-side marker cache — every guarded write performs one probe, so a
///   freshly armed domain is observed on the very next write (a stale cache
///   would silently turn the guard into dead code).
/// * An unbound guard (no [CoreApi] yet: pre-init, unit tests, a core that
///   failed to start) allows the write. There is no core to defer to, so the
///   legacy path stays authoritative.
/// * A probe failure is logged and treated as **not blocked** (fail-open). A
///   broken core must not brick legacy writes; the block decision is
///   authoritative only when the probe actually succeeds.
class LegacyWriteGuard {
  LegacyWriteGuard._();

  /// Test seam: overrides the native marker probe.
  static CoreWriteProbe? probeOverride;

  static CoreApi? _api;

  /// Binds the live core handle (called by `CoreApiFacade` at bootstrap).
  static void bind(CoreApi api) {
    _api = api;
  }

  /// Test-only: drops the bound handle and the injected probe.
  @visibleForTesting
  static void resetForTest() {
    _api = null;
    probeOverride = null;
  }

  /// Throws [LegacyWriteBlocked] when [domain] is owned by the Rust core.
  ///
  /// Call this from the public entry point of every legacy writer, before the
  /// write happens.
  static Future<void> assertAllowed(String domain) async {
    final bool blocked;
    try {
      blocked = await (probeOverride ?? _defaultProbe)(domain);
    } catch (error) {
      // Fail-open: a broken probe must not brick legacy writes.
      debugPrint('[LegacyWriteGuard] 域标记探测失败（放行旧写入）$domain: $error');
      return;
    }
    if (blocked) throw LegacyWriteBlocked(domain);
  }

  static Future<bool> _defaultProbe(String domain) async {
    final api = _api;
    if (api == null) return false;
    return (await api.coreWriteMarker(domain: domain)) != null;
  }
}

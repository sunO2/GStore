import '../core_flags.dart';
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
/// While [CoreFlags.coreWrites] is false (the default) this guard is a no-op,
/// so the old Dart paths remain authoritative.
class LegacyWriteGuard {
  LegacyWriteGuard._();

  /// Test seam: overrides the native marker probe.
  static CoreWriteProbe? probeOverride;

  static CoreApi? _api;

  static void bind(CoreApi api) {
    _api = api;
  }

  static Future<void> assertAllowed(String domain) async {
    if (!CoreFlags.coreWrites) return;
    final blocked = await (probeOverride ?? _defaultProbe)(domain);
    if (blocked) throw LegacyWriteBlocked(domain);
  }

  static Future<bool> _defaultProbe(String domain) async {
    final api = _api;
    if (api == null) return false;
    return (await api.coreWrites(domain: domain)) != null;
  }
}

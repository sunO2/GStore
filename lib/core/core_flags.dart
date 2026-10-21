import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Immutable snapshot of the Rust-owned feature flags.
///
/// Every field defaults to `false`, matching the Rust `Flags::DISABLED` default.
class CoreFlagsSnapshot {
  const CoreFlagsSnapshot({
    this.channels = false,
    this.catalog = false,
    this.update = false,
    this.download = false,
    this.install = false,
    this.jsChannel = false,
    this.coreWrites = false,
  });

  /// All flags disabled; the value before any backend read.
  static const disabled = CoreFlagsSnapshot();

  final bool channels;
  final bool catalog;
  final bool update;
  final bool download;
  final bool install;
  final bool jsChannel;
  final bool coreWrites;

  factory CoreFlagsSnapshot.fromRust(rust.Flags flags) {
    return CoreFlagsSnapshot(
      channels: flags.channels,
      catalog: flags.catalog,
      update: flags.update,
      download: flags.download,
      install: flags.install,
      jsChannel: flags.jsChannel,
      coreWrites: flags.coreWrites,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CoreFlagsSnapshot &&
        other.channels == channels &&
        other.catalog == catalog &&
        other.update == update &&
        other.download == download &&
        other.install == install &&
        other.jsChannel == jsChannel &&
        other.coreWrites == coreWrites;
  }

  @override
  int get hashCode => Object.hash(
        channels,
        catalog,
        update,
        download,
        install,
        jsChannel,
        coreWrites,
      );

  @override
  String toString() =>
      'CoreFlagsSnapshot(channels: $channels, catalog: $catalog, '
      'update: $update, download: $download, install: $install, '
      'jsChannel: $jsChannel, coreWrites: $coreWrites)';
}

/// Read/write source for [CoreFlags]. The default implementation talks to the
/// core's FRB `FlagsApi`; tests inject a fake with [CoreFlags.installBackend].
abstract class CoreFlagsBackend {
  Future<CoreFlagsSnapshot> read();

  Future<void> write(CoreFlagsSnapshot flags);
}

/// FRB-backed flag backend. The Rust core remains the source of truth.
class FrbCoreFlagsBackend implements CoreFlagsBackend {
  Future<rust.FlagsApi>? _api;

  Future<rust.FlagsApi> get _instance => _api ??= rust.FlagsApi.init();

  @override
  Future<CoreFlagsSnapshot> read() async {
    final flags = await (await _instance).get_();
    return CoreFlagsSnapshot.fromRust(flags);
  }

  @override
  Future<void> write(CoreFlagsSnapshot flags) async {
    await (await _instance).set_(
      patch: rust.FlagsPatch(
        channels: flags.channels,
        catalog: flags.catalog,
        update: flags.update,
        download: flags.download,
        install: flags.install,
        jsChannel: flags.jsChannel,
        coreWrites: flags.coreWrites,
      ),
    );
  }
}

/// Read-only Dart mirror of the Rust-owned feature flags.
///
/// Call [refresh] to pull a new snapshot from the backend. There are no public
/// flag setters: Rust owns the values, and direct assignment is a compile error.
class CoreFlags {
  CoreFlags._();

  static CoreFlagsBackend _backend = FrbCoreFlagsBackend();
  static CoreFlagsSnapshot _snapshot = CoreFlagsSnapshot.disabled;

  static bool get channels => _snapshot.channels;
  static bool get catalog => _snapshot.catalog;
  static bool get update => _snapshot.update;
  static bool get download => _snapshot.download;
  static bool get install => _snapshot.install;
  static bool get jsChannel => _snapshot.jsChannel;
  static bool get coreWrites => _snapshot.coreWrites;

  /// Current mirrored snapshot (read-only).
  static CoreFlagsSnapshot get snapshot => _snapshot;

  /// Re-reads the snapshot from the backend. Failures leave the last snapshot
  /// untouched (the mirror stays all-false before the first successful read).
  static Future<void> refresh() async {
    _snapshot = await _backend.read();
  }

  /// Replaces the backend for tests and resets the mirror to all-false.
  ///
  /// This is a test seam, not a flag setter.
  @visibleForTesting
  static void installBackend(CoreFlagsBackend backend) {
    _backend = backend;
    _snapshot = CoreFlagsSnapshot.disabled;
  }

  /// Restores the FRB backend and the all-false mirror (test teardown).
  @visibleForTesting
  static void resetBackend() {
    _backend = FrbCoreFlagsBackend();
    _snapshot = CoreFlagsSnapshot.disabled;
  }
}

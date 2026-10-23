import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Immutable snapshot of the Rust-owned feature flags.
///
/// This Dart mirror starts all-false until the first successful
/// [CoreFlags.refresh]. The Rust process default is `Flags::WAVE06B_CUTOVER`
/// (download + install true, the other five flags false); `Flags::DISABLED`
/// remains the all-off opt-out used by tests.
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

/// Partial flag update forwarded to the Rust core.
///
/// Only non-null fields are sent; an omitted (`null`) flag is left unchanged by
/// the Rust `FlagsApi`. There is deliberately no `coreWrites` field: the
/// `core_writes` projection is owned by the Rust migration marker and is never
/// operator-settable.
class CoreFlagsPatch {
  const CoreFlagsPatch({
    this.channel,
    this.catalog,
    this.update,
    this.download,
    this.install,
    this.jsChannel,
  });

  final bool? channel;
  final bool? catalog;
  final bool? update;
  final bool? download;
  final bool? install;
  final bool? jsChannel;

  /// Whether this patch carries no change (an all-null call).
  bool get isEmpty =>
      channel == null &&
      catalog == null &&
      update == null &&
      download == null &&
      install == null &&
      jsChannel == null;

  @override
  String toString() => 'CoreFlagsPatch(channel: $channel, catalog: $catalog, '
      'update: $update, download: $download, install: $install, '
      'jsChannel: $jsChannel)';
}

/// Read/write source for [CoreFlags]. The default implementation talks to the
/// core's FRB `FlagsApi`; tests inject a fake with [CoreFlags.installBackend].
abstract class CoreFlagsBackend {
  Future<CoreFlagsSnapshot> read();

  /// Applies [patch]. Implementations must forward only the supplied fields so
  /// the Rust core keeps every omitted flag unchanged.
  Future<void> write(CoreFlagsPatch patch);
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
  Future<void> write(CoreFlagsPatch patch) async {
    await (await _instance).set_(patch: toRustPatch(patch));
  }

  /// Maps a partial Dart patch onto the FRB wire type. Only the supplied fields
  /// are forwarded; passing `false` for an omitted flag is the wire-level stomp
  /// this type exists to prevent, and `coreWrites` is always left to Rust.
  @visibleForTesting
  static rust.FlagsPatch toRustPatch(CoreFlagsPatch patch) => rust.FlagsPatch(
        channels: patch.channel,
        catalog: patch.catalog,
        update: patch.update,
        download: patch.download,
        install: patch.install,
        jsChannel: patch.jsChannel,
        coreWrites: null,
      );
}

/// Dart mirror of the Rust-owned feature flags.
///
/// The Rust process default is `Flags::WAVE06B_CUTOVER` (download + install
/// true, the other five flags false); `Flags::DISABLED` / `Default` remain the
/// all-off opt-out. Call [refresh] to pull a new snapshot from the backend.
///
/// [set] is the **only** partial-flip path: it forwards a *partial* patch (only
/// the supplied flags) and then refreshes. Rust remains the source of truth and
/// validates every value; the `coreWrites` projection is never operator-
/// settable (the patch type has no such field). Direct field assignment is a
/// compile error.
///
/// Reads and writes are serialized in call order, so a [refresh] issued while
/// a [set] is in flight cannot install a stale snapshot.
class CoreFlags {
  CoreFlags._();

  static CoreFlagsBackend _backend = FrbCoreFlagsBackend();
  static CoreFlagsSnapshot _snapshot = CoreFlagsSnapshot.disabled;

  /// Tail of the serialized operation queue. Each operation runs after the
  /// previous one settles (success or failure).
  static Future<void> _queue = Future<void>.value();

  static Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

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
  static Future<void> refresh() => _serialize(() async {
        _snapshot = await _backend.read();
      });

  /// Applies a partial flip and returns the refreshed snapshot.
  ///
  /// This is the only partial-flip path; there is no whole-snapshot setter.
  /// Only the non-null arguments are forwarded; every omitted flag is left
  /// untouched by Rust (they are sent as `null`, never `false`). An all-null
  /// call writes nothing and only performs a [refresh]. `coreWrites` is never
  /// part of the patch.
  ///
  /// Concurrent calls are serialized: the last enqueued write wins and the
  /// mirror always reflects the write-then-read pair of each call. A backend
  /// write failure surfaces to the caller and leaves the mirror unchanged.
  static Future<CoreFlagsSnapshot> set({
    bool? channel,
    bool? catalog,
    bool? update,
    bool? download,
    bool? install,
    bool? jsChannel,
  }) {
    final patch = CoreFlagsPatch(
      channel: channel,
      catalog: catalog,
      update: update,
      download: download,
      install: install,
      jsChannel: jsChannel,
    );
    return _serialize(() async {
      if (!patch.isEmpty) {
        await _backend.write(patch);
      }
      _snapshot = await _backend.read();
      return _snapshot;
    });
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

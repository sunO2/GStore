import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:gstore/core/rust/ModuleManager.dart' show RustModuleManager;
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;

/// The download module's push lane on the host module-event bus.
///
/// The download kernel does **not** run inside the host `start_task` context, so
/// it publishes progress/terminal state through `emit_event` on the broadcast
/// bus (see `rust/gstore_mod_download/src/lib.rs`: `download.progress` /
/// `download.done`, payload JSON carrying `taskId`). This class is the typed
/// gate onto that lane — the `lib/core/download` layer depends on it and never
/// touches [RustModuleManager] directly (enforced by the
/// `rust_download_service_gate_test` source gate). It mirrors the established
/// `lib/core/rust/proxy` and `lib/core/rust/perf` module gateways.
class DownloadEventSource {
  DownloadEventSource._();

  /// Per-task progress tick (throttled by the scheduler). Payload keys:
  /// `taskId`, `status`, `total`, `received`, `speedBps`, `etaSec`,
  /// and (when changed) `segments`.
  static const String progressType = 'download.progress';

  /// Per-task terminal snapshot (completed/failed/cancelled/paused). Payload is
  /// the full module `TaskDto` (`id`, `status`, `total`, `received`, ...).
  static const String doneType = 'download.done';

  /// Live download events only. Other modules' events never cross this lane.
  static Stream<ModuleEvent> get events =>
      RustModuleManager.instance.moduleEvents.where(_isDownloadEvent);

  static bool _isDownloadEvent(ModuleEvent event) =>
      event.eventType == progressType || event.eventType == doneType;

  /// Test seam: lets a suite substitute a synthetic lane.
  @visibleForTesting
  static Stream<ModuleEvent> Function() override = () => events;
}

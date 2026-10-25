import 'dart:async';
import 'dart:convert';

import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;

/// Push-driven download task updates.
///
/// Replaces the removed 500 ms core poll (`DownloadApi::watch_all`): live updates
/// come from the download module's own `emit_event` lane (`download.progress` /
/// `download.done`, payload carries `taskId`), demultiplexed per task. The
/// authoritative core row is consulted exactly twice — never per tick:
///
///  * **seed** — one `loadAll()` on subscribe, so every consumer starts from the
///    authoritative list and the payload (which lacks metadata like `appId`) can
///    be merged onto a full task;
///  * **safety net** — a slow `safetyInterval` reconcile that runs **only while a
///    task is active**, covering a missed/omitted event (e.g. a queued task
///    cancelled without a terminal emit).
///
/// There is no second source: this stream never touches the facade poll stream,
/// so a tick can never be delivered twice.
class DownloadPushStream {
  DownloadPushStream({
    required Stream<ModuleEvent> lane,
    required Future<List<DownloadTask>> Function() loadAll,
    required Future<DownloadTask?> Function(int id) fetchOne,
    Duration safetyInterval = const Duration(seconds: 4),
  })  : _lane = lane,
        _loadAll = loadAll,
        _fetchOne = fetchOne,
        _safetyInterval = safetyInterval;

  final Stream<ModuleEvent> _lane;
  final Future<List<DownloadTask>> Function() _loadAll;
  final Future<DownloadTask?> Function(int id) _fetchOne;
  final Duration _safetyInterval;

  static const String progressType = 'download.progress';
  static const String doneType = 'download.done';

  final Map<int, DownloadTask> _cache = <int, DownloadTask>{};
  final Map<int, DownloadTask> _emitted = <int, DownloadTask>{};

  late StreamController<DownloadTask> _out;
  StreamSubscription<ModuleEvent>? _laneSub;
  Timer? _safety;

  /// The single update stream for one subscription.
  Stream<DownloadTask> tasks() async* {
    _out = StreamController<DownloadTask>();
    try {
      // 1. Authoritative seed (one full read; not a poll).
      try {
        for (final task in await _loadAll()) {
          _emit(task);
        }
      } catch (error, stack) {
        if (!_out.isClosed) _out.addError(error, stack);
      }
      _armSafetyNet();

      // 2. Push lane — the only live source.
      _laneSub = _lane.listen(
        (event) => unawaited(_onEvent(event)),
        onError: (Object error, StackTrace stack) {
          if (!_out.isClosed) _out.addError(error, stack);
        },
      );

      yield* _out.stream;
    } finally {
      await _laneSub?.cancel();
      _laneSub = null;
      _safety?.cancel();
      _safety = null;
      if (!_out.isClosed) await _out.close();
    }
  }

  Future<void> _onEvent(ModuleEvent event) async {
    final parsed = _parse(event);
    if (parsed == null) return;
    var base = _cache[parsed.id];
    if (base == null) {
      try {
        base = await _fetchOne(parsed.id);
      } catch (_) {
        base = null;
      }
      if (base == null) return;
    }
    _emit(_merge(base, parsed));
  }

  void _emit(DownloadTask task) {
    final id = task.id;
    if (id == null) return;
    final previous = _emitted[id];
    if (previous != null && _sameVisible(previous, task)) return;
    _emitted[id] = task;
    _cache[id] = task;
    if (!_out.isClosed) _out.add(task);
    if (task.isActive) _armSafetyNet();
  }

  void _armSafetyNet() {
    if (_safety != null) return;
    _safety = Timer.periodic(_safetyInterval, (_) {
      if (!_hasActive) {
        _safety?.cancel();
        _safety = null;
        return;
      }
      unawaited(_safetyReconcile());
    });
  }

  bool get _hasActive => _cache.values.any((task) => task.isActive);

  Future<void> _safetyReconcile() async {
    try {
      for (final task in await _loadAll()) {
        _emit(task);
      }
    } catch (_) {
      // Best-effort: a failed safety sweep must never kill the stream.
    }
  }

  _DownloadEvent? _parse(ModuleEvent event) {
    if (event.eventType != progressType && event.eventType != doneType) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(event.data));
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final id = _asInt(decoded['taskId']) ?? _asInt(decoded['id']);
    final rawStatus = _asInt(decoded['status']);
    if (id == null ||
        rawStatus == null ||
        rawStatus < 0 ||
        rawStatus >= DownloadStatusEnum.values.length) {
      return null;
    }
    return _DownloadEvent(
      id: id,
      status: DownloadStatusEnum.values[rawStatus],
      total: _asInt(decoded['total']),
      received: _asInt(decoded['received']),
      speedBps: _asInt(decoded['speedBps']),
      etaSec: _asInt(decoded['etaSec']),
      hasError: decoded.containsKey('error'),
      error: decoded['error'] as String?,
      hasSegments: decoded.containsKey('segments'),
      segments: _parseSegments(decoded['segments']),
    );
  }

  DownloadTask _merge(DownloadTask base, _DownloadEvent event) => DownloadTask(
        id: base.id,
        appId: base.appId,
        appName: base.appName,
        version: base.version,
        fileName: base.fileName,
        url: base.url,
        filePath: base.filePath,
        total: event.total ?? base.total,
        received: event.received ?? base.received,
        status: event.status,
        speedBps: event.speedBps ?? base.speedBps,
        etaSec: event.etaSec,
        error: event.hasError ? event.error : base.error,
        segments: event.hasSegments ? event.segments : base.segments,
        headers: base.headers,
        installAfterDownload: base.installAfterDownload,
        lastStartedAt: base.lastStartedAt,
        createdAt: base.createdAt,
        updatedAt: DateTime.now(),
      );
}

/// Parsed push payload (progress event or terminal `TaskDto` share these keys).
class _DownloadEvent {
  const _DownloadEvent({
    required this.id,
    required this.status,
    required this.total,
    required this.received,
    required this.speedBps,
    required this.etaSec,
    required this.hasError,
    required this.error,
    required this.hasSegments,
    required this.segments,
  });

  final int id;
  final DownloadStatusEnum status;
  final int? total;
  final int? received;
  final int? speedBps;
  final int? etaSec;
  final bool hasError;
  final String? error;
  final bool hasSegments;
  final List<SegmentInfo>? segments;
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  return int.tryParse('$value');
}

List<SegmentInfo>? _parseSegments(Object? raw) {
  if (raw is! List) return null;
  final out = <SegmentInfo>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final map = entry.cast<String, dynamic>();
    final index = _asInt(map['index']);
    final start = _asInt(map['startByte']);
    final end = _asInt(map['endByte']);
    if (index == null || start == null || end == null) continue;
    out.add(SegmentInfo(
      index: index,
      startByte: start,
      endByte: end,
      received: _asInt(map['received']) ?? 0,
    ));
  }
  return out;
}

bool _sameVisible(DownloadTask a, DownloadTask b) =>
    a.received == b.received &&
    a.total == b.total &&
    a.status == b.status &&
    a.speedBps == b.speedBps &&
    a.etaSec == b.etaSec &&
    a.error == b.error &&
    _sameSegments(a.segments, b.segments);

bool _sameSegments(List<SegmentInfo>? a, List<SegmentInfo>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x.index != y.index ||
        x.startByte != y.startByte ||
        x.endByte != y.endByte ||
        x.received != y.received) {
      return false;
    }
  }
  return true;
}

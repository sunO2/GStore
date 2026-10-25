/// Unit tests for the push-driven download update source (task 258).
///
/// The 500 ms core poll is replaced by the download module's own `emit_event`
/// lane; these tests exercise `DownloadPushStream` directly (seed, progress
/// merge, terminal, live segments, slow safety net, dedupe). The failing-first
/// end-to-end proof lives in `download_push_wiring_test.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/download_push_stream.dart';
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;

ModuleEvent _evt(String type, Map<String, dynamic> payload) => ModuleEvent(
      moduleId: BigInt.one,
      instanceId: BigInt.one,
      eventType: type,
      data: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      timestampMs: 0,
    );

ModuleEvent _progress(int id, int received,
        {int total = 1000,
        int speedBps = 2048,
        int? etaSec = 5,
        List<Map<String, dynamic>>? segments}) =>
    _evt('download.progress', {
      'taskId': id,
      'status': 2,
      'total': total,
      'received': received,
      'speedBps': speedBps,
      'etaSec': etaSec,
      if (segments != null) 'segments': segments,
    });

ModuleEvent _done(int id, int status) => _evt('download.done', {
      'id': id,
      'status': status,
      'total': 1000,
      'received': 1000,
      'speedBps': 0,
      'etaSec': null,
      'error': null,
      'segments': const <Map<String, dynamic>>[],
    });

DownloadTask _task(
  int id, {
  int received = 0,
  int total = 1000,
  DownloadStatusEnum status = DownloadStatusEnum.downloading,
}) =>
    DownloadTask(
      id: id,
      appId: 'com.example.app',
      appName: '示例',
      version: '1.0.0',
      fileName: 'app.apk',
      url: 'https://example.test/app.apk',
      filePath: '/tmp/app.apk',
      total: total,
      received: received,
      status: status,
      speedBps: 0,
      etaSec: null,
      error: null,
      segments: null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );

void main() {
  group('DownloadPushStream (unit)', () {
    test('seeds once, then applies pushed progress (no per-tick loadAll)',
        () async {
      final lane = StreamController<ModuleEvent>.broadcast();
      addTearDown(lane.close);
      var loadAllCalls = 0;
      final got = <DownloadTask>[];
      final sub = DownloadPushStream(
        lane: lane.stream,
        loadAll: () async {
          loadAllCalls++;
          return <DownloadTask>[_task(1)];
        },
        fetchOne: (id) async => _task(1),
        safetyInterval: const Duration(hours: 1),
      ).tasks().listen(got.add);

      await pumpEventQueue();
      expect(got, hasLength(1));
      expect(got.single.received, 0);

      lane.add(_progress(1, 250));
      await pumpEventQueue();

      expect(got, hasLength(2), reason: 'one pushed tick → one update');
      expect(got.last.received, 250);
      expect(got.last.speedBps, 2048);
      expect(got.last.status, DownloadStatusEnum.downloading);
      expect(loadAllCalls, 1,
          reason: 'only the subscribe-time seed reads the full list');

      await sub.cancel();
    });

    test('a terminal event still marks the task terminal', () async {
      final lane = StreamController<ModuleEvent>.broadcast();
      addTearDown(lane.close);
      final got = <DownloadTask>[];
      final sub = DownloadPushStream(
        lane: lane.stream,
        loadAll: () async => <DownloadTask>[_task(1)],
        fetchOne: (id) async => _task(1),
        safetyInterval: const Duration(hours: 1),
      ).tasks().listen(got.add);
      await pumpEventQueue();

      lane.add(_done(1, DownloadStatusEnum.completed.index));
      await pumpEventQueue();

      expect(got.last.status, DownloadStatusEnum.completed);
      expect(got.last.received, 1000);
      await sub.cancel();
    });

    test('live segments from a progress event reach the task', () async {
      final lane = StreamController<ModuleEvent>.broadcast();
      addTearDown(lane.close);
      final got = <DownloadTask>[];
      final sub = DownloadPushStream(
        lane: lane.stream,
        loadAll: () async => <DownloadTask>[_task(1)],
        fetchOne: (id) async => _task(1),
        safetyInterval: const Duration(hours: 1),
      ).tasks().listen(got.add);
      await pumpEventQueue();

      lane.add(_progress(1, 250, segments: [
        {
          'index': 0,
          'startByte': 0,
          'endByte': 499,
          'received': 250,
        }
      ]));
      await pumpEventQueue();

      expect(got.last.segments, hasLength(1));
      expect(got.last.segments!.single.received, 250);
      await sub.cancel();
    });

    test('the slow safety net reconciles a missed event while active',
        () async {
      final lane = StreamController<ModuleEvent>.broadcast();
      addTearDown(lane.close);
      var current = _task(1, received: 0);
      final got = <DownloadTask>[];
      final sub = DownloadPushStream(
        lane: lane.stream,
        loadAll: () async => <DownloadTask>[current],
        fetchOne: (id) async => current,
        safetyInterval: const Duration(milliseconds: 30),
      ).tasks().listen(got.add);
      await pumpEventQueue();
      expect(got.last.received, 0);

      // The task advances, but its event is never pushed (missed).
      current = _task(1, received: 777);
      await Future<void>.delayed(const Duration(milliseconds: 140));

      expect(got.last.received, 777,
          reason: 'the safety net must reconcile an event that never arrived');
      await sub.cancel();
    });

    test('the same tick is never emitted twice (push + safety net dedupe)',
        () async {
      final lane = StreamController<ModuleEvent>.broadcast();
      addTearDown(lane.close);
      final got = <DownloadTask>[];
      final sub = DownloadPushStream(
        lane: lane.stream,
        loadAll: () async => <DownloadTask>[_task(1, received: 250)],
        fetchOne: (id) async => _task(1),
        safetyInterval: const Duration(milliseconds: 25),
      ).tasks().listen(got.add);
      await pumpEventQueue();
      final afterSeed = got.length;

      lane.add(_progress(1, 250, speedBps: 0, etaSec: null)); // same as seed
      await pumpEventQueue();
      expect(got.length, afterSeed,
          reason: 'an unchanged pushed tick must not re-emit');

      lane.add(_progress(1, 250, speedBps: 0, etaSec: null)); // duplicate tick
      await pumpEventQueue();
      expect(got.length, afterSeed,
          reason: 'a duplicated tick must not emit twice');

      // Safety-net reconcile returning the same state must not re-emit either.
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(got.length, afterSeed);
      await sub.cancel();
    });
  });
}

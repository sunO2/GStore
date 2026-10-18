import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/perf_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('perf_history_store_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  PerfHistoryStore makeStore({int capacity = kPerfHistoryStoreCapacity}) =>
      PerfHistoryStore(directoryProvider: () async => tempDir, capacity: capacity);

  test('save/load 往返（全部序列）', () async {
    final store = makeStore();
    await store.save(const PerfHistorySnapshot(
      fps: <double>[60, 59],
      cpu: <double>[10, 20],
      memory: <double>[50, 51],
      thermal: <double>[40, 41],
      thirdPartyCpu: <double>[5, 6],
      thirdPartyMem: <double>[100, 101],
      thirdPartyJank: <double>[1, 2],
    ));
    final loaded = await store.load();
    expect(loaded.fps, <double>[60, 59]);
    expect(loaded.cpu, <double>[10, 20]);
    expect(loaded.memory, <double>[50, 51]);
    expect(loaded.thermal, <double>[40, 41]);
    expect(loaded.thirdPartyCpu, <double>[5, 6]);
    expect(loaded.thirdPartyMem, <double>[100, 101]);
    expect(loaded.thirdPartyJank, <double>[1, 2]);
    expect(File('${tempDir.path}/perf_history.json').existsSync(), isTrue);
  });

  test('无文件时 load 返回空快照（不抛）', () async {
    final loaded = await makeStore().load();
    expect(loaded.isEmpty, isTrue);
  });

  test('损坏 JSON 时 load 返回空快照（静默）', () async {
    File('${tempDir.path}/perf_history.json').writeAsStringSync('{not json');
    final loaded = await makeStore().load();
    expect(loaded.isEmpty, isTrue);
  });

  test('保存与读取均裁剪到容量上限，保留最新值', () async {
    final store = makeStore(capacity: 3);
    await store.save(const PerfHistorySnapshot(fps: <double>[1, 2, 3, 4, 5]));
    final loaded = await store.load();
    expect(loaded.fps, <double>[3, 4, 5]);
  });

  test('非有限值在保存时被过滤', () async {
    final store = makeStore();
    await store.save(const PerfHistorySnapshot(
      cpu: <double>[1, double.nan, 2, double.infinity],
    ));
    final loaded = await store.load();
    expect(loaded.cpu, <double>[1, 2]);
  });

  test('容量下限：超过上限的持久化文件读取后被裁剪', () async {
    final store = makeStore(capacity: 2);
    File('${tempDir.path}/perf_history.json').writeAsStringSync(
      '{"fps":[1,2,3,4],"cpu":[],"memory":[],"thermal":[]}',
    );
    final loaded = await store.load();
    expect(loaded.fps, <double>[3, 4]);
  });
}

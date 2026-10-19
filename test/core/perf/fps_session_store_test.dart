import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/fps_session.dart';
import 'package:gstore/core/perf/fps_session_store.dart';

/// 便捷构造：以 [startMs] 派生 id，含 1 个样本。
FpsSession _session(
  int startMs, {
  String? id,
  String label = 'L',
  List<double> samples = const <double>[60],
}) =>
    FpsSession.fromRecording(
      id: id ?? 'id_$startMs',
      label: label,
      startMs: startMs,
      endMs: startMs + 1000,
      samples: samples,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InMemoryFpsSessionStore', () {
    test('append/load 新→旧；delete；clear', () async {
      final store = InMemoryFpsSessionStore();
      await store.append(_session(1000));
      await store.append(_session(2000));

      var list = await store.load();
      expect(list.map((s) => s.id).toList(), <String>['id_2000', 'id_1000']);

      expect(await store.delete('id_1000'), isTrue);
      list = await store.load();
      expect(list.map((s) => s.id).toList(), <String>['id_2000']);

      // 删除不存在的 id 也返回 true（幂等）。
      expect(await store.delete('missing'), isTrue);

      await store.clear();
      expect(await store.load(), isEmpty);
    });

    test('容量裁剪最旧（保留最新）', () async {
      final store = InMemoryFpsSessionStore(capacity: 2);
      await store.append(_session(1000));
      await store.append(_session(2000));
      await store.append(_session(3000));
      final list = await store.load();
      expect(list.map((s) => s.id).toList(), <String>['id_3000', 'id_2000']);
    });

    test('save 覆盖写入并排序', () async {
      final store = InMemoryFpsSessionStore();
      await store.save(<FpsSession>[_session(500), _session(100)]);
      final list = await store.load();
      expect(list.map((s) => s.id).toList(), <String>['id_500', 'id_100']);
    });
  });

  group('SharedPrefsFpsSessionStore', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('跨实例往返 + 容量裁剪', () async {
      const store = SharedPrefsFpsSessionStore(capacity: 2);
      await store.append(_session(1000, samples: const <double>[60, 30]));
      await store.append(_session(2000));
      await store.append(_session(3000));

      const store2 = SharedPrefsFpsSessionStore(capacity: 2);
      final list = await store2.load();
      expect(list.map((s) => s.id).toList(), <String>['id_3000', 'id_2000']);
      expect(list.last.samples, <double>[60]);
    });

    test('损坏 JSON 静默降级为空列表', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fps_sessions': '{not json',
      });
      final list = await const SharedPrefsFpsSessionStore().load();
      expect(list, isEmpty);
    });

    test('delete / clear', () async {
      const store = SharedPrefsFpsSessionStore();
      await store.append(_session(1000));
      await store.append(_session(2000));

      expect(await store.delete('id_1000'), isTrue);
      expect(
        (await store.load()).map((s) => s.id).toList(),
        <String>['id_2000'],
      );

      await store.clear();
      expect(await store.load(), isEmpty);
    });

    test('列表内损坏条目被跳过，其余正常读取', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fps_sessions': '[{"id":"ok","label":"L","start_ms":5,"end_ms":6,'
            '"samples":[60]}, 42, {"id":"ok2","label":"M","start_ms":7,'
            '"end_ms":8,"samples":[30]}]',
      });
      final list = await const SharedPrefsFpsSessionStore().load();
      expect(list.map((s) => s.id).toSet(), <String>{'ok', 'ok2'});
    });
  });
}

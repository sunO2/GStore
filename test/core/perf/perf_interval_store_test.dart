import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gstore/core/perf/perf_interval_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPrefsPerfIntervalStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('无记录 → null（保持默认间隔）', () async {
      const store = SharedPrefsPerfIntervalStore();
      expect(await store.load(), isNull);
    });

    test('save → load 往返恢复', () async {
      const store = SharedPrefsPerfIntervalStore();
      await store.save(5);
      expect(await store.load(), 5);
      await store.save(10);
      expect(await store.load(), 10);
    });

    test('读取既有值（模拟跨启动恢复）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SharedPrefsPerfIntervalStore.storageKey: 5,
      });
      const store = SharedPrefsPerfIntervalStore();
      expect(await store.load(), 5);
    });
  });

  group('InMemoryPerfIntervalStore', () {
    test('可预置且 save → load 往返', () async {
      final store = InMemoryPerfIntervalStore();
      expect(await store.load(), isNull);
      await store.save(1);
      expect(await store.load(), 1);

      final seeded = InMemoryPerfIntervalStore(5);
      expect(await seeded.load(), 5);
    });
  });
}

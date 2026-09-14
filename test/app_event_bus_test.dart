import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/event/app_event.dart';
import 'package:gstore/core/event/app_event_bus_bootstrap.dart';
import 'package:gstore/core/event/database_event.dart';

void main() {
  setUp(() => AppEventBus.instance.resetGuards());

  group('AppEventBus 核心', () {
    test('按类型订阅与过滤', () async {
      final bus = AppEventBus.instance;
      final got = <AppEvent>[];
      final sub = bus.on('test.a', got.add);

      bus.emit('test.a', data: {'x': 1});
      bus.emit('test.b');
      await Future<void>.delayed(Duration.zero);

      expect(got, hasLength(1));
      expect(got.first.data?['x'], 1);
      await sub.cancel();
    });

    test('downlink 事件只回调已注册的 sink', () async {
      final bus = AppEventBus.instance;
      final down = <AppEvent>[];
      bus.registerDownlinkSink(down.add);
      addTearDown(() => bus.registerDownlinkSink(null));

      bus.emit('test.dl', downlink: true);
      bus.emit('test.nodl');
      await Future<void>.delayed(Duration.zero);

      expect(down, hasLength(1));
      expect(down.first.type, 'test.dl');
    });

    test('configEvents 按 key 过滤', () async {
      final bus = AppEventBus.instance;
      final got = <AppEvent>[];
      final sub = bus.configEvents(['k1']).listen(got.add);

      bus.emit(AppEventTypes.configChanged, data: {'key': 'k1'});
      bus.emit(AppEventTypes.configChanged, data: {'key': 'k2'});
      await Future<void>.delayed(Duration.zero);

      expect(got, hasLength(1));
      expect(got.first.data?['key'], 'k1');
      await sub.cancel();
    });
  });

  group('AppEventBus 护栏（去重/限流/防回环）', () {
    test('相同 type+payload 在窗口内去重', () async {
      final bus = AppEventBus.instance;
      bus.dedupWindow = const Duration(seconds: 5);
      final got = <AppEvent>[];
      final sub = bus.on('test.dedup', got.add);

      bus.emit('test.dedup', data: {'k': 1});
      bus.emit('test.dedup', data: {'k': 1});
      await Future<void>.delayed(Duration.zero);

      expect(got, hasLength(1), reason: '重复事件应被去重');
      expect(bus.droppedDuplicate, 1);
      await sub.cancel();
    });

    test('类型限流丢弃窗口内重复', () async {
      final bus = AppEventBus.instance;
      bus.throttleType('test.throttle', const Duration(seconds: 10));
      final got = <AppEvent>[];
      final sub = bus.on('test.throttle', got.add);

      bus.emit('test.throttle', data: {'n': 1});
      bus.emit('test.throttle', data: {'n': 2}); // 不同 payload 也应被限流
      await Future<void>.delayed(Duration.zero);

      expect(got, hasLength(1));
      expect(bus.droppedThrottled, 1);
      await sub.cancel();
    });

    test('同步回环被深度护栏截断（不栈溢出）', () async {
      final bus = AppEventBus.instance;
      var calls = 0;
      bus.registerDownlinkSink((e) {
        calls++;
        // 每次 payload 不同（避开去重），验证深度护栏生效
        bus.emit('test.loop', data: {'n': calls}, downlink: true);
      });
      addTearDown(() => bus.registerDownlinkSink(null));

      bus.emit('test.loop', data: {'n': 0}, downlink: true);

      expect(calls, lessThanOrEqualTo(bus.maxDispatchDepth));
      expect(bus.droppedLoop, greaterThan(0), reason: '回环应被深度护栏截断');
    });
  });

  group('AppEventBusBootstrap 适配', () {
    setUp(() => AppEventBusBootstrap.initialize());
    tearDown(() async => AppEventBusBootstrap.dispose());

    test('DatabaseEventBus → AppEventBus(db.changed)', () async {
      final got = <AppEvent>[];
      final sub = AppEventBus.instance.on(AppEventTypes.dbChanged, got.add);

      DatabaseEventBus.instance
          .send(const DatabaseChangeEvent(type: DatabaseChangeType.appAdded));
      await Future<void>.delayed(Duration.zero);

      expect(got, hasLength(1));
      expect(got.first.source, AppEventSource.database);
      expect(got.first.data?['type'], 'appAdded');
      await sub.cancel();
    });

    test('ConfigService.onChange → AppEventBus(config.changed, downlink)', () async {
      // 内存配置存储 + 注册一个 key
      ConfigStore.instance.resetForTest();
      await ConfigStore.instance.initialize(storages: [MemoryConfigStorage()]);
      ConfigService.instance.register(
        const ConfigEntry(key: 'evt_test_key', type: ConfigValueType.string),
      );

      final got = <AppEvent>[];
      final sub = AppEventBus.instance.on(AppEventTypes.configChanged, got.add);

      await ConfigService.instance.set(
        'evt_test_key',
        'v',
        source: ConfigChangeSource.user,
      );
      await Future<void>.delayed(Duration.zero);

      final hit = got.where((e) => e.data?['key'] == 'evt_test_key');
      expect(hit, isNotEmpty, reason: '配置写入应经适配进入统一总线');
      expect(hit.first.downlink, isTrue, reason: '配置变化应标记为可下行');
      await sub.cancel();
    });

    test('主题变化 → AppEventBus(theme.changed, downlink)', () async {
      ConfigStore.instance.resetForTest();
      await ConfigStore.instance.initialize(storages: [MemoryConfigStorage()]);
      ConfigService.instance.register(
        const ConfigEntry(key: ConfigKeys.themeMode, type: ConfigValueType.int),
      );

      final got = <AppEvent>[];
      final sub = AppEventBus.instance.on(AppEventTypes.themeChanged, got.add);

      await ConfigService.instance.set(
        ConfigKeys.themeMode,
        1,
        source: ConfigChangeSource.user,
      );
      await Future<void>.delayed(Duration.zero);

      expect(got, hasLength(1));
      expect(got.first.downlink, isTrue);
      expect(got.first.data?['key'], ConfigKeys.themeMode);
      await sub.cancel();
    });
  });
}

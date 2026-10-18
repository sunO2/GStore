import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/perf/perf_profile.dart';
import 'package:gstore/core/perf/perf_profile_store.dart';

/// 统一初始化：全部使用内存存储（避免插件依赖），并注册内置配置。
Future<void> initForTest() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
  ConfigRegistry.registerAll(ConfigService.instance);
}

PerfProfile _profile(String pkg, {bool enabled = true, int? gpuLevel}) {
  return PerfProfile(
    package: pkg,
    enabled: enabled,
    cpuClusters: const <String, PerfCpuClusterProfile>{
      'policy0': PerfCpuClusterProfile(governor: 'schedutil', maxFreqMhz: 1800),
    },
    gpuLevel: gpuLevel,
    cpuset: 'top-app',
    thermalEnabled: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initForTest();
  });

  group('配置键注册（决定：走注册表路径）', () {
    test('perf.profiles 已注册为 json 类型且默认空 map', () {
      final entry = ConfigService.instance.entry(ConfigKeys.perfProfiles);
      expect(entry, isNotNull);
      expect(entry!.type, ConfigValueType.json);
      expect(entry.defaultValue, <String, dynamic>{});
      expect(entry.agentAccessible, isFalse);
      expect(entry.sensitive, isFalse);
    });

    test('未设置时经 ConfigService 读取为 null（store 层再降级为空）', () async {
      await initForTest();
      expect(
        await ConfigService.instance.getRaw(ConfigKeys.perfProfiles),
        isNull,
      );
    });
  });

  group('decodePerfProfiles（纯函数，绝不抛）', () {
    test('null / 非 Map / 非法 JSON / 空串 → 空 map', () {
      expect(decodePerfProfiles(null), isEmpty);
      expect(decodePerfProfiles(42), isEmpty);
      expect(decodePerfProfiles(true), isEmpty);
      expect(decodePerfProfiles(''), isEmpty);
      expect(decodePerfProfiles('   '), isEmpty);
      expect(decodePerfProfiles('not-json'), isEmpty);
      expect(decodePerfProfiles('[1,2,3]'), isEmpty);
      expect(decodePerfProfiles(<dynamic>[1, 2]), isEmpty);
    });

    test('合法 JSON 字符串解析', () {
      final decoded = decodePerfProfiles(
        '{"com.a":{"package":"com.a","enabled":true,"gpu_level":2}}',
      );
      expect(decoded.keys, <String>['com.a']);
      expect(decoded['com.a']!.enabled, isTrue);
      expect(decoded['com.a']!.gpuLevel, 2);
    });

    test('缺 package 字段 → 以 map 键归一', () {
      final decoded = decodePerfProfiles(<String, dynamic>{
        'com.x': <String, dynamic>{'enabled': true},
      });
      expect(decoded['com.x']!.package, 'com.x');
    });

    test('部分损坏 map：坏条目跳过，好条目保留', () {
      final decoded = decodePerfProfiles(<String, dynamic>{
        'com.good': <String, dynamic>{'enabled': true},
        'com.bad': 'not-a-map',
        'com.num': 7,
        '': <String, dynamic>{'enabled': true},
      });
      expect(decoded.keys, <String>['com.good']);
      expect(decoded['com.good']!.enabled, isTrue);
    });

    test('encodePerfProfiles 省略空包并产出 JSON map', () {
      final encoded = encodePerfProfiles(<String, PerfProfile>{
        'com.a': _profile('com.a'),
        '': const PerfProfile(package: ''),
      });
      expect(encoded.keys, <String>['com.a']);
      expect(encoded['com.a'], isA<Map<String, dynamic>>());
    });
  });

  group('ConfigPerfProfileStore', () {
    test('happy: saveAll → loadAll 往返相等', () async {
      const store = ConfigPerfProfileStore();
      final profiles = <String, PerfProfile>{
        'com.a': _profile('com.a', gpuLevel: 1),
        'com.b': _profile('com.b', enabled: false),
      };
      expect(await store.saveAll(profiles), isTrue);

      final loaded = await store.loadAll();
      expect(loaded, profiles);
      expect(loaded['com.a']!.gpuLevel, 1);
      expect(
        loaded['com.a']!.cpuClusters['policy0']!.governor,
        'schedutil',
      );
      expect(loaded['com.b']!.enabled, isFalse);
      expect(loaded['com.a']!.thermalEnabled, isFalse);
    });

    test('save / load 单个 + 覆盖更新', () async {
      const store = ConfigPerfProfileStore();
      expect(await store.load('com.a'), isNull);

      expect(await store.save(_profile('com.a', gpuLevel: 1)), isTrue);
      expect((await store.load('com.a'))!.gpuLevel, 1);

      // 覆盖
      expect(await store.save(_profile('com.a', gpuLevel: 3)), isTrue);
      expect((await store.load('com.a'))!.gpuLevel, 3);
      expect((await store.loadAll()).length, 1);
    });

    test('空包名 save → false 且不写入', () async {
      const store = ConfigPerfProfileStore();
      expect(await store.save(const PerfProfile(package: '')), isFalse);
      expect(await store.loadAll(), isEmpty);
    });

    test('remove 删除单个；不存在视为成功', () async {
      const store = ConfigPerfProfileStore();
      await store.saveAll(<String, PerfProfile>{
        'com.a': _profile('com.a'),
        'com.b': _profile('com.b'),
      });
      expect(await store.remove('com.a'), isTrue);
      expect((await store.loadAll()).keys, <String>['com.b']);
      expect(await store.remove('com.missing'), isTrue);
    });

    test('clear 清空全部', () async {
      const store = ConfigPerfProfileStore();
      await store.saveAll(<String, PerfProfile>{'com.a': _profile('com.a')});
      expect(await store.clear(), isTrue);
      expect(await store.loadAll(), isEmpty);
    });

    test('failure: 损坏 JSON 字符串 → 空 map 且不抛', () async {
      const store = ConfigPerfProfileStore();
      // 直接向底层写入非法 JSON 串（模拟存储被外部写坏）
      await ConfigStore.instance.write(ConfigKeys.perfProfiles, '{not json');
      final loaded = await store.loadAll();
      expect(loaded, isEmpty);
    });

    test('failure: 部分损坏 map → best-effort 解码不抛', () async {
      const store = ConfigPerfProfileStore();
      await ConfigStore.instance.write(ConfigKeys.perfProfiles, <String, dynamic>{
        'com.good': <String, dynamic>{'enabled': true},
        'com.bad': 'oops',
        'com.num': 7,
      });
      final loaded = await store.loadAll();
      expect(loaded.keys, <String>['com.good']);
      expect(loaded['com.good']!.enabled, isTrue);
      expect(loaded['com.good']!.package, 'com.good');
    });

    test('failure: 存储层抛异常 → 空 map（不冒泡）', () async {
      // 未初始化的 ConfigStore 会在 _store 上抛 StateError；store 必须吞掉。
      ConfigStore.instance.resetForTest();
      const store = ConfigPerfProfileStore();
      expect(await store.loadAll(), isEmpty);
    });
  });

  group('InMemoryPerfProfileStore', () {
    test('可预置且 save/load/remove/clear 往返', () async {
      final seeded = InMemoryPerfProfileStore(<String, PerfProfile>{
        'com.a': _profile('com.a'),
      });
      expect((await seeded.loadAll()).keys, <String>['com.a']);

      final store = InMemoryPerfProfileStore();
      expect(await store.loadAll(), isEmpty);
      expect(await store.save(_profile('com.b')), isTrue);
      expect((await store.load('com.b'))!.package, 'com.b');
      expect(await store.remove('com.b'), isTrue);
      expect(await store.load('com.b'), isNull);
      expect(await store.clear(), isTrue);
      expect(await store.loadAll(), isEmpty);
    });
  });
}

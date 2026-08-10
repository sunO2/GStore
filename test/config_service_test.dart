import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';

/// 测试用统一初始化：全部使用内存存储（避免插件依赖）
Future<void> initForTest() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
  ConfigRegistry.registerAll(ConfigService.instance);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await initForTest();
  });

  group('ConfigStore 存储', () {
    test('内存存储读写与事件', () async {
      final store = ConfigStore.instance;
      final events = <StorageChangeEvent>[];
      final sub = store.changes.listen(events.add);

      expect(await store.writeString('test_key', 'hello'), true);
      expect(await store.readString('test_key'), 'hello');
      expect(events, hasLength(1));
      expect(events.first.key, 'test_key');
      expect(events.first.value, 'hello');

      await store.remove('test_key');
      expect(await store.readString('test_key'), isNull);
      expect(events, hasLength(2));
      expect(events.last.value, isNull);

      await sub.cancel();
    });

    test('类型化读写', () async {
      final store = ConfigStore.instance;
      await store.write('bool_key', true);
      expect(await store.readBool('bool_key'), true);

      await store.write('int_key', 42);
      expect(await store.readInt('int_key'), 42);

      await store.write('list_key', ['a', 'b']);
      expect(await store.readStringList('list_key'), ['a', 'b']);
    });

    test('敏感 key 自动路由加密存储', () async {
      final store = ConfigStore.instance;
      store.markSensitive('secret_key');
      expect(store.isSensitive('secret_key'), true);
      expect(await store.writeString('secret_key', 'password123'), true);
      expect(await store.readString('secret_key'), 'password123');
    });

    test('migrate 迁移键', () async {
      final store = ConfigStore.instance;
      await store.write('old_key', 'value');
      expect(await store.migrate('old_key', 'new_key'), true);
      expect(await store.readString('new_key'), 'value');
      expect(await store.readString('old_key'), isNull);
    });

    test('watch 监听指定 key', () async {
      final store = ConfigStore.instance;
      final seen = <Object?>[];
      final sub = store.watch('watch_key').listen((e) => seen.add(e.value));

      await store.write('watch_key', 'v1');
      await store.write('watch_key', 'v2');
      await store.write('other_key', 'x'); // 不应触发

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, ['v1', 'v2']);
      await sub.cancel();
    });
  });

  group('ConfigService 注册表', () {
    test('内置注册项完整', () {
      final service = ConfigService.instance;
      expect(service.has(ConfigKeys.themeMode), true);
      expect(service.has(ConfigKeys.themeConfig), true);
      expect(service.has(ConfigKeys.downloadConfig), true);
      expect(service.has(ConfigKeys.updateConfig), true);
      expect(service.has(ConfigKeys.webdavConfig), true);
      expect(service.has(ConfigKeys.proxyUrl), true);
      expect(service.has(ConfigKeys.agentSelectedModelId), true);
      expect(service.has(ConfigKeys.fdroidSources), true);
      expect(service.has(ConfigKeys.selectedChannels), true);
    });

    test('agent 白名单', () {
      final service = ConfigService.instance;
      expect(service.isAgentAccessible(ConfigKeys.themeMode), true);
      expect(service.isAgentAccessible(ConfigKeys.proxyUrl), true);
      expect(service.isAgentAccessible(ConfigKeys.agentModels), false);
      expect(service.isAgentAccessible(ConfigKeys.fdroidSources), false);
    });

    test('list 按 key 排序', () {
      final keys = ConfigService.instance.list().map((e) => e.key).toList();
      final sorted = List.of(keys)..sort();
      expect(keys, sorted);
    });
  });

  group('ConfigService set/get', () {
    test('写入并读取普通配置', () async {
      final service = ConfigService.instance;
      final result = await service.set(ConfigKeys.themeMode, 2);
      expect(result.success, true);
      expect(await service.getT<int>(ConfigKeys.themeMode), 2);
    });

    test('类型校验失败', () async {
      final service = ConfigService.instance;
      final result = await service.set(ConfigKeys.themeMode, 'not-an-int');
      expect(result.success, false);
      expect(result.message, contains('整数'));
    });

    test('未知配置项', () async {
      final service = ConfigService.instance;
      final result = await service.set('no_such_key', 1);
      expect(result.success, false);
      expect(result.message, contains('未知配置项'));
    });

    test('敏感配置脱敏读取', () async {
      final service = ConfigService.instance;
      await service.set(ConfigKeys.webdavConfig, {
        'url': 'dav.example.com',
        'username': 'user',
        'password': 'secret',
      });
      // 敏感项对外读取脱敏
      final value = await service.get(ConfigKeys.webdavConfig);
      expect(value, '***');
    });

    test('JSON 类型配置兼容字符串输入（jsonDecode）', () async {
      final service = ConfigService.instance;
      // Agent 传 JSON 字符串
      final result = await service.set(
        ConfigKeys.themeConfig,
        '{"fontStyle":3}',
      );
      expect(result.success, true, reason: result.message);
      // 已解析为 Map 写入
      final raw = await service.getRaw(ConfigKeys.themeConfig);
      expect(raw, isA<Map>());
    });

    test('JSON 类型配置非法字符串返回友好错误', () async {
      final service = ConfigService.instance;
      final result = await service.set(
        ConfigKeys.themeConfig,
        'not-json{{{',
      );
      expect(result.success, false);
      expect(result.message, contains('JSON'));
    });

    test('JSON 类型配置传 Map 仍正常', () async {
      final service = ConfigService.instance;
      final result = await service.set(ConfigKeys.themeConfig, {
        'fontStyle': 3,
      });
      expect(result.success, true, reason: result.message);
    });

    test('未设置返回 null', () async {
      final service = ConfigService.instance;
      expect(await service.get(ConfigKeys.proxyUrl), isNull);
    });

    test('clear 清除配置', () async {
      final service = ConfigService.instance;
      await service.set(ConfigKeys.themeMode, 1);
      final result = await service.clear(ConfigKeys.themeMode);
      expect(result.success, true);
      expect(await service.getT<int>(ConfigKeys.themeMode), isNull);
    });

    test('reset 恢复默认值', () async {
      final service = ConfigService.instance;
      await service.set(ConfigKeys.themeMode, 1);
      final result = await service.reset(ConfigKeys.themeMode);
      expect(result.success, true);
      expect(await service.getT<int>(ConfigKeys.themeMode), 0);
    });
  });

  group('ConfigService 事件总线', () {
    test('set 广播事件（含 source）', () async {
      final service = ConfigService.instance;
      final events = <ConfigChangeEvent>[];
      final sub = service.onChange.listen(events.add);

      await service.set(
        ConfigKeys.themeMode,
        1,
        source: ConfigChangeSource.agent,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events, hasLength(1));
      expect(events.first.key, ConfigKeys.themeMode);
      expect(events.first.newValue, 1);
      expect(events.first.source, ConfigChangeSource.agent);

      await sub.cancel();
    });

    test('watch 过滤指定 key', () async {
      final service = ConfigService.instance;
      final seen = <Object?>[];
      final sub = service.watch(ConfigKeys.themeMode).listen((e) {
        seen.add(e.newValue);
      });

      await service.set(ConfigKeys.themeMode, 1);
      await service.set(ConfigKeys.proxyUrl, 'https://p.example.com/');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, [1]);
      await sub.cancel();
    });

    test('watchMany 多 key 监听', () async {
      final service = ConfigService.instance;
      final seen = <String>[];
      final sub = service
          .watchMany([ConfigKeys.themeMode, ConfigKeys.proxyUrl])
          .listen((e) => seen.add(e.key));

      await service.set(ConfigKeys.themeMode, 2);
      await service.set(ConfigKeys.proxyUrl, 'https://x.example.com/');

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, [ConfigKeys.themeMode, ConfigKeys.proxyUrl]);
      await sub.cancel();
    });
  });

  group('ConfigSnapshot 快照', () {
    test('snapshot 包含元数据与当前值', () async {
      final service = ConfigService.instance;
      await service.set(ConfigKeys.themeMode, 2);

      final snap = await service.snapshot(ConfigKeys.themeMode);
      expect(snap, isNotNull);
      expect(snap!.key, ConfigKeys.themeMode);
      expect(snap.type, 'int');
      expect(snap.value, 2);
      expect(snap.defaultValue, 0);
      expect(snap.enumValues, ['0', '1', '2']);
      expect(snap.category, 'theme');
      expect(snap.agentAccessible, true);
      expect(snap.sensitive, false);
    });

    test('snapshot 敏感项 value 脱敏', () async {
      final service = ConfigService.instance;
      await service.set(ConfigKeys.webdavConfig, {
        'url': 'dav.example.com',
        'username': 'u',
        'password': 'p',
      });

      final snap = await service.snapshot(ConfigKeys.webdavConfig);
      expect(snap, isNotNull);
      expect(snap!.sensitive, true);
      expect(snap.value, '***');
    });

    test('snapshot 未设置时 value 为 null', () async {
      final snap = await ConfigService.instance.snapshot(ConfigKeys.proxyUrl);
      expect(snap, isNotNull);
      expect(snap!.value, isNull);
      expect(snap.defaultValue, '');
      expect(snap.category, 'network');
      expect(snap.example, isNotEmpty);
    });

    test('snapshot 未知 key 返回 null', () async {
      final snap = await ConfigService.instance.snapshot('no_such');
      expect(snap, isNull);
    });

    test('snapshots 全量按 key 排序且含类型字段', () async {
      final snaps = await ConfigService.instance.snapshots();
      expect(snaps, isNotEmpty);
      expect(snaps.length, greaterThanOrEqualTo(9));
      final keys = snaps.map((s) => s.key).toList();
      final sorted = List.of(keys)..sort();
      expect(keys, sorted);
      for (final s in snaps) {
        expect(s.type, isNotEmpty);
        expect(s.toJson()['key'], s.key);
        expect(s.toJson()['type'], s.type);
      }
    });

    test('snapshot toJson 结构完整', () async {
      await ConfigService.instance.set(ConfigKeys.themeMode, 1);
      final snap = await ConfigService.instance.snapshot(ConfigKeys.themeMode);
      final json = snap!.toJson();
      expect(json['key'], ConfigKeys.themeMode);
      expect(json['type'], 'int');
      expect(json['value'], 1);
      expect(json['defaultValue'], 0);
      expect(json['sensitive'], false);
      expect(json['agentAccessible'], true);
      expect(json['enumValues'], ['0', '1', '2']);
      expect(json['category'], 'theme');
      expect(json.containsKey('unit'), true);
    });
  });

  group('ConfigService 模块化注册', () {
    test('registerModule 后配置立即可用', () async {
      final service = ConfigService.instance;
      expect(service.hasModule('app_core'), true);
      expect(service.moduleNames, contains('app_core'));

      // 自定义模块注册
      final module = _TestConfigModule();
      service.registerModule(module);
      expect(service.hasModule('test_module'), true);
      expect(service.has('test_volume'), true);

      // 注册后可读写
      final result = await service.set('test_volume', 50);
      expect(result.success, true);
      expect(await service.getT<int>('test_volume'), 50);

      // 快照可见
      final snap = await service.snapshot('test_volume');
      expect(snap, isNotNull);
      expect(snap!.value, 50);
      expect(snap.unit, 'MB');
      expect(snap.min, 1);
      expect(snap.max, 200);
      expect(snap.example, '64');
    });

    test('重复注册同名模块覆盖更新', () async {
      final service = ConfigService.instance;
      service.registerModule(_TestConfigModule());
      service.registerModule(_TestConfigModule());
      expect(service.hasModule('test_module'), true);
      // 配置项仍只有一个
      expect(service.has('test_volume'), true);
    });

    test('unregisterModule 移除配置项但保留数据', () async {
      final service = ConfigService.instance;
      service.registerModule(_TestConfigModule());
      await service.set('test_volume', 80);

      service.unregisterModule('test_module');
      expect(service.hasModule('test_module'), false);
      expect(service.has('test_volume'), false);

      // 存储数据保留（重新注册后可读回）
      service.registerModule(_TestConfigModule());
      expect(await service.getT<int>('test_volume'), 80);
    });

    test('set 数值范围校验', () async {
      final service = ConfigService.instance;
      service.registerModule(_TestConfigModule());
      final tooBig = await service.set('test_volume', 999);
      expect(tooBig.success, false);
      expect(tooBig.message, contains('不能大于'));
      final tooSmall = await service.set('test_volume', 0);
      expect(tooSmall.success, false);
      expect(tooSmall.message, contains('不能小于'));
    });

    test('ConfigOpResult 结构化字段', () async {
      final service = ConfigService.instance;
      final result = await service.set(
        ConfigKeys.themeMode,
        1,
        source: ConfigChangeSource.agent,
      );
      expect(result.success, true);
      expect(result.key, ConfigKeys.themeMode);
      expect(result.value, 1);
      expect(result.defaultValue, 0);
    });
  });
}

/// 测试用配置模块
class _TestConfigModule extends ConfigModule {
  @override
  String get moduleName => 'test_module';

  @override
  List<ConfigEntry> get configs => [
        const ConfigEntry(
          key: 'test_volume',
          type: ConfigValueType.int,
          defaultValue: 64,
          agentAccessible: true,
          category: 'test',
          unit: 'MB',
          min: 1,
          max: 200,
          example: '64',
          description: '测试音量配置',
          descriptionEn: 'Test volume config',
        ),
      ];
}

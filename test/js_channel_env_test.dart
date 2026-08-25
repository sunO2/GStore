import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';

/// 内存版 ChannelAddedAppDao（测试用，模拟渠道数据库）
class _FakeAppDao implements ChannelAddedAppDao {
  final List<ChannelAddedApp> _apps = [];

  @override
  Future<void> insertApp(ChannelAddedApp app) async {
    _apps.removeWhere(
        (a) => a.channelCode == app.channelCode && a.appId == app.appId);
    _apps.add(app);
  }

  @override
  Future<void> insertApps(List<ChannelAddedApp> apps) async {
    for (final app in apps) {
      await insertApp(app);
    }
  }

  @override
  Future<List<ChannelAddedApp>> getAppsByChannel(String channelCode) async =>
      _apps.where((a) => a.channelCode == channelCode).toList();

  @override
  Future<ChannelAddedApp?> getApp(String appId, String channelCode) async {
    for (final a in _apps) {
      if (a.appId == appId && a.channelCode == channelCode) return a;
    }
    return null;
  }

  @override
  Future<void> removeApp(String appId, String channelCode) async {
    _apps.removeWhere((a) => a.appId == appId && a.channelCode == channelCode);
  }

  @override
  Future<int?> getCountByChannel(String channelCode) async =>
      _apps.where((a) => a.channelCode == channelCode).length;

  @override
  Future<void> clearChannel(String channelCode) async {
    _apps.removeWhere((a) => a.channelCode == channelCode);
  }

  @override
  Future<List<ChannelAddedApp>> getAllApps() async => List.of(_apps);

  @override
  Future<int?> getTotalCount() async => _apps.length;
}

/// 固定响应 Dio adapter（测试用，模拟网络层）
class _FakeDioAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode({'echo': options.path}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// runtime env 测试脚本：host.env 三件套
const String _envScript = '''
async function envGet(name) {
  return await host.env.get(name);
}

async function envAll() {
  return await host.env.all();
}

async function envHas(name) {
  return await host.env.has(name);
}
''';

/// JsChannel env 集成脚本：getAllApps 把 host.env 读到的 PINGAN_USER 拼进 appId
/// （验证 持久化 → runtime 快照 → JS 可见 全链路）
const String _channelEnvScript = '''
async function main(method, params) {
  switch (method) {
    case 'getAllApps': {
      const all = await host.env.all();
      const user = await host.env.get('PINGAN_USER');
      const apps = [];
      if (all && all.data && all.data.PINGAN_USER) {
        apps.push({
          appId: 'env-' + all.data.PINGAN_USER,
          name: (user && user.data) || 'no-user',
          icon: 'icon://env'
        });
      }
      return { ok: true, data: apps };
    }
    default:
      return null;
  }
}
''';

/// 测试用统一初始化：全部使用内存存储（避免插件依赖）
Future<void> initStoreForTest() async {
  ConfigStore.instance.resetForTest();
  await ConfigStore.instance.initialize(storages: [
    MemoryConfigStorage(),
    MemoryConfigStorage(),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAppDao appDao;
  late Dio dio;

  setUp(() async {
    await initStoreForTest();
    appDao = _FakeAppDao();
    dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter();
  });

  group('JsChannelRuntime host.env', () {
    test('① host.env.get 返回注入的 envReader 值（JS 侧断言）', () async {
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _envScript,
        envReader: () => {'PINGAN_USER': 'alice', 'PINGAN_PASS': 'pwd123'},
      );
      await runtime.initialize();

      final result = await runtime.call('envGet', ['PINGAN_USER']);
      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['ok'], isTrue);
      expect(map['data'], 'alice');

      await runtime.dispose();
    });

    test('② env 缺失返回 null（data 为 null，不抛错）', () async {
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _envScript,
        envReader: () => {'PINGAN_USER': 'alice'},
      );
      await runtime.initialize();

      final result = await runtime.call('envGet', ['MISSING_KEY']);
      expect(result, isA<Map>());
      expect((result as Map)['ok'], isTrue);
      expect(result['data'], isNull);

      await runtime.dispose();
    });

    test('③ host.env.all 返回全量 env map', () async {
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _envScript,
        envReader: () => {'A': '1', 'B': '2'},
      );
      await runtime.initialize();

      final result = await runtime.call('envAll');
      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['ok'], isTrue);
      final data = map['data'] as Map;
      expect(data, {'A': '1', 'B': '2'});

      await runtime.dispose();
    });

    test('host.env.has 存在/不存在返回 bool', () async {
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _envScript,
        envReader: () => {'PINGAN_USER': 'alice'},
      );
      await runtime.initialize();

      final has = await runtime.call('envHas', ['PINGAN_USER']);
      expect((has as Map)['data'], isTrue);

      final notHas = await runtime.call('envHas', ['NOPE']);
      expect((notHas as Map)['data'], isFalse);

      await runtime.dispose();
    });

    test('未注入 envReader → env 为空 map（get 全 null / all 空）', () async {
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _envScript,
      );
      await runtime.initialize();

      final get = await runtime.call('envGet', ['K']);
      expect((get as Map)['data'], isNull);

      final all = await runtime.call('envAll');
      expect(((all as Map)['data'] as Map), isEmpty);

      await runtime.dispose();
    });

    test('⑤ updateEnv 后 JS 侧 env.get 变化（无需重建引擎）', () async {
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _envScript,
        envReader: () => {'OLD': '1'},
      );
      await runtime.initialize();

      // 旧值可见
      final before = await runtime.call('envGet', ['OLD']);
      expect((before as Map)['data'], '1');

      // 热更新快照：新 key 出现、旧 key 消失
      runtime.updateEnv({'NEW': '2'});
      final after = await runtime.call('envGet', ['NEW']);
      expect((after as Map)['data'], '2');
      final gone = await runtime.call('envGet', ['OLD']);
      expect((gone as Map)['data'], isNull);

      await runtime.dispose();
    });
  });

  group('JsChannel env 持久化', () {
    JsChannel buildChannel({required String channelKey, String? script}) {
      return JsChannel(
        channelKey: channelKey,
        script: script ?? _channelEnvScript,
        dio: dio,
        appDao: appDao,
      );
    }

    test('④ setEnv → getAllEnv roundtrip（ConfigStore 持久化，重启读取）', () async {
      final channel = buildChannel(channelKey: 'js.persist');
      await channel.setEnv('PINGAN_USER', 'alice');
      await channel.setEnv('PINGAN_PASS', 'pwd123');
      expect(await channel.getAllEnv(), {'PINGAN_USER': 'alice', 'PINGAN_PASS': 'pwd123'});

      // 模拟重启：新实例（同 channelKey）从 ConfigStore 读到持久化 env
      await channel.dispose();
      final restarted = buildChannel(channelKey: 'js.persist');
      await restarted.initialize();
      expect(await restarted.getAllEnv(), {'PINGAN_USER': 'alice', 'PINGAN_PASS': 'pwd123'});

      // 存储层直查：确认落盘为 JSON map（键 channel_env_<channelKey>）
      final raw = await ConfigStore.instance.readString('channel_env_js.persist');
      expect(jsonDecode(raw!), {'PINGAN_USER': 'alice', 'PINGAN_PASS': 'pwd123'});

      await restarted.dispose();
    });

    test('setEnv → getAllEnv 含新值（持久化立即写入）', () async {
      final channel = buildChannel(channelKey: 'js.link');
      await channel.initialize();
      await channel.setEnv('PINGAN_USER', 'u1');

      // B3 适配：setEnv 后 envSnapshot 立即可见（不再经脚本 getAllApps 验证）
      final env = await channel.getAllEnv();
      expect(env, containsPair('PINGAN_USER', 'u1'));

      await channel.dispose();
    });

    test('重启后（新实例 initialize）getAllEnv 含持久化值', () async {
      final channel = buildChannel(channelKey: 'js.restart');
      await channel.setEnv('PINGAN_USER', 'alice');
      await channel.setEnv('PINGAN_PASS', 'pwd123');
      await channel.dispose();

      // 模拟重启：新实例从 ConfigStore 读持久化 env
      final restarted = buildChannel(channelKey: 'js.restart');
      await restarted.initialize();

      // B3 适配：getAllEnv 从 ConfigStore 读到持久化值（不再经脚本 getAllApps 验证）
      expect(await restarted.getAllEnv(),
          {'PINGAN_USER': 'alice', 'PINGAN_PASS': 'pwd123'});

      await restarted.dispose();
    });

    test('removeEnv 删除后 getAllEnv 不再包含', () async {
      final channel = buildChannel(channelKey: 'js.remove');
      await channel.setEnv('KEEP', '1');
      await channel.setEnv('DROP', '2');

      await channel.removeEnv('DROP');
      expect(await channel.getAllEnv(), {'KEEP': '1'});

      await channel.dispose();
    });

    test('⑥ 渠道隔离：两个 JsChannel 各自 env 不串（A set K=1，B 无 K）', () async {
      final channelA = buildChannel(channelKey: 'js.a');
      final channelB = buildChannel(channelKey: 'js.b');
      await channelA.initialize();
      await channelB.initialize();

      await channelA.setEnv('PINGAN_USER', '1');
      await channelA.setEnv('K', '1');

      // B3 适配：快照隔离断言（不再经脚本 getAllApps 验证）
      // B 的 env 无 K（快照不串）
      expect(await channelB.getAllEnv(), isEmpty);

      // A 自己的 env 正常（快照独立）
      expect(await channelA.getAllEnv(), {'PINGAN_USER': '1', 'K': '1'});

      await channelA.dispose();
      await channelB.dispose();
    });
  });
}

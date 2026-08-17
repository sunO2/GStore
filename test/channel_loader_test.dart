import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/channel_loader.dart';

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

/// 合法脚本 A：实现 getAllApps/searchApps/getAppInfo，应用名含 'A'
const String _scriptA = '''
const CHANNEL_META = { name: 'A 渠道', description: 'A 描述' };

const apps = [
  { appId: 'com.a.one', name: 'App A One', icon: 'icon://a1', des: 'A 第一个' }
];

async function main(method, params) {
  switch (method) {
    case 'getAllApps':
      return { ok: true, data: apps };
    case 'searchApps':
      return { ok: true, data: apps };
    case 'getAppInfo':
      return { ok: true, data: apps[0] };
    default:
      return null;
  }
}
''';

/// 合法脚本 B：与 A 同名渠道下的"更新版"，应用名含 'B'
const String _scriptB = '''
const CHANNEL_META = { name: 'B 渠道' };

const apps = [
  { appId: 'com.b.one', name: 'App B One', icon: 'icon://b1', des: 'B 第一个' }
];

async function main(method, params) {
  switch (method) {
    case 'getAllApps':
      return { ok: true, data: apps };
    case 'searchApps':
      return { ok: true, data: apps };
    default:
      return null;
  }
}
''';

/// 语法错误脚本：QuickJS 加载即失败
const String _brokenScript = '''
const broken = ;
function main(method, params) {
  return { ok: true, data: [1, 2] };
''';

/// 非法文件名脚本（'my-channel.js' 含连字符，不是合法标识符，应跳过）
const String _validBody = '''
async function main(method, params) { return null; }
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAppDao appDao;
  late Dio dio;

  setUp(() {
    appDao = _FakeAppDao();
    dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter();
  });

  ChannelManager getManager() => ChannelManager.instance;

  /// 在临时目录写入脚本文件，返回目录
  Future<Directory> writeScripts(Map<String, String> files) async {
    final dir = await Directory.systemTemp.createTemp('channel_loader_test');
    for (final entry in files.entries) {
      await File('${dir.path}/${entry.key}').writeAsString(entry.value);
    }
    return dir;
  }

  tearDown(() async {
    // 清理本次测试注册的动态渠道（单例隔离）
    for (final channel in getManager().dynamicChannels) {
      if (channel is DynamicChannel && (channel as DynamicChannel).channelKey.startsWith('js_')) {
        getManager().unregisterChannelByKey((channel as DynamicChannel).channelKey);
      }
    }
  });

  group('ChannelLoader', () {
    test('① 扫描目录 → 注册成功且 getChannelByKey 返回（渠道已初始化）', () async {
      final dir = await writeScripts({
        'one.js': _scriptA,
        'two.js': _scriptB,
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      // key = 'js_' + 文件名（无扩展）
      expect(loaded.map((c) => c.channelKey), containsAll(['js_one', 'js_two']));

      final channel = getManager().getChannelByKey('js_one');
      expect(channel, isNotNull);
      expect(channel, isA<JsChannel>());
      // 加载时已校验初始化
      expect(channel!.isInitialized, isTrue);

      // 脚本可正常分发调用（searchApps 走脚本）
      final result = await (channel as JsChannel).searchApps('App');
      expect(result.success, isTrue);
      expect(result.data, hasLength(1));
      expect(result.data!.first.name, 'App A One');

      // 另一个文件同样注册
      expect(getManager().getChannelByKey('js_two'), isNotNull);
    });

    test('② 目录为空 → 不报错，返回空列表', () async {
      final dir = await Directory.systemTemp.createTemp('channel_loader_empty');
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      expect(loaded, isEmpty);
      expect(getManager().dynamicChannels.where((c) => c is DynamicChannel && (c as DynamicChannel).channelKey.startsWith('js_')), isEmpty);
    });

    test('③ 非法脚本（语法错误）→ 跳过 + 日志，不阻塞其他脚本', () async {
      final dir = await writeScripts({
        'bad.js': _brokenScript,
        'good.js': _scriptA,
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      // 坏脚本未注册
      expect(getManager().getChannelByKey('js_bad'), isNull);
      // 好脚本正常注册
      expect(loaded.map((c) => c.channelKey), ['js_good']);
      expect(getManager().getChannelByKey('js_good'), isNotNull);
    });

    test('④ 幂等：重复调用不重复注册（内容未变 → 跳过）', () async {
      final dir = await writeScripts({'dup.js': _scriptA});
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final first = await loader.loadAndRegister();
      final second = await loader.loadAndRegister();

      expect(first, hasLength(1));
      // 第二次调用无新增注册
      expect(second, isEmpty);

      final count = getManager()
          .dynamicChannels
          .where((c) => c is DynamicChannel && (c as DynamicChannel).channelKey == 'js_dup')
          .length;
      expect(count, 1);
    });

    test('⑤ 同名 key：脚本内容变化 → 更新注册（不残留旧渠道）', () async {
      final dir = await writeScripts({'dup.js': _scriptA});
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      await loader.loadAndRegister();

      final before = getManager().getChannelByKey('js_dup') as JsChannel;
      expect((await before.searchApps('App')).data!.first.name, 'App A One');

      // 覆盖脚本内容（模拟用户更新脚本）后重新加载
      await File('${dir.path}/dup.js').writeAsString(_scriptB);
      final updated = await loader.loadAndRegister();
      expect(updated, hasLength(1));
      expect(updated.first.channelKey, 'js_dup');

      final after = getManager().getChannelByKey('js_dup') as JsChannel;
      expect(after.isInitialized, isTrue);
      expect((await after.searchApps('App')).data!.first.name, 'App B One');

      // 更新后仍只有 1 个同 key 渠道（旧实例已注销）
      final count = getManager()
          .dynamicChannels
          .where((c) => c is DynamicChannel && (c as DynamicChannel).channelKey == 'js_dup')
          .length;
      expect(count, 1);
    });

    test('⑥ 非法文件名（含连字符）→ 跳过，不阻塞其他脚本', () async {
      final dir = await writeScripts({
        'my-channel.js': _validBody,
        'ok.js': _scriptA,
      });
      addTearDown(() => dir.delete(recursive: true));

      final loader = ChannelLoader(dio: dio, appDao: appDao, directory: dir);
      final loaded = await loader.loadAndRegister();

      expect(getManager().getChannelByKey('js_my-channel'), isNull);
      expect(loaded.map((c) => c.channelKey), ['js_ok']);
    });

    test('⑦ 集成冒烟：ChannelLoader 加载 assets/channels/example.js → JsChannel.initialize 成功', () async {
      // 内置模板（assets 声明于 pubspec，flutter test 可经 rootBundle 读取）
      final script = await ChannelLoader.loadAssetScript('assets/channels/example.js');
      expect(script, contains('main'));
      expect(script, contains('host.network'));

      final channel = JsChannel(
        channelKey: 'js_example',
        script: script,
        dio: dio,
        appDao: appDao,
      );

      // 模板脚本可被引擎加载（语法/契约有效）
      await channel.initialize();
      expect(channel.isInitialized, isTrue);

      // main 分发器可调用（searchApps 走 host.network 示例 → fake dio 返回非数组 → 空结果）
      final result = await channel.searchApps('example');
      expect(result.success, isTrue);
      expect(result.data, isEmpty);

      await channel.dispose();
    });
  });
}

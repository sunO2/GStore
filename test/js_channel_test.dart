import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppSummary.dart';

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

/// 渠道脚本契约测试脚本：
/// 导出 main(method, params) 统一分发器 + 可选 CHANNEL_META
/// - getAllApps / searchApps / getAppInfo / checkUpdate 已实现
/// - searchApps 关键词 'boom' 抛错（异常路径）
/// - doUpdate 未实现（走 JSChannel 拉全量落库兜底）
const String _testScript = '''
const CHANNEL_META = { name: '测试脚本渠道', description: '脚本化渠道测试', icon: 'meta-icon' };

const apps = [
  { appId: 'com.example.one', name: 'App One', icon: 'icon://one', des: '第一个应用', category: ['工具', '效率'], extra: { channel: 'test' } },
  { appId: 'com.example.two', name: 'App Two', user: 'dev', repositories: 'repo-two', icon: 'icon://two', des: '第二个应用' }
];

async function main(method, params) {
  switch (method) {
    case 'getAllApps':
      return { ok: true, data: apps };
    case 'searchApps':
      if (params && params.keyword === 'boom') throw new Error('脚本搜索内部错误');
      return { ok: true, data: apps.filter(a => a.name.indexOf(params.keyword) !== -1 || a.des.indexOf(params.keyword) !== -1) };
    case 'getAppInfo':
      if (!params || !params.appId || params.appId === 'missing') return { ok: true, data: null };
      return { ok: true, data: apps.find(a => a.appId === params.appId) || null };
    case 'checkUpdate':
      return { ok: true, data: false };
    case 'detailMenu':
      if (!params || !params.appId) return null;
      return { ok: true, data: [{ action: '切换版本', jscall: 'jsswitchVersion', clickIsDimiss: true }] };
    default:
      return null;
  }
}
''';

/// 渠道 B 脚本：应用 ID 与 A 完全不同（隔离断言用）
const String _testScriptB = '''
const CHANNEL_META = { name: 'B 渠道', description: 'B 描述' };

const apps = [
  { appId: 'com.b.one', name: 'B App One', icon: 'icon://b1', des: 'B 第一个' },
  { appId: 'com.b.two', name: 'B App Two', icon: 'icon://b2', des: 'B 第二个' }
];

async function main(method, params) {
  switch (method) {
    case 'getAllApps':
      return { ok: true, data: apps };
    default:
      return null;
  }
}
''';

void main() {
  late _FakeAppDao appDao;
  late Dio dio;

  setUp(() {
    appDao = _FakeAppDao();
    dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter();
  });

  JsChannel buildChannel({String channelKey = 'js.test', String? script}) {
    return JsChannel(
      channelKey: channelKey,
      script: script ?? _testScript,
      dio: dio,
      appDao: appDao,
    );
  }

  group('JsChannel', () {
    test('① 脚本返回 list → searchApps 成功且 AppSummary 字段映射正确', () async {
      final channel = buildChannel();
      await channel.initialize();
      expect(channel.isInitialized, isTrue);

      final result = await channel.searchApps('App');
      expect(result.success, isTrue);
      expect(result.from, ChannelType.custom);
      expect(result.data, isNotNull);

      final apps = result.data!;
      expect(apps.length, 2);

      // 第一条：脚本未提供 user/repositories → JSChannel 兜底填 channelKey
      final first = apps[0];
      expect(first.appId, 'com.example.one');
      expect(first.name, 'App One');
      expect(first.user, 'js.test', reason: 'user 兜底 = channelKey');
      expect(first.repositories, 'js.test', reason: 'repositories 兜底 = channelKey');
      expect(first.icon, 'icon://one');
      expect(first.des, '第一个应用');
      expect(first.category, ['工具', '效率']);
      expect(first.extra, {'channel': 'test'});

      // 第二条：脚本提供的 user/repositories 原样保留
      final second = apps[1];
      expect(second.user, 'dev');
      expect(second.repositories, 'repo-two');

      await channel.dispose();
    });

    test('② 脚本返回 null → getAppInfo 成功且 data 为空（查库兜底同样无）', () async {
      final channel = buildChannel();
      await channel.initialize();

      final result = await channel.getAppInfo('missing');
      expect(result.success, isTrue);
      expect(result.data, isNull);

      // 脚本有该应用 → 返回映射后的 AppSummary
      final found = await channel.getAppInfo('com.example.one');
      expect(found.success, isTrue);
      expect(found.data?.name, 'App One');

      await channel.dispose();
    });

    test('③ 脚本抛错 → 方法返回 failure 不崩，渠道仍可用', () async {
      final channel = buildChannel();
      await channel.initialize();

      final failed = await channel.searchApps('boom');
      expect(failed.success, isFalse);
      expect(failed.error, isNotNull);

      // 抛错后渠道仍可用
      final ok = await channel.searchApps('App Two');
      expect(ok.success, isTrue);
      expect(ok.data, hasLength(1));

      await channel.dispose();
    });

    test('⑦ 脚本未返回详情数据 → getAppDetail 错误信息中性（不误导为未实现）', () async {
      final channel = buildChannel();
      await channel.initialize();

      // _testScript 未实现 getAppDetail → main 返回 null → 中性错误文案
      final result = await channel.getAppDetail('com.example.one');
      expect(result.success, isFalse);
      expect(result.error, '脚本未返回详情数据（脚本未实现或数据获取失败）');

      await channel.dispose();
    });

    test('④ checkUpdate 走脚本；doUpdate 未实现 → 拉全量落库到 channelKey', () async {
      final channel = buildChannel();
      await channel.initialize();

      final check = await channel.checkUpdate();
      expect(check.success, isTrue);
      expect(check.data, isFalse);

      final update = await channel.doUpdate();
      expect(update.success, isTrue);
      expect(update.data, isTrue);

      // 落库强制 channelKey
      final saved = await appDao.getAppsByChannel('js.test');
      expect(saved, hasLength(2));
      for (final app in saved) {
        expect(app.channelCode, 'js.test');
      }
      final first = saved.firstWhere((a) => a.appId == 'com.example.one');
      expect(first.user, 'js.test', reason: '落库时 user 兜底 = channelKey');
      expect(first.extra, isNotNull);
      expect(jsonDecode(first.extra!), {'channel': 'test'});

      await channel.dispose();
    });

    test('⑤ 数据隔离：两个 JsChannel（key A/B）各自落库/查库不串', () async {
      final channelA = buildChannel(channelKey: 'js.a');
      final channelB = buildChannel(channelKey: 'js.b', script: _testScriptB);
      await channelA.initialize();
      await channelB.initialize();

      await channelA.doUpdate();
      await channelB.doUpdate();

      final aApps = await appDao.getAppsByChannel('js.a');
      final bApps = await appDao.getAppsByChannel('js.b');
      expect(aApps, hasLength(2));
      expect(bApps, hasLength(2));

      // A 库只有 A 的应用（channelCode 全部为 js.a，无 B 数据混入）
      expect(aApps.every((a) => a.channelCode == 'js.a'), isTrue);
      expect(aApps.map((a) => a.appId), containsAll(['com.example.one', 'com.example.two']));
      // B 库只有 B 的应用
      expect(bApps.every((a) => a.channelCode == 'js.b'), isTrue);
      expect(bApps.map((a) => a.appId), containsAll(['com.b.one', 'com.b.two']));

      // 跨渠道查询互不可见
      expect(await appDao.getApp('com.example.one', 'js.b'), isNull);
      expect(await appDao.getApp('com.b.one', 'js.a'), isNull);

      // A 落库的 user 兜底为 A 的 channelKey，不会混用 B
      expect(aApps.first.user, 'js.a');
      expect(bApps.first.user, 'js.b');

      await channelA.dispose();
      await channelB.dispose();
    });

    test('⑥ 读取脚本 CHANNEL_META（name/description）', () async {
      final channel = buildChannel();
      await channel.initialize();

      expect(channel.info.type, ChannelType.custom);
      expect(channel.info.name, '测试脚本渠道');
      expect(channel.info.description, '脚本化渠道测试');
      expect(channel.channelKey, 'js.test');

      await channel.dispose();
    });

    test('addApp/removeApp 走本渠道库（channelKey 隔离）', () async {
      final channel = buildChannel();
      await channel.initialize();

      final addResult = await channel.addApp(_sampleApp());
      expect(addResult.success, isTrue);
      expect(await appDao.getApp('com.manual.add', 'js.test'), isNotNull);

      final removeResult = await channel.removeApp('com.manual.add');
      expect(removeResult.success, isTrue);
      expect(await appDao.getApp('com.manual.add', 'js.test'), isNull);

      await channel.dispose();
    });

    test('⑧ detailMenu 返回脚本声明的详情页操作列表', () async {
      final channel = buildChannel();
      await channel.initialize();

      final menu = await channel.detailMenu('com.example.one');
      expect(menu, isNotNull);
      expect(menu, hasLength(1));
      expect(menu![0]['action'], '切换版本');
      expect(menu[0]['jscall'], 'jsswitchVersion');
      expect(menu[0]['clickIsDimiss'], true);

      await channel.dispose();
    });

    test('⑨ 脚本未实现 detailMenu → null（调用方维持现状兜底）', () async {
      final channel = buildChannel(script: _testScriptB);
      await channel.initialize();

      final menu = await channel.detailMenu('com.example.one');
      expect(menu, isNull);

      await channel.dispose();
    });

    test('⑩ invokeScriptMethod 通用脚本调用（jscall 契约）', () async {
      final channel = buildChannel();
      await channel.initialize();

      // 已实现方法 → 返回 {ok:true,data} 的 data
      final data = await channel
          .invokeScriptMethod('getAppInfo', {'appId': 'com.example.one'});
      expect(data, isA<Map>());
      expect((data as Map)['name'], 'App One');

      // 未实现方法 → null（脚本 default 分支）
      final missing = await channel.invokeScriptMethod('noSuchMethod');
      expect(missing, isNull);

      await channel.dispose();
    });
  });
}

AppSummary _sampleApp() {
  return const AppSummary(
    appId: 'com.manual.add',
    name: '手动添加',
    user: 'manual-user',
    repositories: 'manual-repo',
    icon: 'icon://manual',
    des: '手动添加的应用',
  );
}

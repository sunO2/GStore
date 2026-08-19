import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/js_detail_channel.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';

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

/// detail.js 测试脚本：实现全部详情方法（getAppDetail/getAppInfo/versionOptions/
/// switchVersion/buildHistory/detailMenu），特定 appId 'fail' → { ok: false }，
/// 未实现 method → null（降级路径）。
const String _detailScript = '''
async function main(method, params) {
  switch (method) {
    case 'getAppDetail':
      if (params && params.appId === 'fail') return { ok: false };
      return { ok: true, data: {
        appId: params.appId,
        name: 'Detail App',
        icon: 'icon://detail',
        des: '详情描述',
        packageName: params.appId,
        developer: 'dev',
        readme: 'readme',
        receivedVersion: params && params.version
      } };
    case 'getAppInfo':
      if (params && params.appId === 'fail') return { ok: false };
      return { ok: true, data: {
        appId: params.appId, name: 'Info App', user: 'owner', repositories: 'repo' } };
    case 'versionOptions':
      if (params && params.appId === 'fail') return { ok: false };
      return { ok: true, data: {
        envs: ['prod', 'test'],
        versions: [{ version: '1.0.0', envs: ['prod', 'test'], buildCount: 3 }],
        currentEnv: 'prod',
        currentVersion: '1.0.0',
        receivedEnv: params && params.env
      } };
    case 'switchVersion':
      if (params && params.appId === 'fail') return { ok: false };
      return { ok: true, data: { appId: params.appId, name: 'Switched App', packageName: params.appId } };
    case 'buildHistory':
      if (params && params.appId === 'fail') return { ok: false };
      return { ok: true, data: { builds: [
        { num: 2, publishedAt: '2024-01-02', size: 1024, changelog: '修复', installTimes: 8, builtBy: 'ci', ipaName: 'one-1.0.0-2.ipa' }
      ] } };
    case 'detailMenu':
      return { ok: true, data: [
        { action: '签到', jscall: 'checkin' },
        { action: '关于', jscall: 'about' }
      ] };
    default:
      return null;
  }
}
''';

/// entry.js 测试脚本（工厂测试用：JsChannel 本体只需可初始化）
const String _entryScript = '''
const CHANNEL_META = { name: '详情工厂渠道' };
async function main(method, params) { return null; }
''';

/// 状态隔离测试脚本：每个 runtime 实例独立维护 visitCount，host.env 按实例注入
const String _statefulScript = '''
let visitCount = 0;
async function main(method, params) {
  switch (method) {
    case 'visit':
      visitCount += 1;
      return { ok: true, data: { visitCount: visitCount } };
    case 'envValue':
      const env = await host.env.get('TOKEN');
      return { ok: true, data: { value: env.data } };
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
  late _FakeAppDao appDao;
  late Dio dio;

  setUp(() async {
    await initStoreForTest();
    appDao = _FakeAppDao();
    dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter();
  });

  JsChannel buildChannel({
    String channelKey = 'js.detail',
    String? script,
    String? detailScript,
  }) {
    return JsChannel(
      channelKey: channelKey,
      script: script ?? _entryScript,
      detailScript: detailScript,
      dio: dio,
      appDao: appDao,
    );
  }

  group('JsDetailChannel 页面级详情通道', () {
    test('① 直接构造：各方法正确（detail.js 分发 + mock 响应）', () async {
      final detail = JsDetailChannel(
        channelKey: 'js.detail',
        detailScript: _detailScript,
        dio: dio,
        appDao: appDao,
      );

      // getAppDetail：详情 Map + version 透传
      final appDetail = await detail.getAppDetail('com.example.one');
      expect(appDetail, isNotNull);
      expect(appDetail!['appId'], 'com.example.one');
      expect(appDetail['name'], 'Detail App');
      expect(appDetail['packageName'], 'com.example.one');
      expect(appDetail['developer'], 'dev');
      expect(appDetail['receivedVersion'], isNull);
      final withVersion =
          await detail.getAppDetail('com.example.one', version: '1.0.0');
      expect(withVersion!['receivedVersion'], '1.0.0');

      // getAppInfo：AppInfo JSON Map
      final appInfo = await detail.getAppInfo('com.example.one');
      expect(appInfo, isNotNull);
      expect(appInfo!['name'], 'Info App');
      expect(appInfo['user'], 'owner');

      // versionOptions：envs/versions/current + env 透传
      final options = await detail.versionOptions('com.example.one');
      expect(options, isNotNull);
      expect(options!['envs'], ['prod', 'test']);
      expect(options['currentEnv'], 'prod');
      expect(options['currentVersion'], '1.0.0');
      final versions = options['versions'] as List;
      expect(versions, hasLength(1));
      expect((versions[0] as Map)['buildCount'], 3);
      final withEnv = await detail.versionOptions('com.example.one', env: 'test');
      expect(withEnv!['receivedEnv'], 'test');

      // switchVersion：详情 Map
      final switched = await detail.switchVersion(
        appId: 'com.example.one',
        env: 'prod',
        version: '1.0.0',
      );
      expect(switched, isNotNull);
      expect(switched!['name'], 'Switched App');

      // buildHistory：builds Map
      final history = await detail.buildHistory(
        appId: 'com.example.one',
        version: '1.0.0',
        env: 'prod',
      );
      expect(history, isNotNull);
      final builds = history!['builds'] as List;
      expect(builds, hasLength(1));
      expect((builds[0] as Map)['num'], 2);
      expect((builds[0] as Map)['ipaName'], 'one-1.0.0-2.ipa');

      // detailMenu：动作数组
      final menu = await detail.detailMenu('com.example.one');
      expect(menu, isNotNull);
      expect(menu, hasLength(2));
      expect(menu![0]['action'], '签到');
      expect(menu[1]['jscall'], 'about');

      // 脚本 {ok:false} → null（失败降级）
      expect(await detail.getAppDetail('fail'), isNull);
      expect(await detail.versionOptions('fail'), isNull);
      expect(await detail.buildHistory(
        appId: 'fail',
        version: '1.0.0',
        env: 'prod',
      ), isNull);

      await detail.dispose();
    });

    test('② JsChannel.getDetailChannel(appId) 返回实例（含 detailScript）', () async {
      final channel = buildChannel(detailScript: _detailScript);
      await channel.initialize();

      final detail = channel.getDetailChannel('com.example.one');
      expect(detail, isNotNull);
      expect(detail!.detailScript, _detailScript);
      expect(detail.channelKey, 'js.detail');

      // 工厂创建的实例可正常消费 detail.js
      final appDetail = await detail.getAppDetail('com.example.one');
      expect(appDetail, isNotNull);
      expect(appDetail!['name'], 'Detail App');

      await channel.dispose();
    });

    test('③ 同 appId 复用（同一实例，存活期间不重建）', () async {
      final channel = buildChannel(detailScript: _detailScript);

      final first = channel.getDetailChannel('com.example.one');
      final second = channel.getDetailChannel('com.example.one');
      expect(identical(first, second), isTrue);

      await channel.dispose();
    });

    test('④ releaseDetailChannel → 释放 + 再取新实例（数据随实例释放）', () async {
      final channel = buildChannel(detailScript: _detailScript);

      final first = channel.getDetailChannel('com.example.one');
      expect(first, isNotNull);

      channel.releaseDetailChannel('com.example.one');
      expect(first!.isDisposed, isTrue);

      // 再取 → 新实例（独立 runtime）
      final second = channel.getDetailChannel('com.example.one');
      expect(second, isNotNull);
      expect(identical(second, first), isFalse);
      expect(second!.isDisposed, isFalse);

      // 释放未创建的 appId → 幂等无操作
      channel.releaseDetailChannel('never.created');

      await channel.dispose();
    });

    test('⑤ 渠道包无 detail.js → getDetailChannel 返回 null（详情走原路径）', () async {
      final channel = buildChannel(); // detailScript 缺省 null

      expect(channel.getDetailChannel('com.example.one'), isNull);

      await channel.dispose();
    });

    test('⑥ 状态隔离：两个 appId 实例各自 JS 状态/env 不串', () async {
      // 直接构造两个实例（模拟工厂为不同 appId 创建的独立 runtime），
      // 各自注入不同 envReader，验证 JS 全局状态与 host.env 均隔离。
      final a = JsDetailChannel(
        channelKey: 'js.detail',
        detailScript: _statefulScript,
        envReader: () => {'TOKEN': 'TOKEN-A'},
      );
      final b = JsDetailChannel(
        channelKey: 'js.detail',
        detailScript: _statefulScript,
        envReader: () => {'TOKEN': 'TOKEN-B'},
      );

      // 各自独立 JS 全局状态：a 自增不影响 b
      final a1 = await a.callMain('visit') as Map;
      expect(a1['visitCount'], 1);
      final b1 = await b.callMain('visit') as Map;
      expect(b1['visitCount'], 1);
      final a2 = await a.callMain('visit') as Map;
      expect(a2['visitCount'], 2); // a 继续自增
      final b2 = await b.callMain('visit') as Map;
      expect(b2['visitCount'], 2); // b 独立自增

      // env 隔离：各实例读自己的注入 env
      final aEnv = await a.callMain('envValue') as Map;
      expect(aEnv['value'], 'TOKEN-A');
      final bEnv = await b.callMain('envValue') as Map;
      expect(bEnv['value'], 'TOKEN-B');

      await a.dispose();
      await b.dispose();
    });

    test('⑦ dispose 清理：渠道下线释放全部 detail，缓存清空', () async {
      final channel = buildChannel(detailScript: _detailScript);

      final d1 = channel.getDetailChannel('com.example.one');
      final d2 = channel.getDetailChannel('com.example.two');
      expect(d1, isNotNull);
      expect(d2, isNotNull);

      await channel.dispose();

      // 全部 detail runtime 已释放
      expect(d1!.isDisposed, isTrue);
      expect(d2!.isDisposed, isTrue);

      // 缓存已清空：再取 → 新实例（非已释放旧实例）
      final d3 = channel.getDetailChannel('com.example.one');
      expect(d3, isNotNull);
      expect(identical(d3, d1), isFalse);
      expect(d3!.isDisposed, isFalse);

      await channel.dispose(); // 二次 dispose 幂等
    });

    test('⑧ detail 通道在 setEnv 前创建 → 之后读到最新 env（缓存复用不陈旧）', () async {
      final channel = buildChannel(detailScript: _statefulScript);
      await channel.initialize();

      // 先创建 detail 通道（模拟用户先进详情页，此时 env 未配置）
      final detail = channel.getDetailChannel('com.example.one');
      final before = await detail!.callMain('envValue') as Map;
      expect(before['value'], isNull);

      // 用户去设置页配置 env（setEnv → 热更新 entry runtime）
      await channel.setEnv('TOKEN', 'TOKEN-NEW');

      // 回到详情页（同一 detail 通道实例，缓存复用）→ 应读到最新 env
      // （回归：detail runtime 只在 initialize 快照一次 env 的 bug）
      final after = await detail.callMain('envValue') as Map;
      expect(after['value'], 'TOKEN-NEW');

      await channel.dispose();
    });
  });
}

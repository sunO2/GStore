import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';

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

/// 版本切换契约测试脚本：
/// - versionOptions / switchVersion / buildHistory 已实现
/// - 未实现 method（main 无 case）→ 返回 null（降级路径）
/// - 特定 appId 'fail' → 返回 { ok: false }（失败路径）
const String _versionScript = '''
const CHANNEL_META = { name: '版本切换渠道', description: '版本切换测试' };

const versionOptionsData = {
  envs: ['prod', 'test'],
  versions: [
    { version: '1.0.0', envs: ['prod', 'test'], buildCount: 3 },
    { version: '1.1.0', envs: ['prod'], buildCount: 1 }
  ],
  currentEnv: 'prod',
  currentVersion: '1.0.0'
};

const detailData = {
  appId: 'com.example.one',
  name: 'App One',
  icon: 'icon://one',
  des: '第一个应用',
  packageName: 'com.example.one',
  developer: 'dev',
  readme: 'readme'
};

const buildsData = {
  builds: [
    { num: 3, publishedAt: '2024-01-03', size: 1024, changelog: '修复', installTimes: 10, builtBy: 'ci', ipaName: 'one-1.0.0-3.ipa' },
    { num: 2, publishedAt: '2024-01-02', size: 1024, changelog: '新增', installTimes: 8, builtBy: 'ci', ipaName: 'one-1.0.0-2.ipa' }
  ]
};

async function main(method, params) {
  switch (method) {
    case 'versionOptions':
      if (params && params.appId === 'fail') return { ok: false };
      // 回显收到的 env（断言按需单 env 拉取契约）
      return { ok: true, data: Object.assign({}, versionOptionsData, { receivedEnv: params && params.env }) };
    case 'switchVersion':
      if (params && params.appId === 'fail') return { ok: false };
      return { ok: true, data: detailData };
    case 'buildHistory':
      if (params && params.appId === 'fail') return { ok: false };
      return { ok: true, data: buildsData };
    case 'getAppDetail':
      if (params && params.appId === 'fail') return { ok: false };
      // 回显收到的 version（断言单版本拉取契约）
      return { ok: true, data: Object.assign({}, detailData, { receivedVersion: params && params.version }) };
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

  JsChannel buildChannel({String channelKey = 'js.version', String? script}) {
    return JsChannel(
      channelKey: channelKey,
      script: script ?? _versionScript,
      dio: dio,
      appDao: appDao,
    );
  }

  group('JsChannel 版本切换', () {
    test('① 脚本实现 versionOptions → 返回正确 Map（envs/versions/current）', () async {
      final channel = buildChannel();
      await channel.initialize();

      final data = await channel.versionOptions('com.example.one');
      expect(data, isNotNull);
      expect(data!['envs'], ['prod', 'test']);
      expect(data['currentEnv'], 'prod');
      expect(data['currentVersion'], '1.0.0');

      final versions = data['versions'] as List;
      expect(versions, hasLength(2));
      final first = versions[0] as Map;
      expect(first['version'], '1.0.0');
      expect(first['envs'], ['prod', 'test']);
      expect(first['buildCount'], 3);

      await channel.dispose();
    });

    test('② 脚本未实现（main 无 case 返回 null）→ 返回 null（降级）', () async {
      final channel = buildChannel(script: '''
const CHANNEL_META = { name: '无版本方法渠道' };
async function main(method, params) {
  switch (method) {
    case 'getAllApps':
      return { ok: true, data: [] };
    default:
      return null;
  }
}
''');
      await channel.initialize();

      expect(await channel.versionOptions('com.example.one'), isNull);
      expect(await channel.switchVersion(
        appId: 'com.example.one',
        env: 'prod',
        version: '1.0.0',
      ), isNull);
      expect(await channel.buildHistory(
        appId: 'com.example.one',
        version: '1.0.0',
        env: 'prod',
      ), isNull);

      await channel.dispose();
    });

    test('③ switchVersion → 返回详情 Map（同 getAppDetail 结构）', () async {
      final channel = buildChannel();
      await channel.initialize();

      final data = await channel.switchVersion(
        appId: 'com.example.one',
        env: 'prod',
        version: '1.0.0',
      );
      expect(data, isNotNull);
      expect(data!['appId'], 'com.example.one');
      expect(data['name'], 'App One');
      expect(data['packageName'], 'com.example.one');
      expect(data['developer'], 'dev');

      await channel.dispose();
    });

    test('④ buildHistory → 返回 builds Map', () async {
      final channel = buildChannel();
      await channel.initialize();

      final data = await channel.buildHistory(
        appId: 'com.example.one',
        version: '1.0.0',
        env: 'prod',
      );
      expect(data, isNotNull);
      final builds = data!['builds'] as List;
      expect(builds, hasLength(2));
      final first = builds[0] as Map;
      expect(first['num'], 3);
      expect(first['publishedAt'], '2024-01-03');
      expect(first['size'], 1024);
      expect(first['changelog'], '修复');
      expect(first['installTimes'], 10);
      expect(first['builtBy'], 'ci');
      expect(first['ipaName'], 'one-1.0.0-3.ipa');

      await channel.dispose();
    });

    test('⑤ ok:false → 返回 null（失败降级）', () async {
      final channel = buildChannel();
      await channel.initialize();

      expect(await channel.versionOptions('fail'), isNull);
      expect(await channel.switchVersion(
        appId: 'fail',
        env: 'prod',
        version: '1.0.0',
      ), isNull);
      expect(await channel.buildHistory(
        appId: 'fail',
        version: '1.0.0',
        env: 'prod',
      ), isNull);

      await channel.dispose();
    });

    test('⑥ versionOptions 带 env → 脚本收到 env（按需单 env 拉取）', () async {
      final channel = buildChannel();
      await channel.initialize();

      final data = await channel.versionOptions('com.example.one', env: 'test');
      expect(data, isNotNull);
      expect(data!['receivedEnv'], 'test');
      // 其余字段不受影响
      expect(data['envs'], ['prod', 'test']);
      expect(data['currentEnv'], 'prod');

      await channel.dispose();
    });

    test('⑦ versionOptions 不带 env → 脚本不收到 env（兼容旧调用）', () async {
      final channel = buildChannel();
      await channel.initialize();

      final data = await channel.versionOptions('com.example.one');
      expect(data, isNotNull);
      expect(data!['receivedEnv'], isNull);

      await channel.dispose();
    });

    test('⑧ getAppDetail 带 version → 脚本收到 version（单版本拉取）', () async {
      final channel = buildChannel();
      await channel.initialize();

      final result = await channel.getAppDetail(
        'com.example.one',
        version: '1.0.0',
      );
      expect(result.success, isTrue);
      final proxy = result.data as JsChannelDetailProxy;
      expect(proxy.data['receivedVersion'], '1.0.0');

      await channel.dispose();
    });

    test('⑨ getAppDetail 不带 version → 脚本不收到 version（兼容旧调用）', () async {
      final channel = buildChannel();
      await channel.initialize();

      final result = await channel.getAppDetail('com.example.one');
      expect(result.success, isTrue);
      final proxy = result.data as JsChannelDetailProxy;
      expect(proxy.data['receivedVersion'], isNull);

      await channel.dispose();
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
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

/// 固定响应 Dio adapter（测试用，模拟网络层；支持 __status 指定状态码）
class _FakeDioAdapter implements HttpClientAdapter {
  final Map<String, dynamic> Function(RequestOptions options)? handler;

  _FakeDioAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = handler?.call(options) ?? {'ok': true};
    var status = 200;
    if (data['__status'] != null) {
      status = data.remove('__status') as int;
    }
    return ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 测试脚本：导出 add/getObject/throwError 同步函数 + async 的 host 调用函数
const String _testScript = '''
function add(a, b) { return a + b; }

function getObject() {
  return {name: 'test', count: 3, list: [1, 2, 3]};
}

function throwError() { throw new Error('boom'); }

async function fetchData() {
  const res = await host.network.get('https://example.com/api', {params: {q: 'x'}});
  return res;
}

async function degradeOnStatus() {
  const res = await host.network.get('https://example.com/api', {params: {q: 'x'}});
  if (res && res.status === 500) {
    return { ok: false, status: res.status, data: res.data, degraded: true };
  }
  return res;
}

async function postData() {
  const res = await host.network.post('https://example.com/api', {json: {a: 1}});
  return res;
}

async function insertAndQuery() {
  const n = await host.database.insertApps([
    {appId: 'app1', name: 'App One', user: 'dev', repositories: 'repo', icon: 'i', description: 'd'},
    {appId: 'app2', name: 'App Two', user: 'dev', repositories: 'repo', icon: 'i', description: 'd'}
  ]);
  const apps = await host.database.getAppsByChannel();
  return {inserted: n, count: apps.data.length};
}

async function tryOtherChannel() {
  const app = await host.database.getApp('app-other');
  return app;
}

async function getConfig() {
  return await host.config.get('testKey');
}

async function logSomething() {
  host.log.info('hello info');
  host.log.error('hello error');
  return 'logged';
}
''';

void main() {
  late _FakeAppDao appDao;
  late Dio dio;
  late List<String> logMessages;

  setUp(() {
    appDao = _FakeAppDao();
    dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter((options) {
      return {
        'echo': options.path,
        'query': options.queryParameters,
        'method': options.method,
      };
    });
    logMessages = [];
  });

  JsChannelRuntime buildRuntime({String channelKey = 'js.test'}) {
    return JsChannelRuntime(
      channelKey: channelKey,
      script: _testScript,
      dio: dio,
      appDao: appDao,
      configGetter: (key) async => key == 'testKey' ? 'config-value' : null,
      logInfo: (msg) => logMessages.add('info: $msg'),
      logError: (msg) => logMessages.add('error: $msg'),
    );
  }

  group('JsChannelRuntime', () {
    test('① initialize 加载脚本成功', () async {
      final runtime = buildRuntime();
      await runtime.initialize();
      expect(runtime.isInitialized, isTrue);
      expect(runtime.isDisposed, isFalse);
      await runtime.dispose();
    });

    test('② call 调 JS 函数返回正确 JSON', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final sum = await runtime.call('add', [1, 2]);
      expect(sum, 3);

      final obj = await runtime.call('getObject');
      expect(obj, isA<Map>());
      final map = obj as Map;
      expect(map['name'], 'test');
      expect(map['count'], 3);
      expect(map['list'], [1, 2, 3]);

      await runtime.dispose();
    });

    test('③ host network 回调（fake Dio）返回 {ok, status, data}', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('fetchData');
      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['ok'], isTrue);
      expect(map['status'], 200);
      final data = map['data'] as Map;
      expect(data['echo'], 'https://example.com/api');
      expect(data['query'], {'q': 'x'});

      final postResult = await runtime.call('postData');
      expect((postResult as Map)['ok'], isTrue);

      await runtime.dispose();
    });

    test('③a host.network 500 → 不抛，返回 {ok:false, status:500, data:响应体}', () async {
      final dio2 = Dio();
      dio2.httpClientAdapter = _FakeDioAdapter((options) {
        return {'__status': 500, 'msg': 'server error'};
      });
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _testScript,
        dio: dio2,
        appDao: appDao,
        logInfo: (msg) => logMessages.add('info: $msg'),
        logError: (msg) => logMessages.add('error: $msg'),
      );
      await runtime.initialize();

      final result = await runtime.call('fetchData');
      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['ok'], isFalse);
      expect(map['status'], 500);
      expect(map['error'], isNotEmpty);
      final data = map['data'] as Map;
      expect(data['msg'], 'server error'); // 非 2xx 响应体保留

      await runtime.dispose();
    });

    test('③b host.network 401 → {ok:false, status:401, data:响应体}', () async {
      final dio2 = Dio();
      dio2.httpClientAdapter = _FakeDioAdapter((options) {
        return {'__status': 401, 'msg': 'unauthorized'};
      });
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _testScript,
        dio: dio2,
        appDao: appDao,
        logInfo: (msg) => logMessages.add('info: $msg'),
        logError: (msg) => logMessages.add('error: $msg'),
      );
      await runtime.initialize();

      final result = await runtime.call('fetchData');
      final map = result as Map;
      expect(map['ok'], isFalse);
      expect(map['status'], 401);
      expect((map['data'] as Map)['msg'], 'unauthorized');

      await runtime.dispose();
    });

    test('③c host.network 200 → {ok:true, status:200, data}（无 error 键）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('fetchData');
      final map = result as Map;
      expect(map['ok'], isTrue);
      expect(map['status'], 200);
      expect(map.containsKey('error'), isFalse);
      expect(map['data'], isA<Map>());

      await runtime.dispose();
    });

    test('③d 网络异常（连接失败）→ {ok:false, error}（不崩）', () async {
      final dio2 = Dio();
      dio2.httpClientAdapter = _FakeDioAdapter((options) {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'Connection refused',
        );
      });
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _testScript,
        dio: dio2,
        appDao: appDao,
        logInfo: (msg) => logMessages.add('info: $msg'),
        logError: (msg) => logMessages.add('error: $msg'),
      );
      await runtime.initialize();

      final result = await runtime.call('fetchData');
      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['ok'], isFalse);
      expect(map['error'], isNotEmpty);
      expect(logMessages.any((m) => m.contains('error:')), isTrue);

      await runtime.dispose();
    });

    test('③e JS 脚本按 status 降级（status==500 → 降级分支，读响应体）', () async {
      final dio2 = Dio();
      dio2.httpClientAdapter = _FakeDioAdapter((options) {
        return {'__status': 500, 'msg': 'server error'};
      });
      final runtime = JsChannelRuntime(
        channelKey: 'js.test',
        script: _testScript,
        dio: dio2,
        appDao: appDao,
        logInfo: (msg) => logMessages.add('info: $msg'),
        logError: (msg) => logMessages.add('error: $msg'),
      );
      await runtime.initialize();

      final result = await runtime.call('degradeOnStatus');
      final map = result as Map;
      expect(map['ok'], isFalse);
      expect(map['status'], 500);
      expect(map['degraded'], isTrue);
      expect((map['data'] as Map)['msg'], 'server error');

      await runtime.dispose();
    });

    test('④ host database 强制 channelKey（其他渠道数据不可见）', () async {
      // 预置其他渠道的数据
      await appDao.insertApp(ChannelAddedApp(
        appId: 'app-other',
        name: 'Other Channel App',
        user: 'u',
        repositories: 'r',
        icon: 'i',
        description: 'd',
        addTime: 1,
        channelCode: 'js.other', // 其他渠道
      ));

      final runtime = buildRuntime(channelKey: 'js.test');
      await runtime.initialize();

      // 插入当前渠道数据
      final insertResult = await runtime.call('insertAndQuery');
      final insertMap = insertResult as Map;
      // insertApps 返回 {ok, data} 包装，data 为插入数量
      expect((insertMap['inserted'] as Map)['data'], 2);
      expect(insertMap['count'], 2);

      // 尝试读取 app-other（其他渠道有，当前渠道无）→ 返回 null
      final otherResult = await runtime.call('tryOtherChannel');
      expect(otherResult, isA<Map>());
      expect((otherResult as Map)['ok'], isTrue);
      expect(otherResult['data'], isNull);

      // 当前渠道确实有 app1（隔离验证：插入时强制 channelKey）
      final own = await appDao.getApp('app1', 'js.test');
      expect(own, isNotNull);
      expect(own!.channelCode, 'js.test');

      await runtime.dispose();
    });

    test('⑤ JS 抛错 → call 抛 JsChannelException 不崩应用', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      await expectLater(
        runtime.call('throwError'),
        throwsA(isA<JsChannelException>()),
      );

      // 抛错后 runtime 仍可用
      final sum = await runtime.call('add', [10, 20]);
      expect(sum, 30);

      await runtime.dispose();
    });

    test('⑥ dispose 释放后不可再调用', () async {
      final runtime = buildRuntime();
      await runtime.initialize();
      await runtime.dispose();

      expect(runtime.isDisposed, isTrue);
      await expectLater(
        runtime.call('add', [1, 1]),
        throwsA(isA<JsChannelException>()),
      );
    });

    test('host config 与 log 回调', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final config = await runtime.call('getConfig');
      expect((config as Map)['data'], 'config-value');

      final logged = await runtime.call('logSomething');
      expect(logged, 'logged');
      expect(logMessages, contains('info: hello info'));
      expect(logMessages, contains('error: hello error'));

      await runtime.dispose();
    });
  });
}
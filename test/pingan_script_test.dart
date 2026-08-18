import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';

/// pingan.js 渠道脚本测试：验证脚本语法正确 + 引擎加载无错 + 分发器各方法行为。
///
/// ⚠️ 本测试不请求真实网络：host.network 走注入的假 Dio adapter（按 path 路由假响应），
/// host.database 走内存假 DAO。真实调用（连平安 test-b-fat 平台）需真机/可用网络。
///
/// 注意：脚本在 test/ 下直接读取 scripts/channels/pingan.js（flutter test 以项目根为 cwd）。

const String _pinganHost = 'https://test-b-fat.pingan.com.cn/istore';
const String _channelKey = 'js_pingan_test';

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

/// 固定响应 Dio adapter（测试用，模拟网络层；按 path 路由）
class _FakeDioAdapter implements HttpClientAdapter {
  final Map<String, dynamic> Function(RequestOptions options) handler;
  final List<String> requestLog;

  _FakeDioAdapter(this.handler, this.requestLog);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestLog.add('${options.method} ${options.path}'
        '?pageNum=${options.queryParameters['pageNum'] ?? '-'}'
        '&appname=${options.queryParameters['appname'] ?? '-'}'
        '&version=${options.queryParameters['version'] ?? '-'}'
        '&env=${options.queryParameters['env'] ?? '-'}');
    final data = handler(options);    if (data['__status'] != null) {
      final status = data.remove('__status') as int;
      return ResponseBody.fromString(
        jsonEncode(data),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode(data),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 假平台响应构建器：app-list 分页 / build-list 版本 / login/check 认证
class _FakePinganApi {
  /// total 条应用（分页 pageSize=20）；pageNum 超过所需页 → 空 appList
  Map<String, dynamic> appList(int total, int pageNum) {
    final items = <Map<String, dynamic>>[];
    final start = (pageNum - 1) * 20 + 1;
    for (var i = start; i <= total && i < start + 20; i++) {
      items.add({
        '_id': 'id-$i',
        'name': 'app-$i',
        'displayname': '应用$i',
        'intro': '应用$i 的简介 description-$i',
        'imgSrc': '/icons/$i.png',
        'screenshots': ['/shots/${i}a.png', '/shots/${i}b.png'],
      });
    }
    return {'total': total, 'appList': items};
  }

  /// build-list：ios 组 publishedAt 最新（用于验证"排序后取第一个 android"）
  Map<String, dynamic> buildList({required bool withFileUrl}) {
    return {
      'appLogo': '/logo/app.png',
      'buildList': [
        {
          '_id': 'bg-ios',
          'version': '2.0.0',
          'platform': 'ios',
          'env': 'sit',
          'publishedAt': 1700000000000,
          'status': 'success',
          'builds': [
            {
              'identifier': 'com.pingan.ios',
              'versionname': '2.0.0',
              'num': 2,
              'size': 8000,
              'installTimes': 1,
              'changelog': 'ios changelog',
              'builtBy': 'tester',
              'fileurl': [],
            },
          ],
        },
        {
          '_id': 'bg-android',
          'version': '1.9.0',
          'platform': 'android',
          'env': 'sit',
          'publishedAt': 1690000000000, // 比 ios 旧 → 排序后仍应选 android
          'status': 'success',
          'builds': [
            {
              'identifier': 'com.pingan.app',
              'versionname': '1.9.0',
              'num': 7,
              'size': 12345678,
              'installTimes': 99,
              'changelog': '修复若干问题',
              'builtBy': 'ci-bot',
              'fileurl': withFileUrl ? ['/apk/com.pingan.app-1.9.0.apk'] : [],
            },
          ],
        },
      ],
    };
  }

  /// build-list：仅 ios 组（无 android 构建）
  Map<String, dynamic> buildListNoAndroid() {
    final data = buildList(withFileUrl: false);
    (data['buildList'] as List).removeAt(1);
    return data;
  }
}

void main() {
  late _FakeAppDao appDao;
  late List<String> requestLog;
  late List<String> logMessages;

  setUp(() {
    appDao = _FakeAppDao();
    requestLog = [];
    logMessages = [];
  });

  final api = _FakePinganApi();

  late String script;
  setUpAll(() {
    script = File('scripts/channels/pingan.js').readAsStringSync();
    expect(script, contains('CHANNEL_META'), reason: '脚本应包含 CHANNEL_META');
  });

  /// 默认 handler：app-list 25 条分页 + build-list（fileurl 空）+ 认证 200 无 url
  Map<String, dynamic> defaultHandler(RequestOptions options) {
    final path = options.path;
    if (path.contains('/sunflower/i/app-list')) {
      return api.appList(25, (options.queryParameters['pageNum'] as num?)?.toInt() ?? 1);
    }
    if (path.contains('/sunflower/i/build-list')) {
      return api.buildList(withFileUrl: false);
    }
    if (path.contains('login/check')) {
      return {'code': 0, 'msg': 'ok'}; // 认证成功但响应无下载地址
    }
    return {'code': -1};
  }

  JsChannelRuntime buildRuntime({
    Map<String, String> Function()? env,
    Map<String, dynamic> Function(RequestOptions options)? handler,
  }) {
    final dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter(handler ?? defaultHandler, requestLog);
    return JsChannelRuntime(
      channelKey: _channelKey,
      script: script,
      dio: dio,
      appDao: appDao,
      envReader: env ?? () => const <String, String>{},
      logInfo: (msg) => logMessages.add('info: $msg'),
      logError: (msg) => logMessages.add('error: $msg'),
    );
  }

  group('pingan.js 脚本渠道', () {
    test('① initialize 加载脚本成功 + CHANNEL_META 正确', () async {
      final runtime = buildRuntime();
      await runtime.initialize();
      expect(runtime.isInitialized, isTrue);

      final meta = await runtime.evaluate(
          "typeof CHANNEL_META !== 'undefined' ? CHANNEL_META : null");
      expect(meta, isA<Map>());
      final map = meta as Map;
      expect(map['name'], '平安测试商店');
      expect(map['description'], contains('Iris Store'));

      await runtime.dispose();
    });

    test('② getAllApps 分页拉全量（2 页 25 条）+ AppInfo 映射', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', ['getAllApps', {}]);
      expect(result, isA<Map>());
      final map = result as Map;
      expect(map['ok'], isTrue);

      final data = map['data'] as List;
      expect(data.length, 25);

      final first = data.first as Map;
      expect(first['appId'], 'app-1'); // 列表阶段 appId = a.name
      expect(first['name'], '应用1'); // displayname
      expect(first['des'], '应用1 的简介 description-1'); // intro
      expect(first['icon'], '$_pinganHost/icons/1.png'); // imgSrc 补全 host
      expect(first['description'], '应用1 的简介 description-1'); // 落库兼容字段
      expect(first['repositories'], 'id-1');

      final extra = first['extra'] as Map;
      expect(extra['_id'], 'id-1');
      expect(extra['screenshots'], [
        '$_pinganHost/shots/1a.png',
        '$_pinganHost/shots/1b.png',
      ]); // screenshots 补全

      // 分页请求只到第 2 页（第 3 页 appList 空提前结束）
      final pageRequests =
          requestLog.where((r) => r.contains('app-list')).toList();
      expect(pageRequests.length, 2);
      expect(pageRequests[0], contains('pageNum=1'));
      expect(pageRequests[1], contains('pageNum=2'));

      await runtime.dispose();
    });

    test('②b 所有请求携带 Android Chrome User-Agent 头', () async {
      const expectedUa =
          'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';
      final capturedHeaders = <Map<String, dynamic>>[];
      final runtime = buildRuntime(handler: (options) {
        capturedHeaders.add(options.headers);
        return defaultHandler(options);
      });
      await runtime.initialize();

      // 触发 app-list + build-list + login/check 三类请求
      await runtime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;

      expect(capturedHeaders, isNotEmpty);
      for (final h in capturedHeaders) {
        expect(h['User-Agent'], expectedUa,
            reason: '每个请求都应携带写死的 Android Chrome UA');
      }

      await runtime.dispose();
    });

    test('③ getAllApps 网络失败 → {ok:false, data:null} + 日志', () async {      final runtime = buildRuntime(handler: (options) {
        return {'__status': 500, 'msg': 'server error'};
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['getAllApps', {}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(logMessages.any((m) => m.contains('error:')), isTrue);

      await runtime.dispose();
    });

    test('④ searchApps 本地过滤（名称/描述，忽略大小写）+ 上限 50', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/app-list')) {
          // 3 页共 60 条（total=60）
          return api.appList(60, (options.queryParameters['pageNum'] as num?)?.toInt() ?? 1);
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      // 大小写不敏感：大写 keyword 命中 intro 中的小写 description-25
      // （description-5 会同时命中 description-50..59，故用唯一的 25）
      final r1 = await runtime.call('main', ['searchApps', {'keyword': 'DESCRIPTION-25'}]) as Map;
      expect(r1['ok'], isTrue);
      final d1 = r1['data'] as List;
      expect(d1.length, 1);
      expect((d1.first as Map)['appId'], 'app-25');

      // 命中 displayname（应用25）
      final r2 = await runtime.call('main', ['searchApps', {'keyword': '应用25'}]) as Map;
      final d2 = r2['data'] as List;
      expect(d2.length, 1);
      expect((d2.first as Map)['name'], '应用25');

      // 空 keyword → 空数组（不发网络请求）
      final r3 = await runtime.call('main', ['searchApps', {'keyword': ''}]) as Map;
      expect(r3['ok'], isTrue);
      expect(r3['data'], isEmpty);

      // 全部命中（60 条）→ 上限 50
      final r4 = await runtime.call('main', ['searchApps', {'keyword': 'app-'}]) as Map;
      expect((r4['data'] as List).length, 50);

      await runtime.dispose();
    });

    test('⑤ getAppInfo：取最新 android 构建（排序 + platform 过滤）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final app = result['data'] as Map;

      expect(app['appId'], 'com.pingan.app'); // builds[0].identifier 真实包名
      expect(app['name'], '1.9.0'); // versionname
      expect(app['des'], 'app-1'); // des = 查询用 appId
      expect(app['icon'], '$_pinganHost/logo/app.png'); // appLogo 补全

      final extra = app['extra'] as Map;
      expect(extra['_id'], 'bg-android');
      expect(extra['version'], '1.9.0');
      expect(extra['versionname'], '1.9.0');
      expect(extra['num'], 7);
      expect(extra['size'], 12345678);
      expect(extra['installTimes'], 99);
      expect(extra['changelog'], '修复若干问题');
      expect(extra['builtBy'], 'ci-bot');
      expect(extra['env'], 'sit');
      expect(extra['platform'], 'android');
      expect(extra['publishedAt'], 1690000000000);

      // fileurl 空 + 无环境变量 → 认证降级
      expect(extra['apkUrl'], isNull);
      expect(extra['downloadNote'], '需认证或暂不可下载');
      expect((extra['authError'] as String), contains('未配置'));

      await runtime.dispose();
    });

    test('⑥ getAppInfo：fileurl 非空 → apkUrl 直接绝对化（不认证）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return api.buildList(withFileUrl: true);
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;
      final extra = (result['data'] as Map)['extra'] as Map;
      expect(extra['apkUrl'], '$_pinganHost/apk/com.pingan.app-1.9.0.apk');
      expect(extra['downloadNote'], isNull);
      // 未发起认证请求
      expect(requestLog.any((r) => r.contains('login/check')), isFalse);

      await runtime.dispose();
    });

    test('⑦ getAppInfo：fileurl 空 + 配置环境变量 → 认证成功拿下载地址', () async {
      final runtime = buildRuntime(
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'secret'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildList(withFileUrl: false);
          }
          if (options.path.contains('login/check')) {
            return {'code': 0, 'url': '/download/token-redirect.apk'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;
      final extra = (result['data'] as Map)['extra'] as Map;
      expect(extra['apkUrl'], '$_pinganHost/download/token-redirect.apk');
      expect(extra['downloadNote'], isNull);
      // 确实发起了认证请求（先主路径，成功即止）
      final authRequests = requestLog.where((r) => r.contains('login/check')).toList();
      expect(authRequests.length, 1);
      expect(authRequests.first, contains('/mcd-api/mcd-api/login/check'));

      await runtime.dispose();
    });

    test('⑧ getAppInfo：认证失败（401）→ 降级不抛，记录 authError', () async {
      final runtime = buildRuntime(
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'wrong'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildList(withFileUrl: false);
          }
          if (options.path.contains('login/check')) {
            return {'__status': 401, 'msg': 'unauthorized'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;
      // 认证失败绝不抛 → 脚本正常返回 AppInfo
      expect(result['ok'], isTrue);
      final extra = (result['data'] as Map)['extra'] as Map;
      expect(extra['apkUrl'], isNull);
      expect(extra['downloadNote'], '需认证或暂不可下载');
      expect((extra['authError'] as String), contains('认证失败'));
      // 主路径失败 → 尝试了文档路径
      expect(requestLog.where((r) => r.contains('login/check')).length, 2);

      await runtime.dispose();
    });

    test('⑨ getAppInfo：无 android 构建 → {ok:false, data:null, error}（非 data:null）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return api.buildListNoAndroid();
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], '未找到该应用的 Android 构建');

      await runtime.dispose();
    });

    test('⑩ getAppInfo：网络失败 → {ok:false, data:null}（不抛）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {'__status': 500, 'msg': 'boom'};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);

      await runtime.dispose();
    });

    test('⑪ getAppInfo 空 appId → 直接 null，不发请求', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppInfo', {'appId': ''}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(requestLog, isEmpty);

      await runtime.dispose();
    });

    test('⑫ doUpdate 落库（强制 channelKey）+ checkUpdate 长度对比', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      // 库为空 → checkUpdate 返回 true（有变化）
      final before = await runtime.call('main', ['checkUpdate', {}]) as Map;
      expect(before['ok'], isTrue);
      expect(before['data'], isTrue);

      // doUpdate → 拉全量落库 → true
      final upd = await runtime.call('main', ['doUpdate', {}]) as Map;
      expect(upd['ok'], isTrue);
      expect(upd['data'], isTrue);

      final saved = await appDao.getAppsByChannel(_channelKey);
      expect(saved.length, 25);
      expect(saved.every((a) => a.channelCode == _channelKey), isTrue);
      // 描述与 extra 完整落库
      final first = saved.first;
      expect(first.description, '应用1 的简介 description-1');
      final extra = first.getExtraData();
      expect(extra?['_id'], 'id-1');
      expect((extra?['screenshots'] as List).length, 2);

      // 落库后长度一致 → checkUpdate 返回 false
      final after = await runtime.call('main', ['checkUpdate', {}]) as Map;
      expect(after['ok'], isTrue);
      expect(after['data'], isFalse);

      await runtime.dispose();
    });

    test('⑬ doUpdate 网络失败 → {ok:false, data:false} 不落库', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/app-list')) {
          return {'__status': 500, 'msg': 'boom'};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['doUpdate', {}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isFalse);
      expect(await appDao.getCountByChannel(_channelKey), 0);

      await runtime.dispose();
    });

    test('⑭ getAppDetail：同 getAppInfo + 详情页字段（downloads 等）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;

      expect(d['appId'], 'com.pingan.app');
      expect(d['name'], '1.9.0');
      expect(d['packageName'], 'com.pingan.app');
      expect(d['version'], '1.9.0');
      expect(d['description'], 'app-1');

      // extra 完整（含降级 note）
      final extra = d['extra'] as Map;
      expect(extra['_id'], 'bg-android');
      expect(extra['downloadNote'], '需认证或暂不可下载');

      // downloads 数组（详情页代理读取：size 为数字）
      final downloads = d['downloads'] as List;
      expect(downloads.length, 1);
      final dl = downloads.first as Map;
      expect(dl['url'], ''); // 无下载地址时 url 为空串
      expect(dl['name'], '1.9.0.apk');
      expect(dl['size'], 12345678);
      expect(dl['version'], '1.9.0');
      expect(dl['platform'], 'android');

      await runtime.dispose();
    });

    test('⑰ getAppDetail：无 android 构建 → {ok:false, data:null, error}（非 data:null）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return api.buildListNoAndroid();
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], '未找到该应用的 Android 构建');

      await runtime.dispose();
    });

    test('⑱ getAppDetail：appId 传包名（已落库有 name）→ 查库解析 name → 成功返回详情', () async {
      // 落库一条记录：appId=列表 name（ibank），extra.appId=真实包名 identifier
      await appDao.insertApp(ChannelAddedApp(
        appId: 'ibank',
        name: 'ibank',
        user: '',
        repositories: 'id-ibank',
        icon: '',
        description: '平安口袋银行',
        addTime: 0,
        channelCode: _channelKey,
        extra: jsonEncode({'appId': 'com.pingan.pabank.activity'}),
      ));

      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          final appname = options.queryParameters['appname']?.toString() ?? '';
          if (appname == 'com.pingan.pabank.activity') {
            return api.buildListNoAndroid(); // 包名查不到 android 构建
          }
          return api.buildList(withFileUrl: false); // 列表 name 查到
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'com.pingan.pabank.activity'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;
      expect(d['appId'], 'com.pingan.app'); // builds[0].identifier 真实包名
      expect(d['packageName'], 'com.pingan.app');
      expect(d['version'], '1.9.0');

      // 两次 build-list：先包名（无结果）→ 再列表 name（成功）
      final buildRequests = requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 2);
      expect(buildRequests[0], contains('appname=com.pingan.pabank.activity'));
      expect(buildRequests[1], contains('appname=ibank'));

      await runtime.dispose();
    });

    test('⑲ getAppDetail：网络失败 → {ok:false, data:null}（不抛）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {'__status': 500, 'msg': 'boom'};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], contains('build-list 请求失败'));

      await runtime.dispose();
    });

    test('⑮ 未实现 method（getConfig）→ null，不抛（JsChannel 降级策略）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', ['getConfig', {}]);
      expect(result, isNull);

      await runtime.dispose();
    });

    test('⑯ checkAppUpdate 返回版本信息', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', ['checkAppUpdate', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final data = result['data'] as Map;
      expect(data['appId'], 'com.pingan.app');
      expect(data['packageName'], 'com.pingan.app');
      expect(data['version'], '1.9.0');

      await runtime.dispose();
    });

    test('⑳ getVersionOptions 带 env → 只拉该 env 一次（envs 仍全量 5 个）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          final env = options.queryParameters['env']?.toString() ?? '';
          // 按 env 返回不同版本组（验证只请求目标 env）
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-$env',
                'version': '1.0.0',
                'platform': 'android',
                'env': env,
                'publishedAt': 1700000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.app',
                    'versionname': '1.0.0',
                    'num': 1,
                    'size': 100,
                    'fileurl': [],
                  },
                ],
              },
            ],
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['versionOptions', {'appId': 'app-1', 'env': 'uat'}]) as Map;
      expect(result['ok'], isTrue);
      final data = result['data'] as Map;

      // envs 仍返回全部 5 个（chips 显示用）
      expect(data['envs'], ['sit', 'uat', 'prd', 'rge', 'tmp']);
      // versions 只含该 env 的版本
      final versions = data['versions'] as List;
      expect(versions.length, 1);
      expect((versions.first as Map)['version'], '1.0.0');
      expect((versions.first as Map)['envs'], ['uat']);
      expect(data['currentEnv'], 'uat');
      expect(data['currentVersion'], '1.0.0');

      // 只发了一次 build-list 请求（按 env 单次，不再遍历 5 env）
      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('env=uat'));

      await runtime.dispose();
    });

    test('㉑ getVersionOptions 不带 env → 按凭证默认 env（sit）单次拉取', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['versionOptions', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final data = result['data'] as Map;
      expect(data['currentEnv'], 'sit');
      // defaultHandler 的 buildList 有 ios(2.0.0) + android(1.9.0) 两组
      final versions = data['versions'] as List;
      expect(versions.length, 2);
      expect((versions.first as Map)['version'], '2.0.0'); // 最新 publishedAt 在前

      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('env=sit'));

      await runtime.dispose();
    });

    test('㉒ getVersionOptions 单 env 失败 → ok:false（不再静默跳过）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {'__status': 500, 'msg': 'boom'};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['versionOptions', {'appId': 'app-1', 'env': 'prd'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);

      await runtime.dispose();
    });

    test('㉓ getAppDetail 带 version → build-list 单版本拉取（version 参数）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'app-1', 'version': '1.9.0'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;
      expect(d['version'], '1.9.0');
      expect(d['appId'], 'com.pingan.app');

      // 单版本拉取：只发一次 build-list，且携带 version 参数
      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('version=1.9.0'));

      await runtime.dispose();
    });

    test('㉔ getAppInfo 带 version → build-list 单版本拉取（version 参数）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppInfo', {'appId': 'app-1', 'version': '1.9.0'}]) as Map;
      expect(result['ok'], isTrue);
      final app = result['data'] as Map;
      expect(app['name'], '1.9.0'); // versionname
      expect((app['extra'] as Map)['version'], '1.9.0');

      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('version=1.9.0'));

      await runtime.dispose();
    });
  });
}

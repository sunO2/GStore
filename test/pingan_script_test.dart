import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';
import 'package:gstore/core/js/js_native_host.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';

/// pingan.js 渠道脚本测试（zip 渠道包）：验证脚本语法正确 + 引擎加载无错 + 分发器各方法行为。
///
/// ⚠️ 本测试不请求真实网络：host.network 走注入的假 Dio adapter（按 path 路由假响应），
/// host.database 走内存假 DAO。真实调用（连平安 test-b-fat 平台）需真机/可用网络。
///
/// 注意：脚本在 test/ 下读取 scripts/channels/pingan.zip（flutter test 以项目根为 cwd），
/// 经 ChannelPackage.decode 解出 entry.js（发现页）与 detail.js（详情页）两份脚本：
/// - 发现页/更新路径方法（getAllApps/searchApps/getAppInfo/getAppDetail/checkAppUpdate/
///   checkUpdate/doUpdate）→ entry runtime（JsChannel 消费）
/// - 详情页方法（getAppDetail/versionOptions/switchVersion/buildHistory/detailMenu/
///   jsswitchVersion/jsBuildHistory）→ detail runtime（JsDetailChannel 消费）
/// entry/detail 各自独立 runtime（独立 QuickJS context），工具函数/认证缓存不共享。

const String _pinganHost = 'https://test-b-fat.pingan.com.cn/istore';
const String _apiBase = '$_pinganHost/istore-api';
const String _mcdBase = 'https://test-b-fat.pingan.com.cn/mcd-api/mcd-api';
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
  /// __v 为 0 基构建计数（__v=34 → 35 次构建），此处 android 7 次 → __v=6。
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
          '__v': 1, // 2 次构建（0 基）
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
          '__v': 6, // 7 次构建（0 基）
          'builds': [
            {
              'identifier': 'com.pingan.app',
              'versionname': '1.9.0',
              'num': 7,
              'size': 12345678,
              'installTimes': 99,
              'changelog': '修复若干问题',
              'builtBy': 'ci-bot',
              // 真实接口结构：ipa[0].name 下载文件名（proxy 转发）
              'ipa': [
                {'name': 'com.pingan.app-1.9.0.apk', '_id': 'ipa-1'},
              ],
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

  /// 真实接口结构：build-list 组内 builds **无 ipa 字段**（仅 fileurl/versionname/num），
  /// 平安口袋银行场景（appname=ibank, env=sit, android 8.8.0）——首次路径下载名/URL
  /// 必须靠 build 接口（_id）补全 ipa[0].name 才能拼出（首次下载项 bug 的根因 mock）。
  Map<String, dynamic> buildListNoIpa() {
    return {
      'appLogo': '/logo/app.png',
      'buildList': [
        {
          '_id': 'bg-ibank',
          'version': '8.8.0',
          'platform': 'android',
          'env': 'sit',
          'publishedAt': 1700000000000,
          'status': 'success',
          'builds': [
            {
              'identifier': 'com.pingan.pabank.activity',
              'versionname': '8.8.0',
              'num': 35,
              'size': 23456789,
              'installTimes': 88,
              'changelog': '修复若干问题',
              'builtBy': 'ci-bot',
              'fileurl': <Object>[],
            },
          ],
        },
      ],
    };
  }

  /// build 接口（_id 查询）：真实结构 {'build': {'builds': [...]}, 'appInfo': {...}}，
  /// 每条构建含 ipa[0].name 真实下载文件名（proxy 转发用，如 PABank-Debug-8.8.0-35.apk）
  Map<String, dynamic> buildDetail(String groupId, {required String ipaName}) {
    return {
      'build': {
        '_id': groupId,
        'version': '8.8.0',
        'builds': [
          {
            'identifier': 'com.pingan.pabank.activity',
            'versionname': '8.8.0',
            'num': 35,
            'size': 23456789,
            'installTimes': 88,
            'changelog': '修复若干问题',
            'builtBy': 'ci-bot',
            'ipa': [
              {'name': ipaName, '_id': 'ipa-35'},
            ],
            'fileurl': <Object>[],
          },
        ],
      },
      'appInfo': {
        'displayname': '平安口袋银行',
        'intro': '平安口袋银行介绍',
        'name': 'ibank',
        'screenshots': <Object>[],
      },
    };
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
  late String detailScript;
  late Map<String, dynamic> pkgMeta;
  setUpAll(() {
    final zipBytes = File('scripts/channels/pingan.zip').readAsBytesSync();
    final pkg = ChannelPackage.decode(zipBytes);
    expect(pkg, isNotNull, reason: 'pingan.zip 应可解析（entry.js 必须）');
    script = pkg!.entryScript;
    detailScript = pkg.detailScript!;
    expect(detailScript, isNotEmpty, reason: 'pingan.zip 应包含 detail.js');
    pkgMeta = pkg.meta!;
    expect(script, contains('CHANNEL_META'), reason: 'entry.js 应包含 CHANNEL_META');
    expect(pkgMeta['name'], '平安测试商店', reason: 'meta.json name 正确');
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
      return {'code': '000000', 'msg': 'success'}; // 认证成功
    }
    return {'code': -1};
  }

  JsChannelRuntime buildRuntime({
    Map<String, String> Function()? env,
    Map<String, dynamic> Function(RequestOptions options)? handler,
    String? scriptOverride,
  }) {
    final dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter(handler ?? defaultHandler, requestLog);
    return JsChannelRuntime(
      channelKey: _channelKey,
      script: scriptOverride ?? script,
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
      expect(first['icon'], '$_apiBase/icons/1.png'); // imgSrc 补全 API_BASE
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

    test('③ getAllApps 网络失败 → {ok:false, data:null}（不抛）', () async {      final runtime = buildRuntime(handler: (options) {
        return {'__status': 500, 'msg': 'server error'};
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['getAllApps', {}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], isNotEmpty);

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

      // 修复契约：appId 保持渠道查询键（build-list 的 appname），不再用 identifier 包名覆盖；
      // 真实包名移入 packageName / extra.identifier（否则详情/聚合请求 appId 变包名 → ok:false）
      expect(app['appId'], 'app-1'); // 查询键
      expect(app['packageName'], 'com.pingan.app'); // 真实包名（安装检测用）
      expect(app['name'], '1.9.0'); // versionname
      expect(app['des'], 'app-1'); // des = 查询用 appId
      expect(app['icon'], '$_apiBase/logo/app.png'); // appLogo 补全 API_BASE

      final extra = app['extra'] as Map;
      expect(extra['_id'], 'bg-android');
      expect(extra['identifier'], 'com.pingan.app'); // 真实包名
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

    test('⑦ getAppInfo：fileurl 空 + 配置环境变量 → 一次性凭证检测通过 → proxy 下载地址', () async {
      final runtime = buildRuntime(
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'secret'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildList(withFileUrl: false);
          }
          if (options.path.contains('login/check')) {
            return {'code': '000000', 'msg': 'success'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;
      final extra = (result['data'] as Map)['extra'] as Map;
      // 下载地址 = proxy 拼接（不经 login/check 返回值）；无 PINGAN_ENV → 默认 env=sit
      expect(
        extra['apkUrl'],
        '$_mcdBase/proxy/prd/com.pingan.app-1.9.0.apk?um=tester&value=secret',
      );
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
      // 主路径失败
      expect(requestLog.where((r) => r.contains('login/check')).length, 1);

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
      final runtime = buildRuntime(scriptOverride: detailScript);
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;

      expect(d['appId'], 'app-1'); // 查询键（修复：不再用 identifier 包名覆盖）
      expect(d['name'], '1.9.0');
      expect(d['packageName'], 'com.pingan.app'); // 真实包名
      expect(d['version'], '1.9.0');
      expect(d['description'], 'app-1');

      // extra 完整（含降级 note）
      final extra = d['extra'] as Map;
      expect(extra['_id'], 'bg-android');
      expect(extra['identifier'], 'com.pingan.app'); // 真实包名
      expect(extra['downloadNote'], '需认证或暂不可下载');

      // downloads 数组（详情页代理读取：size 为数字）
      final downloads = d['downloads'] as List;
      expect(downloads.length, 1);
      final dl = downloads.first as Map;
      expect(dl['url'], ''); // 无下载地址时 url 为空串
      expect(dl['name'], 'com.pingan.app-1.9.0.apk'); // 下载名优先真实 ipa[0].name
      expect(dl['size'], 12345678);
      expect(dl['version'], '1.9.0');
      expect(dl['platform'], 'android');

      await runtime.dispose();
    });

    test('⑰ getAppDetail：无 android 构建 → {ok:false, data:null, error}（非 data:null）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
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

      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
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
      expect(d['appId'], 'ibank'); // 查库解析出的渠道查询名（不再用 identifier 包名覆盖）
      expect(d['packageName'], 'com.pingan.app');
      expect(d['version'], '1.9.0');
      expect((d['extra'] as Map)['identifier'], 'com.pingan.app');

      // 两次 build-list：先包名（无结果）→ 再列表 name（成功）
      final buildRequests = requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 2);
      expect(buildRequests[0], contains('appname=com.pingan.pabank.activity'));
      expect(buildRequests[1], contains('appname=ibank'));

      await runtime.dispose();
    });

    test('⑲ getAppDetail：网络失败 → {ok:false, data:null}（不抛）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
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
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
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
      final runtime = buildRuntime(scriptOverride: detailScript);
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['versionOptions', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final data = result['data'] as Map;
      expect(data['currentEnv'], 'sit'); // readCredentials 默认 env=sit（无 PINGAN_ENV）
      // defaultHandler 的 buildList 有 ios(2.0.0) + android(1.9.0) 两组；
      // versions 只统计 android 平台组 → ios 2.0.0 不进版本列表（最新版本必须基于 android）
      final versions = data['versions'] as List;
      expect(versions.length, 1);
      expect((versions.first as Map)['version'], '1.9.0'); // 仅 android 版本
      expect(data['currentVersion'], '1.9.0');

      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('env=sit'));

      await runtime.dispose();
    });

    test('㉑b 配置 PINGAN_ENV → 覆盖默认 env（sit 默认被替换为 prd）', () async {
      final runtime = buildRuntime(
        scriptOverride: detailScript,
        env: () => {'PINGAN_ENV': 'prd'},
      );
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['versionOptions', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect((result['data'] as Map)['currentEnv'], 'prd');

      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('env=prd'));

      await runtime.dispose();
    });

    test('㉒ getVersionOptions 单 env 失败 → ok:false（不再静默跳过）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
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

    test('㉑c getVersionOptions：真实结构（8.9.0 仅 ios/harmony + 8.8.0 android）→ versions 只含 android 8.8.0（残留根因回归）', () async {
      // 接口实测：build-list 全量返回各平台组（每组 builds 仅最新 1 条）：
      // 最新「版本」8.9.0 只有 ios/harmony 构建（无 android 组），android 最新是 8.8.0。
      // 旧实现遍历所有平台组 → versions[0]=8.9.0 → getBuildHistory(8.9.0) 过滤 android
      // 后空 → 历史构建只剩 1 条；修复后 versions 只统计 android 平台组。
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-ios-890',
                'version': '8.9.0',
                'platform': 'ios',
                'env': 'sit',
                'publishedAt': 1701000000000, // 8.9.0 最新（但无 android 构建）
                'builds': [
                  {
                    'identifier': 'com.pingan.ios',
                    'versionname': '8.9.0',
                    'num': 1,
                    'size': 500,
                    'fileurl': <Object>[],
                  },
                ],
              },
              {
                '_id': 'bg-harmony-890',
                'version': '8.9.0',
                'platform': 'harmony',
                'env': 'sit',
                'publishedAt': 1701000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.harmony',
                    'versionname': '8.9.0',
                    'num': 1,
                    'size': 300,
                    'fileurl': <Object>[],
                  },
                ],
              },
              {
                '_id': 'bg-android',
                'version': '8.8.0',
                'platform': 'android',
                'env': 'sit',
                'publishedAt': 1700000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.app',
                    'versionname': '8.8.0',
                    'num': 35,
                    'size': 100,
                    'fileurl': <Object>[],
                  },
                ],
              },
              {
                '_id': 'bg-ios-880',
                'version': '8.8.0',
                'platform': 'ios',
                'env': 'sit',
                'publishedAt': 1690000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.ios',
                    'versionname': '8.8.0',
                    'num': 4,
                    'size': 500,
                    'fileurl': <Object>[],
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
          'main', ['versionOptions', {'appId': 'app-1', 'env': 'sit'}]) as Map;
      expect(result['ok'], isTrue);
      final data = result['data'] as Map;
      final versions = data['versions'] as List;
      // 只含 android 平台版本：8.9.0（ios/harmony）被过滤，versions 仅 8.8.0
      expect(versions.length, 1);
      expect((versions.first as Map)['version'], '8.8.0');
      expect((versions.first as Map)['envs'], ['sit']);
      expect(data['currentVersion'], '8.8.0'); // 最新 android 版本

      await runtime.dispose();
    });

    test('㉓ getAppDetail 带 version → build-list 单版本拉取（version 参数）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript);
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'app-1', 'version': '1.9.0'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;
      expect(d['version'], '1.9.0');
      expect(d['appId'], 'app-1'); // 查询键保持

      // 单版本拉取：只发一次 build-list，且携带 version 参数
      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('version=1.9.0'));

      await runtime.dispose();
    });

    test('㉓b getAppDetail 不带 version（真实结构）→ 默认取最新 android 版本 8.8.0（8.9.0 无 android 构建）', () async {
      // 与 ㉑c 同款真实结构 mock：最新「版本」8.9.0 只有 ios/harmony，
      // android 最新是 8.8.0 → 详情默认版本必须是 8.8.0（android 组列表排序）。
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-ios-890',
                'version': '8.9.0',
                'platform': 'ios',
                'env': 'sit',
                'publishedAt': 1701000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.ios',
                    'versionname': '8.9.0',
                    'num': 1,
                    'size': 500,
                    'fileurl': <Object>[],
                  },
                ],
              },
              {
                '_id': 'bg-harmony-890',
                'version': '8.9.0',
                'platform': 'harmony',
                'env': 'sit',
                'publishedAt': 1701000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.harmony',
                    'versionname': '8.9.0',
                    'num': 1,
                    'size': 300,
                    'fileurl': <Object>[],
                  },
                ],
              },
              {
                '_id': 'bg-android',
                'version': '8.8.0',
                'platform': 'android',
                'env': 'sit',
                'publishedAt': 1700000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.app',
                    'versionname': '8.8.0',
                    'num': 35,
                    'size': 100,
                    'fileurl': <Object>[],
                  },
                ],
              },
              {
                '_id': 'bg-ios-880',
                'version': '8.8.0',
                'platform': 'ios',
                'env': 'sit',
                'publishedAt': 1690000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.ios',
                    'versionname': '8.8.0',
                    'num': 4,
                    'size': 500,
                    'fileurl': <Object>[],
                  },
                ],
              },
            ],
          };
        }
        if (options.path.endsWith('/sunflower/i/build')) {
          // 真实结构：{build:{builds:[...]}, appInfo}——完整历史在 build 键内层
          final id = options.queryParameters['_id']?.toString() ?? '';
          if (id != 'bg-android') {
            return {'build': {'_id': id, 'builds': <Object>[]}, 'appInfo': <Object>{}};
          }
          final builds = <Map<String, dynamic>>[];
          for (var num = 35; num >= 1; num--) {
            builds.add({
              'identifier': 'com.pingan.app',
              'versionname': '8.8.0',
              'num': num,
              'size': 100 + num,
              'ipa': [
                {'name': 'PABank-8.8.0-$num.apk', '_id': 'ipa-$num'},
              ],
              'fileurl': <Object>[],
            });
          }
          return {
            'build': {'_id': 'bg-android', 'version': '8.8.0', 'builds': builds},
            'appInfo': {'screenshots': <Object>[]},
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;
      expect(d['version'], '8.8.0'); // 默认版本 = 最新 android 版本（非 8.9.0）
      final downloads = d['downloads'] as List;
      expect(downloads.length, 1);
      expect((downloads.first as Map)['version'], '8.8.0');

      // 只拉一次全量 build-list（version 空）+ 一次 build 接口（android 组 _id）
      final buildRequests = requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('version=-'));
      expect(requestLog.where((r) => r.contains('/sunflower/i/build?')).length, 1);

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

    test('㉕ 会话缓存：同凭证连续两次 getAppDetail → login/check 只调 1 次', () async {
      var loginCheckCount = 0;
      final runtime = buildRuntime(
        scriptOverride: detailScript,
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'secret'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildList(withFileUrl: false);
          }
          if (options.path.contains('login/check')) {
            loginCheckCount++;
            return {'code': '000000', 'msg': 'success'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final r1 = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(r1['ok'], isTrue);
      final r2 = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(r2['ok'], isTrue);

      // 同凭证两次详情 → login/check 只调 1 次（detail runtime 会话缓存命中）
      expect(loginCheckCount, 1);

      // 详情可下载（proxy url + downloadable:true）；无 PINGAN_ENV → 默认 env=sit
      final d1 = r1['data'] as Map;
      final dl1 = (d1['downloads'] as List).first as Map;
      expect(dl1['url'],
          '$_mcdBase/proxy/prd/com.pingan.app-1.9.0.apk?um=tester&value=secret');
      expect(dl1['downloadable'], isTrue);
      expect(dl1['note'], '');

      await runtime.dispose();

      // zip 拆分后 entry/detail 各自独立 runtime（独立 QuickJS context）：
      // 认证缓存不再跨方法共享——entry runtime 的 getAppInfo 持有自己的
      // 会话缓存，首次调用重新检测 1 次（总数 2，而非旧单文件的 1）。
      final entryRuntime = buildRuntime(
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'secret'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildList(withFileUrl: false);
          }
          if (options.path.contains('login/check')) {
            loginCheckCount++;
            return {'code': '000000', 'msg': 'success'};
          }
          return defaultHandler(options);
        },
      );
      await entryRuntime.initialize();
      final r3 = await entryRuntime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;
      expect(r3['ok'], isTrue);
      expect(loginCheckCount, 2);

      await entryRuntime.dispose();
    });

    test('㉖ 凭证变更 → 重新检测（缓存按 user/pass）', () async {
      var loginCheckCount = 0;
      final runtime = buildRuntime(
        scriptOverride: detailScript,
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'secret'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildList(withFileUrl: false);
          }
          if (options.path.contains('login/check')) {
            loginCheckCount++;
            return {'code': '000000', 'msg': 'success'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]);
      expect(loginCheckCount, 1);

      // 更换凭证（updateEnv 热更新）→ 缓存不匹配 → 重新检测
      runtime.updateEnv({'PINGAN_USER': 'tester2', 'PINGAN_PASS': 'secret2'});
      final r2 = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(r2['ok'], isTrue);
      expect(loginCheckCount, 2);

      await runtime.dispose();
    });

    test('㉗ login/check 失败 → 详情仍正常返回（downloadable:false + note，失败 60s 冷却防风暴）', () async {
      var loginCheckCount = 0;
      final runtime = buildRuntime(
        scriptOverride: detailScript,
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'wrong'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildList(withFileUrl: false);
          }
          if (options.path.contains('login/check')) {
            loginCheckCount++;
            return {'__status': 401, 'msg': 'unauthorized'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final r1 = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(r1['ok'], isTrue); // 认证失败绝不阻塞详情
      final d1 = r1['data'] as Map;
      final dl1 = (d1['downloads'] as List).first as Map;
      expect(dl1['url'], '');
      expect(dl1['downloadable'], isFalse);
      expect(dl1['note'], isNotEmpty);
      expect((d1['extra'] as Map)['authError'], contains('认证失败'));

      // 失败 60s 冷却 → 再次调用不重发 login/check（修复前每次重发 main+doc 2 次 = 4）
      await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]);
      expect(loginCheckCount, 1);
      // 冷却期内第三次调用 → 依旧不重发（请求风暴防护）
      await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]);
      expect(loginCheckCount, 1);
      // 冷却跳过有日志（来源可定位）
      expect(logMessages.any((m) => m.contains('[login/check] 失败冷却中跳过重发')), isTrue);

      await runtime.dispose();
    });

    test('㉘ 真实结构（ipa + fileurl 混合）→ 详情 downloads 只含最新版本组单条', () async {
      var loginCheckCount = 0;
      final runtime = buildRuntime(
        scriptOverride: detailScript,
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'secret'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return {
              'appLogo': '/logo/app.png',
              'buildList': [
                {
                  '_id': 'bg-real-ipa',
                  'version': '3.2.1',
                  'platform': 'android',
                  'env': 'sit',
                  'publishedAt': 1710000000000,
                  'builds': [
                    {
                      'identifier': 'com.pingan.real',
                      'versionname': '3.2.1',
                      'num': 42,
                      'size': 56789012,
                      'installTimes': 1024,
                      'changelog': '修复若干问题',
                      'builtBy': 'jenkins',
                      'ipa': [
                        {'name': 'com.pingan.real-3.2.1.apk', '_id': 'ipa-1'},
                      ],
                      'fileurl': [],
                    },
                  ],
                },
                {
                  '_id': 'bg-real-file',
                  'version': '1.0.0',
                  'platform': 'android',
                  'env': 'sit',
                  'publishedAt': 1700000000000,
                  'builds': [
                    {
                      'identifier': 'com.pingan.file',
                      'versionname': '1.0.0',
                      'num': 1,
                      'size': 1000,
                      'fileurl': ['/apk/direct.apk'],
                    },
                  ],
                },
              ],
            };
          }
          if (options.path.contains('login/check')) {
            loginCheckCount++;
            return {'code': '000000', 'msg': 'success'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;
      expect(d['appId'], 'app-1'); // 查询键保持（最新组 ipa proxy）
      expect(d['version'], '3.2.1');

      // 只显示最新版本组（3.2.1）最新构建单条：不再遍历所有版本（1.0.0 不出现）
      final downloads = d['downloads'] as List;
      expect(downloads.length, 1);
      final dl0 = downloads[0] as Map; // 最新组：ipa name → proxy 拼接（默认 env=sit）
      expect(dl0['url'],
          '$_mcdBase/proxy/prd/com.pingan.real-3.2.1.apk?um=tester&value=secret');
      expect(dl0['downloadable'], isTrue);
      expect(dl0['version'], '3.2.1');

      // 一次详情 → login/check 只调 1 次
      expect(loginCheckCount, 1);

      await runtime.dispose();
    });

    test('㉙ fetchBuildDetail 失败 → 详情仍返回（screenshots 空）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.endsWith('/sunflower/i/build')) {
          return {'__status': 500, 'msg': 'boom'};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue); // build 详情失败 → 降级继续，不阻塞详情
      final d = result['data'] as Map;
      expect(d['appId'], 'app-1'); // 查询键保持
      expect((d['extra'] as Map)['screenshots'], isEmpty);
      expect(d['downloads'], isNotEmpty);

      await runtime.dispose();
    });

    test('㉙b safeGet 非 2xx 保留响应体（data）供脚本按 status 降级', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.endsWith('/sunflower/i/build')) {
          return {'__status': 500, 'msg': 'boom', 'code': 500};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'safeGet', ['/sunflower/i/build', {'uuid': 'x', '_id': 'bg-android'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['status'], 500);
      final data = result['data'] as Map;
      expect(data['msg'], 'boom'); // 非 2xx 响应体保留
      expect(data['code'], 500);
      expect(result['error'], isNotEmpty);

      await runtime.dispose();
    });

    test('㉙c getBuildHistory：build 接口补全完整构建历史（build-list 单版本只返回最新 1 条 = 根因）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          // 模拟真实平台：build-list 带 version 只返回该版本最新构建 1 条
          // （getBuildHistory 旧实现直接取 group.builds → 历史列表仅 1 项的根因）
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-full',
                'version': '8.8.0',
                'platform': 'android',
                'env': 'sit',
                'publishedAt': 1700000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.app',
                    'versionname': '8.8.0',
                    'num': 35,
                    'size': 100,
                    'installTimes': 5,
                    'changelog': '最新构建',
                    'builtBy': 'ci',
                    'fileurl': ['/apk/com.pingan.app-8.8.0.apk'],
                  },
                ],
              },
            ],
          };
        }
        if (options.path.endsWith('/sunflower/i/build')) {
          // 真实平台：build 接口返回 {build:{builds}}（完整历史在 build 键内层，
          // 实测 num 降序 35→1）+ appInfo；每条含 ipa:[{name,_id}]（代理文件名）
          final builds = <Map<String, dynamic>>[];
          for (var num = 35; num >= 1; num--) {
            builds.add({
              'identifier': 'com.pingan.app',
              'versionname': '8.8.0',
              'num': num,
              'size': 100 + num,
              'installTimes': num,
              'changelog': '构建 $num',
              'builtBy': 'ci-bot',
              'publishedAt': 1700000000000 + num,
              'ipa': [
                {'name': 'PABank-8.8.0-$num.apk', '_id': 'ipa-$num'},
              ],
              'fileurl': <Object>[],
            });
          }
          return {
            'build': {'_id': 'bg-android', 'version': '8.8.0', 'builds': builds},
            'appInfo': {'screenshots': <Object>[]},
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['buildHistory', {'appId': 'app-1', 'version': '8.8.0', 'env': 'sit'}]) as Map;
      expect(result['ok'], isTrue);
      final builds = (result['data'] as Map)['builds'] as List;
      expect(builds.length, 35); // 完整历史（非 build-list 单版本 1 条）
      // num 倒序
      final nums = builds.map((b) => (b as Map)['num']).toList();
      expect(nums, List.generate(35, (i) => 35 - i));
      final first = builds.first as Map;
      expect(first['num'], 35);
      expect(first['changelog'], '构建 35');
      expect(first['ipaName'], 'PABank-8.8.0-35.apk'); // 真实字段：优先 ipa[0].name
      expect(first['size'], 135);
      final last = builds.last as Map;
      expect(last['num'], 1);
      expect(last['ipaName'], 'PABank-8.8.0-1.apk');

      // build-list（1 次，全量无 version，复用 getAppDetail 缓存）+ build 接口（1 次 _id）
      final buildListRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildListRequests.length, 1);
      expect(buildListRequests.first, contains('version=-'));
      expect(requestLog.where((r) => r.contains('/sunflower/i/build?')).length, 1);

      await runtime.dispose();
    });

    test('㉙d getBuildHistory：build 接口失败 → 降级用 build-list builds（不抛）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.endsWith('/sunflower/i/build')) {
          return {'__status': 500, 'msg': 'boom'};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['buildHistory', {'appId': 'app-1', 'version': '1.9.0', 'env': 'sit'}]) as Map;
      expect(result['ok'], isTrue); // build 接口失败 → 降级，不抛
      final builds = (result['data'] as Map)['builds'] as List;
      // 降级：build-list 组内 builds（defaultHandler 单条，至少最新构建可用）
      expect(builds.length, 1);
      expect((builds.first as Map)['num'], 7);

      await runtime.dispose();
    });

    test('㉙e getBuildHistory：build-list 返回 3 平台组（ios 排前）→ isAndroidGroup 过滤取 android 组 → build 接口完整历史', () async {
      // 真实接口实测：build-list（带 version）返回 android/ios/harmony 3 平台组，
      // 每组 builds 只有最新 1 条；取错组（ios/harmony）→ build 接口拿不到 android 完整历史
      // （旧实现按 version 匹配取第一个组 → 可能取到 ios 组 → 历史列表仍只有 1 条）
      final buildIds = <String>[];
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          // 3 平台组：ios/harmony 排前且 version 相同（真实接口 order），android 最后
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-ios',
                'version': '8.8.0',
                'platform': 'ios',
                'env': 'sit',
                'publishedAt': 1700000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.ios',
                    'versionname': '8.8.0',
                    'num': 12,
                    'size': 500,
                    'fileurl': [],
                  },
                ],
              },
              {
                '_id': 'bg-harmony',
                'version': '8.8.0',
                'platform': 'harmony',
                'env': 'sit',
                'publishedAt': 1700000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.harmony',
                    'versionname': '8.8.0',
                    'num': 3,
                    'size': 300,
                    'fileurl': [],
                  },
                ],
              },
              {
                '_id': 'bg-android',
                'version': '8.8.0',
                'platform': 'android',
                'env': 'sit',
                'publishedAt': 1700000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.app',
                    'versionname': '8.8.0',
                    'num': 35,
                    'size': 100,
                    'fileurl': [],
                  },
                ],
              },
            ],
          };
        }
        if (options.path.endsWith('/sunflower/i/build')) {
          // build 接口按 _id 路由：只有 android 组返回完整历史（ios/harmony 组无 android 构建）；
          // 真实结构 {build:{builds}}——历史在 build 键内层
          final id = options.queryParameters['_id']?.toString() ?? '';
          buildIds.add(id);
          if (id != 'bg-android') {
            return {'build': {'_id': id, 'builds': <Object>[]}, 'appInfo': <Object>{}};
          }
          final builds = <Map<String, dynamic>>[];
          for (var num = 35; num >= 1; num--) {
            builds.add({
              'identifier': 'com.pingan.app',
              'versionname': '8.8.0',
              'num': num,
              'size': 100 + num,
              'ipa': [
                {'name': 'PABank-8.8.0-$num.apk', '_id': 'ipa-$num'},
              ],
              'fileurl': <Object>[],
            });
          }
          return {
            'build': {'_id': 'bg-android', 'version': '8.8.0', 'builds': builds},
            'appInfo': {'screenshots': <Object>[]},
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['buildHistory', {'appId': 'app-1', 'version': '8.8.0', 'env': 'sit'}]) as Map;
      expect(result['ok'], isTrue);
      final builds = (result['data'] as Map)['builds'] as List;
      expect(builds.length, 35); // android 组完整历史（ios 组排前也不取错）
      final nums = builds.map((b) => (b as Map)['num']).toList();
      expect(nums, List.generate(35, (i) => 35 - i)); // num 倒序
      final first = builds.first as Map;
      expect(first['num'], 35);
      expect(first['ipaName'], 'PABank-8.8.0-35.apk'); // 真实字段：优先 ipa[0].name

      // build 接口只调了一次，且用 android 组 _id（非排前的 ios 组）
      expect(buildIds, ['bg-android']);
      final buildRequests = requestLog.where((r) => r.contains('/sunflower/i/build?')).toList();
      expect(buildRequests.length, 1);

      await runtime.dispose();
    });

    test('㉚ buildDetailFromGroup 畸形 group → 不抛，返回最简详情', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-malformed',
                'version': '0.0.1',
                'platform': 'android',
                'env': 'sit',
                'publishedAt': null,
                'builds': [
                  null, // 脏数据：null 历史构建
                  {'num': 'abc', 'size': 'xyz', 'identifier': null, 'changelog': null},
                ],
              },
            ],
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue); // 畸形 group 不抛
      final d = result['data'] as Map;
      expect(d['name'], '0.0.1');
      final extra = d['extra'] as Map;
      expect(extra['versionHistory'], isNotEmpty);
      final downloads = d['downloads'] as List;
      expect(downloads.length, 1);
      expect((downloads.first as Map)['downloadable'], isFalse);

      await runtime.dispose();
    });

    test('㉛ getAppDetail 包名 appId（无缓存 + 库无记录）→ ok:false + error 含解析失败提示', () async {
      // 库中无该包名 → resolveAppName 返回原值 → 两次 build-list(包名) 均空 → 明确错误提示
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          final appname = options.queryParameters['appname']?.toString() ?? '';
          if (appname == 'com.pingan.pabank.activity') {
            return api.buildListNoAndroid(); // 包名查不到（含首次与 resolve 后重试）
          }
          return api.buildList(withFileUrl: false);
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'com.pingan.pabank.activity'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect((result['error'] as String),
          contains('无法解析为渠道应用名：com.pingan.pabank.activity'));

      await runtime.dispose();
    });

    test('㉛b getAppInfo 包名 appId（无缓存 + 库无记录）→ ok:false + error 含解析失败提示', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          final appname = options.queryParameters['appname']?.toString() ?? '';
          if (appname == 'com.pingan.pabank.activity') {
            return api.buildListNoAndroid();
          }
          return api.buildList(withFileUrl: false);
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppInfo', {'appId': 'com.pingan.pabank.activity'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect((result['error'] as String),
          contains('无法解析为渠道应用名：com.pingan.pabank.activity'));

      await runtime.dispose();
    });

    test('㉜ 同 detail runtime：getAppDetail(name) 成功后 switchVersion(包名) 经 _nameCache 解析成功', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          final appname = options.queryParameters['appname']?.toString() ?? '';
          // 包名直查 → 空（走 resolveAppName 缓存解析，不再发第二次 build-list）
          if (appname == 'com.pingan.pabank.activity') {
            return api.buildListNoAndroid();
          }
          // 渠道查询名 → 构建组 identifier = com.pingan.pabank.activity（触发缓存记录）
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-ibank',
                'version': '1.9.0',
                'platform': 'android',
                'env': 'sit',
                'publishedAt': 1690000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.pabank.activity',
                    'versionname': '1.9.0',
                    'num': 7,
                    'size': 12345678,
                    'installTimes': 99,
                    'changelog': '修复若干问题',
                    'builtBy': 'ci-bot',
                    'fileurl': ['/apk/com.pingan.pabank.activity-1.9.0.apk'],
                  },
                ],
              },
            ],
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      // 先用渠道查询名成功拉详情（identifier 为 com.pingan.pabank.activity）→ 记录缓存
      final r1 = await runtime.call(
          'main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(r1['ok'], isTrue);
      expect((r1['data'] as Map)['packageName'], 'com.pingan.pabank.activity');

      // 之后用包名调 switchVersion → _nameCache 命中（app-1）→ 一次 build-list 成功
      final r2 = await runtime.call(
          'main', ['switchVersion', {'appId': 'com.pingan.pabank.activity', 'env': 'sit', 'version': ''}]) as Map;
      expect(r2['ok'], isTrue);
      final d = r2['data'] as Map;
      expect(d['appId'], 'app-1'); // 查询键（缓存解析出的 name）
      expect(d['packageName'], 'com.pingan.pabank.activity');

      // getAppDetail(1) + switchVersion(0，build-list 缓存命中复用) → 共 1 次 build-list
      // （修复前 switchVersion 重复拉全量 build-list = 2 次；缓存后同查询零请求）
      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.last, contains('appname=app-1'));

      await runtime.dispose();
    });

    test('㉚b 同 entry runtime：getAppInfo(name) 成功后 getAppInfo(包名) 经 _nameCache 解析成功', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          final appname = options.queryParameters['appname']?.toString() ?? '';
          // 包名直查 → 空（走 resolveAppName 缓存解析，不再发第二次 build-list）
          if (appname == 'com.pingan.pabank.activity') {
            return api.buildListNoAndroid();
          }
          // 渠道查询名 → 构建组 identifier = com.pingan.pabank.activity（触发缓存记录）
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-ibank',
                'version': '1.9.0',
                'platform': 'android',
                'env': 'sit',
                'publishedAt': 1690000000000,
                'builds': [
                  {
                    'identifier': 'com.pingan.pabank.activity',
                    'versionname': '1.9.0',
                    'num': 7,
                    'size': 12345678,
                    'installTimes': 99,
                    'changelog': '修复若干问题',
                    'builtBy': 'ci-bot',
                    'fileurl': ['/apk/com.pingan.pabank.activity-1.9.0.apk'],
                  },
                ],
              },
            ],
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      // 先用渠道查询名成功拉基础信息 → 缓存 包名→name
      final r1 = await runtime.call('main', ['getAppInfo', {'appId': 'app-1'}]) as Map;
      expect(r1['ok'], isTrue);
      expect((r1['data'] as Map)['packageName'], 'com.pingan.pabank.activity');

      // 用包名再查 → _nameCache 命中 → 解析为 app-1 → 成功
      final r2 = await runtime.call(
          'main', ['getAppInfo', {'appId': 'com.pingan.pabank.activity'}]) as Map;
      expect(r2['ok'], isTrue);
      final app = r2['data'] as Map;
      expect(app['appId'], 'app-1'); // 查询键（缓存解析）
      expect(app['packageName'], 'com.pingan.pabank.activity');

      // getAppInfo 两次：name 直查(1) + 包名(直查失败1 + 缓存命中重查0) = 2 次 build-list
      // （修复前 resolve 后重查重复拉全量 = 3 次；build-list 缓存后同查询零请求）
      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 2);
      // 最后一次实际请求是包名直查（空结果）；app-1 重查走缓存（日志可证）
      expect(buildRequests.last, contains('appname=com.pingan.pabank.activity'));
      expect(logMessages.any((m) => m.contains('[build-list] 缓存命中')), isTrue);

      await runtime.dispose();
    });

    test('㉛c getAppDetail 首次（真实结构：build-list 无 ipa + build 接口补全 + 凭证）→ downloads 真实文件名 + proxy URL 非空', () async {
      // 回归首次下载项 bug：build-list builds[0] 无 ipa → 修复前 name 合成
      // "8.8.0.apk"/"平安口袋银行.apk" + ipaName 空 → proxy URL 拼不出（下载地址空）
      final runtime = buildRuntime(
        scriptOverride: detailScript,
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'secret'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildListNoIpa(); // 真实结构：builds[0] 无 ipa 字段
          }
          if (options.path.endsWith('/sunflower/i/build')) {
            return api.buildDetail('bg-ibank', ipaName: 'PABank-Debug-8.8.0-35.apk');
          }
          if (options.path.contains('login/check')) {
            return {'code': '000000', 'msg': 'success'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'ibank'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;
      expect(d['version'], '8.8.0');
      final downloads = d['downloads'] as List;
      expect(downloads.length, 1);
      final dl = downloads.first as Map;
      // 真实文件名（build 接口 ipa[0].name 补全，非合成名）
      expect(dl['name'], 'PABank-Debug-8.8.0-35.apk');
      // proxy URL（env + ipaName + um/value 编码）——修复前为 ''（下载地址空）
      expect(
        dl['url'],
        '$_mcdBase/proxy/prd/PABank-Debug-8.8.0-35.apk?um=tester&value=secret',
      );
      expect(dl['downloadable'], isTrue);
      expect(dl['note'], '');
      // 首次路径确实调用了 build 接口（_id 补全）
      expect(requestLog.where((r) => r.contains('/sunflower/i/build?')).length, 1);

      await runtime.dispose();
    });

    test('㉛d getAppDetail 首次无凭证（真实结构）→ 真实文件名 + url 空 + note（降级不抛）', () async {
      final runtime = buildRuntime(
        scriptOverride: detailScript,
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildListNoIpa();
          }
          if (options.path.endsWith('/sunflower/i/build')) {
            return api.buildDetail('bg-ibank', ipaName: 'PABank-Debug-8.8.0-35.apk');
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'ibank'}]) as Map;
      expect(result['ok'], isTrue); // 无凭证绝不阻塞详情
      final downloads = (result['data'] as Map)['downloads'] as List;
      final dl = downloads.first as Map;
      expect(dl['name'], 'PABank-Debug-8.8.0-35.apk'); // 文件名仍真实（build 补全）
      expect(dl['url'], ''); // 无凭证 → 下载地址空（降级）
      expect(dl['downloadable'], isFalse);
      expect((dl['note'] as String), contains('PINGAN_USER/PINGAN_PASS'));
      // 未发起认证请求
      expect(requestLog.any((r) => r.contains('login/check')), isFalse);

      await runtime.dispose();
    });

    test('㉛e getAppDetail 首次 build 接口失败（真实结构）→ 降级合成名 + url 空（不抛）', () async {
      final runtime = buildRuntime(
        scriptOverride: detailScript,
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'secret'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildListNoIpa(); // builds[0] 无 ipa
          }
          if (options.path.endsWith('/sunflower/i/build')) {
            return {'__status': 500, 'msg': 'boom'}; // build 补全失败
          }
          if (options.path.contains('login/check')) {
            return {'code': '000000', 'msg': 'success'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'ibank'}]) as Map;
      expect(result['ok'], isTrue); // 补全失败降级，不抛
      final downloads = (result['data'] as Map)['downloads'] as List;
      final dl = downloads.first as Map;
      expect(dl['name'], '8.8.0.apk'); // 降级：versionname + '.apk' 合成
      expect(dl['url'], ''); // ipaName 缺失 → proxy URL 拼不出（降级行为）
      expect(dl['downloadable'], isFalse);
      expect((dl['note'] as String), isNotEmpty);

      await runtime.dispose();
    });

    test('㉛f 同 entry runtime：getAppDetail 首次（真实结构）→ downloads 真实文件名 + proxy URL 非空', () async {
      final runtime = buildRuntime(
        env: () => {'PINGAN_USER': 'tester', 'PINGAN_PASS': 'secret'},
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return api.buildListNoIpa();
          }
          if (options.path.endsWith('/sunflower/i/build')) {
            return api.buildDetail('bg-ibank', ipaName: 'PABank-Debug-8.8.0-35.apk');
          }
          if (options.path.contains('login/check')) {
            return {'code': '000000', 'msg': 'success'};
          }
          return defaultHandler(options);
        },
      );
      await runtime.initialize();

      final result = await runtime.call('main', ['getAppDetail', {'appId': 'ibank'}]) as Map;
      expect(result['ok'], isTrue);
      final downloads = (result['data'] as Map)['downloads'] as List;
      final dl = downloads.first as Map;
      expect(dl['name'], 'PABank-Debug-8.8.0-35.apk');
      expect(
        dl['url'],
        '$_mcdBase/proxy/prd/PABank-Debug-8.8.0-35.apk?um=tester&value=secret',
      );
      expect(dl['downloadable'], isTrue);

      await runtime.dispose();
    });

    test('㉜ 渐进推送：getAppDetail 三阶段 ui.updateDetail 序列（S1 选组/S2 截图/S3 下载项）', () async {
      // buildRuntime 默认不注册 nativeHost → host.ui.call 静默 no-op 无法断言，
      // 必须先注入捕获用 host（ui.updateDetail handler 收集推送 payload）。
      final captured = <Map<String, dynamic>>[];
      final runtime = buildRuntime(scriptOverride: detailScript);
      runtime.setNativeHost(JSNativeHost()
        ..register('ui', 'updateDetail', (p) async {
          captured.add(Map<String, dynamic>.from(p));
          return null;
        }));
      await runtime.initialize();

      final result =
          await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      expect(captured.length, 3, reason: 'S1 选组/S2 build 补全/S3 下载项各推一次');

      // S1：选组完成 → 名称/版本 + 下载区骨架声明（extra 展开键）
      final s1 = captured[0];
      expect(s1['name'], 'app-1');
      expect(s1['version'], '1.9.0');
      expect(s1['sections'], ['downloads']);
      final s1Extra = s1['extra'] as Map;
      expect(s1Extra['identifier'], 'com.pingan.app');
      expect(s1Extra['env'], 'sit'); // envReader 空 → 凭证默认 sit
      expect(s1Extra['platform'], 'android');

      // S2：build 补全 → sections 含 screenshots 且 screenshots 在顶层（非嵌 extra）
      final s2 = captured[1];
      expect(s2['sections'], ['downloads', 'screenshots']);
      expect(s2.containsKey('extra'), isFalse,
          reason: 'screenshots 必须顶层键（UI getter 读 _data[\'screenshots\']）');
      expect(s2['screenshots'], isA<List>());

      // S3：真实下载项填充（与最终 return 同一数组内容）
      final s3 = captured[2];
      final finalDownloads = (result['data'] as Map)['downloads'] as List;
      expect(s3['downloads'], isA<List>());
      expect((s3['downloads'] as List).length, finalDownloads.length);
      expect((s3['downloads'] as List).first, finalDownloads.first);

      await runtime.dispose();
    });

    test('㉝ 全量替换持久性：最终 return 顶层 sections+screenshots 经 JsChannelDetailProxy 可读', () async {
      // 防"推送时显示、全量替换后消失"回归：截图区块依赖最终 return 的
      // 顶层 screenshots 键 + sections 声明（仅 extra.screenshots 嵌套不够）。
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.endsWith('/sunflower/i/build')) {
          return {
            'build': {
              '_id': 'bg-android',
              'version': '1.9.0',
              'builds': [
                {
                  'identifier': 'com.pingan.app',
                  'versionname': '1.9.0',
                  'num': 7,
                  'size': 12345678,
                  'ipa': [
                    {'name': 'com.pingan.app-1.9.0.apk', '_id': 'ipa-1'},
                  ],
                  'fileurl': <Object>[],
                },
              ],
            },
            'appInfo': {
              'displayname': '应用1',
              'intro': '应用1 的简介',
              'screenshots': ['/shots/x1.png', '/shots/x2.png'],
            },
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result =
          await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;

      // 最终 return 双顶层键（绝对化截图 + 区块声明）
      expect(d['sections'], ['downloads', 'screenshots']);
      expect(d['screenshots'],
          ['$_pinganHost/shots/x1.png', '$_pinganHost/shots/x2.png']); // abs 绝对化

      // 以最终 return 数据构造代理（模拟 load 成功后 refreshDetail 全量替换）：
      // UI getter 必须能读到截图区块，否则全量替换后截图闪现即逝。
      final proxy = JsChannelDetailProxy(Map<String, dynamic>.from(d));
      expect(proxy.sections, contains(DetailSection.screenshots));
      expect(proxy.screenshots, isNotNull);
      expect(proxy.screenshots!, isNotEmpty);
      expect(proxy.screenshots!.length, 2);
      expect(proxy.screenshots!.first.url, '$_pinganHost/shots/x1.png');

      await runtime.dispose();
    });

    test('㉞ 推送抛错不阻塞主链：updateDetail handler throw → getAppDetail 仍 ok:true', () async {
      final runtime = buildRuntime(scriptOverride: detailScript);
      runtime.setNativeHost(JSNativeHost()
        ..register('ui', 'updateDetail', (p) async {
          throw StateError('模拟 UI 推送失败');
        }));
      await runtime.initialize();

      final result =
          await runtime.call('main', ['getAppDetail', {'appId': 'app-1'}]) as Map;
      expect(result['ok'], isTrue, reason: '脚本侧 try/catch 包裹——推送失败绝不影响主链');
      final d = result['data'] as Map;
      expect(d['downloads'], isA<List>());
      expect((d['downloads'] as List).length, 1);

      await runtime.dispose();
    });
  });
}

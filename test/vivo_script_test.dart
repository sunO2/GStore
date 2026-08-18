import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';

/// vivo.js 渠道脚本测试（zip 渠道包）：验证脚本语法正确 + 引擎加载无错 + 分发器各方法行为。
///
/// ⚠️ 本测试不请求真实网络：host.network 走注入的假 Dio adapter（按 path 路由假响应），
/// host.database 走内存假 DAO。mock 结构对齐 VivoChannel.dart 的请求/响应格式
/// （搜索 POST result-list 参数在 queryParameters；详情 GET detailInfo 参数 appId=vivoId）。
///
/// 注意：脚本在 test/ 下读取 scripts/channels/vivo.zip（flutter test 以项目根为 cwd），
/// 经 ChannelPackage.decode 解出 entry.js（发现页）与 detail.js（详情页）两份脚本：
/// - 发现页/更新路径方法（getAllApps/searchApps/getAppInfo/getAppDetail/checkAppUpdate/
///   checkUpdate/doUpdate）→ entry runtime（JsChannel 消费）
/// - 详情页方法（getAppDetail/checkAppUpdate/detailMenu）→ detail runtime（JsDetailChannel 消费）
/// entry/detail 各自独立 runtime（独立 QuickJS context），工具函数不共享。

const String _vivoBase = 'https://h5-api.appstore.vivo.com.cn';
const String _channelKey = 'js_vivo_test';

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
        '?appId=${options.queryParameters['appId'] ?? '-'}'
        '&key=${options.queryParameters['key'] ?? '-'}');
    final data = handler(options);
    // 原始 body 透传（模拟空 body / 非 JSON 响应）
    if (data['__rawBody'] != null) {
      final raw = data.remove('__rawBody') as String;
      return ResponseBody.fromString(
        raw,
        (data['__status'] as int?) ?? 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    if (data['__status'] != null) {
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

/// 假 vivo API 响应构建器：搜索 result-list / 详情 detailInfo
class _FakeVivoApi {
  /// 搜索响应：{code: 0, data: {appSearchResponse: {value: [...]}}}
  Map<String, dynamic> search(int code, List<Map<String, dynamic>> items) {
    return {
      'code': code,
      'data': {
        'appSearchResponse': {'value': items},
      },
    };
  }

  Map<String, dynamic> searchItem({
    required String id,
    required String titleZh,
    required String packageName,
    String iconUrl = 'https://cdn.vivo.com/icon.png',
    String developer = '开发者X',
    String remark = '应用简介',
  }) {
    return {
      'id': id,
      'title_zh': titleZh,
      'title_en': titleZh,
      'icon_url': iconUrl,
      'package_name': packageName,
      'developer': developer,
      'remark': remark,
    };
  }

  /// 详情响应：完整字段（对齐 VivoChannel.dart 解析字段）
  Map<String, dynamic> detail({
    String id = 'vivo-10086',
    String packageName = 'com.tencent.mm',
    String titleZh = '微信',
    String downloadUrl = 'https://cdn.vivo.com/apk/mm.apk',
    String? apk,
  }) {
    return {
      'id': id,
      'icon_url': 'https://cdn.vivo.com/icon.png',
      'title_zh': titleZh,
      'title_en': titleZh,
      'package_name': packageName,
      'developerName': '腾讯',
      'introduction': '微信，超过10亿人使用',
      'categoryName': '社交',
      'version_name': '8.0.49',
      'version_code': '1555',
      'size': 260000000,
      'download_count': 10000000,
      'score': 4.5,
      'raters_count': 88888,
      'favorite_count': 1234,
      'screenshotList': ['https://cdn.vivo.com/s1.png', 'https://cdn.vivo.com/s2.png'],
      'permissionList': [
        {'permissionName': '读取存储'},
        '网络权限',
      ],
      'download_url': downloadUrl,
      'apk': apk ?? '/apk/mm-8.0.49.apk',
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

  final api = _FakeVivoApi();

  late String script;
  late String detailScript;
  late Map<String, dynamic> pkgMeta;
  setUpAll(() {
    final zipBytes = File('scripts/channels/vivo.zip').readAsBytesSync();
    final pkg = ChannelPackage.decode(zipBytes);
    expect(pkg, isNotNull, reason: 'vivo.zip 应可解析（entry.js 必须）');
    script = pkg!.entryScript;
    detailScript = pkg.detailScript!;
    expect(detailScript, isNotEmpty, reason: 'vivo.zip 应包含 detail.js');
    pkgMeta = pkg.meta!;
    expect(script, contains('CHANNEL_META'), reason: 'entry.js 应包含 CHANNEL_META');
    expect(pkgMeta['name'], 'vivo 应用市场', reason: 'meta.json name 正确');
  });

  /// 默认 handler：搜索 2 条 + 详情完整响应
  Map<String, dynamic> defaultHandler(RequestOptions options) {
    final path = options.path;
    if (path.contains('/h5appstore/search/result-list')) {
      return api.search(0, [
        api.searchItem(
          id: 'vivo-10086',
          titleZh: '微信',
          packageName: 'com.tencent.mm',
        ),
        api.searchItem(
          id: 'vivo-20001',
          titleZh: '抖音',
          packageName: 'com.ss.android.ugc.aweme',
          developer: '字节跳动',
          remark: '记录美好生活',
        ),
      ]);
    }
    if (path.contains('/detailInfo')) {
      return api.detail();
    }
    return {'code': -1};
  }

  JsChannelRuntime buildRuntime({
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
      logInfo: (msg) => logMessages.add('info: $msg'),
      logError: (msg) => logMessages.add('error: $msg'),
    );
  }

  /// 落库一条 vivo 搜索结果（模拟用户搜索保存）
  Future<void> insertSavedApp({
    String appId = 'com.tencent.mm',
    String name = '微信',
    String repositories = 'vivo-10086',
    String? extra,
  }) async {
    await appDao.insertApp(ChannelAddedApp(
      appId: appId,
      name: name,
      user: '腾讯',
      repositories: repositories,
      icon: 'https://cdn.vivo.com/icon.png',
      description: '微信，超过10亿人使用',
      addTime: 0,
      channelCode: _channelKey,
      extra: extra ??
          jsonEncode({
            'vivoId': 'vivo-10086',
            'packageName': 'com.tencent.mm',
            'title': '微信',
          }),
    ));
  }

  group('vivo.js 脚本渠道', () {
    test('① initialize 加载脚本成功 + CHANNEL_META 正确', () async {
      final runtime = buildRuntime();
      await runtime.initialize();
      expect(runtime.isInitialized, isTrue);

      final meta = await runtime.evaluate(
          "typeof CHANNEL_META !== 'undefined' ? CHANNEL_META : null");
      expect(meta, isA<Map>());
      final map = meta as Map;
      expect(map['name'], 'vivo 应用市场');
      expect(map['description'], contains('vivo'));

      await runtime.dispose();
    });

    test('② searchApps：POST result-list + AppInfo 字段映射（对齐 _parseSearchResults）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['searchApps', {'keyword': '微信'}]) as Map;
      expect(result['ok'], isTrue);
      final data = result['data'] as List;
      expect(data.length, 2);

      final first = data.first as Map;
      expect(first['appId'], 'com.tencent.mm'); // appId = packageName
      expect(first['packageName'], 'com.tencent.mm');
      expect(first['name'], '微信'); // title_zh
      expect(first['user'], '开发者X'); // developer
      expect(first['repositories'], 'vivo-10086'); // repositories = vivoId
      expect(first['icon'], 'https://cdn.vivo.com/icon.png'); // icon_url
      expect(first['des'], '应用简介'); // remark
      expect(first['category'], isNull); // 搜索无分类

      // extra 完整（vivoId 等）
      final extra = first['extra'] as Map;
      expect(extra['vivoId'], 'vivo-10086');
      expect(extra['packageName'], 'com.tencent.mm');
      expect(extra['title'], '微信');
      expect(extra['developer'], '开发者X');

      // 请求格式：POST + queryParameters 携带 key/page_index/apps_per_page
      final searchRequests =
          requestLog.where((r) => r.contains('result-list')).toList();
      expect(searchRequests.length, 1);
      expect(searchRequests.first, contains('POST'));
      expect(searchRequests.first, contains('key=微信'));
      expect(searchRequests.first, contains('$_vivoBase/h5appstore/search/result-list'));

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

      // 触发搜索 + 详情两类请求
      await runtime.call('main', ['searchApps', {'keyword': '微信'}]) as Map;
      await runtime.call('main', ['getAppInfo', {'appId': 'com.tencent.mm'}]) as Map;

      expect(capturedHeaders, isNotEmpty);
      for (final h in capturedHeaders) {
        expect(h['User-Agent'], expectedUa,
            reason: '每个请求都应携带写死的 Android Chrome UA');
      }

      await runtime.dispose();
    });

    test('③ searchApps 网络失败 → {ok:false, data:null}（不抛）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/h5appstore/search/result-list')) {
          return {'__status': 500, 'msg': 'server error'};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['searchApps', {'keyword': '微信'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(logMessages.any((m) => m.contains('error:')), isTrue);

      await runtime.dispose();
    });

    test('④ searchApps 空 keyword → 空数组，不发请求', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['searchApps', {'keyword': ''}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isEmpty);
      expect(requestLog, isEmpty);

      await runtime.dispose();
    });

    test('⑤ searchApps API 错误码（code != 0）→ 成功空数组（对齐 Dart）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/h5appstore/search/result-list')) {
          return api.search(-1, []);
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['searchApps', {'keyword': '微信'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isEmpty);

      await runtime.dispose();
    });

    test('⑥ getAllApps：无全量接口 → 返回本渠道库已保存应用（对齐 Dart getChannelApps）', () async {
      await insertSavedApp();
      await appDao.insertApp(ChannelAddedApp(
        appId: 'com.ss.android.ugc.aweme',
        name: '抖音',
        user: '字节跳动',
        repositories: 'vivo-20001',
        icon: '',
        description: '记录美好生活',
        category: '娱乐,短视频',
        addTime: 0,
        channelCode: _channelKey,
        extra: jsonEncode({
          'vivoId': 'vivo-20001',
          'packageName': 'com.ss.android.ugc.aweme',
          'title': '抖音',
        }),
      ));

      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', ['getAllApps', {}]) as Map;
      expect(result['ok'], isTrue);
      final data = result['data'] as List;
      expect(data.length, 2);
      expect(requestLog, isEmpty); // 纯查库，不发网络请求

      final first = data.first as Map;
      expect(first['appId'], 'com.tencent.mm');
      expect(first['name'], '微信');
      expect(first['repositories'], 'vivo-10086');
      expect(first['des'], '微信，超过10亿人使用');
      expect((first['extra'] as Map)['vivoId'], 'vivo-10086');

      // category 逗号串 → 数组
      final second = data[1] as Map;
      expect(second['category'], ['娱乐', '短视频']);

      await runtime.dispose();
    });

    test('⑦ getAppInfo：库中无记录 → detailInfo API（appId=查询 appId）+ 详情路径映射', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppInfo', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isTrue);
      final app = result['data'] as Map;

      expect(app['appId'], 'com.tencent.mm'); // package_name
      expect(app['name'], '微信'); // title_zh
      expect(app['user'], '腾讯'); // developerName
      expect(app['repositories'], 'com.tencent.mm'); // ⚠️ 详情路径 repositories = 包名
      expect(app['icon'], 'https://cdn.vivo.com/icon.png');
      expect(app['des'], '微信，超过10亿人使用'); // introduction
      expect(app['category'], ['社交']); // categoryName

      // detailInfo 请求参数：appId = 查询 appId
      final detailRequests =
          requestLog.where((r) => r.contains('/detailInfo')).toList();
      expect(detailRequests.length, 1);
      expect(detailRequests.first, contains('GET'));
      expect(detailRequests.first, contains('appId=com.tencent.mm'));

      await runtime.dispose();
    });

    test('⑧ getAppInfo：库中命中 → 直接返回库数据，不发请求', () async {
      await insertSavedApp();
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppInfo', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isTrue);
      final app = result['data'] as Map;
      expect(app['name'], '微信');
      expect(app['repositories'], 'vivo-10086');
      expect(requestLog, isEmpty); // 未发网络请求

      await runtime.dispose();
    });

    test('⑨ getAppInfo 网络失败 → {ok:false, data:null}（不抛）', () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/detailInfo')) {
          return {'__status': 500, 'msg': 'boom'};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppInfo', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);

      await runtime.dispose();
    });

    test('⑩ getAppDetail：extra.vivoId 优先解析 → detailInfo 请求携带 vivoId + 详情字段完整', () async {
      await insertSavedApp(); // extra.vivoId = 'vivo-10086'
      final runtime = buildRuntime(scriptOverride: detailScript);
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;

      // 请求 appId = extra.vivoId（而非包名）
      final detailRequests =
          requestLog.where((r) => r.contains('/detailInfo')).toList();
      expect(detailRequests.length, 1);
      expect(detailRequests.first, contains('appId=vivo-10086'));

      // 基本信息（库中记录兜底）
      expect(d['appId'], 'com.tencent.mm');
      expect(d['name'], '微信');
      expect(d['icon'], 'https://cdn.vivo.com/icon.png');

      // 版本/包名
      expect(d['version'], '8.0.49'); // version_name
      expect(d['packageName'], 'com.tencent.mm'); // package_name
      expect(d['developer'], '腾讯'); // developerName
      expect(d['description'], '微信，超过10亿人使用');

      // 下载列表（文件名: packageName_versionCode.apk）
      final downloads = d['downloads'] as List;
      expect(downloads.length, 1);
      final dl = downloads.first as Map;
      expect(dl['url'], 'https://cdn.vivo.com/apk/mm.apk'); // download_url
      expect(dl['name'], 'com.tencent.mm_1555.apk');
      expect(dl['size'], 260000000);
      expect(dl['version'], '8.0.49');
      expect(dl['platform'], 'android');

      // sections（对齐 _buildSections：version/statistics/rating/downloads/readme/permissions）
      expect(d['sections'], [
        'version',
        'statistics',
        'rating',
        'downloads',
        'readme',
        'permissions',
      ]);

      // 统计/截图/权限
      expect(d['downloadCount'], 10000000);
      expect(d['rating'], 4.5);
      expect(d['ratingCount'], 88888);
      expect(d['favorites'], 1234);
      expect(d['screenshots'], [
        'https://cdn.vivo.com/s1.png',
        'https://cdn.vivo.com/s2.png',
      ]);
      expect(d['permissions'], ['读取存储', '网络权限']);
      expect(d['readme'], '微信，超过10亿人使用');

      // detailData 原始数据透传
      expect((d['detailData'] as Map)['version_code'], '1555');

      await runtime.dispose();
    });

    test('⑪ getAppDetail：无 extra.vivoId → 库 repositories 兜底为 vivoId', () async {
      await insertSavedApp(
        extra: jsonEncode({'packageName': 'com.tencent.mm'}),
        repositories: 'vivo-9999',
      );
      final runtime = buildRuntime(scriptOverride: detailScript);
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isTrue);
      final detailRequests =
          requestLog.where((r) => r.contains('/detailInfo')).toList();
      expect(detailRequests.first, contains('appId=vivo-9999'));

      await runtime.dispose();
    });

    test('⑫ getAppDetail：download_url 缺失 → apk 相对路径兜底拼 BASE_URL（对齐 Dart）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/detailInfo')) {
          final d = api.detail();
          d['download_url'] = '';
          return d;
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isTrue);
      final d = result['data'] as Map;
      final dl = (d['downloads'] as List).first as Map;
      expect(dl['url'], '$_vivoBase/apk/mm-8.0.49.apk');

      await runtime.dispose();
    });

    test('⑬ getAppDetail：空响应 body → {ok:false, data:null}（不抛）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/detailInfo')) {
          return {'__rawBody': '', '__status': 200}; // 空字符串 body
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], contains('空数据'));

      await runtime.dispose();
    });

    test('⑭ getAppDetail 网络失败 → {ok:false, data:null}（不抛）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript, handler: (options) {
        if (options.path.contains('/detailInfo')) {
          return {'__status': 500, 'msg': 'boom'};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['getAppDetail', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);

      await runtime.dispose();
    });

    test('⑮ checkAppUpdate：detailInfo → 版本信息（appId/packageName/version）', () async {
      // 正常流程：应用已在渠道库（详情 name/icon 取自库记录，对齐 Dart appInfo 兜底）
      await insertSavedApp();
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['checkAppUpdate', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isTrue);
      final data = result['data'] as Map;
      expect(data['appId'], 'com.tencent.mm');
      expect(data['packageName'], 'com.tencent.mm');
      expect(data['name'], '微信');
      expect(data['icon'], 'https://cdn.vivo.com/icon.png');
      expect(data['version'], '8.0.49');

      await runtime.dispose();
    });

    test('⑯ detailMenu → 空 Actions（vivo 无多版本/额外操作）', () async {
      final runtime = buildRuntime(scriptOverride: detailScript);
      await runtime.initialize();

      final result = await runtime.call(
          'main', ['detailMenu', {'appId': 'com.tencent.mm'}]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isEmpty);

      await runtime.dispose();
    });

    test('⑰ checkUpdate/doUpdate → false/true（vivo 无全量接口，对齐 Dart）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final cu = await runtime.call('main', ['checkUpdate', {}]) as Map;
      expect(cu['ok'], isTrue);
      expect(cu['data'], isFalse);

      final du = await runtime.call('main', ['doUpdate', {}]) as Map;
      expect(du['ok'], isTrue);
      expect(du['data'], isTrue);
      expect(requestLog, isEmpty); // 不发网络请求

      await runtime.dispose();
    });

    test('⑱ 未实现 method（getConfig/versionOptions）→ null，不抛（JsChannel 降级策略）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      expect(await runtime.call('main', ['getConfig', {}]), isNull);
      expect(await runtime.call('main', ['versionOptions', {}]), isNull);
      expect(await runtime.call('main', ['switchVersion', {}]), isNull);
      expect(await runtime.call('main', ['buildHistory', {}]), isNull);

      await runtime.dispose();
    });
  });
}

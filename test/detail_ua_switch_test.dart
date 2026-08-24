import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/channel_package.dart';
import 'package:gstore/core/js/js_channel_runtime.dart';
import 'package:gstore/core/js/js_native_host.dart';

/// pingan.js 详情页 UA 切换测试（回归："切为 Harmony UA 后下载列表仍为 Android"）。
///
/// 真实接口行为（据此建模）：
/// - build-list **不按 UA 过滤**：无论请求什么 User-Agent 恒定返回全部平台组
///   （android/ios/harmony，通常 android 排前）；平台过滤是脚本侧的
///   `findPlatformGroup`/`isAndroidGroup`（客户端基于 _currentUA 过滤）。
/// - 因此修复前 `switchVersion` 下载列表只取 `groups[0]`（服务器首组 android）→
///   切 Harmony UA 后列表仍是 Android 的；修复后按当前 UA 平台过滤，下载列表
///   只含当前 UA 对应平台（如 Harmony）的下载项。
///
/// 同时验证 UA 头传递链：safeGet 在 headers 设 `'User-Agent': _currentUA` →
/// host.network.get 注入 Dio Options(headers) → dio per-request headers 覆盖
/// BaseOptions（模拟真实 DioClient 的 `User-Agent: GStore-App/1.0`）→ 请求头
/// 应为切换后的 UA（adapter 记录 final RequestOptions.headers）。
const String _channelKey = 'js_pingan_ua_switch_test';

// ---- 与 detail.js _UAS / DEFAULT_UA 对齐（断言脚本发送的 UA 头值）----
const String _defaultUA =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7 Build/TQ3A.230805.001) '
    'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';
const String _androidUA =
    'Mozilla/5.0 (Linux; Android 14; Pixel 9) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/146.0.0.0 Mobile Safari/537.36';
const String _harmonyUA =
    'Mozilla/5.0 (Phone; HarmonyOS 5.0) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/114.0.0.0 Safari/537.36 ArkWeb/4.1.6.1 Mobile HuaweiBrowser/5.0.3.351';

/// 内存版 ChannelAddedAppDao（resolveAppName 查库；空库 → appId 原样）
class _FakeAppDao implements ChannelAddedAppDao {
  @override
  Future<void> insertApp(ChannelAddedApp app) async {}

  @override
  Future<void> insertApps(List<ChannelAddedApp> apps) async {}

  @override
  Future<List<ChannelAddedApp>> getAppsByChannel(String channelCode) async => [];

  @override
  Future<ChannelAddedApp?> getApp(String appId, String channelCode) async => null;

  @override
  Future<void> removeApp(String appId, String channelCode) async {}

  @override
  Future<int?> getCountByChannel(String channelCode) async => 0;

  @override
  Future<void> clearChannel(String channelCode) async {}

  @override
  Future<List<ChannelAddedApp>> getAllApps() async => [];

  @override
  Future<int?> getTotalCount() async => 0;
}

/// 固定响应 Dio adapter（测试用）：按 path 路由，记录每个请求的最终
/// RequestOptions.headers['User-Agent']（dio 合并 BaseOptions 后的值）。
class _FakeDioAdapter implements HttpClientAdapter {
  final Map<String, dynamic> Function(RequestOptions options) handler;
  final List<String> uaLog;

  _FakeDioAdapter(this.handler, this.uaLog);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uaLog.add(options.headers['User-Agent']?.toString() ?? '');
    final data = handler(options);
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

/// build-list：**恒**返回 [android 首组, harmony 组]（真实接口不分 UA 恒返回全部
/// 平台组；android 排前复现"切 Harmony 后仍取到 android 组"的用户场景）。
Map<String, dynamic> _buildListForVersion(String version) {
  return {
    'appLogo': '/logo/app.png',
    'buildList': [
      {
        '_id': 'bg-android',
        'version': version,
        'platform': 'android',
        'env': 'sit',
        'publishedAt': 1700000000001,
        'builds': [
          {
            'identifier': 'com.pingan.app',
            'versionname': version,
            'num': 10,
            'size': 100,
            'fileurl': <Object>[],
          },
        ],
      },
      {
        '_id': 'bg-harmony',
        'version': version,
        'platform': 'harmony',
        'env': 'sit',
        'publishedAt': 1700000000000,
        'builds': [
          {
            'identifier': 'com.pingan.harmony',
            'versionname': version,
            'num': 2,
            'size': 200,
            'fileurl': <Object>[],
          },
        ],
      },
    ],
  };
}

/// build 接口：按 _id 返回 real 结构 {build:{builds}, appInfo}（真实字段
/// 每条含 ipa[0].name；android 组历史/名称区别于 harmony 组）。
Map<String, dynamic> _buildDetailById(RequestOptions options) {
  final id = options.queryParameters['_id']?.toString() ?? '';
  final isAndroid = id.contains('android');
  final identifier =
      isAndroid ? 'com.pingan.app' : 'com.pingan.harmony';
  final ipaName =
      isAndroid ? 'App-1.0.0-android.apk' : 'App-1.0.0-harmony.hap';
  return {
    'build': {
      '_id': id,
      'version': '1.0.0',
      'builds': [
        {
          'identifier': identifier,
          'versionname': '1.0.0',
          'num': isAndroid ? 10 : 2,
          'size': isAndroid ? 100 : 200,
          'ipa': [
            {'name': ipaName, '_id': 'ipa-${isAndroid ? 10 : 2}'},
          ],
          'fileurl': <Object>[],
        },
      ],
    },
    'appInfo': {'screenshots': <Object>[], 'intro': '测试应用', 'name': '示例银行'},
  };
}

Map<String, dynamic> _defaultHandler(RequestOptions options) {
  if (options.path.contains('/sunflower/i/build-list')) {
    final version = options.queryParameters['version']?.toString() ?? '1.0.0';
    return _buildListForVersion(version);
  }
  if (options.path.endsWith('/sunflower/i/build')) {
    return _buildDetailById(options);
  }
  return {'code': -1};
}

void main() {
  late List<String> uaLog;
  late List<String> logMessages;

  setUp(() {
    uaLog = [];
    logMessages = [];
  });

  late String script;
  setUpAll(() {
    final zipBytes = File('scripts/channels/pingan.zip').readAsBytesSync();
    final pkg = ChannelPackage.decode(zipBytes);
    expect(pkg, isNotNull, reason: 'pingan.zip 应可解析（entry.js 必须）');
    script = pkg!.detailScript!;
    expect(script, contains('getDetailMenu'),
        reason: 'detail.js 应包含 Hybrid detailMenu');
    expect(script, contains('isAndroidUA'),
        reason: 'detail.js 应包含 isAndroidUA（UA 切换修复）');
  });

  /// 模拟真实 DioClient：BaseOptions 带默认 `User-Agent: GStore-App/1.0`，
  /// 验证 dio 按 per-request headers 覆盖（JS 传入的 _currentUA 生效）。
  JsChannelRuntime buildUaRuntime({
    Map<String, dynamic> Function(RequestOptions options)? handler,
    JSNativeHost? nativeHost,
  }) {
    final dio = Dio(BaseOptions(
      headers: {
        'Accept': 'application/json',
        'User-Agent': 'GStore-App/1.0',
      },
    ));
    dio.httpClientAdapter = _FakeDioAdapter(handler ?? _defaultHandler, uaLog);
    return JsChannelRuntime(
      channelKey: _channelKey,
      script: script,
      dio: dio,
      appDao: _FakeAppDao(),
      logInfo: (msg) => logMessages.add('info: $msg'),
      logError: (msg) => logMessages.add('error: $msg'),
      nativeHost: nativeHost,
    );
  }

  group('pingan 详情页 UA 切换', () {
    test('① 初始加载（默认 Android UA）：请求头为 DEFAULT_UA + 下载列表 1 条 android', () async {
      final runtime = buildUaRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', [
        'getAppDetail',
        {'appId': 'com.pingan.app'}
      ]) as Map;
      expect(result['ok'], isTrue);
      final detail = result['data'] as Map;
      final downloads = detail['downloads'] as List;
      expect(downloads.length, 1);
      expect((downloads.first as Map)['platform'], 'android');

      // 全部请求的 UA 头 = DEFAULT_UA（且 dio 默认 'GStore-App/1.0' 被 per-request 覆盖）
      expect(uaLog, isNotEmpty);
      expect(uaLog.every((ua) => ua == _defaultUA), isTrue,
          reason: 'safeGet 必须把 DEFAULT_UA 通过 headers 传给 HTTP 请求');

      await runtime.dispose();
    });

    test(
        '② jsswitchUA→Harmony：切换后请求头变 Harmony UA（UA 传递链）'
        '+ refreshDetail downloads 只含 harmony 下载项（UA 过滤当前平台）',
        () async {
      Map<String, dynamic>? pickerOptions;
      Map<String, dynamic>? refreshParams;
      final runtime = buildUaRuntime(
        nativeHost: JSNativeHost()
          ..register('ui', 'showUAPicker', (options) async {
            pickerOptions = options;
            return 'Harmony'; // Flutter 侧返回 label → 脚本解析为完整 Harmony UA
          })
          ..register('ui', 'refreshDetail', (params) async {
            refreshParams = params;
            return null;
          }),
      );
      await runtime.initialize();

      // 先加载一次（默认 Android 态）
      await runtime.call('main', [
        'getAppDetail',
        {'appId': 'com.pingan.app'}
      ]);
      final preSwitchUaCount = uaLog.length;
      expect(uaLog.every((ua) => ua == _defaultUA), isTrue);

      // 切换 UA
      final result = await runtime.call('main', [
        'jsswitchUA',
        {'appId': 'com.pingan.app'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isTrue);

      // 选择框收到当前完整 UA（默认= DEFAULT_UA）
      expect(pickerOptions, isNotNull);
      expect(pickerOptions!['current'], _defaultUA);

      // UA 头传递链：切换后所有请求都携带 Harmony UA（dio per-request 覆盖 base UA）
      final postSwitchUa = uaLog.sublist(preSwitchUaCount);
      expect(postSwitchUa, isNotEmpty, reason: '切换 UA 后应重新发起网络请求');
      expect(postSwitchUa.every((ua) => ua == _harmonyUA), isTrue,
          reason: '切 Harmony UA 后 build-list/build 请求必须携带 Harmony 的 User-Agent');

      // refreshDetail 收到完整详情：downloads 只含当前 UA（Harmony）平台的一项
      expect(refreshParams, isNotNull);
      final downloads = refreshParams!['downloads'] as List;
      expect(downloads, isNotEmpty);
      final platforms = downloads.map((d) => (d as Map)['platform']).toList();
      expect(platforms, ['harmony'],
          reason: '修复：非 Android UA 下载列表只含当前 UA 平台（Harmony）的一项，'
              '不再取服务器首组 android（修复前只有 android）');
      final harmony = downloads.firstWhere((d) => (d as Map)['platform'] == 'harmony') as Map;
      expect(harmony['size'], 200); // harmony 组构建

      await runtime.dispose();
    });

    test('③ jsswitchUA→Harmony 之后 main(\'switchVersion\')：detail.downloads 同含 harmony 项', () async {
      Map<String, dynamic>? refreshParams;
      final runtime = buildUaRuntime(
        nativeHost: JSNativeHost()
          ..register('ui', 'showUAPicker', (options) async => 'Harmony')
          ..register('ui', 'refreshDetail', (params) async {
            refreshParams = params;
            return null;
          }),
      );
      await runtime.initialize();

      await runtime.call('main', [
        'jsswitchUA',
        {'appId': 'com.pingan.app'}
      ]);
      expect(refreshParams, isNotNull);

      // 直接调 switchVersion（Flutter 侧切版本路径同源）
      final r2 = await runtime.call('main', [
        'switchVersion',
        {'appId': 'com.pingan.app', 'env': 'sit', 'version': '1.0.0'}
      ]) as Map;
      expect(r2['ok'], isTrue);
      final downloads = (r2['data'] as Map)['downloads'] as List;
      final platforms = downloads.map((d) => (d as Map)['platform']).toList();
      expect(platforms, contains('harmony'));

      await runtime.dispose();
    });

    test('④ showUAPicker 取消：不切换、不刷新、无任何网络请求', () async {
      var refreshCalled = false;
      final runtime = buildUaRuntime(
        nativeHost: JSNativeHost()
          ..register('ui', 'showUAPicker', (options) async => null)
          ..register('ui', 'refreshDetail', (params) async {
            refreshCalled = true;
            return null;
          }),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsswitchUA',
        {'appId': 'com.pingan.app'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(refreshCalled, isFalse);
      expect(uaLog, isEmpty);

      await runtime.dispose();
    });

    test('⑤ Android UA 选项：切后过滤仍生效（只显 android 组下载）', () async {
      Map<String, dynamic>? refreshParams;
      final runtime = buildUaRuntime(
        nativeHost: JSNativeHost()
          ..register('ui', 'showUAPicker', (options) async => 'Android')
          ..register('ui', 'refreshDetail', (params) async {
            refreshParams = params;
            return null;
          }),
      );
      await runtime.initialize();

      await runtime.call('main', [
        'getAppDetail',
        {'appId': 'com.pingan.app'}
      ]);
      final preSwitchCount = uaLog.length;
      await runtime.call('main', [
        'jsswitchUA',
        {'appId': 'com.pingan.app'}
      ]);
      expect(refreshParams, isNotNull);
      // 切换 Android 项后：请求头切换为 _UAS.ANDROID（UA 传递链）
      final postSwitchUa = uaLog.sublist(preSwitchCount);
      expect(postSwitchUa, isNotEmpty);
      expect(postSwitchUa.every((ua) => ua == _androidUA), isTrue,
          reason: '切 Android UA 后请求必须携带 _UAS.ANDROID 的 User-Agent');
      // Android 显式 UA → 平台过滤收窄为 android（行为与默认一致）
      final downloads = refreshParams!['downloads'] as List;
      final platforms = downloads.map((d) => (d as Map)['platform']).toList();
      expect(platforms, ['android']);

      await runtime.dispose();
    });
  });
}
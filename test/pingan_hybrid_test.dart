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

/// pingan.js Hybrid 详情页测试（Wave C，zip 渠道包 detail.js）：detailMenu 声明 Actions +
/// jsswitchVersion 用 host.native 驱动版本选择/刷新 + jsBuildHistory 用 host.native 驱动构建历史选择。
///
/// 与 pingan_script_test.dart 同款假网络/Dao 注入；本文件聚焦 host.native：
/// showVersionPicker / refreshDetail / showBuildHistory / updateDownloadList
/// 注册表条目捕获参数断言，不发真实网络。
///
/// 注意：Hybrid 详情方法（detailMenu/jsswitchVersion/jsBuildHistory）由页面级
/// JsDetailChannel 消费 → 本测试读取 scripts/channels/pingan.zip 解出的 detail.js
/// （flutter test 以项目根为 cwd）。
///
/// 契约（脚本侧）：
/// - main('detailMenu', {appId}) → {ok, data:[{action, jscall, clickIsDimiss}]}
/// - main('jsswitchVersion', {appId}) → 拉版本选项 → showVersionPicker →
///   用户选 {env, version} → refreshDetail({appId, env, version}) → {ok:true, data:true}
///   取消/能力未注册 → 静默 {ok:true, data:null}
/// - main('jsBuildHistory', {appId}) → 拉最新版本 builds（缓存复用）→ showBuildHistory →
///   用户选 build → 从缓存取该构建 → 生成单条 downloads →
///   updateDownloadList({downloads:[单条]}) 局部更新下载区 → {ok:true, data:true}
///   （不再 refreshDetail 全量重拉：切构建历史数据同源，仅下载项不同）
///   取消/能力未注册/失败 → 静默 {ok:true, data:null}；无版本/无构建 → {ok:false, error}

const String _channelKey = 'js_pingan_hybrid_test';

/// 内存版 ChannelAddedAppDao（测试用；resolveAppName 查库，空库 → appId 原样）
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

/// 固定响应 Dio adapter（测试用，按 path 路由，记录请求）
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
        '&appname=${options.queryParameters['appname'] ?? '-'}'
        '&version=${options.queryParameters['version'] ?? '-'}'
        '&env=${options.queryParameters['env'] ?? '-'}');
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

/// build-list 假响应：按请求 env 返回一个 android 版本组（version 8.9.0）
Map<String, dynamic> buildListForEnv(String env) {
  return {
    'appLogo': '/logo/app.png',
    'buildList': [
      {
        '_id': 'bg-$env',
        'version': '8.9.0',
        'platform': 'android',
        'env': env,
        'publishedAt': 1700000000000,
        'builds': [
          {
            'identifier': 'com.pingan.app',
            'versionname': '8.9.0',
            'num': 1,
            'size': 100,
            'fileurl': ['/apk/com.pingan.app-8.9.0.apk'],
          },
        ],
      },
    ],
  };
}

/// 默认 handler：build-list 按 env 返回；其余 path 未命中
Map<String, dynamic> defaultHandler(RequestOptions options) {
  if (options.path.contains('/sunflower/i/build-list')) {
    final env = options.queryParameters['env']?.toString() ?? 'sit';
    return buildListForEnv(env);
  }
  return {'code': -1};
}

/// 完整历史 handler：build-list 返回 android 8.9.0 组 + build 接口返回 35 条完整历史
/// （真实结构 {build:{builds}}，每条含 ipa[0].name）。供 jsBuildHistory 缓存/命中类测试复用。
Map<String, dynamic> fullHistoryHandler(RequestOptions options) {
  if (options.path.contains('/sunflower/i/build-list')) {
    return {
      'appLogo': '/logo/app.png',
      'buildList': [
        {
          '_id': 'bg-android',
          'version': '8.9.0',
          'platform': 'android',
          'env': 'sit',
          'publishedAt': 1700000000000,
          'builds': [
            {
              'identifier': 'com.pingan.app',
              'versionname': '8.9.0',
              'num': 35,
              'size': 100,
              'fileurl': <Object>[],
            },
          ],
        },
      ],
    };
  }
  if (options.path.endsWith('/sunflower/i/build')) {
    final builds = <Map<String, dynamic>>[];
    for (var num = 35; num >= 1; num--) {
      builds.add({
        'identifier': 'com.pingan.app',
        'versionname': '8.9.0',
        'num': num,
        'size': 100 + num,
        'ipa': [
          {'name': 'PABank-8.9.0-$num.apk', '_id': 'ipa-$num'},
        ],
        'fileurl': <Object>[],
      });
    }
    return {
      'build': {'_id': 'bg-android', 'version': '8.9.0', 'builds': builds},
      'appInfo': {'screenshots': <Object>[]},
    };
  }
  return {'code': -1};
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

  late String script;
  setUpAll(() {
    final zipBytes = File('scripts/channels/pingan.zip').readAsBytesSync();
    final pkg = ChannelPackage.decode(zipBytes);
    expect(pkg, isNotNull, reason: 'pingan.zip 应可解析（entry.js 必须）');
    script = pkg!.detailScript!;
    expect(script, contains('getDetailMenu'),
        reason: 'detail.js 应包含 Hybrid detailMenu');
  });

  JsChannelRuntime buildRuntime({
    Map<String, dynamic> Function(RequestOptions options)? handler,
    Map<String, String> Function()? envReader,
    JSNativeHost? nativeHost,
  }) {
    final dio = Dio();
    dio.httpClientAdapter =
        _FakeDioAdapter(handler ?? defaultHandler, requestLog);
    return JsChannelRuntime(
      channelKey: _channelKey,
      script: script,
      dio: dio,
      appDao: appDao,
      envReader: envReader,
      logInfo: (msg) => logMessages.add('info: $msg'),
      logError: (msg) => logMessages.add('error: $msg'),
      nativeHost: nativeHost,
    );
  }

  group('pingan.js Hybrid 详情页', () {
    test('① detailMenu 返回 Actions 声明（切换版本/历史构建/切换UA，clickIsDimiss=true）', () async {
      final runtime = buildRuntime();
      await runtime.initialize();

      final result = await runtime.call('main', [
        'detailMenu',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      final actions = result['data'] as List;
      expect(actions.length, 3);

      final switchAction = actions[0] as Map;
      expect(switchAction['action'], '切换版本');
      expect(switchAction['jscall'], 'jsswitchVersion');
      expect(switchAction['clickIsDimiss'], isTrue);

      final historyAction = actions[1] as Map;
      expect(historyAction['action'], '历史构建');
      expect(historyAction['jscall'], 'jsBuildHistory');
      expect(historyAction['clickIsDimiss'], isTrue);

      final uaAction = actions[2] as Map;
      expect(uaAction['action'], '切换UA');
      expect(uaAction['jscall'], 'jsswitchUA');
      expect(uaAction['clickIsDimiss'], isTrue);

      // 纯声明：不发任何网络请求
      expect(requestLog, isEmpty);

      await runtime.dispose();
    });

    test(
        '② jsswitchVersion：用户选 {env:uat, version:8.9.0} → refreshDetail 参数正确 + ok:true',
        () async {
      Map<String, dynamic>? pickerOptions;
      Map<String, dynamic>? refreshParams;
      final runtime = buildRuntime(
        nativeHost: JSNativeHost()
          ..register('ui', 'showVersionPicker', (options) async {
            pickerOptions = options;
            return {'env': 'uat', 'version': '8.9.0'};
          })
          ..register('ui', 'refreshDetail', (params) async {
            refreshParams = params;
            return null;
          }),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsswitchVersion',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isTrue);

      // 选择框收到的 options 正确（来自 getVersionOptions：envs 全量 5 个，当前 sit）
      expect(pickerOptions, isNotNull);
      expect(pickerOptions!['title'], '切换版本');
      expect(pickerOptions!['envs'], ['sit', 'uat', 'prd', 'rge', 'tmp']);
      expect(pickerOptions!['currentEnv'], 'sit');
      expect(pickerOptions!['currentVersion'], '8.9.0');
      final versions = pickerOptions!['versions'] as List;
      expect(versions.length, 1);
      expect((versions.first as Map)['version'], '8.9.0');

      // refreshDetail 收到用户选择的 env+version（Flutter 侧据此拉单版本数据更新）
      expect(refreshParams, isNotNull);
      expect(refreshParams!['appId'], 'app-1');
      expect(refreshParams!['env'], 'uat');
      expect(refreshParams!['version'], '8.9.0');

      // 只拉了一次 build-list（当前 env=sit 单次，Wave 拉取优化）
      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests.first, contains('env=sit'));

      await runtime.dispose();
    });

    test('③ jsswitchVersion：用户取消（data:null）→ refreshDetail 不被调 + 静默 ok:true',
        () async {
      var refreshCalled = false;
      final runtime = buildRuntime(
        nativeHost: JSNativeHost()
          ..register('ui', 'showVersionPicker', (p) async => null)
          ..register('ui', 'refreshDetail', (params) async => refreshCalled = true),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsswitchVersion',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(refreshCalled, isFalse);

      await runtime.dispose();
    });

    test('④ jsswitchVersion：showVersionPicker 失败（回调抛异常）→ 静默 ok:true 不崩',
        () async {
      var refreshCalled = false;
      final runtime = buildRuntime(
        nativeHost: JSNativeHost()
          ..register('ui', 'showVersionPicker',
              (p) async => throw Exception('picker broken'))
          ..register('ui', 'refreshDetail', (params) async => refreshCalled = true),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsswitchVersion',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(refreshCalled, isFalse);
      // 异常被 runtime 捕获记日志，脚本不抛
      expect(logMessages.any((m) => m.contains('picker broken')), isTrue);

      await runtime.dispose();
    });

    test('⑤ jsswitchVersion：能力未注册（未注入回调）→ 静默 ok:true', () async {
      final runtime = buildRuntime(); // 未注入 showVersionPicker
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsswitchVersion',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);

      await runtime.dispose();
    });

    test('⑥ jsswitchVersion：getVersionOptions 失败 → {ok:false, error} 不弹框',
        () async {
      var pickerCalled = false;
      final runtime = buildRuntime(
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            return {'__status': 500, 'msg': 'boom'};
          }
          return defaultHandler(options);
        },
        nativeHost: JSNativeHost()
          ..register('ui', 'showVersionPicker', (options) async {
            pickerCalled = true;
            return {'env': 'sit', 'version': '8.9.0'};
          }),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsswitchVersion',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], '获取版本选项失败');
      expect(pickerCalled, isFalse);

      await runtime.dispose();
    });

    test(
        '⑦ jsBuildHistory：3 平台组取 android 组 → build 接口完整 35 条 → 选 num=5 → updateDownloadList 单条（不再 refreshDetail）',
        () async {
      Map<String, dynamic>? historyOptions;
      List<dynamic>? updateDownloads;
      var refreshCalled = false;
      final runtime = buildRuntime(
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            final env = options.queryParameters['env']?.toString() ?? 'sit';
            // 真实接口：build-list（带 version）返回 android/ios/harmony 3 平台组，
            // 每组 builds 只含最新 1 条（真实平台单版本行为）；ios/harmony 排前
            return {
              'appLogo': '/logo/app.png',
              'buildList': [
                {
                  '_id': 'bg-ios',
                  'version': '8.9.0',
                  'platform': 'ios',
                  'env': env,
                  'publishedAt': 1700000000000,
                  'builds': [
                    {
                      'identifier': 'com.pingan.ios',
                      'versionname': '8.9.0',
                      'num': 4,
                      'size': 500,
                      'fileurl': <Object>[],
                    },
                  ],
                },
                {
                  '_id': 'bg-harmony',
                  'version': '8.9.0',
                  'platform': 'harmony',
                  'env': env,
                  'publishedAt': 1700000000000,
                  'builds': [
                    {
                      'identifier': 'com.pingan.harmony',
                      'versionname': '8.9.0',
                      'num': 2,
                      'size': 300,
                      'fileurl': <Object>[],
                    },
                  ],
                },
                {
                  '_id': 'bg-android',
                  'version': '8.9.0',
                  'platform': 'android',
                  'env': env,
                  'publishedAt': 1700000000000,
                  'builds': [
                    {
                      'identifier': 'com.pingan.app',
                      'versionname': '8.9.0',
                      'num': 35,
                      'size': 100,
                      'fileurl': <Object>[],
                    },
                  ],
                },
              ],
            };
          }
          if (options.path.endsWith('/sunflower/i/build')) {
            // 真实平台：build 接口返回 {build:{builds}}（完整历史在 build 键内层，
            // 实测 num 降序 35→1）+ appInfo；真实字段：每条含 ipa:[{name,_id}]（代理文件名）
            // + fileurl:[]
            final builds = <Map<String, dynamic>>[];
            for (var num = 35; num >= 1; num--) {
              builds.add({
                'identifier': 'com.pingan.app',
                'versionname': '8.9.0',
                'num': num,
                'size': 100 + num,
                'installTimes': num,
                'changelog': '构建 $num',
                'builtBy': 'ci',
                'publishedAt': 1700000000000 + num,
                'ipa': [
                  {'name': 'PABank-8.9.0-$num.apk', '_id': 'ipa-$num'},
                ],
                'fileurl': <Object>[],
              });
            }
            return {
              'build': {
                '_id': 'bg-android',
                'version': '8.9.0',
                'builds': builds
              },
              'appInfo': {'screenshots': <Object>[]},
            };
          }
          return defaultHandler(options);
        },
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory', (options) async {
            historyOptions = options;
            return {'num': 5, 'ipaName': 'PABank-8.9.0-5.apk'};
          })
          ..register('ui', 'refreshDetail', (params) async {
            refreshCalled = true;
            return null;
          })
          ..register('ui', 'updateDownloadList', (p) async {
            updateDownloads = p['downloads'] as List<dynamic>?;
            return null;
          }),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isTrue);

      // 选择器收到的 options 正确：最新版本（8.9.0）+ 凭证默认 env（无 PINGAN_ENV → sit）
      expect(historyOptions, isNotNull);
      expect(historyOptions!['version'], '8.9.0');
      expect(historyOptions!['env'], 'sit');
      final builds = historyOptions!['builds'] as List;
      expect(
          builds.length, 35); // android 组完整历史（build 接口补全，非 build-list 单版本 1 条）
      final nums = builds.map((b) => (b as Map)['num']).toList();
      expect(nums, List.generate(35, (i) => 35 - i)); // num 倒序
      final build0 = builds.first as Map;
      expect(build0['num'], 35);
      expect(build0['ipaName'], 'PABank-8.9.0-35.apk'); // 真实字段：优先 ipa[0].name
      expect(build0['size'], 135);

      // updateDownloadList 收到选中构建的单条下载项（缓存生成，无凭证 → url 空 + 不可下载）
      expect(updateDownloads, isNotNull);
      expect(updateDownloads!.length, 1);
      final dl = updateDownloads!.first as Map;
      expect(dl['name'], 'PABank-8.9.0-5.apk'); // 选中构建 ipa[0].name
      expect(dl['size'], 105); // 选中构建 size（100+5）
      expect(dl['version'], '8.9.0');
      expect(dl['platform'], 'android');
      expect(dl['url'], '');
      expect(dl['downloadable'], isFalse);
      expect(dl['note'], '需在渠道环境变量配置 PINGAN_USER/PINGAN_PASS 后下载');

      // 切构建历史不再 refreshDetail 全量重拉
      expect(refreshCalled, isFalse);

      // 单次 build-list：getVersionOptions（version 空，全量）→ getBuildHistory 按
      // version 过滤并复用同一全量缓存（0 新请求）+ build 接口（android 组 _id）
      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests[0], contains('env=sit'));
      expect(buildRequests[0], contains('version=-'));
      expect(
          requestLog.where((r) => r.contains('/sunflower/i/build&')).length, 1);

      await runtime.dispose();
    });

    test(
        '⑦b jsBuildHistory：真实结构（8.9.0 仅 ios/harmony，android 最新 8.8.0）→ 取 8.8.0 → build 接口完整 35 条（残留根因回归）',
        () async {
      // 接口实测：build-list 全量返回各平台组（每组 builds 仅最新 1 条）；
      // 最新「版本」8.9.0 只有 ios/harmony 构建，android 最新是 8.8.0。
      // 旧实现 getVersionOptions 遍历所有平台组 → versions[0]=8.9.0（无 android）→
      // getBuildHistory(8.9.0) 过滤 android 后空 → 历史构建只剩 1 条。
      // 修复后 versions 只统计 android 组 → 取 8.8.0 → build 接口（bg-android）35 条。
      // 第二个残留根因：build 接口真实结构为 {build:{builds:[...]}, appInfo}——完整历史在
      // build 键内层；旧脚本读顶层 bd.builds（undefined）→ 降级 build-list 组内 1 条
      // （build 35）。mock 用真实结构（本文件 ⑦b/⑦ 已对齐），脚本按 build.builds 读取。
      Map<String, dynamic>? historyOptions;
      List<dynamic>? updateDownloads;
      var refreshCalled = false;
      final runtime = buildRuntime(
        handler: (options) {
          if (options.path.contains('/sunflower/i/build-list')) {
            final version =
                options.queryParameters['version']?.toString() ?? '';
            if (version.isNotEmpty && version != '8.8.0') {
              // 带 version 且非 8.8.0（如旧实现误取 8.9.0）→ 真实接口只返回 ios/harmony 组
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
                ],
              };
            }
            // 全量 / version=8.8.0：android 8.8.0 组 + ios/harmony 干扰组
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
            // build 接口按 _id 路由：只有 android 组返回完整历史
            // （真实结构：{build:{builds:[...]}, appInfo}——历史在 build 键内层）
            final id = options.queryParameters['_id']?.toString() ?? '';
            if (id != 'bg-android') {
              return {
                'build': {'_id': id, 'builds': <Object>[]},
                'appInfo': <Object>{}
              };
            }
            final builds = <Map<String, dynamic>>[];
            for (var num = 35; num >= 1; num--) {
              builds.add({
                'identifier': 'com.pingan.app',
                'versionname': '8.8.0',
                'num': num,
                'size': 100 + num,
                'installTimes': num,
                'changelog': '构建 $num',
                'builtBy': 'ci',
                'publishedAt': 1700000000000 + num,
                'ipa': [
                  {'name': 'PABank-8.8.0-$num.apk', '_id': 'ipa-$num'},
                ],
                'fileurl': <Object>[],
              });
            }
            return {
              'build': {
                '_id': 'bg-android',
                'version': '8.8.0',
                'builds': builds
              },
              'appInfo': {'screenshots': <Object>[]},
            };
          }
          return defaultHandler(options);
        },
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory', (options) async {
            historyOptions = options;
            return {'num': 5, 'ipaName': 'PABank-8.8.0-5.apk'};
          })
          ..register('ui', 'refreshDetail', (params) async {
            refreshCalled = true;
            return null;
          })
          ..register('ui', 'updateDownloadList', (p) async {
            updateDownloads = p['downloads'] as List<dynamic>?;
            return null;
          }),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isTrue);

      // 选择器收到的是 android 最新版本 8.8.0（非 8.9.0）+ 完整 35 条
      expect(historyOptions, isNotNull);
      expect(historyOptions!['version'], '8.8.0');
      expect(historyOptions!['env'], 'sit');
      final builds = historyOptions!['builds'] as List;
      expect(builds.length, 35);
      final nums = builds.map((b) => (b as Map)['num']).toList();
      expect(nums, List.generate(35, (i) => 35 - i)); // num 倒序
      final build0 = builds.first as Map;
      expect(build0['num'], 35);
      expect(build0['ipaName'], 'PABank-8.8.0-35.apk');

      // updateDownloadList 收到选中构建单条（version=8.8.0，无凭证 → url 空）
      expect(updateDownloads, isNotNull);
      expect(updateDownloads!.length, 1);
      final dl = updateDownloads!.first as Map;
      expect(dl['name'], 'PABank-8.8.0-5.apk');
      expect(dl['size'], 105);
      expect(dl['version'], '8.8.0');
      expect(dl['url'], '');
      expect(dl['downloadable'], isFalse);

      // 切构建历史不再 refreshDetail 全量重拉
      expect(refreshCalled, isFalse);

      // 单次 build-list（全量，version 空）→ getBuildHistory 复用全量缓存按 8.8.0 过滤；
      // 绝不携带 8.9.0（旧实现误取路径）
      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);
      expect(buildRequests[0], contains('env=sit'));
      expect(buildRequests[0], contains('version=-'));
      expect(buildRequests[0], isNot(contains('version=8.9.0')));
      expect(
          requestLog.where((r) => r.contains('/sunflower/i/build&')).length, 1);

      await runtime.dispose();
    });

    test(
        '⑦c jsBuildHistory：凭证注入 + 认证通过 → updateDownloadList 单条含 proxy URL（downloadable:true）',
        () async {
      // 凭证注入（PINGAN_USER/PINGAN_PASS）→ ensureAuthChecked 走 login/check 通过 →
      // buildDownloads 生成 proxy URL（含 um/value 凭证）；无凭证路径见 ⑦（url 空）。
      List<dynamic>? updateDownloads;
      var refreshCalled = false;
      final runtime = buildRuntime(
        envReader: () => {'PINGAN_USER': 'user1', 'PINGAN_PASS': 'pass1'},
        handler: (options) {
          if (options.path.contains('/login/check')) {
            return {'code': '000000'}; // login/check 真实契约：code=000000 通过
          }
          return fullHistoryHandler(options);
        },
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory',
              (options) async => {'num': 5, 'ipaName': 'PABank-8.9.0-5.apk'})
          ..register('ui', 'refreshDetail', (params) async {
            refreshCalled = true;
            return null;
          })
          ..register('ui', 'updateDownloadList', (p) async {
            updateDownloads = p['downloads'] as List<dynamic>?;
            return null;
          }),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isTrue);

      // updateDownloadList 单条：proxy URL 含凭证（um/value），downloadable:true，note 空
      // （proxy env 恒为 prd：resolveDownloadUrl/buildDownloads 硬编码 buildApkUrl('prd');
      //   base 为 BASE_HOST + /mcd-api/mcd-api，无 istore 前缀——旧 zip 前缀已变更）
      expect(updateDownloads, isNotNull);
      expect(updateDownloads!.length, 1);
      final dl = updateDownloads!.first as Map;
      expect(dl['name'], 'PABank-8.9.0-5.apk');
      expect(dl['size'], 105);
      expect(dl['version'], '8.9.0');
      expect(dl['url'],
          'https://test-b-fat.pingan.com.cn/mcd-api/mcd-api/proxy/prd/PABank-8.9.0-5.apk?um=user1&value=pass1');
      expect(dl['downloadable'], isTrue);
      expect(dl['note'], '');

      // 切构建历史不再 refreshDetail
      expect(refreshCalled, isFalse);

      await runtime.dispose();
    });

    test('⑦d jsBuildHistory：缓存复用——两次 jsBuildHistory（同版本）build 接口只拉一次',
        () async {
      // 第一次 jsBuildHistory：versionOptions（build-list 无 version）+ getBuildHistory
      // （复用全量 build-list 缓存 + build 接口）→ 缓存完整 builds；
      // 第二次 jsBuildHistory：build-list/build 缓存命中 → 0 新请求。
      var updateCount = 0;
      final runtime = buildRuntime(
        handler: fullHistoryHandler,
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory',
              (options) async => {'num': 5, 'ipaName': 'PABank-8.9.0-5.apk'})
          ..register('ui', 'updateDownloadList', (p) async => updateCount++),
      );
      await runtime.initialize();

      final r1 = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(r1['ok'], isTrue);
      final r2 = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(r2['ok'], isTrue);

      // 两次都局部更新下载区
      expect(updateCount, 2);

      // build 接口只拉一次（缓存复用）；build-list 也只拉一次（第一次 versionOptions
      // 全量缓存供 getBuildHistory 复用；第二次两者均缓存命中 → 0 新请求）
      expect(
          requestLog.where((r) => r.contains('/sunflower/i/build&')).length, 1);
      final buildRequests =
          requestLog.where((r) => r.contains('build-list')).toList();
      expect(buildRequests.length, 1);

      await runtime.dispose();
    });

    test('⑦e jsBuildHistory：缓存无该构建（选中 num 不在缓存）→ 降级 {ok:false, error} 不崩',
        () async {
      // 异常路径：选择器回传的构建不在缓存 builds[]（如脏数据/缓存被清）→
      // 降级提示，不调 updateDownloadList/refreshDetail，不抛。
      var updateCalled = false;
      var refreshCalled = false;
      final runtime = buildRuntime(
        handler: fullHistoryHandler,
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory',
              (options) async => {'num': 999, 'ipaName': 'ghost.apk'})
          ..register('ui', 'refreshDetail', (params) async => refreshCalled = true)
          ..register('ui', 'updateDownloadList', (p) async => updateCalled = true),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], '未找到所选构建，请重试');
      expect(updateCalled, isFalse);
      expect(refreshCalled, isFalse);

      await runtime.dispose();
    });

    test('⑦f jsBuildHistory：updateDownloadList 未注册（未注入回调）→ 静默 ok:true 不崩',
        () async {
      // 能力未注册：host.native.call('updateDownloadList') 返回 {ok:false}（非抛）→ 脚本静默继续 ok:true。
      final runtime = buildRuntime(
        handler: fullHistoryHandler,
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory',
              (options) async => {'num': 5, 'ipaName': 'PABank-8.9.0-5.apk'}),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isTrue);

      await runtime.dispose();
    });

    test(
        '⑧ jsBuildHistory：用户取消（data:null）→ refreshDetail/updateDownloadList 不被调 + 静默 ok:true',
        () async {
      var refreshCalled = false;
      var updateCalled = false;
      final runtime = buildRuntime(
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory', (p) async => null)
          ..register('ui', 'refreshDetail', (params) async => refreshCalled = true)
          ..register('ui', 'updateDownloadList', (p) async => updateCalled = true),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(refreshCalled, isFalse);
      expect(updateCalled, isFalse);

      await runtime.dispose();
    });

    test('⑨ jsBuildHistory：showBuildHistory 失败（回调抛异常）→ 静默 ok:true 不崩',
        () async {
      var refreshCalled = false;
      final runtime = buildRuntime(
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory',
              (options) async => throw Exception('sheet broken'))
          ..register('ui', 'refreshDetail', (params) async => refreshCalled = true),
      );
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);
      expect(refreshCalled, isFalse);
      // 异常被 runtime 捕获记日志，脚本不抛
      expect(logMessages.any((m) => m.contains('sheet broken')), isTrue);

      await runtime.dispose();
    });

    test('⑩ jsBuildHistory：能力未注册（未注入回调）→ 静默 ok:true', () async {
      final runtime = buildRuntime(); // 未注入 showBuildHistory
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isTrue);
      expect(result['data'], isNull);

      await runtime.dispose();
    });

    test('⑪ jsBuildHistory：无版本数据（buildList 空）→ {ok:false, error: 无版本数据}',
        () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {'appLogo': '', 'buildList': <Object>[]};
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], '无版本数据');

      await runtime.dispose();
    });

    test('⑫ jsBuildHistory：无构建记录（builds 空）→ {ok:false, error: 无构建记录}',
        () async {
      final runtime = buildRuntime(handler: (options) {
        if (options.path.contains('/sunflower/i/build-list')) {
          return {
            'appLogo': '/logo/app.png',
            'buildList': [
              {
                '_id': 'bg-empty',
                'version': '8.9.0',
                'platform': 'android',
                'env': 'sit',
                'publishedAt': 1700000000000,
                'builds': <Object>[],
              },
            ],
          };
        }
        return defaultHandler(options);
      });
      await runtime.initialize();

      final result = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(result['ok'], isFalse);
      expect(result['data'], isNull);
      expect(result['error'], '无构建记录');

      await runtime.dispose();
    });
  });

  group('请求风暴防护（build-list 缓存 + login 冷却 + 空参防护）', () {
    /// 真实结构 handler：build-list 全量 + build 接口完整历史 + login/check 成功（code=000000）
    Map<String, dynamic> stormHandler(RequestOptions options) {
      if (options.path.contains('login/check')) {
        return {'code': '000000'};
      }
      return fullHistoryHandler(options);
    }

    test('ⓐ 进入详情全流程（真实结构 mock）→ 请求收敛：build-list 2 + build 1 + login 1（非十几次）',
        () async {
      // 模拟 Flutter 新流程（有 detail.js 跳过 entry getAppInfo）：
      // getAppDetail（1 build-list + 1 build + 1 login）→ jsBuildHistory ×2
      // （首次 versionOptions 复用 getAppDetail 全量 build-list 缓存 0 新请求 +
      //  getBuildHistory 全量缓存命中 + build 接口同 groupId 缓存命中；
      //  二次 jsBuildHistory 全缓存命中 0 请求）→ switchVersion（build-list 带
      //  version 首次发 1 次，build 接口缓存命中）。
      var updateCount = 0;
      final runtime = buildRuntime(
        handler: stormHandler,
        envReader: () => {'PINGAN_USER': 'user1', 'PINGAN_PASS': 'pass1'},
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory',
              (options) async => {'num': 5, 'ipaName': 'PABank-8.9.0-5.apk'})
          ..register('ui', 'updateDownloadList', (p) async => updateCount++),
      );
      await runtime.initialize();

      // ① 进入详情：getAppDetail（1 build-list + 1 build + 1 login）
      final r1 = await runtime.call('main', [
        'getAppDetail',
        {'appId': 'app-1'}
      ]) as Map;
      expect(r1['ok'], isTrue);
      expect(requestLog.where((r) => r.contains('build-list')).length, 1);
      expect(
          requestLog.where((r) => r.contains('/sunflower/i/build&')).length, 1);
      expect(requestLog.where((r) => r.contains('login/check')).length, 1);

      // ② 首次 jsBuildHistory：versionOptions 命中 getAppDetail 的全量缓存（0 请求），
      //    getBuildHistory 复用全量 build-list 缓存（0 请求，build 接口同 groupId 缓存命中）
      final r2 = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(r2['ok'], isTrue);
      expect(updateCount, 1);
      expect(requestLog.where((r) => r.contains('build-list')).length, 1);
      expect(
          requestLog.where((r) => r.contains('/sunflower/i/build&')).length, 1);
      expect(requestLog.where((r) => r.contains('login/check')).length, 1);

      // ③ 二次 jsBuildHistory：全缓存命中 → 0 新请求（切构建历史不再重拉版本/构建）
      final r3 = await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]) as Map;
      expect(r3['ok'], isTrue);
      expect(updateCount, 2);
      expect(requestLog.where((r) => r.contains('build-list')).length, 1);
      expect(
          requestLog.where((r) => r.contains('/sunflower/i/build&')).length, 1);
      expect(requestLog.where((r) => r.contains('login/check')).length, 1);

      // ④ 切版本（switchVersion 同 env+version）：build-list 带 version 首次请求
      // （key name|8.9.0|sit 未缓存）→ +1；build 接口缓存命中 → 0
      final r4 = await runtime.call('main', [
        'switchVersion',
        {'appId': 'app-1', 'env': 'sit', 'version': '8.9.0'}
      ]) as Map;
      expect(r4['ok'], isTrue);
      expect(requestLog.where((r) => r.contains('build-list')).length, 2);
      expect(
          requestLog.where((r) => r.contains('/sunflower/i/build&')).length, 1);
      expect(requestLog.where((r) => r.contains('login/check')).length, 1);

      // 缓存命中日志可定位来源
      expect(logMessages.any((m) => m.contains('[build-list] 缓存命中')), isTrue);
      expect(
          logMessages.any((m) => m.contains('[login/check] 会话缓存命中')), isTrue);

      await runtime.dispose();
    });

    test('ⓑ 空 appId → 不发任何请求（含 build-list 空参防护）', () async {
      final runtime = buildRuntime(handler: stormHandler);
      await runtime.initialize();

      final r = await runtime.call('main', [
        'getAppDetail',
        {'appId': ''}
      ]) as Map;
      expect(r['ok'], isTrue);
      expect(r['data'], isNull);
      expect(requestLog, isEmpty);

      await runtime.dispose();
    });

test('ⓒ login/check 失败 → 60s 冷却：连续操作只发 1 次（会话级单次），不再每次重发',
        () async {
      var loginCheckCount = 0;
      final runtime = buildRuntime(
        handler: (options) {
          if (options.path.contains('login/check')) {
            loginCheckCount++;
            return {'__status': 401, 'msg': 'unauthorized'};
          }
          return fullHistoryHandler(options);
        },
        envReader: () => {'PINGAN_USER': 'user1', 'PINGAN_PASS': 'pass1'},
        nativeHost: JSNativeHost()
          ..register('ui', 'showBuildHistory',
              (options) async => {'num': 5, 'ipaName': 'PABank-8.9.0-5.apk'})
          ..register('ui', 'updateDownloadList', (p) async {
            return null;
          }),
      );
      await runtime.initialize();

      // getAppDetail（单次 login/check 失败）→ 进入冷却
      await runtime.call('main', [
        'getAppDetail',
        {'appId': 'app-1'}
      ]);
      expect(loginCheckCount, 1);

      // jsBuildHistory（groupNeedsAuth → ensureAuthChecked）→ 冷却命中，不重发
      await runtime.call('main', [
        'jsBuildHistory',
        {'appId': 'app-1'}
      ]);
      expect(loginCheckCount, 1);

      // switchVersion → 冷却命中，不重发
      await runtime.call('main', [
        'switchVersion',
        {'appId': 'app-1', 'env': 'sit', 'version': '8.9.0'}
      ]);
      expect(loginCheckCount, 1);

      expect(logMessages.any((m) => m.contains('[login/check] 失败冷却中跳过重发')),
          isTrue);

      await runtime.dispose();
    });
  });
}

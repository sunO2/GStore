import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/impl/js_detail_channel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/page/detail/state.dart';

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

/// load 纪律测试桩：覆写 getAppDetail 返回可编程响应，
/// 不依赖 JS 引擎（qjs .so 缺失环境亦可跑）；detailMenu 走真实 callMain
/// （引擎缺失 → null → actions 空，确定性）。
class _StubAppDetailChannel extends JsDetailChannel {
  _StubAppDetailChannel({required super.appId})
      : super(
          channelKey: 'js.detail',
          detailScript: 'async function main(method, params) { return null; }',
        );

  /// getAppDetail 响应器（返回 null → 模拟脚本失败/未实现；
  /// 可返回挂起的 Future 以观察 load 中间态）
  Future<Map<String, dynamic>?> Function(String appId)? detailResponder;

  @override
  Future<Map<String, dynamic>?> getAppDetail(
    String appId, {
    String? version,
  }) async =>
      detailResponder?.call(appId);
}

/// 捕获式 callbacks：记录 refreshDetail/updateDetail/showError 调用，
/// 并按 DetailLogic 同款语义把数据写入 bound state（供内容保留断言）。
class _CapturingCallbacks implements DetailCallbacks {
  final List<Map<String, dynamic>> refreshCalls = [];
  final List<Map<String, dynamic>> updateCalls = [];
  final List<String> errors = [];
  final List<String> successes = [];

  DetailState? state;

  @override
  Future<void> refreshDetail({
    required Map<String, dynamic> detailData,
  }) async {
    refreshCalls.add(Map<String, dynamic>.from(detailData));
    final s = state;
    if (s != null) s.detailInfo.value = JsChannelDetailProxy(detailData);
  }

  @override
  Future<void> updateDetail({required Map<String, dynamic> partial}) async {
    updateCalls.add(Map<String, dynamic>.from(partial));
    final s = state;
    if (s == null) return;
    // 与 DetailLogic.updateDetail 展开合并语义一致
    final current = s.detailInfo.value;
    if (current is JsChannelDetailProxy) {
      final merged = Map<String, dynamic>.from(current.data);
      partial.forEach((k, v) {
        if (k == 'extra' && v is Map) {
          v.forEach((ek, ev) => merged[ek.toString()] = ev);
        } else {
          merged[k] = v;
        }
      });
      s.detailInfo.value = JsChannelDetailProxy(merged);
    } else {
      final flat = Map<String, dynamic>.from(partial);
      if (partial['extra'] is Map) {
        (partial['extra'] as Map)
            .forEach((ek, ev) => flat[ek.toString()] = ev);
      }
      s.detailInfo.value = JsChannelDetailProxy(flat);
    }
  }

  @override
  void showError(String message, {String? title}) => errors.add(message);

  @override
  Future<void> setActionBusy({required bool visible, String? label}) async {
    final s = state;
    if (s == null) return;
    // 与 DetailLogic.setActionBusy 写 state 语义一致（单测无需 Timer 兜底）
    if (visible) {
      if (label != null && label.isNotEmpty) s.actionBusyLabel.value = label;
      s.actionBusy.value = true;
    } else {
      s.actionBusy.value = false;
      s.actionBusyLabel.value = '';
    }
  }

  @override
  void showSuccess(String message, {String? title}) => successes.add(message);

  // 以下交互回调测试不触达，no-op 兜底
  @override
  Future<void> showVersionPicker({
    required Map<String, dynamic> options,
    required String appId,
  }) async {}

  @override
  Future<void> showBuildHistory({
    required List<Map<String, dynamic>> builds,
    required String appId,
    required String version,
    required String env,
  }) async {}

  @override
  Future<String?> showUAPicker({
    required List<String>? uaOptions,
    required String appId,
    String? current,
  }) async =>
      null;

  @override
  Future<void> updateDownloadList({
    required List<DownloadInfo> downloads,
  }) async {}

  @override
  void syncDownloadToFB(DownloadInfo download) {}

  @override
  Future<void> startDownload(DownloadInfo download, {int? downloadSize, bool fromScript = false}) async {}

  @override
  Future<bool?> showWarningDialog({
    required String title,
    required String content,
    String? confirmText,
    String? cancelText,
    bool isDangerous = false,
  }) async =>
      null;

  @override
  void startApp(String packageName) {}

  @override
  void openBrowser(String url) {}

  @override
  void openProjectBrowser() {}

  @override
  Future<void> submitAppMetadata() async {}

  @override
  Future<List<String>?> showMoreActionsSheet({
    required String appName,
    required List<String> presetTags,
    required List<String> currentTags,
    required List<DetailAction> actions,
  }) async =>
      null;
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
        appId: 'com.example.one',
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
      final jsDetail = detail as JsDetailChannel;
      expect(jsDetail.detailScript, _detailScript);
      expect(jsDetail.channelKey, 'js.detail');

      // 工厂创建的实例可正常消费 detail.js
      final appDetail = await jsDetail.getAppDetail('com.example.one');
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
      expect((first as JsDetailChannel).isDisposed, isTrue);

      // 再取 → 新实例（独立 runtime）
      final second = channel.getDetailChannel('com.example.one');
      expect(second, isNotNull);
      expect(identical(second, first), isFalse);
      expect((second as JsDetailChannel).isDisposed, isFalse);

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
        appId: 'com.example.a',
        channelKey: 'js.detail',
        detailScript: _statefulScript,
        envReader: () => {'TOKEN': 'TOKEN-A'},
      );
      final b = JsDetailChannel(
        appId: 'com.example.b',
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
      expect((d1 as JsDetailChannel).isDisposed, isTrue);
      expect((d2 as JsDetailChannel).isDisposed, isTrue);

      // 缓存已清空：再取 → 新实例（非已释放旧实例）
      final d3 = channel.getDetailChannel('com.example.one');
      expect(d3, isNotNull);
      expect(identical(d3, d1), isFalse);
      expect((d3 as JsDetailChannel).isDisposed, isFalse);

      await channel.dispose(); // 二次 dispose 幂等
    });

    test('⑧ detail 通道在 setEnv 前创建 → 之后读到最新 env（缓存复用不陈旧）', () async {
      final channel = buildChannel(detailScript: _statefulScript);
      await channel.initialize();

      // 先创建 detail 通道（模拟用户先进详情页，此时 env 未配置）
      final detail = channel.getDetailChannel('com.example.one');
      expect(detail, isNotNull);
      final jsDetail = detail as JsDetailChannel;
      final before = await jsDetail.callMain('envValue') as Map;
      expect(before['value'], isNull);

      // 用户去设置页配置 env（setEnv → 热更新 entry runtime）
      await channel.setEnv('TOKEN', 'TOKEN-NEW');

      // 回到详情页（同一 detail 通道实例，缓存复用）→ 应读到最新 env
      // （回归：detail runtime 只在 initialize 快照一次 env 的 bug）
      final after = await jsDetail.callMain('envValue') as Map;
      expect(after['value'], 'TOKEN-NEW');

      await channel.dispose();
    });
  });

  group('JsDetailChannel load 纪律 + ui.updateDetail 桥', () {
    test('⑨ ui.updateDetail 桥：转发 partial 到 callbacks + 既有 5 handler 保留',
        () async {
      final detail = _StubAppDetailChannel(appId: 'com.example.one');
      final cb = _CapturingCallbacks()..state = DetailState();
      final state = cb.state!;
      state.request = const AppDetailRequest(
        appId: 'com.example.one',
        name: 'Req App',
        channel: ChannelType.custom,
      );
      detail.bind(state, cb);

      // 向后兼容：既有 6 个 ui.* handler 未删改 + 新增 ui.setBusy 共 7 个
      final host = detail.nativeHostForTest;
      expect(
        host.names,
        containsAll([
          'ui.showVersionPicker',
          'ui.showBuildHistory',
          'ui.refreshDetail',
          'ui.updateDownloadList',
          'ui.showUAPicker',
        ]),
      );
      expect(host.names, contains('ui.updateDetail'));
      expect(host.names, contains('ui.setBusy'));
      expect(host.names, hasLength(7));

      // 经桥触发：payload 等价转发到 cb.updateDetail 并写入 state
      await host['ui.updateDetail']!({
        'name': 'Pushed Name',
        'sections': ['downloads'],
        'extra': {'identifier': 'id-1'},
      });
      expect(cb.updateCalls, hasLength(1));
      expect(cb.updateCalls.first['name'], 'Pushed Name');
      expect(cb.updateCalls.first['sections'], ['downloads']);
      expect(state.detailInfo.value, isA<JsChannelDetailProxy>());
      expect(state.detailInfo.value!.name, 'Pushed Name');
      // extra 展开合并写入顶层（非嵌套）
      expect((state.detailInfo.value as JsChannelDetailProxy).data['identifier'],
          'id-1');

      // 空 payload / 缺键不抛（partial 任意键子集语义）
      await host['ui.updateDetail']!(<String, dynamic>{});
      expect(cb.updateCalls, hasLength(2));

      await detail.dispose();
    });

    test('⑨b ui.setBusy 桥：visible/label 转发写入 state.actionBusy', () async {
      final detail = _StubAppDetailChannel(appId: 'com.example.one');
      final cb = _CapturingCallbacks()..state = DetailState();
      final state = cb.state!;
      state.request = const AppDetailRequest(
        appId: 'com.example.one',
        name: 'Req App',
        channel: ChannelType.custom,
      );
      detail.bind(state, cb);

      final host = detail.nativeHostForTest;
      await host['ui.setBusy']!({'visible': true, 'label': 'x'});
      expect(state.actionBusy.value, isTrue);
      expect(state.actionBusyLabel.value, 'x');

      await host['ui.setBusy']!({'visible': false});
      expect(state.actionBusy.value, isFalse);
      expect(state.actionBusyLabel.value, '');

      await detail.dispose();
    });

    test('⑩ load 成功路径：prefill 先注入 → 全量替换 + loading 复位', () async {
      final detail = _StubAppDetailChannel(appId: 'com.example.one');
      final gate = Completer<void>();
      detail.detailResponder = (_) => gate.future.then((_) =>
          <String, dynamic>{
            'appId': 'com.example.one',
            'name': 'Full App',
            'des': '全量描述',
            'packageName': 'com.example.one',
            'readme': 'README',
            'downloads': const [],
            'sections': ['downloads', 'readme'],
          });
      final cb = _CapturingCallbacks()..state = DetailState();
      final state = cb.state!;
      state.request = const AppDetailRequest(
        appId: 'com.example.one',
        name: 'Req App',
        channel: ChannelType.custom,
        packageName: 'com.example.one',
        icon: 'icon://req',
        description: '请求描述',
      );
      detail.bind(state, cb);

      final loading = detail.load();
      // 排空 microtask：prefill 注入完成、getAppDetail 挂起在 gate
      await Future<void>.delayed(Duration.zero);

      // prefill 先注入（detailInfo 非 null 且为 request 内容）+ 骨架标志 true
      expect(cb.refreshCalls, hasLength(1));
      expect(state.detailInfo.value, isNotNull);
      expect(state.detailInfo.value!.name, 'Req App');
      expect(state.isLoadingDetail.value, isTrue);
      expect(state.downloadsLoading.value, isTrue);
      expect(state.readmeLoading.value, isTrue);
      expect(state.statisticsLoading.value, isTrue);

      gate.complete();
      await loading;

      // 全量替换 + 复位
      expect(cb.refreshCalls, hasLength(2));
      expect(state.detailInfo.value!.name, 'Full App');
      expect(state.isLoadingDetail.value, isFalse);
      expect(state.downloadsLoading.value, isFalse);
      expect(state.readmeLoading.value, isFalse);
      expect(state.statisticsLoading.value, isFalse);
      expect(state.errorMessage.value, '');
      expect(cb.errors, isEmpty);

      await detail.dispose();
    });

    test('⑪ load 失败分支 A（纯 prefill 未推送）：errorMessage 设置且无异常',
        () async {
      final detail = _StubAppDetailChannel(appId: 'com.example.one');
      detail.detailResponder = (_) async => null;
      final cb = _CapturingCallbacks()..state = DetailState();
      final state = cb.state!;
      state.request = const AppDetailRequest(
        appId: 'com.example.one',
        name: 'Req App',
        channel: ChannelType.custom,
      );
      detail.bind(state, cb);

      await detail.load();

      expect(state.errorMessage.value, '详情加载失败');
      expect(cb.errors, isEmpty, reason: '未推送过阶段数据 → 走错误页而非 toast');
      expect(state.isLoadingDetail.value, isFalse);

      await detail.dispose();
    });

    test('⑫ load 失败分支 B（已推送）：showError 保内容，errorMessage 不设置',
        () async {
      final detail = _StubAppDetailChannel(appId: 'com.example.one');
      // 模拟生产时序：脚本在 getAppDetail 执行窗口内推送阶段数据后返回 null
      // （load 进入即复位标志 → 推送必须发生在本次 load 的拉取窗口内才置位）
      detail.detailResponder = (_) async {
        await detail.nativeHostForTest['ui.updateDetail']!({
          'name': 'Pushed Name',
          'sections': ['downloads'],
        });
        return null;
      };
      final cb = _CapturingCallbacks()..state = DetailState();
      final state = cb.state!;
      state.request = const AppDetailRequest(
        appId: 'com.example.one',
        name: 'Req App',
        channel: ChannelType.custom,
      );
      detail.bind(state, cb);

      await detail.load();

      expect(cb.errors, ['详情加载失败，当前显示为已加载内容']);
      expect(state.errorMessage.value, '', reason: '已推送 → 不设错误页');
      expect(state.detailInfo.value!.name, 'Pushed Name',
          reason: '已推送内容保留不被清除');
      expect(state.isLoadingDetail.value, isFalse);

      await detail.dispose();
    });

    test('⑬ prefill 形状：仅含非空字段、绝不含 version、固定 downloads/sections',
        () async {
      final detail = _StubAppDetailChannel(appId: 'com.example.one');
      detail.detailResponder = (_) async => null; // 失败不影响已捕获的 prefill
      final cb = _CapturingCallbacks()..state = DetailState();
      final state = cb.state!;
      // icon/description/packageName 缺省 null → 对应键缺席
      state.request = const AppDetailRequest(
        appId: 'com.example.one',
        name: 'Req App',
        channel: ChannelType.custom,
      );
      detail.bind(state, cb);

      await detail.load();

      final prefill = cb.refreshCalls.first;
      expect(prefill.containsKey('version'), isFalse,
          reason: 'AppDetailRequest 无 version 字段，prefill 绝不含 version');
      expect(prefill['appId'], 'com.example.one');
      expect(prefill['name'], 'Req App');
      expect(prefill.containsKey('icon'), isFalse, reason: '空字段跳过该键');
      expect(prefill.containsKey('description'), isFalse, reason: '空字段跳过该键');
      expect(prefill.containsKey('packageName'), isFalse, reason: '空字段跳过该键');
      expect(prefill.containsKey('extra'), isFalse,
          reason: 'packageName 为空时 extra 键缺席');
      expect(prefill['sections'], ['downloads']);
      expect(prefill['downloads'], isEmpty);

      await detail.dispose();
    });

    test('⑮a load 失败兜底：纯 prefill 失败后三区块 loading 标志全复位',
        () async {
      final detail = _StubAppDetailChannel(appId: 'com.example.one');
      detail.detailResponder = (_) async => null;
      final cb = _CapturingCallbacks()..state = DetailState();
      final state = cb.state!;
      state.request = const AppDetailRequest(
        appId: 'com.example.one',
        name: 'Req App',
        channel: ChannelType.custom,
      );
      detail.bind(state, cb);

      await detail.load();

      expect(state.errorMessage.value, '详情加载失败');
      expect(state.downloadsLoading.value, isFalse,
          reason: 'F-2：失败路径 finally 兜底复位，骨架不永久转圈');
      expect(state.readmeLoading.value, isFalse);
      expect(state.statisticsLoading.value, isFalse);
      expect(state.isLoadingDetail.value, isFalse);
      expect(cb.errors, isEmpty, reason: '纯 prefill 未推送 → 错误页而非 toast');

      await detail.dispose();
    });

    test('⑮b load 失败兜底：先推后败（已推送分支）三区块标志同样全复位',
        () async {
      final detail = _StubAppDetailChannel(appId: 'com.example.one');
      final cb = _CapturingCallbacks()..state = DetailState();
      final state = cb.state!;
      state.request = const AppDetailRequest(
        appId: 'com.example.one',
        name: 'Req App',
        channel: ChannelType.custom,
      );
      detail.bind(state, cb);
      // 捕获 native host：bind 后即可直触发桥 handler（无需 JS 引擎）
      final capturedNativeHost = detail.nativeHostForTest;

      final gate = Completer<Map<String, dynamic>?>();
      detail.detailResponder = (_) => gate.future;
      final loading = detail.load();
      // 排空 microtask：prefill 注入完成、getAppDetail 挂起在 gate
      await Future<void>.delayed(Duration.zero);
      expect(state.downloadsLoading.value, isTrue,
          reason: '前置确认：拉取窗口内三区块骨架确已置 true');

      // 先推：拉取窗口内经桥推送阶段数据（置位 _receivedUpdateDetail）
      await capturedNativeHost['ui.updateDetail']!({
        'name': 'Pushed Name',
        'sections': ['downloads'],
      });
      expect(state.detailInfo.value!.name, 'Pushed Name');

      // 后败：getAppDetail 返回 null → 已推送分支（showError 保内容）
      gate.complete(null);
      await loading;

      expect(cb.errors, ['详情加载失败，当前显示为已加载内容']);
      expect(state.errorMessage.value, '', reason: '已推送 → 不设错误页');
      expect(state.detailInfo.value!.name, 'Pushed Name',
          reason: '已推送内容保留不被清除');
      expect(state.downloadsLoading.value, isFalse,
          reason: 'F-2：失败路径 finally 兜底复位，骨架不永久转圈');
      expect(state.readmeLoading.value, isFalse);
      expect(state.statisticsLoading.value, isFalse);
      expect(state.isLoadingDetail.value, isFalse);

      await detail.dispose();
    });
  });
}

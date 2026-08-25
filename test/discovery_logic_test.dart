import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;
import 'package:gstore/page/home/tab/discovery/logic.dart';

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

/// 最小枚举渠道（测试用）：验证枚举渠道 code 映射不受脚本渠道改造影响
class _FakeEnumChannel extends IChannel {
  _FakeEnumChannel(this._type, this._apps);

  final ChannelType _type;
  final List<AppSummary> _apps;

  @override
  ChannelInfo get info =>
      ChannelInfo(type: _type, name: _type.code, description: '测试用枚举渠道');

  @override
  bool isInitialized = false;

  @override
  Future<void> initialize() async => isInitialized = true;

  @override
  Future<bool> checkAvailable() async => true;

  @override
  Widget? getAddAppWidget(BuildContext context, Function(AppSummary) onAppAdded,
          {VoidCallback? onAppSaved}) =>
      null;

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: _apps, from: _type);

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(String appId,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(String appId,
          {bool forceRefresh = false}) async =>
      ChannelResult.failure(from: _type, error: '不支持');

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(String appId) async =>
      ChannelResult.failure(from: _type, error: '不支持');

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => appInfo.appId;

  @override
  Future<ChannelResult<void>> removeApp(String appId) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(String keyword,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: _type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(String categoryId,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: _type);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: _type);

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: false, from: _type);

  @override
  Future<ChannelResult<bool>> doUpdate(
          {Function(int current, int total)? onProgress}) async =>
      ChannelResult.success(data: true, from: _type);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

/// 合法脚本 A：应用名含 'A'
const String _scriptA = '''
const CHANNEL_META = { name: 'A 渠道', description: 'A 描述' };

const apps = [
  { appId: 'com.a.one', name: 'App A One', icon: 'icon://a1', des: 'A 第一个' }
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

/// 合法脚本 B：应用名含 'B'
const String _scriptB = '''
const CHANNEL_META = { name: 'B 渠道' };

const apps = [
  { appId: 'com.b.one', name: 'App B One', icon: 'icon://b1', des: 'B 第一个' }
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAppDao appDao;
  late Dio dio;

  setUp(() async {
    await ModuleManager.instance.clear();
    ModuleManager.instance.injectContext(null);
    Get.reset();
    // 绑定 ChannelManager 单例（DiscoveryLogic 经 ModuleManager 取渠道管理器）
    ModuleManager.instance.bind<ChannelManager>(ChannelManager.instance);
    appDao = _FakeAppDao();
    dio = Dio();
    dio.httpClientAdapter = _FakeDioAdapter();
  });

  tearDown(() {
    // 清理本次测试注册的动态渠道（单例隔离）
    for (final channel in ChannelManager.instance.dynamicChannels) {
      if (channel is JsChannel) {
        ChannelManager.instance.unregisterChannelByKey(channel.channelKey);
      }
    }
    // 清理枚举渠道（custom 槽位可能残留脚本渠道，一并清空）
    for (final type in ChannelType.values) {
      if (ChannelManager.instance.getChannel(type) != null) {
        ChannelManager.instance.unregisterChannel(type);
      }
    }
    ModuleManager.instance.unbind<ChannelManager>();
    Get.reset();
  });

  Future<JsChannel> registerScriptChannel(String key, String script) async {
    final channel = JsChannel(
      channelKey: key,
      script: script,
      dio: dio,
      appDao: appDao,
    );
    await channel.initialize();
    ChannelManager.instance.registerChannel(channel);
    return channel;
  }

  /// 向内存 DAO 预置应用数据（适配 getAllApps 只读库语义）。
  /// getAllApps 改为读 appDao.getAppsByChannel(channelKey) 后，
  /// 脚本不再驱动 getAllApps 数据，需在 setup 阶段预置。
  Future<void> seedAppsFor(
    String channelCode,
    List<({String appId, String name})> apps,
  ) async {
    for (final app in apps) {
      await appDao.insertApp(ChannelAddedApp(
        channelCode: channelCode,
        appId: app.appId,
        name: app.name,
        user: '',
        repositories: '',
        icon: '',
        description: '',
        addTime: 0,
      ));
    }
  }

  group('DiscoveryLogic 脚本渠道按 code 独立显示', () {
    test('① 未注册脚本渠道：sortedChannelCodes 仅含已加载渠道（空）', () {
      final logic = DiscoveryLogic();
      expect(logic.sortedChannelCodes, isEmpty);
    });

    test('② 注册两个脚本渠道 → sortedChannelCodes 含两个 code（未加载也占位）',
        () async {
      await registerScriptChannel('js_pingan', _scriptA);
      await registerScriptChannel('js_vivo', _scriptB);

      final logic = DiscoveryLogic();
      expect(logic.sortedChannelCodes, containsAll(['js_pingan', 'js_vivo']));
      // 不再出现共享的 custom 槽位
      expect(logic.sortedChannelCodes, isNot(contains('custom')));
    });

    test('③ loadData 后 channelApps 有两个独立槽位（code 键），数据不串', () async {
      // B3 适配：getAllApps 只读本地已添加库 → 预置 DAO 数据（不再依赖脚本执行）
      await seedAppsFor('js_pingan', [
        (appId: 'com.a.one', name: 'App A One'),
      ]);
      await seedAppsFor('js_vivo', [
        (appId: 'com.b.one', name: 'App B One'),
      ]);
      await registerScriptChannel('js_pingan', _scriptA);
      await registerScriptChannel('js_vivo', _scriptB);

      final logic = DiscoveryLogic();
      // onReady 设置 _channelManager 并触发 loadData（与真实页面生命周期一致）
      logic.onReady();
      await logic.loadData();

      expect(logic.state.channelApps.keys, containsAll(['js_pingan', 'js_vivo']));
      expect(logic.state.channelApps['js_pingan'], hasLength(1));
      expect(logic.state.channelApps['js_vivo'], hasLength(1));
      expect(logic.state.channelApps['js_pingan']!.first.name, 'App A One');
      expect(logic.state.channelApps['js_vivo']!.first.name, 'App B One');
      // 无 custom 合并槽位（后注册不再覆盖先注册）
      expect(logic.state.channelApps.containsKey('custom'), isFalse);
    });

    test('④ selectedChannel 按 code 切换', () async {
      // B3 适配：getAllApps 只读本地已添加库 → 预置 DAO 数据
      await seedAppsFor('js_pingan', [
        (appId: 'com.a.one', name: 'App A One'),
      ]);
      await seedAppsFor('js_vivo', [
        (appId: 'com.b.one', name: 'App B One'),
      ]);
      await registerScriptChannel('js_pingan', _scriptA);
      await registerScriptChannel('js_vivo', _scriptB);

      final logic = DiscoveryLogic();
      logic.onReady();
      await logic.loadData();

      // 全部：两个渠道应用都显示
      expect(logic.getDisplayApps(), hasLength(2));

      logic.selectChannel('js_pingan');
      expect(logic.state.selectedChannel.value, 'js_pingan');
      final pinganApps = logic.getDisplayApps();
      expect(pinganApps, hasLength(1));
      expect(pinganApps.first.$1.name, 'App A One');
      expect(pinganApps.first.$2, 'js_pingan');

      logic.selectChannel('js_vivo');
      final vivoApps = logic.getDisplayApps();
      expect(vivoApps, hasLength(1));
      expect(vivoApps.first.$1.name, 'App B One');
      expect(vivoApps.first.$2, 'js_vivo');

      logic.selectChannel(null);
      expect(logic.state.selectedChannel.value, isNull);
      expect(logic.getDisplayApps(), hasLength(2));
    });

    test('⑤ 重启模拟：重新注册渠道后再次加载，各自槽位数据仍在（不复盖丢失）',
        () async {
      // B3 适配：getAllApps 只读本地已添加库 → 预置 DAO 数据
      await seedAppsFor('js_pingan', [
        (appId: 'com.a.one', name: 'App A One'),
      ]);
      await seedAppsFor('js_vivo', [
        (appId: 'com.b.one', name: 'App B One'),
      ]);
      await registerScriptChannel('js_pingan', _scriptA);
      await registerScriptChannel('js_vivo', _scriptB);

      final logic = DiscoveryLogic();
      logic.onReady();
      await logic.loadData();
      expect(logic.state.channelApps['js_pingan']!.first.name, 'App A One');
      expect(logic.state.channelApps['js_vivo']!.first.name, 'App B One');

      // 模拟重启：注销全部脚本渠道后重新注册（新实例、同 key）
      for (final channel in ChannelManager.instance.dynamicChannels.toList()) {
        if (channel is JsChannel) {
          ChannelManager.instance.unregisterChannelByKey(channel.channelKey);
        }
      }
      await registerScriptChannel('js_pingan', _scriptA);
      await registerScriptChannel('js_vivo', _scriptB);

      await logic.loadData();

      expect(logic.state.channelApps['js_pingan'], isNotNull);
      expect(logic.state.channelApps['js_vivo'], isNotNull);
      expect(logic.state.channelApps['js_pingan']!.first.name, 'App A One');
      expect(logic.state.channelApps['js_vivo']!.first.name, 'App B One');
    });

    test('⑥ 枚举渠道（vivo）仍正常（code 映射）', () async {
      final vivo = _FakeEnumChannel(ChannelType.vivo, [
        AppSummary(
          appId: 'com.vivo.app',
          name: 'Vivo App',
          user: '',
          repositories: '',
          icon: '',
          des: '',
        ),
      ]);
      ChannelManager.instance.registerChannel(vivo);

      final logic = DiscoveryLogic();
      logic.onReady();
      await logic.loadData();

      expect(logic.state.channelApps['vivo'], hasLength(1));
      expect(logic.state.channelApps['vivo']!.first.name, 'Vivo App');
      expect(logic.sortedChannelCodes, contains('vivo'));

      logic.selectChannel('vivo');
      final apps = logic.getDisplayApps();
      expect(apps, hasLength(1));
      expect(apps.first.$2, 'vivo');
    });
  });
}
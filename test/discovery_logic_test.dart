import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_added_app_dao.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/module/module_manager.dart';
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

  group('DiscoveryLogic 动态脚本渠道显示', () {
    test('① 未注册脚本渠道：sortedChannelTypes 仅含已加载渠道（空）', () {
      final logic = DiscoveryLogic();
      expect(logic.sortedChannelTypes, isEmpty);
    });

    test('② 脚本渠道注册后 sortedChannelTypes 并入 custom（数据未加载也占位）', () async {
      await registerScriptChannel('js_vivo', _scriptA);

      final logic = DiscoveryLogic();
      expect(logic.sortedChannelTypes, contains(ChannelType.custom));
    });

    test('③ loadData 后脚本渠道数据进入 channelApps[custom]', () async {
      await registerScriptChannel('js_vivo', _scriptA);

      final logic = DiscoveryLogic();
      // onReady 设置 _channelManager 并触发 loadData（与真实页面生命周期一致）
      logic.onReady();
      await logic.loadData();

      final apps = logic.state.channelApps[ChannelType.custom];
      expect(apps, isNotNull);
      expect(apps, hasLength(1));
      expect(apps!.first.name, 'App A One');
      expect(logic.sortedChannelTypes, contains(ChannelType.custom));
    });

    test('④ 多个脚本渠道共享 custom 槽位（合并显示，后注册覆盖）', () async {
      await registerScriptChannel('js_one', _scriptA);
      await registerScriptChannel('js_two', _scriptB);

      final logic = DiscoveryLogic();
      // 合并显示：custom 只出现一次
      expect(
        logic.sortedChannelTypes.where((t) => t == ChannelType.custom).length,
        1,
      );

      logic.onReady();
      await logic.loadData();

      // 共享 custom 键 → 单槽位，后注册渠道数据胜出（多脚本独立展示留待后续）
      final apps = logic.state.channelApps[ChannelType.custom];
      expect(apps, isNotNull);
      expect(apps, hasLength(1));
      expect(apps!.first.name, 'App B One');
    });
  });
}
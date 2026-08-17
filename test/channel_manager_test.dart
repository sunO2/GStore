import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;

/// 最小枚举渠道（测试用）：模拟既有注册逻辑，验证动态索引不破坏旧行为
class _FakeEnumChannel extends IChannel {
  @override
  final ChannelInfo info = ChannelInfo(
    type: ChannelType.github,
    name: 'fake-github',
    description: '测试用枚举渠道',
  );

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
      ChannelResult.success(data: [], from: ChannelType.github);

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(String appId,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: null, from: ChannelType.github);

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(String appId,
          {bool forceRefresh = false}) async =>
      ChannelResult.failure(from: ChannelType.github, error: '不支持');

  @override
  Future<ChannelResult<AppUpdateCheckResult>> checkAppUpdate(String appId) async =>
      ChannelResult.failure(from: ChannelType.github, error: '不支持');

  @override
  Future<ChannelResult<void>> addApp(AppSummary app) async =>
      ChannelResult.success(data: null, from: ChannelType.github);

  @override
  Future<String> canonicalAppId(AppSummary appInfo) async => appInfo.appId;

  @override
  Future<ChannelResult<void>> removeApp(String appId) async =>
      ChannelResult.success(data: null, from: ChannelType.github);

  @override
  Future<ChannelResult<List<AppSummary>>> searchApps(String keyword,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: ChannelType.github);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(String categoryId,
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: ChannelType.github);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: [], from: ChannelType.github);

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: false, from: ChannelType.github);

  @override
  Future<ChannelResult<bool>> doUpdate(
          {Function(int current, int total)? onProgress}) async =>
      ChannelResult.success(data: true, from: ChannelType.github);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig(
          {bool forceRefresh = false}) async =>
      ChannelResult.success(data: null, from: ChannelType.github);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

void main() {
  setUp(() async {
    // 单例重置（既有测试约定）：disposeAll 清空渠道并置空 _instance
    await ChannelManager.instance.disposeAll();
  });

  group('ChannelManager 动态字符串索引', () {
    test('registerChannel(JSChannel) → getChannelByKey 返回、dynamicChannels 含它', () async {
      final manager = ChannelManager.instance;
      final js = JsChannel(
        channelKey: 'js.vivo',
        script: 'const CHANNEL_META = { name: "vivo 脚本" };\n'
            'function main(method, params) { return null; }',
      );

      manager.registerChannel(js);

      expect(manager.getChannelByKey('js.vivo'), same(js),
          reason: '动态索引按 key 可取回同一实例');
      expect(manager.getChannelByKey('js.other'), isNull);

      expect(manager.dynamicChannels, contains(js));
      expect(manager.dynamicChannels, hasLength(1));

      // JSChannel 同时登记 _channels[custom]（后注册覆盖决策）
      expect(manager.getChannel(ChannelType.custom), same(js));
    });

    test('unregisterChannelByKey 清理动态索引', () async {
      final manager = ChannelManager.instance;
      final js = JsChannel(
        channelKey: 'js.x',
        script: 'function main(method, params) { return null; }',
      );
      manager.registerChannel(js);

      manager.unregisterChannelByKey('js.x');

      expect(manager.getChannelByKey('js.x'), isNull);
      expect(manager.dynamicChannels, isEmpty);
      expect(manager.getChannel(ChannelType.custom), isNull,
          reason: 'custom 槽位同步清理');
    });

    test('unregisterChannel(custom) 同步清理 _channelsByKey', () async {
      final manager = ChannelManager.instance;
      final js = JsChannel(
        channelKey: 'js.y',
        script: 'function main(method, params) { return null; }',
      );
      manager.registerChannel(js);

      manager.unregisterChannel(ChannelType.custom);

      expect(manager.getChannelByKey('js.y'), isNull);
      expect(manager.dynamicChannels, isEmpty);
    });

    test('既有枚举渠道逻辑不受影响', () async {
      final manager = ChannelManager.instance;
      final fake = _FakeEnumChannel();
      final js = JsChannel(
        channelKey: 'js.z',
        script: 'function main(method, params) { return null; }',
      );

      manager.registerChannel(fake);
      manager.registerChannel(js);

      // 枚举渠道按类型可取回；非 DynamicChannel 不进动态索引
      expect(manager.getChannel(ChannelType.github), same(fake));
      expect(manager.dynamicChannels, hasLength(1));

      manager.unregisterChannel(ChannelType.github);
      expect(manager.getChannel(ChannelType.github), isNull);
      expect(manager.getChannelByKey('js.z'), same(js),
          reason: '注销枚举渠道不影响动态索引');

      manager.unregisterChannelByKey('js.z');
      expect(manager.getChannelByKey('js.z'), isNull);
    });
  });

  group('ChannelManager.getChannelByCode 统一 code 查询', () {
    test('枚举渠道 code 命中 _channels[type]', () async {
      final manager = ChannelManager.instance;
      final fake = _FakeEnumChannel();
      manager.registerChannel(fake);

      expect(manager.getChannelByCode('github'), same(fake),
          reason: '枚举 code（type.code）应返回对应渠道');
      expect(manager.getChannelByCode('vivo'), isNull,
          reason: '未注册的枚举 code 返回 null');
    });

    test('脚本渠道 channelKey 命中 _channelsByKey', () async {
      final manager = ChannelManager.instance;
      final js = JsChannel(
        channelKey: 'js_pingan',
        script: 'function main(method, params) { return null; }',
      );
      manager.registerChannel(js);

      expect(manager.getChannelByCode('js_pingan'), same(js),
          reason: '脚本渠道 code（channelKey）应返回对应渠道');
    });

    test('枚举 code 与脚本 key 并存时互不干扰', () async {
      final manager = ChannelManager.instance;
      final fake = _FakeEnumChannel();
      final js = JsChannel(
        channelKey: 'js_vivo',
        script: 'function main(method, params) { return null; }',
      );
      manager.registerChannel(fake);
      manager.registerChannel(js);

      expect(manager.getChannelByCode('github'), same(fake));
      expect(manager.getChannelByCode('js_vivo'), same(js));
      expect(manager.getChannelByCode('unknown_code'), isNull,
          reason: '两者皆无 → null');
    });
  });
}

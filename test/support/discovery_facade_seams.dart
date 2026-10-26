/// Shared test seams for the discovery add-to-library facade tests.
///
/// Not a test file (no `main`); imported by `discovery_add_via_facade_test.dart`
/// and `discovery_settags_via_facade_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/IChannel.dart';
import 'package:gstore/core/channel/model/AppUpdateCheckResult.dart';
import 'package:gstore/core/channel/model/ChannelInfo.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/db/apps/AppInfo.dart' as db;

/// Records every added-apps facade call so a test can prove which lane ran and
/// which one did not.
class RecordingAddedApps implements AddedAppsBackend {
  RecordingAddedApps(this.label);

  final String label;

  final List<(String, String)> toggleCalls = [];
  final List<(String, String)> addCalls = [];
  final List<(String, String, List<String>)> setTagsCalls = [];
  final List<String> clearCalls = [];
  int notifyCalls = 0;

  @override
  Future<void> add(String channel, String appId,
      {int? sortOrder, AppSummary? appInfo}) async {
    addCalls.add((channel, appId));
  }

  @override
  Future<bool> toggle(String channel, String appId) async {
    toggleCalls.add((channel, appId));
    return true;
  }

  @override
  Future<void> setTags(String channel, String appId, List<String> tags) async {
    setTagsCalls.add((channel, appId, tags));
  }

  @override
  Future<void> clearChannel(String channel) async {
    clearCalls.add(channel);
  }

  @override
  Future<void> notifyChanged() async => notifyCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused added-apps backend method: ${invocation.memberName}');
}

/// Minimal aggregate seam. Serves the read paths the discovery notifier keeps
/// (`getAddedAppsIndex`, `getTags`) and FAILS LOUDLY if any write path reaches
/// it — recording the member name so a test can assert it stayed untouched.
class RecordingAggregate implements IAggregateService {
  int indexCalls = 0;
  Map<String, Set<String>> index = {};
  List<String> tags = const [];
  final List<Symbol> writeCalls = [];

  @override
  Stream<List<AddedAppInfo>> get appsChangedStream => const Stream.empty();

  @override
  Future<Map<String, Set<String>>> getAddedAppsIndex() async {
    indexCalls++;
    return index;
  }

  @override
  Future<List<String>> getTags({
    required String channelCode,
    required String appId,
  }) async =>
      tags;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    writeCalls.add(invocation.memberName);
    throw UnimplementedError(
        'legacy aggregate write must not run: ${invocation.memberName}');
  }
}

class FakeFlagsBackend implements CoreFlagsBackend {
  FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
  }
}

/// Minimal enum channel so a Dart registry entry exists and the discovery
/// notifier's `getChannelByCode` gate passes without a network/db.
class FakeEnumChannel extends IChannel {
  FakeEnumChannel(this._type, this._apps);

  final ChannelType _type;
  final List<AppSummary> _apps;
  int getAllAppsCalls = 0;

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
  Widget? getAddAppWidget(
    BuildContext context,
    Function(AppSummary) onAppAdded, {
    VoidCallback? onAppSaved,
  }) =>
      null;

  @override
  Future<ChannelResult<List<AppSummary>>> getAllApps({
    bool forceRefresh = false,
  }) async {
    getAllAppsCalls++;
    return ChannelResult.success(data: _apps, from: _type);
  }

  @override
  Future<ChannelResult<AppSummary?>> getAppInfo(
    String appId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<ChannelResult<IDetailInfo>> getAppDetail(
    String appId, {
    bool forceRefresh = false,
  }) async =>
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
  Future<ChannelResult<List<AppSummary>>> searchApps(
    String keyword, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: _type);

  @override
  Future<ChannelResult<List<AppSummary>>> searchByCategory(
    String categoryId, {
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: _type);

  @override
  Future<ChannelResult<List<db.AppCategory>>> getAllCategories({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: const [], from: _type);

  @override
  Future<ChannelResult<bool>> checkUpdate() async =>
      ChannelResult.success(data: false, from: _type);

  @override
  Future<ChannelResult<bool>> doUpdate({
    Function(int current, int total)? onProgress,
  }) async =>
      ChannelResult.success(data: true, from: _type);

  @override
  Future<ChannelResult<db.AppInfoConfig?>> getConfig({
    bool forceRefresh = false,
  }) async =>
      ChannelResult.success(data: null, from: _type);

  @override
  Future<void> clearCache() async {}

  @override
  Future<int> getCacheSize() async => 0;

  @override
  Future<void> dispose() async {}
}

const AppSummary sampleApp = AppSummary(
  appId: 'com.added',
  name: 'Added App',
  user: '',
  repositories: '',
  icon: '',
  des: '',
);

/// Installs a flags backend with only `catalog` set, then refreshes.
Future<void> setCatalogFlag({required bool catalog}) async {
  CoreFlags.installBackend(FakeFlagsBackend(CoreFlagsSnapshot(catalog: catalog)));
  await CoreFlags.refresh();
  expect(CoreFlags.catalog, catalog);
}

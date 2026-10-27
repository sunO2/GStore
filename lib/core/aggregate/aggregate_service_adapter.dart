/// Thin [IAggregateService] adapter over the core-only [AddedAppsFacade].
///
/// `AppAggregatorManager` is now DB-free (it only performs the pure metadata
/// join), so it can no longer satisfy [IAggregateService]. This adapter keeps
/// the public `IAggregateService` contract for the two consumers
/// (`applist`/`discovery`), delegating every read/write to the flag-routed
/// facade and forwarding the change signal from the manager.
///
/// No recursion: the facade's aggregated reads delegate to
/// [AppAggregatorManager.aggregateWithMeta], which never calls back into this
/// adapter or the facade.
library;

import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';

class AggregateServiceAdapter implements IAggregateService {
  AggregateServiceAdapter({
    AddedAppsFacade? facade,
    AppAggregatorManager? manager,
  })  : _facade = facade ?? AddedAppsFacade.instance,
        _manager = manager ?? AppAggregatorManager.instance;

  final AddedAppsFacade _facade;
  final AppAggregatorManager _manager;

  @override
  Stream<List<AddedAppInfo>> get appsChangedStream =>
      _manager.appsChangedStream;

  @override
  Future<void> removeApp({
    required String channelCode,
    required String appId,
  }) =>
      _facade.remove(channelCode, appId);

  @override
  Future<bool> isAppAdded({
    required String channelCode,
    required String appId,
  }) =>
      _facade.isAdded(channelCode, appId);

  @override
  Future<List<AddedAppInfo>> getAllAddedApps() => _facade.list();

  @override
  Future<List<AddedAppInfo>> getAppsByChannel(String channelCode) =>
      _facade.listChannel(channelCode);

  @override
  Future<int> getTotalCount() => _facade.totalCount();

  @override
  Future<void> addApps({
    required String channelCode,
    required List<AppSummary> appInfos,
  }) async {
    for (final app in appInfos) {
      await _facade.add(channelCode, app.appId, appInfo: app);
    }
  }

  @override
  Future<bool> toggleApp({
    required String channelCode,
    required AppSummary appInfo,
  }) =>
      _facade.toggle(channelCode, appInfo.appId);

  @override
  Future<List<String>> getTags({
    required String channelCode,
    required String appId,
  }) =>
      _facade.tags(channelCode, appId);

  @override
  Future<void> setTags({
    required String channelCode,
    required String appId,
    required List<String> tags,
  }) =>
      _facade.setTags(channelCode, appId, tags);

  @override
  Future<void> clearChannel(String channelCode) =>
      _facade.clearChannel(channelCode);

  @override
  Future<Map<String, Set<String>>> getAddedAppsIndex() async {
    final apps = await _facade.list();
    final index = <String, Set<String>>{};
    for (final app in apps) {
      index.putIfAbsent(app.channelId, () => <String>{}).add(app.appId);
    }
    return index;
  }

  @override
  Future<List<AggregatedAppInfo>> getAggregatedApps() =>
      _facade.getAggregatedApps();

  @override
  Future<(List<AggregatedAppInfo> apps, int total)> getAggregatedAppsPage({
    required int offset,
    required int limit,
  }) =>
      _facade.getAggregatedAppsPage(offset: offset, limit: limit);
}

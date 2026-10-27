/// Core-only facade over added apps and user tags.
///
/// The legacy Dart store (`AppAddedDatabase`) was deleted, so this facade now
/// routes exclusively to the FRB `AddedAppsApi` ([FrbAddedAppsBackend]). Reads
/// are joined by the DB-free [AppAggregatorManager.aggregateWithMeta].
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Injectable added-apps transport seam.
abstract class AddedAppsBackend {
  Future<void> add(String channel, String appId,
      {int? sortOrder, AppSummary? appInfo});

  Future<bool> remove(String channel, String appId);

  Future<void> rename(String channel, String oldAppId, String newAppId);

  Future<void> setOrder(String channel, String appId, int sortOrder);

  Future<bool> toggle(String channel, String appId);

  Future<void> clearChannel(String channel);

  Future<void> clearAll();

  Future<List<AddedAppInfo>> list();

  Future<List<AddedAppInfo>> listChannel(String channel);

  Future<AddedAppInfo?> get(String channel, String appId);

  Future<bool> isAdded(String channel, String appId);

  Future<int> totalCount();

  Future<int> countChannel(String channel);

  Future<void> setTags(String channel, String appId, List<String> tags);

  Future<void> addTag(String channel, String appId, String tag);

  Future<void> removeTag(String channel, String appId, String tag);

  Future<List<String>> tags(String channel, String appId);

  Future<Map<String, List<String>>> tagsIndex();

  /// Announces that added-app data changed.
  ///
  /// The legacy backend fans out on the manager's `appsChangedStream`; the core
  /// backend has no Dart-side stream, so it refreshes the authoritative
  /// projection (the Rust core owns the `catalog.changed` event lane).
  Future<void> notifyChanged();
}

/// Production FRB backend.
class FrbAddedAppsBackend implements AddedAppsBackend {
  FrbAddedAppsBackend({this.dataDir, this.filesDir, this.cacheDir});

  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;

  rust.AddedAppsApi? _api;
  Future<rust.AddedAppsApi>? _pending;

  Future<rust.AddedAppsApi> _ensureApi() {
    final existing = _api;
    if (existing != null) return Future.value(existing);
    return _pending ??= _create();
  }

  Future<rust.AddedAppsApi> _create() async {
    try {
      await RustBridge.ensureInitialized();
      final dirs = await _resolveDirs();
      final api = await rust.AddedAppsApi.init(
        dataDir: dirs.$1,
        filesDir: dirs.$2,
        cacheDir: dirs.$3,
      );
      _api = api;
      return api;
    } finally {
      _pending = null;
    }
  }

  Future<(String, String, String)> _resolveDirs() async {
    if (dataDir != null && filesDir != null && cacheDir != null) {
      return (dataDir!, filesDir!, cacheDir!);
    }
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    return ('$root/data', '$root/files', '$root/cache');
  }

  Future<T> _call<T>(Future<T> Function(rust.AddedAppsApi api) action) async {
    final api = await _ensureApi();
    return action(api);
  }

  @override
  Future<void> add(String channel, String appId,
          {int? sortOrder, AppSummary? appInfo}) =>
      _call((api) => api.add(
            channel: channel,
            appId: appId,
            sortOrder: sortOrder,
          ));

  @override
  Future<bool> remove(String channel, String appId) =>
      _call((api) => api.remove(channel: channel, appId: appId));

  @override
  Future<void> rename(String channel, String oldAppId, String newAppId) =>
      _call((api) => api.rename(
            channel: channel,
            oldAppId: oldAppId,
            newAppId: newAppId,
          ));

  @override
  Future<void> setOrder(String channel, String appId, int sortOrder) =>
      _call((api) => api.setOrder(
            channel: channel,
            appId: appId,
            sortOrder: sortOrder,
          ));

  @override
  Future<bool> toggle(String channel, String appId) =>
      _call((api) => api.toggle(channel: channel, appId: appId));

  @override
  Future<void> clearChannel(String channel) =>
      _call((api) => api.clearChannel(channel: channel));

  @override
  Future<void> clearAll() => _call((api) => api.clearAll());

  @override
  Future<List<AddedAppInfo>> list() =>
      _call((api) => api.list()).then(_mapApps);

  @override
  Future<List<AddedAppInfo>> listChannel(String channel) =>
      _call((api) => api.listChannel(channel: channel)).then(_mapApps);

  @override
  Future<AddedAppInfo?> get(String channel, String appId) async {
    final entry =
        await _call((api) => api.get_(channel: channel, appId: appId));
    return entry == null ? null : addedAppFromRust(entry);
  }

  @override
  Future<bool> isAdded(String channel, String appId) =>
      _call((api) => api.isAdded(channel: channel, appId: appId));

  @override
  Future<int> totalCount() =>
      _call((api) => api.totalCount()).then((value) => value.toInt());

  @override
  Future<int> countChannel(String channel) => _call((api) => api.countChannel(
        channel: channel,
      )).then((value) => value.toInt());

  @override
  Future<void> setTags(String channel, String appId, List<String> tags) =>
      _call((api) => api.setTags(channel: channel, appId: appId, tags: tags));

  @override
  Future<void> addTag(String channel, String appId, String tag) =>
      _call((api) => api.addTag(channel: channel, appId: appId, tag: tag));

  @override
  Future<void> removeTag(String channel, String appId, String tag) =>
      _call((api) => api.removeTag(channel: channel, appId: appId, tag: tag));

  @override
  Future<List<String>> tags(String channel, String appId) =>
      _call((api) => api.tags(channel: channel, appId: appId));

  @override
  Future<Map<String, List<String>>> tagsIndex() =>
      _call((api) => api.tagsIndex()).then(
        (groups) => <String, List<String>>{
          for (final group in groups) group.key: group.tags,
        },
      );

  @override
  Future<void> notifyChanged() async {
    // Core path: re-read the authoritative projection. The Rust core emits and
    // owns `catalog.changed`; there is no Dart-side broadcast stream here.
    await _call((api) => api.list());
  }

  List<AddedAppInfo> _mapApps(List<rust.AddedAppEntry> entries) =>
      entries.map(addedAppFromRust).toList(growable: false);
}

/// Maps one FRB entry to the existing Dart `AddedAppInfo` model.
AddedAppInfo addedAppFromRust(rust.AddedAppEntry entry) => AddedAppInfo(
      id: entry.id.toInt(),
      channelId: entry.channelId,
      appId: entry.appId,
      addTime: entry.addTime.toInt(),
      sortOrder: entry.sortOrder.toInt(),
      isEnabled: entry.isEnabled,
    );

/// Core-only added-apps facade.
class AddedAppsFacade {
  AddedAppsFacade({AddedAppsBackend? frb}) : _frb = frb ?? FrbAddedAppsBackend();

  static AddedAppsFacade instance = AddedAppsFacade();

  /// Test seam: replaces the FRB backend.
  @visibleForTesting
  static AddedAppsBackend? backendOverride;

  final AddedAppsBackend _frb;

  /// Core-only routing: the legacy Dart store was deleted, so the facade always
  /// uses the FRB backend (or the injected test override).
  Future<AddedAppsBackend> _backend() async => backendOverride ?? _frb;

  Future<void> add(
    String channel,
    String appId, {
    int? sortOrder,
    AppSummary? appInfo,
  }) async =>
      (await _backend())
          .add(channel, appId, sortOrder: sortOrder, appInfo: appInfo);

  Future<bool> remove(String channel, String appId) async =>
      (await _backend()).remove(channel, appId);

  Future<void> rename(String channel, String oldAppId, String newAppId) async =>
      (await _backend()).rename(channel, oldAppId, newAppId);

  Future<void> setOrder(String channel, String appId, int sortOrder) async =>
      (await _backend()).setOrder(channel, appId, sortOrder);

  Future<bool> toggle(String channel, String appId) async =>
      (await _backend()).toggle(channel, appId);

  Future<void> clearChannel(String channel) async =>
      (await _backend()).clearChannel(channel);

  Future<void> clearAll() async => (await _backend()).clearAll();

  Future<List<AddedAppInfo>> list() async => (await _backend()).list();

  Future<List<AddedAppInfo>> listChannel(String channel) async =>
      (await _backend()).listChannel(channel);

  Future<AddedAppInfo?> get(String channel, String appId) async =>
      (await _backend()).get(channel, appId);

  Future<bool> isAdded(String channel, String appId) async =>
      (await _backend()).isAdded(channel, appId);

  Future<int> totalCount() async => (await _backend()).totalCount();

  Future<int> countChannel(String channel) async =>
      (await _backend()).countChannel(channel);

  /// Aggregated read: rows and tags come from the core backend; the metadata
  /// join is delegated to the (pure) [AppAggregatorManager.aggregateWithMeta],
  /// which reads no catalog DB and never calls back into this facade — so it
  /// cannot recurse.
  Future<(List<AggregatedAppInfo>, int)> getAggregatedAppsPage({
    required int offset,
    required int limit,
  }) async {
    final backend = await _backend();
    final rows = await backend.list();
    final tags = await backend.tagsIndex();
    final total = rows.length;
    if (offset >= total || limit <= 0) {
      return (<AggregatedAppInfo>[], total);
    }
    final end = (offset + limit > total) ? total : offset + limit;
    final apps = await AppAggregatorManager.instance.aggregateWithMeta(
      rows.sublist(offset, end),
      tagsIndex: tags,
    );
    return (apps, total);
  }

  /// Flag-routed full aggregated read (no slicing); see
  /// [getAggregatedAppsPage] for the recursion argument.
  Future<List<AggregatedAppInfo>> getAggregatedApps() async {    final backend = await _backend();
    final rows = await backend.list();
    final tags = await backend.tagsIndex();
    return AppAggregatorManager.instance
        .aggregateWithMeta(rows, tagsIndex: tags);
  }

  Future<void> setTags(String channel, String appId, List<String> tags) async =>
      (await _backend()).setTags(channel, appId, tags);

  Future<void> addTag(String channel, String appId, String tag) async =>
      (await _backend()).addTag(channel, appId, tag);

  Future<void> removeTag(String channel, String appId, String tag) async =>
      (await _backend()).removeTag(channel, appId, tag);

  Future<List<String>> tags(String channel, String appId) async =>
      (await _backend()).tags(channel, appId);

  Future<Map<String, List<String>>> tagsIndex() async =>
      (await _backend()).tagsIndex();

  /// Notifies listeners that added-app data changed.
  ///
  /// Refreshes the core-owned projection, then pokes the DB-free
  /// `AppAggregatorManager.appsChangedStream` so the home list reloads. Callers
  /// (post-install, backup restore) must not reach for the manager singleton
  /// directly. The poked payload is an empty signal; consumers must reload via
  /// this facade rather than trust it.
  Future<void> notifyAppsChanged() async {
    await (await _backend()).notifyChanged();
    AppAggregatorManager.instance.notifyAppsChanged();
  }
}

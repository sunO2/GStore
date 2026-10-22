/// Flag-gated facade over added apps and user tags.
///
/// `CoreFlags.catalog == false` routes to the legacy Dart
/// `AppAggregatorManager`; `true` routes to the FRB `AddedAppsApi`.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// Injectable added-apps transport seam.
abstract class AddedAppsBackend {
  Future<void> add(String channel, String appId, {int? sortOrder});

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
  Future<void> add(String channel, String appId, {int? sortOrder}) => _call(
      (api) => api.add(channel: channel, appId: appId, sortOrder: sortOrder));

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

/// Legacy backend over `AppAggregatorManager`.
class LegacyAddedAppsBackend implements AddedAppsBackend {
  LegacyAddedAppsBackend({
    AppAggregatorManager? manager,
    AppAddedDatabase? database,
  })  : _manager = manager ?? AppAggregatorManager.instance,
        _database = database;

  final AppAggregatorManager _manager;
  AppAddedDatabase? _database;
  Future<AppAddedDatabase>? _pendingDatabase;

  Future<AppAddedDatabase> _db() async {
    final database = _database;
    if (database != null) return database;
    return _pendingDatabase ??= AppAddedDatabase.create().then((created) {
      _database = created;
      return created;
    });
  }

  static AppSummary _placeholder(String appId) => AppSummary(
        appId: appId,
        name: appId,
        user: '',
        repositories: '',
        icon: '',
        des: '',
      );

  @override
  Future<void> add(String channel, String appId, {int? sortOrder}) =>
      _manager.addApp(
        channelCode: channel,
        appInfo: _placeholder(appId),
        sortOrder: sortOrder,
      );

  @override
  Future<bool> remove(String channel, String appId) async {
    final existed = await isAdded(channel, appId);
    await _manager.removeApp(channelCode: channel, appId: appId);
    return existed;
  }

  @override
  Future<void> rename(String channel, String oldAppId, String newAppId) =>
      _manager.renameApp(
        channelCode: channel,
        oldAppId: oldAppId,
        newAppId: newAppId,
      );

  @override
  Future<void> setOrder(String channel, String appId, int sortOrder) async {
    final database = await _db();
    final existing = await database.addedAppDao.getApp(channel, appId);
    final id = existing?.id;
    if (id == null) return;
    await database.addedAppDao.updateSortOrder(id, sortOrder);
  }

  @override
  Future<bool> toggle(String channel, String appId) =>
      _manager.toggleApp(channelCode: channel, appInfo: _placeholder(appId));

  @override
  Future<void> clearChannel(String channel) => _manager.clearChannel(channel);

  @override
  Future<void> clearAll() => _manager.clearAll();

  @override
  Future<List<AddedAppInfo>> list() => _manager.getAllAddedApps();

  @override
  Future<List<AddedAppInfo>> listChannel(String channel) =>
      _manager.getAppsByChannel(channel);

  @override
  Future<AddedAppInfo?> get(String channel, String appId) async {
    final apps = await _manager.getAllAddedApps();
    for (final app in apps) {
      if (app.channelId == channel && app.appId == appId) return app;
    }
    return null;
  }

  @override
  Future<bool> isAdded(String channel, String appId) =>
      _manager.isAppAdded(channelCode: channel, appId: appId);

  @override
  Future<int> totalCount() => _manager.getTotalCount();

  @override
  Future<int> countChannel(String channel) =>
      _manager.getCountByChannel(channel);

  @override
  Future<void> setTags(String channel, String appId, List<String> tags) =>
      _manager.setTags(channelCode: channel, appId: appId, tags: tags);

  @override
  Future<void> addTag(String channel, String appId, String tag) =>
      _manager.addTag(channelCode: channel, appId: appId, tag: tag);

  @override
  Future<void> removeTag(String channel, String appId, String tag) =>
      _manager.removeTag(channelCode: channel, appId: appId, tag: tag);

  @override
  Future<List<String>> tags(String channel, String appId) =>
      _manager.getTags(channelCode: channel, appId: appId);

  @override
  Future<Map<String, List<String>>> tagsIndex() => _manager.getAllTagsIndex();
}

/// Flag-gated added-apps facade.
class AddedAppsFacade {
  AddedAppsFacade({AddedAppsBackend? legacy, AddedAppsBackend? frb})
      : _legacy = legacy ?? LegacyAddedAppsBackend(),
        _frb = frb ?? FrbAddedAppsBackend();

  static AddedAppsFacade instance = AddedAppsFacade();

  /// Test seam: replaces the FRB backend.
  @visibleForTesting
  static AddedAppsBackend? backendOverride;

  /// Test seam: replaces the legacy backend.
  @visibleForTesting
  static AddedAppsBackend? legacyBackendOverride;

  final AddedAppsBackend _legacy;
  final AddedAppsBackend _frb;

  Future<bool> _enabled() async {
    try {
      await CoreFlags.refresh();
    } catch (_) {
      // Keep the last mirror; an unavailable flag backend must not arm a flag.
    }
    return CoreFlags.catalog;
  }

  Future<AddedAppsBackend> _backend() async => await _enabled()
      ? (backendOverride ?? _frb)
      : (legacyBackendOverride ?? _legacy);

  Future<void> add(String channel, String appId, {int? sortOrder}) async =>
      (await _backend()).add(channel, appId, sortOrder: sortOrder);

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
}

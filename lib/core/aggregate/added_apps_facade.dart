/// Core-only facade over added apps and user tags.
///
/// Every write and read routes to the shared `rust.LibraryApi` obtained from
/// [RustChannelFacade.library] — the same `ChannelApi` (one database handle,
/// one driver set) the channel domain uses. The Rust `LibraryService` owns the
/// "channel metadata first, membership second" write, and the Rust
/// `AggregationService` owns the unified home-page read model, so Dart never
/// performs a per-row `channel_apps` join.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/aggregate/AppAggregatorManager.dart';
import 'package:gstore/core/catalog/catalog_facade.dart' show appSummaryFromRust;
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/script/rust_script_lane.dart' show channelAppInfoFromSummary;

/// Injectable added-apps transport seam.
abstract class AddedAppsBackend {
  Future<void> add(String channel, String appId,
      {int? sortOrder, AppSummary? appInfo});

  /// Adds only the `added_apps` membership row; never writes `channel_apps`.
  Future<void> addMembership(String channel, String appId, {int? sortOrder});

  Future<bool> remove(String channel, String appId);

  Future<void> rename(String channel, String oldAppId, String newAppId);

  Future<void> setOrder(String channel, String appId, int sortOrder);

  Future<bool> toggle(String channel, String appId, {AppSummary? appInfo});

  Future<void> clearChannel(String channel);

  Future<void> clearAll();

  Future<List<AddedAppInfo>> list();

  Future<List<AddedAppInfo>> listChannel(String channel);

  Future<AddedAppInfo?> get(String channel, String appId);

  Future<bool> isAdded(String channel, String appId);

  Future<int> totalCount();

  Future<int> countChannel(String channel);

  /// Unified library read: one page of the Rust `LibraryApi.page` model plus
  /// the raw `added_apps` row total.
  Future<(List<AggregatedAppInfo>, int)> page({
    required int offset,
    required int limit,
  });

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

/// Production backend over the shared `rust.LibraryApi`.
///
/// Every method forwards to the library facade returned by
/// [ChannelApiBackend.library] (default: [RustChannelFacade.instance]), so the
/// added-apps writes/reads and the channel domain share ONE `ChannelApi` (one
/// database handle + one driver set).
class FrbAddedAppsBackend implements AddedAppsBackend {
  FrbAddedAppsBackend({
    ChannelApiBackend? channels,
    this.dataDir,
    this.filesDir,
    this.cacheDir,
  }) : _channelsOverride = channels;

  final ChannelApiBackend? _channelsOverride;

  /// Legacy directory hints used only by [rename] (see [_ensureRenameApi]).
  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;

  /// Legacy handle for [rename] only: `rust.LibraryApi` exposes no rename.
  rust.AddedAppsApi? _renameApi;
  Future<rust.AddedAppsApi>? _renamePending;

  /// Resolved lazily so a test-installed `RustChannelFacade` backend is seen
  /// even though `AddedAppsFacade` (and this backend) may be constructed first.
  ChannelApiBackend get _channels =>
      _channelsOverride ?? RustChannelFacade.instance.backend;

  Future<rust.LibraryApi> _library() => _channels.library();

  Future<T> _call<T>(Future<T> Function(rust.LibraryApi api) action) async {
    final api = await _library();
    try {
      return await action(api);
    } catch (error) {
      final typed = ChannelApiException.tryParse(error);
      if (typed != null) throw typed;
      rethrow;
    }
  }

  @override
  Future<void> add(String channel, String appId,
          {int? sortOrder, AppSummary? appInfo}) =>
      _call((api) async {
        await api.add(
          channel: channel,
          app: _channelAppInfo(appId, appInfo),
          sortOrder: sortOrder,
        );
      });

  @override
  Future<void> addMembership(String channel, String appId,
          {int? sortOrder}) =>
      _call((api) async {
        await api.addMembership(
          channel: channel,
          appId: appId,
          sortOrder: sortOrder,
        );
      });

  @override
  Future<bool> remove(String channel, String appId) =>
      _call((api) => api.remove(channel: channel, appId: appId));

  @override
  Future<void> rename(String channel, String oldAppId, String newAppId) async {
    final api = await _ensureRenameApi();
    await api.rename(
      channel: channel,
      oldAppId: oldAppId,
      newAppId: newAppId,
    );
  }

  @override
  Future<void> setOrder(String channel, String appId, int sortOrder) =>
      _call((api) => api.setOrder(
            channel: channel,
            appId: appId,
            sortOrder: sortOrder,
          ));

  @override
  Future<bool> toggle(String channel, String appId, {AppSummary? appInfo}) =>
      _call((api) => api.toggle(
            channel: channel,
            app: _channelAppInfo(appId, appInfo),
          ));

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
  Future<(List<AggregatedAppInfo>, int)> page({
    required int offset,
    required int limit,
  }) =>
      _call((api) async {
        final page = await api.page(offset: offset, limit: limit);
        final apps = page.entries
            .map(aggregatedAppFromLibraryEntry)
            .toList(growable: false);
        return (apps, page.total.toInt());
      });

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

  /// Lazily opens the legacy added-apps API, used ONLY by [rename] (the
  /// `LibraryApi` surface has no rename). Never touched by add/toggle/page.
  Future<rust.AddedAppsApi> _ensureRenameApi() {
    final existing = _renameApi;
    if (existing != null) return Future.value(existing);
    return _renamePending ??= _createRenameApi();
  }

  Future<rust.AddedAppsApi> _createRenameApi() async {
    try {
      await RustBridge.ensureInitialized();
      final dirs = await _resolveDirs();
      final api = await rust.AddedAppsApi.init(
        dataDir: dirs.$1,
        filesDir: dirs.$2,
        cacheDir: dirs.$3,
      );
      _renameApi = api;
      return api;
    } finally {
      _renamePending = null;
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
}

/// Builds the `rust.ChannelAppInfo` written by the Rust library service.
///
/// When the caller has no real metadata (legacy call sites), a placeholder
/// carrying the app id is used; callers that know the name/icon must pass it so
/// the Rust `channel_apps` row is complete.
rust.ChannelAppInfo _channelAppInfo(String appId, AppSummary? appInfo) {
  if (appInfo != null) return channelAppInfoFromSummary(appInfo);
  return rust.ChannelAppInfo(
    appId: appId,
    name: appId,
    user: '',
    repositories: '',
    icon: '',
    des: '',
    category: const <String>[],
    labels: const <rust.ChannelLabel>[],
  );
}

/// Maps one `LibraryEntry` from `LibraryApi.page` to the home-list model.
AggregatedAppInfo aggregatedAppFromLibraryEntry(rust.LibraryEntry entry) {
  final channel = ChannelType.fromCode(entry.channelKind) ??
      ChannelType.fromCode(entry.channelCode) ??
      ChannelType.custom;
  return AggregatedAppInfo(
    addedAppInfo: addedAppFromRust(entry.added),
    appInfo: appSummaryFromRust(entry.app),
    channel: channel,
    channelCode: entry.channelCode,
    isFromCache: entry.isFromCache,
    error: entry.error,
    metadataState: entry.metadataState,
  );
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

  /// Restores only membership: never writes `channel_apps` metadata.
  Future<void> addMembership(String channel, String appId,
          {int? sortOrder}) async =>
      (await _backend()).addMembership(channel, appId, sortOrder: sortOrder);

  Future<bool> remove(String channel, String appId) async =>
      (await _backend()).remove(channel, appId);

  Future<void> rename(String channel, String oldAppId, String newAppId) async =>
      (await _backend()).rename(channel, oldAppId, newAppId);

  Future<void> setOrder(String channel, String appId, int sortOrder) async =>
      (await _backend()).setOrder(channel, appId, sortOrder);

  Future<bool> toggle(String channel, String appId,
          {AppSummary? appInfo}) async =>
      (await _backend()).toggle(channel, appId, appInfo: appInfo);

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

  /// Unified home read: one page of the Rust `LibraryApi.page` model.
  ///
  /// The Rust `AggregationService` resolves each membership row
  /// (driver → `channel_apps` → placeholder), merges tags/categories and
  /// reports the provenance as `metadataState`. `total` stays the raw
  /// `added_apps` row count and `offset`/`limit` keep the raw-row semantics, so
  /// paging/scroll behaviour is unchanged.
  Future<(List<AggregatedAppInfo>, int)> getAggregatedAppsPage({
    required int offset,
    required int limit,
  }) async =>
      (await _backend()).page(offset: offset, limit: limit);

  /// Full unified read (no slicing).
  Future<List<AggregatedAppInfo>> getAggregatedApps() async {
    final (apps, _) =
        await (await _backend()).page(offset: 0, limit: 0x7fffffff);
    return apps;
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

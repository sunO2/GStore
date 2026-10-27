/// Shared test seams for the added-apps READ-via-facade tests
/// (`added_apps_reads_via_facade_test.dart`).
///
/// Not a test file (no `main`). It complements `discovery_facade_seams.dart`
/// (which supplies `FakeEnumChannel`, `sampleApp`, `setCatalogFlag`) with:
///
/// - [FakeAddedApps] is functional for the read/join surface
///   (`list` / `tagsIndex` / `tags` / `setTags` / `notifyChanged`) and records
///   the calls; every other member fails loudly.
/// - [ThrowingAddedApps] records and throws `StateError` on EVERY member, so a
///   test can assert a lane was never reached.
/// - [InMemoryAddedAppsBackend] is a full in-memory `AddedAppsBackend` (all CRUD
///   + tags), used by the backup-service tests now that the legacy Floor store
///   (`AppAddedDatabase`) is gone.
library;

import 'package:gstore/core/aggregate/added_app_types.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/model/AppSummary.dart';

/// Functional in-memory added-apps backend with call recording.
class FakeAddedApps implements AddedAppsBackend {
  FakeAddedApps(this.label);

  final String label;

  /// Added-app store (channelId → set of appIds); drives [list].
  final Map<String, Set<String>> added = {};

  /// Per-app tag store keyed by `channel:appId`; drives [tagsIndex]/[tags].
  final Map<String, List<String>> tagsByApp = {};

  int listCalls = 0;
  int tagsIndexCalls = 0;
  int notifyCalls = 0;
  final List<(String, String, List<String>)> setTagsCalls = [];
  final List<(String, String)> tagsCalls = [];

  /// Any backend member other than the read/write surface above.
  final List<Symbol> unexpectedCalls = [];

  @override
  Future<List<AddedAppInfo>> list() async {
    listCalls++;
    return [
      for (final entry in added.entries)
        for (final appId in entry.value)
          AddedAppInfo(channelId: entry.key, appId: appId),
    ];
  }

  @override
  Future<Map<String, List<String>>> tagsIndex() async {
    tagsIndexCalls++;
    final index = <String, List<String>>{};
    tagsByApp.forEach((key, tags) {
      index.putIfAbsent(key, () => <String>[]).addAll(tags);
    });
    return index;
  }

  @override
  Future<List<String>> tags(String channel, String appId) async {
    tagsCalls.add((channel, appId));
    return tagsByApp['$channel:$appId'] ?? const [];
  }

  @override
  Future<void> setTags(String channel, String appId, List<String> tags) async {
    setTagsCalls.add((channel, appId, List.of(tags)));
    tagsByApp['$channel:$appId'] = List.of(tags);
  }

  @override
  Future<void> notifyChanged() async => notifyCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls.add(invocation.memberName);
    throw UnimplementedError(
        'unexpected $label backend call: ${invocation.memberName}');
  }
}

/// Backend whose EVERY member records the call then throws [StateError].
///
/// Stands for "the lane that must never be reached".
class ThrowingAddedApps implements AddedAppsBackend {
  final List<Symbol> calls = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw StateError('lane must not be reached: ${invocation.memberName}');
  }
}

/// Full in-memory [AddedAppsBackend] for the backup-service tests.
///
/// The backup service reads/writes added apps through the core
/// `AddedAppsFacade`; injecting this via `AddedAppsFacade.backendOverride`
/// keeps the tests off the FRB/sqflite path after the legacy Floor store was
/// deleted.
class InMemoryAddedAppsBackend implements AddedAppsBackend {
  final Map<String, Map<String, AddedAppInfo>> _apps = {};
  final Map<String, Map<String, List<String>>> _tags = {};
  int _seq = 0;
  int notifyCalls = 0;

  /// Seeds one added-app row (test convenience).
  void seed(String channel, String appId, {int? sortOrder, int? addTime}) {
    _apps.putIfAbsent(channel, () => {})[appId] = AddedAppInfo(
      id: ++_seq,
      channelId: channel,
      appId: appId,
      addTime: addTime,
      sortOrder: sortOrder ?? 0,
    );
  }

  /// Seeds one tag (test convenience).
  void seedTag(String channel, String appId, String tag) {
    final tags =
        _tags.putIfAbsent(channel, () => {}).putIfAbsent(appId, () => []);
    if (!tags.contains(tag)) tags.add(tag);
  }

  /// All rows across channels (test convenience, unordered).
  List<AddedAppInfo> get all => [
        for (final byChannel in _apps.values) ...byChannel.values,
      ];

  /// All tags as `channel:appId` → tags (test convenience).
  Map<String, List<String>> get allTags => {
        for (final entry in _tags.entries)
          for (final app in entry.value.entries) '${entry.key}:${app.key}': List.of(app.value),
      };

  @override
  Future<void> add(String channel, String appId,
      {int? sortOrder, AppSummary? appInfo}) async {
    _apps.putIfAbsent(channel, () => {})[appId] = AddedAppInfo(
      id: ++_seq,
      channelId: channel,
      appId: appId,
      sortOrder: sortOrder ?? 0,
    );
  }

  @override
  Future<bool> remove(String channel, String appId) async {
    _tags[channel]?.remove(appId);
    return _apps[channel]?.remove(appId) != null;
  }

  @override
  Future<void> rename(String channel, String oldAppId, String newAppId) async {
    final byChannel = _apps[channel];
    final existing = byChannel?.remove(oldAppId);
    if (byChannel == null || existing == null) return;
    byChannel[newAppId] = AddedAppInfo(
      id: existing.id,
      channelId: channel,
      appId: newAppId,
      addTime: existing.addTime,
      sortOrder: existing.sortOrder,
      isEnabled: existing.isEnabled,
    );
    final movedTags = _tags[channel]?.remove(oldAppId);
    if (movedTags != null) {
      _tags.putIfAbsent(channel, () => {})[newAppId] = movedTags;
    }
  }

  @override
  Future<void> setOrder(String channel, String appId, int sortOrder) async {
    final existing = _apps[channel]?[appId];
    if (existing == null) return;
    _apps[channel]![appId] = AddedAppInfo(
      id: existing.id,
      channelId: channel,
      appId: appId,
      addTime: existing.addTime,
      sortOrder: sortOrder,
      isEnabled: existing.isEnabled,
    );
  }

  @override
  Future<bool> toggle(String channel, String appId) async {
    if (_apps[channel]?.containsKey(appId) ?? false) {
      await remove(channel, appId);
      return false;
    }
    await add(channel, appId);
    return true;
  }

  @override
  Future<void> clearChannel(String channel) async {
    _apps.remove(channel);
    _tags.remove(channel);
  }

  @override
  Future<void> clearAll() async {
    _apps.clear();
    _tags.clear();
  }

  @override
  Future<List<AddedAppInfo>> list() async => [
        for (final byChannel in _apps.values) ...byChannel.values,
      ];

  @override
  Future<List<AddedAppInfo>> listChannel(String channel) async =>
      _apps[channel]?.values.toList() ?? const [];

  @override
  Future<AddedAppInfo?> get(String channel, String appId) async =>
      _apps[channel]?[appId];

  @override
  Future<bool> isAdded(String channel, String appId) async =>
      _apps[channel]?.containsKey(appId) ?? false;

  @override
  Future<int> totalCount() async {
    var total = 0;
    for (final byChannel in _apps.values) {
      total += byChannel.length;
    }
    return total;
  }

  @override
  Future<int> countChannel(String channel) async =>
      _apps[channel]?.length ?? 0;

  @override
  Future<void> setTags(String channel, String appId, List<String> tags) async {
    _tags.putIfAbsent(channel, () => {})[appId] = List.of(tags);
  }

  @override
  Future<void> addTag(String channel, String appId, String tag) async {
    final tags =
        _tags.putIfAbsent(channel, () => {}).putIfAbsent(appId, () => []);
    if (!tags.contains(tag)) tags.add(tag);
  }

  @override
  Future<void> removeTag(String channel, String appId, String tag) async {
    _tags[channel]?[appId]?.remove(tag);
  }

  @override
  Future<List<String>> tags(String channel, String appId) async =>
      List.of(_tags[channel]?[appId] ?? const []);

  @override
  Future<Map<String, List<String>>> tagsIndex() async => {
        for (final entry in _tags.entries)
          for (final app in entry.value.entries)
            '${entry.key}:${app.key}': List.of(app.value),
      };

  @override
  Future<void> notifyChanged() async => notifyCalls++;
}

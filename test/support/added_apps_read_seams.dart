/// Shared test seams for the added-apps READ-via-facade tests
/// (`added_apps_reads_via_facade_test.dart`).
///
/// Not a test file (no `main`). It complements `discovery_facade_seams.dart`
/// (which supplies `FakeEnumChannel`, `sampleApp`, `setCatalogFlag`) with two
/// backends that let a test prove *which* lane a read/write took:
///
/// - [FakeAddedApps] is functional for the read/join surface
///   (`list` / `tagsIndex` / `tags` / `setTags` / `notifyChanged`) and records
///   the calls; every other member fails loudly.
/// - [ThrowingAddedApps] records and throws `StateError` on EVERY member, so a
///   test can assert the lane it stands for was never reached.
library;

import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/aggregate/aggregate.dart'
    show AddedAppInfo, AddedAppDao, AppAddedDatabase;

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
/// Stands for "the lane that must never be reached": flag on must not touch the
/// legacy backend, flag off must not touch the core backend.
class ThrowingAddedApps implements AddedAppsBackend {
  final List<Symbol> calls = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add(invocation.memberName);
    throw StateError('lane must not be reached: ${invocation.memberName}');
  }
}

/// Minimal [AppAddedDatabase] stand-in for the refresh-bridge test.
///
/// `AppAggregatorManager.notifyAppsChanged()` only needs
/// `addedAppDao.getAllAddedApps()` when it pokes its stream. Using a fake here
/// keeps the test off the sqflite FFI path — Floor hardcodes the isolate
/// factory on Linux, whose spawned isolate cannot see the in-process
/// `open.overrideFor('libsqlite3.so.0')` (which is why `added_app_tags_test`
/// fails in a bare environment).
class FakeManagerDatabase implements AppAddedDatabase {
  FakeManagerDatabase(this.apps);

  final List<AddedAppInfo> apps;

  @override
  AddedAppDao get addedAppDao => _FakeAddedAppDao(apps);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused database member: ${invocation.memberName}');
}

class _FakeAddedAppDao implements AddedAppDao {
  _FakeAddedAppDao(this.apps);

  final List<AddedAppInfo> apps;

  @override
  Future<List<AddedAppInfo>> getAllAddedApps() async => apps;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused dao method: ${invocation.memberName}');
}

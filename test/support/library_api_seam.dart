/// Shared fake of the FRB `rust.LibraryApi` used by the S3 write/read tests.
///
/// `FrbAddedAppsBackend` obtains its `LibraryApi` from the shared
/// [ChannelApiBackend.library] seam, so installing a [FakeChannelApiBackend]
/// through `RustChannelFacade.installBackend` lets the production facade run
/// without a native library while a test records the exact
/// `LibraryApi.add`/`toggle` payload (code + appId + name + icon).
library;

import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// In-memory `rust.LibraryApi` covering the membership/tag/page surface the
/// production facade uses. Unused members fail loudly.
class FakeLibraryApi implements rust.LibraryApi {
  final List<({String channel, rust.ChannelAppInfo app, int? sortOrder})>
      addCalls = [];
  final List<({String channel, String appId, int? sortOrder})>
      addMembershipCalls = [];
  final List<({String channel, rust.ChannelAppInfo app})> toggleCalls = [];
  final List<(String, String)> removeCalls = [];
  int pageCalls = 0;
  final List<(int offset, int limit)> pageRequests = [];

  final Map<String, rust.ChannelAppInfo> _apps = {};
  final List<rust.AddedAppEntry> _added = [];
  final Map<String, List<String>> _tags = {};
  int _seq = 0;

  /// Raw `channel_apps` rows seeded/written in this fake (channel:appId →
  /// metadata). `addMembership` must never add an entry here.
  Map<String, rust.ChannelAppInfo> get channelApps => Map.unmodifiable(_apps);

  /// When set, `page` returns exactly these entries (and [pageTotalOverride] or
  /// their length as the total) instead of projecting the in-memory rows.
  List<rust.LibraryEntry>? pageEntries;
  int? pageTotalOverride;

  /// Seeds one membership row without recording a write call.
  void seed({
    required String channel,
    required rust.ChannelAppInfo app,
    int? sortOrder,
  }) {
    _apps['$channel:${app.appId}'] = app;
    _added.add(_entry(channel, app.appId, sortOrder: sortOrder));
  }

  rust.AddedAppEntry _entry(String channel, String appId, {int? sortOrder}) {
    final seq = ++_seq;
    return rust.AddedAppEntry(
      id: seq,
      channelId: channel,
      appId: appId,
      addTime: seq,
      sortOrder: sortOrder ?? 0,
      isEnabled: true,
    );
  }

  rust.ChannelAppInfo _placeholder(String channel, String appId) {
    final app = _apps['$channel:$appId'];
    if (app != null) return app;
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

  @override
  Future<rust.AddedAppEntry> add({
    required String channel,
    required rust.ChannelAppInfo app,
    int? sortOrder,
  }) async {
    addCalls.add((channel: channel, app: app, sortOrder: sortOrder));
    _apps['$channel:${app.appId}'] = app;
    final entry = _entry(channel, app.appId, sortOrder: sortOrder);
    _added.removeWhere(
        (row) => row.channelId == channel && row.appId == app.appId);
    _added.add(entry);
    return entry;
  }

  @override
  Future<rust.AddedAppEntry> addMembership({
    required String channel,
    required String appId,
    int? sortOrder,
  }) async {
    addMembershipCalls.add(
        (channel: channel, appId: appId, sortOrder: sortOrder));
    final entry = _entry(channel, appId, sortOrder: sortOrder);
    _added.removeWhere(
        (row) => row.channelId == channel && row.appId == appId);
    _added.add(entry);
    return entry;
  }

  @override
  Future<bool> toggle({
    required String channel,
    required rust.ChannelAppInfo app,
  }) async {
    toggleCalls.add((channel: channel, app: app));
    final existing =
        _added.where((row) => row.channelId == channel && row.appId == app.appId);
    if (existing.isNotEmpty) {
      await remove(channel: channel, appId: app.appId);
      return false;
    }
    await add(channel: channel, app: app);
    return true;
  }

  @override
  Future<bool> remove({required String channel, required String appId}) async {
    removeCalls.add((channel, appId));
    final before = _added.length;
    _added.removeWhere(
        (row) => row.channelId == channel && row.appId == appId);
    _apps.remove('$channel:$appId');
    _tags.remove('$channel:$appId');
    return _added.length != before;
  }

  @override
  Future<List<rust.AddedAppEntry>> list() async =>
      _added.reversed.toList(growable: false);

  @override
  Future<List<rust.AddedAppEntry>> listChannel({required String channel}) async =>
      _added.reversed.where((row) => row.channelId == channel).toList();

  @override
  Future<rust.AddedAppEntry?> get_({
    required String channel,
    required String appId,
  }) async {
    for (final row in _added) {
      if (row.channelId == channel && row.appId == appId) return row;
    }
    return null;
  }

  @override
  Future<bool> isAdded({required String channel, required String appId}) async =>
      _added.any((row) => row.channelId == channel && row.appId == appId);

  @override
  Future<int> totalCount() async => _added.length;

  @override
  Future<int> countChannel({required String channel}) async =>
      _added.where((row) => row.channelId == channel).length;

  @override
  Future<void> setOrder({
    required String channel,
    required String appId,
    required int sortOrder,
  }) async {
    final index =
        _added.indexWhere((row) => row.channelId == channel && row.appId == appId);
    if (index < 0) return;
    final row = _added[index];
    _added[index] = rust.AddedAppEntry(
      id: row.id,
      channelId: row.channelId,
      appId: row.appId,
      addTime: row.addTime,
      sortOrder: sortOrder,
      isEnabled: row.isEnabled,
    );
  }

  @override
  Future<int> clearChannel({required String channel}) async {
    final before = _added.length;
    _added.removeWhere((row) => row.channelId == channel);
    _apps.removeWhere((key, _) => key.startsWith('$channel:'));
    return before - _added.length;
  }

  @override
  Future<int> clearAll() async {
    final count = _added.length;
    _added.clear();
    _apps.clear();
    _tags.clear();
    return count;
  }

  @override
  Future<void> setTags({
    required String channel,
    required String appId,
    required List<String> tags,
  }) async {
    _tags['$channel:$appId'] = List.of(tags);
  }

  @override
  Future<void> addTag({
    required String channel,
    required String appId,
    required String tag,
  }) async {
    final tags = _tags.putIfAbsent('$channel:$appId', () => <String>[]);
    if (!tags.contains(tag)) tags.add(tag);
  }

  @override
  Future<void> removeTag({
    required String channel,
    required String appId,
    required String tag,
  }) async {
    _tags['$channel:$appId']?.remove(tag);
  }

  @override
  Future<List<String>> tags({
    required String channel,
    required String appId,
  }) async =>
      List.of(_tags['$channel:$appId'] ?? const <String>[]);

  @override
  Future<List<rust.TagGroup>> tagsIndex() async => [
        for (final entry in _tags.entries)
          rust.TagGroup(key: entry.key, tags: List.of(entry.value)),
      ];

  @override
  Future<rust.LibraryPage> page({
    required int offset,
    required int limit,
  }) async {
    pageCalls++;
    pageRequests.add((offset, limit));
    final explicit = pageEntries;
    if (explicit != null) {
      final total = pageTotalOverride ?? explicit.length;
      if (offset >= total || limit <= 0) {
        return rust.LibraryPage(entries: const [], total: total);
      }
      final end = (offset + limit > total) ? total : offset + limit;
      return rust.LibraryPage(
        entries: explicit.sublist(offset, end),
        total: total,
      );
    }
    final rows = await list();
    final total = rows.length;
    if (offset >= total || limit <= 0) {
      return rust.LibraryPage(entries: const [], total: total);
    }
    final end = (offset + limit > total) ? total : offset + limit;
    return rust.LibraryPage(
      entries: [
        for (final row in rows.sublist(offset, end))
          rust.LibraryEntry(
            added: row,
            app: _placeholder(row.channelId, row.appId),
            channelCode: row.channelId,
            channelKind: row.channelId,
            isFromCache: false,
            metadataState: 'resolved',
          ),
      ],
      total: total,
    );
  }

  @override
  Future<rust.RepairReport> repairMissingMetadata() async =>
      const rust.RepairReport(repaired: 0, unresolved: 0);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unused LibraryApi member: ${invocation.memberName}');
}

/// `ChannelApiBackend` that serves a [FakeLibraryApi] and records the legacy
/// `ChannelApi.addApp` (channels-domain) calls, so a test can prove they no
/// longer happen on the add-to-home path.
class FakeChannelApiBackend implements ChannelApiBackend {
  FakeChannelApiBackend(this.fakeLibrary);

  final FakeLibraryApi fakeLibrary;
  final List<({String key, rust.ChannelAppInfo app})> addAppCalls = [];
  final List<(String, String)> getAppInfoCalls = [];
  final List<(String, String)> removeAppCalls = [];

  /// Keys whose `removeApp` must fail (e.g. `LocalDbDriver.remove_app` returns
  /// `unsupported`); the caller is expected to tolerate it.
  final Set<String> failingRemoveKeys = {};

  List<rust.ChannelAppInfo> listAppsResult = const [];

  /// Serves [listAppsResult] and answers `addApp`/`removeApp` when the caller
  /// asks for the channel metadata (`ChannelManager.addAppByCode`).
  @override
  Future<void> removeApp({
    required String key,
    required String appId,
  }) async {
    removeAppCalls.add((key, appId));
    if (failingRemoveKeys.contains(key)) {
      throw StateError('remove_app unsupported for $key');
    }
    listAppsResult =
        listAppsResult.where((app) => app.appId != appId).toList();
  }

  @override
  Future<rust.LibraryApi> library() async => fakeLibrary;

  @override
  Future<rust.ChannelAppInfo> getAppInfo({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) async {
    getAppInfoCalls.add((key, appId));
    throw StateError('getAppInfoByCode must not run on the library page path');
  }

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {
    addAppCalls.add((key: key, app: app));
  }

  @override
  Future<List<rust.ChannelAppInfo>> listApps({
    required String key,
    required bool forceRefresh,
  }) async =>
      listAppsResult;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused ChannelApiBackend member: ${invocation.memberName}');
}

/// HOME lane apps (todo 269): a JS-channel (`js_<stem>`) pack added to the
/// library must appear on the HOME page.
///
/// USER REPORT: "js渠道入库成功，但是首页不显示".
///
/// Root cause: `AppAggregatorManager._aggregateSlice` resolves the channel with
/// `ChannelManager.getChannelByCode(channelCode)` and DROPS the row (`return
/// null`) when it is null. A Rust-lane pack (`js_<stem>`) is deliberately never
/// registered as a Dart channel, so `getChannelByCode('js_<stem>')` is null and
/// the freshly added JS app vanishes from the aggregated HOME list. The
/// discovery page already special-cases lane codes (`_isRustLaneCode`); the
/// aggregation did not.
///
/// These cases pin the fix:
///  (a) a `js_<stem>` row is INCLUDED with the lane's real metadata (name/icon
///      from the lane, not the appId placeholder), categories merged;
///  (b) a non-lane unknown code is still dropped (guard preserved);
///  (c) with `CoreFlags.jsChannel` OFF a `js_*` code is still dropped even when
///      the lane cache holds the pack (the branch is flag-gated);
///  (d) the flag-off legacy path is unchanged (enum channel resolves, unknown
///      drops).
///
/// The cases drive the pure `aggregateWithMeta(rows, tagsIndex:)` seam, so no
/// sqflite/catalog DB is touched (the DB-backed aggregate tests cannot run in
/// this environment — see the evidence file).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/aggregate.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';

import 'support/discovery_facade_seams.dart';

/// In-memory `ScriptApiBackend` (the FRB seam) — enough for the lane to list a
/// pack and return its saved `channel_apps` rows.
class _LaneScriptBackend implements ScriptApiBackend {
  final Map<String, rust_pack.ScriptPackInfo> packs = {};

  /// `key` → the saved rows `storedApps` returns (snake_case AppSummary shape).
  final Map<String, List<Map<String, Object?>>> stored = {};

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {}

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async =>
      packs[expectedKey ?? 'js_unknown']!;

  @override
  Future<void> remove({required String key}) async => packs.remove(key);

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async =>
      packs[key]!;

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async {}

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async {}

  @override
  Future<String> run({
    required String key,
    required String method,
    required String paramsJson,
  }) async =>
      'null';

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async {
    final values = packs.values.toList()..sort((a, b) => a.key.compareTo(b.key));
    return values;
  }

  @override
  Future<String> storedApps({required String key}) async =>
      jsonEncode(stored[key] ?? const <Object?>[]);

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {}

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async {}
}

rust_pack.ScriptPackInfo _pack(String key) => rust_pack.ScriptPackInfo(
      key: key,
      name: 'Probe Pack',
      description: '',
      icon: '',
      hasDetail: false,
    );

/// One saved lane row in the snake_case shape `ScriptApi.storedApps` emits.
Map<String, Object?> _laneRow(
  String appId,
  String name, {
  String icon = '',
  List<String>? category,
}) =>
    {
      'app_id': appId,
      'name': name,
      'icon': icon,
      'des': 'lane description',
      'user': '',
      'repositories': '',
      if (category != null) 'category': category,
    };

Future<void> _setFlag({required bool jsChannel}) async {
  CoreFlags.installBackend(
    FakeFlagsBackend(CoreFlagsSnapshot(jsChannel: jsChannel)),
  );
  await CoreFlags.refresh();
  expect(CoreFlags.jsChannel, jsChannel);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _LaneScriptBackend backend;

  setUp(() async {
    await ChannelManager.instance.disposeAll();
    backend = _LaneScriptBackend();
    ScriptApi.installBackend(backend);
    ScriptChannelService.installForTest(ScriptChannelService(
      coreDirs: () async => (
        '/tmp/gstore_lane_home/data',
        '/tmp/gstore_lane_home/files',
        '/tmp/gstore_lane_home/cache',
      ),
      ensureRust: () async {},
    ));
    // The pure join resolves channel details through the manager's channel
    // manager; the lane branch must not need a registered Dart channel.
    AppAggregatorManager.instance.debugChannelManager = ChannelManager.instance;
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    ScriptApi.resetBackend();
    ScriptChannelService.resetForTest();
    RustScriptChannelLane.resetForTest();
    await ChannelManager.instance.disposeAll();
  });

  group('lane (js_<stem>) apps reach the aggregated HOME list', () {
    test(
        '(a) a js_<stem> row is INCLUDED with the lane metadata (name/icon from '
        'the lane, categories merged), not the appId placeholder', () async {
      await _setFlag(jsChannel: true);
      backend.packs['js_probe'] = _pack('js_probe');
      backend.stored['js_probe'] = [
        _laneRow('com.lane.app', 'Lane App',
            icon: 'https://cdn.example/icon.png', category: const ['工具']),
      ];
      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);
      await lane.refresh();

      // The premise of the bug: no Dart channel instance for the lane code.
      expect(ChannelManager.instance.getChannelByCode('js_probe'), isNull,
          reason: 'a js_* pack is never registered as a Dart channel');

      final apps = await AppAggregatorManager.instance.aggregateWithMeta(
        [AddedAppInfo(channelId: 'js_probe', appId: 'com.lane.app', addTime: 1)],
        tagsIndex: const {
          'js_probe:com.lane.app': ['游戏'],
        },
      );

      expect(apps, hasLength(1),
          reason: 'the lane row must not be dropped from the HOME list');
      final app = apps.single;
      expect(app.channelCode, 'js_probe');
      expect(app.channel, ChannelType.custom);
      expect(app.isFromCache, isFalse,
          reason: 'real lane data, not a cache fallback');
      expect(app.appInfo.name, 'Lane App',
          reason: 'name must come from the lane, not the appId placeholder');
      expect(app.appInfo.icon, 'https://cdn.example/icon.png');
      expect(app.appInfo.category, containsAll(<String>['工具', '游戏']),
          reason: 'lane category + user tags must merge like other branches');
    });

    test('(b) a non-lane unknown code is still dropped (guard preserved)',
        () async {
      await _setFlag(jsChannel: true);
      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);
      await lane.refresh(); // no packs installed

      final apps = await AppAggregatorManager.instance.aggregateWithMeta(
        [AddedAppInfo(channelId: 'totally_unknown', appId: 'x', addTime: 1)],
        tagsIndex: const {},
      );

      expect(apps, isEmpty,
          reason: 'only lane codes get the new branch; truly-unknown stays dropped');
    });

    test(
        '(c) flag-gated: with CoreFlags.jsChannel OFF a js_* code is still '
        'dropped even though the lane cache holds the pack', () async {
      await _setFlag(jsChannel: true);
      backend.packs['js_probe'] = _pack('js_probe');
      backend.stored['js_probe'] = [_laneRow('com.lane.app', 'Lane App')];
      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);
      await lane.refresh();
      expect(lane.packFor('js_probe'), isNotNull,
          reason: 'pack is cached while the flag is on');

      // Flip the flag off: `enabled` becomes false, the cache keeps the pack.
      await _setFlag(jsChannel: false);
      expect(lane.enabled, isFalse);
      expect(lane.packFor('js_probe'), isNotNull,
          reason: 'cache is untouched by the flag flip — the gate is `enabled`');

      final apps = await AppAggregatorManager.instance.aggregateWithMeta(
        [AddedAppInfo(channelId: 'js_probe', appId: 'com.lane.app', addTime: 1)],
        tagsIndex: const {},
      );

      expect(apps, isEmpty,
          reason: 'the lane branch is gated by CoreFlags.jsChannel');
    });

    test(
        '(d) flag OFF: the legacy path is unchanged — a registered enum channel '
        'resolves and an unknown code drops', () async {
      await _setFlag(jsChannel: false);
      ChannelManager.instance
          .registerChannel(FakeEnumChannel(ChannelType.fdroid, const [sampleApp]));

      final apps = await AppAggregatorManager.instance.aggregateWithMeta(
        [
          AddedAppInfo(channelId: 'fdroid', appId: 'com.added', addTime: 1),
          AddedAppInfo(channelId: 'ghost', appId: 'nope', addTime: 2),
        ],
        tagsIndex: const {},
      );

      expect(apps, hasLength(1),
          reason: 'the enum channel resolves; the unknown one is still dropped');
      expect(apps.single.channelCode, 'fdroid');
      expect(apps.single.channel, ChannelType.fdroid);
    });
  });
}

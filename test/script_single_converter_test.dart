/// Todo 5 — single JS converter on the Rust lane.
///
/// The JS channel's data has exactly ONE converter per shape on the Rust lane:
///
/// * **app summary** → `appSummaryFromRust` (FRB `ChannelAppInfo` → `AppSummary`),
///   used by `RustScriptChannelLane.searchApps`. The retired Map-based
///   `appSummaryFromScript` (`lib/core/channel/impl/js_script_utils.dart`) is
///   gone.
/// * **detail** → the typed DTO projection `detailToMap`
///   (`rust_script_detail_mapping.dart`, FRB `ChannelAppDetailInfo` → the page's
///   `Map`), wrapped by the page's `JsChannelDetailProxy` rendering adapter.
///
/// The behavioural assertions prove the lane actually reached the FRB converter
/// — an **identity** check (verbatim fields + `extraJson` decode that a Map-based
/// converter with a channel-key fallback could not satisfy) — not merely that the
/// file compiles (`misleading_success_output` guard). Every process-wide backend
/// the test replaces is restored in `tearDown` (`stale_state` guard).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/catalog/catalog_facade.dart' show appSummaryFromRust;
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/proxy/JsChannelDetailProxy.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/script/rust_script_detail_channel.dart';
import 'package:gstore/core/script/rust_script_detail_mapping.dart';
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/page/detail/state.dart';

/// Records the calls the lane/detail channel make and returns the seeded typed
/// values — so a passing assertion proves the real converter path ran, not that
/// a fake invented a result.
class _FakeChannelApiBackend implements ChannelApiBackend {
  final List<String> searchCalls = [];
  final List<String> getDetailCalls = [];
  final List<String> menuCalls = [];

  final Map<String, List<rust.ChannelAppInfo>> searchResults = {};
  final Map<String, List<rust.ChannelAppInfo>> listAppsResults = {};
  rust.ChannelAppDetailInfo? detailResult;

  @override
  Future<List<rust.ChannelAppInfo>> search({
    required String key,
    required String keyword,
    required bool forceRefresh,
  }) async {
    searchCalls.add('$key:$keyword');
    return searchResults[key] ?? const [];
  }

  @override
  Future<List<rust.ChannelAppInfo>> listApps({
    required String key,
    required bool forceRefresh,
  }) async =>
      listAppsResults[key] ?? const [];

  @override
  Future<rust.ChannelAppDetailInfo> getAppDetail({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) async {
    getDetailCalls.add('$key:$appId');
    return detailResult!;
  }

  @override
  Future<List<rust.ChannelDetailAction>> scriptDetailMenu({
    required String key,
    required String appId,
  }) async {
    menuCalls.add('$key:$appId');
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unexpected facade call: ${invocation.memberName}');
}

/// Capturing callbacks mirroring `DetailLogic.refreshDetail`
/// (`state.detailInfo = JsChannelDetailProxy(detailData)`).
class _CapturingCallbacks implements DetailCallbacks {
  final List<Map<String, dynamic>> refreshCalls = [];
  DetailState? state;

  @override
  Future<void> refreshDetail({required Map<String, dynamic> detailData}) async {
    refreshCalls.add(Map<String, dynamic>.from(detailData));
    state?.detailInfo = JsChannelDetailProxy(detailData);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused DetailCallbacks member: ${invocation.memberName}');
}

class _OnFlagsBackend implements CoreFlagsBackend {
  @override
  Future<CoreFlagsSnapshot> read() async =>
      const CoreFlagsSnapshot(jsChannel: true);

  @override
  Future<void> write(CoreFlagsPatch patch) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // stale_state: restore every process-wide backend the test replaced.
    CoreFlags.resetBackend();
    RustChannelFacade.resetBackend();
    RustScriptChannelLane.resetForTest();
  });

  // ---------------------------------------------------------------------------
  // Structural — the duplicate converter is retired from the lane source
  // ---------------------------------------------------------------------------

  group('the duplicate JS app-summary converter is retired', () {
    test('js_script_utils.dart (appSummaryFromScript) no longer exists', () {
      expect(
        File('lib/core/channel/impl/js_script_utils.dart').existsSync(),
        isFalse,
        reason: 'the Map-based appSummaryFromScript converter must be gone; '
            'the Rust lane maps through appSummaryFromRust',
      );
    });

    test('the Rust lane maps via appSummaryFromRust, never a Map converter', () {
      final source =
          File('lib/core/script/rust_script_lane.dart').readAsStringSync();
      expect(source, contains('appSummaryFromRust'),
          reason:
              'the lane must map typed ChannelAppInfo via appSummaryFromRust');
      expect(source, isNot(contains('appSummaryFromScript')),
          reason: 'no Map-based app-summary converter may sit on the Rust lane');
    });

    test('the Rust detail channel projects typed DTOs, never a Map converter',
        () {
      final source = File('lib/core/script/rust_script_detail_channel.dart')
          .readAsStringSync();
      expect(source, contains('detailToMap'),
          reason: 'the detail channel must use the single typed DTO projection');
      expect(source, isNot(contains('appSummaryFromScript')));
    });
  });

  // ---------------------------------------------------------------------------
  // Behavioural — the lane really calls appSummaryFromRust (identity)
  // ---------------------------------------------------------------------------

  group('the Rust lane maps search through appSummaryFromRust (identity)', () {
    test(
        'searchApps output equals appSummaryFromRust(info); verbatim user/'
        'repositories + extraJson decode prove the FRB converter ran', () async {
      CoreFlags.installBackend(_OnFlagsBackend());
      await CoreFlags.refresh();
      expect(CoreFlags.jsChannel, isTrue);

      final info = rust.ChannelAppInfo(
        appId: 'com.probe',
        packageName: 'com.probe.pkg',
        name: 'Probe App',
        // Verbatim empty: appSummaryFromRust passes these through; the retired
        // appSummaryFromScript filled the channel key.
        user: '',
        repositories: '',
        icon: '',
        des: 'a probe app',
        category: const <String>[],
        // Only the FRB converter decodes extraJson; a Map converter never sees it.
        extraJson: '{"k":"v"}',
        labels: const <rust.ChannelLabel>[],
      );
      final facade = _FakeChannelApiBackend()
        ..searchResults['js_probe'] = [info];
      RustChannelFacade.installBackend(facade);
      final lane = RustScriptChannelLane();
      RustScriptChannelLane.installForTest(lane);

      final apps = await lane.searchApps('js_probe', 'probe');
      expect(facade.searchCalls, ['js_probe:probe']);
      final mapped = apps.single;

      // Identity: field-for-field equal to the single FRB converter's output.
      final expected = appSummaryFromRust(info);
      expect(mapped.appId, expected.appId);
      expect(mapped.packageName, expected.packageName);
      expect(mapped.name, expected.name);
      expect(mapped.user, expected.user);
      expect(mapped.repositories, expected.repositories);
      expect(mapped.icon, expected.icon);
      expect(mapped.des, expected.des);
      expect(mapped.readme, expected.readme);
      expect(mapped.category, expected.category);
      expect(mapped.extra, expected.extra);

      // Distinguishing: verbatim (NOT the channel-key fallback a Map converter
      // used) + the extraJson decode only the FRB converter performs.
      expect(mapped.user, '',
          reason: 'appSummaryFromRust passes user verbatim; a Map converter '
              'would fill the channel key "js_probe"');
      expect(mapped.repositories, '');
      expect(mapped.extra, {'k': 'v'});
    });
  });

  // ---------------------------------------------------------------------------
  // Behavioural — the detail path feeds the page the single DTO projection
  // ---------------------------------------------------------------------------

  group('the Rust lane detail maps through the single DTO projection', () {
    test('load() feeds the page a JsChannelDetailProxy built from detailToMap',
        () async {
      const request = AppDetailRequest(
        appId: 'com.example.one',
        name: 'Req App',
        channel: ChannelType.custom,
        channelCode: 'js_probe',
        packageName: 'com.example.one',
      );
      final typed = rust.ChannelAppDetailInfo(
        appId: 'com.example.one',
        name: 'Full App',
        icon: 'icon://detail',
        description: '详情描述',
        version: 'A',
        packageName: 'com.example.one',
        channel: 'js_local',
        sections: const ['downloads'],
        downloads: const [],
        extraJson: jsonEncode({
          'appId': 'com.example.one',
          'name': 'Full App',
          'downloads': [
            {'url': 'https://x/1.apk', 'name': '1.apk', 'size': 12},
          ],
          'extra': {'env': 'sit'},
        }),
        labels: const <rust.ChannelLabel>[],
      );
      final facade = _FakeChannelApiBackend()..detailResult = typed;
      RustChannelFacade.installBackend(facade);

      final channel = RustScriptDetailChannel(
        appId: request.appId,
        channelKey: 'js_probe',
        request: request,
      );
      final callbacks = _CapturingCallbacks();
      final state = DetailState()..request = request;
      callbacks.state = state;
      channel.bind(state, callbacks);

      await channel.load();

      // Exactly ONE data read on the detail path.
      expect(facade.getDetailCalls, ['js_probe:com.example.one']);
      // The page received the DTO projection verbatim.
      expect(callbacks.refreshCalls.last, detailToMap(typed));
      // …and wrapped it in the single JS rendering adapter.
      expect(state.detailInfo, isA<JsChannelDetailProxy>());
      final detail = state.detailInfo!;
      expect(detail.appId, 'com.example.one');
      expect(detail.name, 'Full App');
      expect(detail.version, 'A');
      expect(detail.downloads.single.url, 'https://x/1.apk');
      expect(detail.downloads.single.name, '1.apk');
      expect(detail.downloads.single.size, 12);
      expect(state.errorMessage, isEmpty);
    });
  });
}

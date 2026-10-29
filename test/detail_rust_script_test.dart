/// Todo 8 — the JS detail channel reads through the unified `ChannelApi`.
///
/// [RustScriptDetailChannel] must obtain `getAppDetail` and the four
/// detail-page methods **only** via [RustChannelFacade] (the typed FRB
/// `ChannelApi` surface) and adapt the typed results to the
/// `Map<String, dynamic>` shapes the page's `JsChannelDetailProxy` consumes.
///
/// The fake [ChannelApiBackend] records every call, so the assertions prove the
/// channel actually reached the facade backend (not merely that the file
/// compiles), and the backend is restored in `tearDown` (stale-state guard).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/proxy/JsChannelDetailProxy.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/script/rust_script_detail_channel.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/page/detail/state.dart';

/// Records every facade call and returns the seeded typed values — so a passing
/// assertion proves the channel reached the backend, not a fake's invention.
class _FakeChannelApiBackend implements ChannelApiBackend {
  final List<Map<String, Object?>> calls = [];
  final List<Map<String, Object?>> actionCalls = [];

  rust.ChannelAppDetailInfo? detailResult;
  Object? detailError;
  rust.ScriptVersionOptions? versionOptionsResult;
  rust.ChannelAppDetailInfo? switchVersionResult;
  List<rust.ScriptBuild> buildHistoryResult = const [];
  List<rust.ChannelDetailAction> detailMenuResult = const [];

  @override
  Future<rust.ChannelAppDetailInfo> getAppDetail({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) async {
    calls.add({
      'method': 'getAppDetail',
      'key': key,
      'appId': appId,
      'forceRefresh': forceRefresh,
    });
    final error = detailError;
    if (error != null) throw error;
    return detailResult!;
  }

  @override
  Future<rust.ScriptVersionOptions?> scriptVersionOptions({
    required String key,
    required String appId,
    String? env,
    String? currentVersion,
  }) async {
    calls.add({
      'method': 'scriptVersionOptions',
      'key': key,
      'appId': appId,
      'env': env,
      'currentVersion': currentVersion,
    });
    return versionOptionsResult;
  }

  @override
  Future<rust.ChannelAppDetailInfo?> scriptSwitchVersion({
    required String key,
    required String appId,
    required String env,
    required String version,
    String? buildJson,
  }) async {
    calls.add({
      'method': 'scriptSwitchVersion',
      'key': key,
      'appId': appId,
      'env': env,
      'version': version,
      'buildJson': buildJson,
    });
    return switchVersionResult;
  }

  @override
  Future<List<rust.ScriptBuild>> scriptBuildHistory({
    required String key,
    required String appId,
    required String env,
    required String version,
  }) async {
    calls.add({
      'method': 'scriptBuildHistory',
      'key': key,
      'appId': appId,
      'env': env,
      'version': version,
    });
    return buildHistoryResult;
  }

  @override
  Future<List<rust.ChannelDetailAction>> scriptDetailMenu({
    required String key,
    required String appId,
  }) async {
    calls.add({'method': 'scriptDetailMenu', 'key': key, 'appId': appId});
    return detailMenuResult;
  }

  @override
  Future<void> scriptDetailAction({
    required String key,
    required String appId,
    required String jscall,
  }) async {
    actionCalls.add({'key': key, 'appId': appId, 'jscall': jscall});
    calls.add({'method': 'scriptDetailAction', 'key': key, 'appId': appId});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unexpected facade call: ${invocation.memberName}');
}

/// Records the retained `ScriptApi` call (`releaseDetail`) so `dispose` can be
/// asserted without FFI.
class _FakeScriptBackend implements ScriptApiBackend {
  final List<Map<String, Object?>> calls = [];

  @override
  Future<void> releaseDetail({required String key, required String appId}) async {
    calls.add({'method': 'releaseDetail', 'key': key, 'appId': appId});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused ScriptApi method: ${invocation.memberName}');
}

class _OnFlagsBackend implements CoreFlagsBackend {
  @override
  Future<CoreFlagsSnapshot> read() async =>
      const CoreFlagsSnapshot(jsChannel: true);

  @override
  Future<void> write(CoreFlagsPatch patch) async {}
}

/// Capturing callbacks mirroring `DetailLogic.refreshDetail`
/// (`state.detailInfo = JsChannelDetailProxy(detailData)`).
class _CapturingCallbacks implements DetailCallbacks {
  final List<Map<String, dynamic>> refreshCalls = [];
  final List<String> errors = [];
  final List<Map<String, dynamic>> versionPickerCalls = [];
  final List<Map<String, dynamic>> buildHistoryCalls = [];
  DetailState? state;

  @override
  Future<void> refreshDetail({required Map<String, dynamic> detailData}) async {
    refreshCalls.add(Map<String, dynamic>.from(detailData));
    state?.detailInfo = JsChannelDetailProxy(detailData);
  }

  @override
  void showError(String message, {String? title}) => errors.add(message);

  @override
  Future<void> showVersionPicker({
    required Map<String, dynamic> options,
    required String appId,
  }) async {
    versionPickerCalls.add(Map<String, dynamic>.from(options));
  }

  @override
  Future<void> showBuildHistory({
    required List<Map<String, dynamic>> builds,
    required String appId,
    required String version,
    required String env,
  }) async {
    buildHistoryCalls.add({
      'builds': builds,
      'appId': appId,
      'version': version,
      'env': env,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unused DetailCallbacks member: ${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const request = AppDetailRequest(
    appId: 'com.example.one',
    name: 'Req App',
    channel: ChannelType.custom,
    channelCode: 'js_probe',
    packageName: 'com.example.one',
    icon: 'icon://req',
    description: '请求描述',
  );

  late _FakeChannelApiBackend facade;
  late _FakeScriptBackend script;

  setUp(() async {
    CoreFlags.installBackend(_OnFlagsBackend());
    await CoreFlags.refresh();
    facade = _FakeChannelApiBackend();
    script = _FakeScriptBackend();
    RustChannelFacade.installBackend(facade);
    ScriptApi.installBackend(script);
  });

  tearDown(() {
    // stale_state: restore every process-wide backend the test replaced.
    RustChannelFacade.resetBackend();
    ScriptApi.resetBackend();
    CoreFlags.resetBackend();
  });

  (RustScriptDetailChannel, DetailState, _CapturingCallbacks) build() {
    final channel = RustScriptDetailChannel(
      appId: request.appId,
      channelKey: 'js_probe',
      request: request,
    );
    final callbacks = _CapturingCallbacks();
    final state = DetailState()..request = request;
    callbacks.state = state;
    channel.bind(state, callbacks);
    return (channel, state, callbacks);
  }

  rust.ChannelAppDetailInfo typedDetail({
    String name = 'Full App',
    String? version,
    String extraJson = '{}',
    List<rust.ChannelAppDownloadInfo> downloads = const [],
  }) =>
      rust.ChannelAppDetailInfo(
        appId: 'com.example.one',
        name: name,
        icon: 'icon://detail',
        description: '详情描述',
        version: version,
        packageName: 'com.example.one',
        channel: 'js_local',
        sections: const ['downloads'],
        downloads: downloads,
        extraJson: extraJson,
        labels: const <rust.ChannelLabel>[],
      );

  group('load — reads getAppDetail through the facade', () {
    test('typed detail is mapped to the page shape; detailMenu refreshed',
        () async {
      facade
        ..detailResult = typedDetail(
          name: 'Full App',
          version: 'A',
          extraJson: jsonEncode({
            'appId': 'com.example.one',
            'name': 'Full App',
            'version': 'A',
            'extra': {'env': 'sit'},
            'downloads': <Object?>[],
          }),
        )
        ..detailMenuResult = const [
          rust.ChannelDetailAction(action: '切换版本', jscall: 'jsswitchVersion'),
        ];
      final (channel, state, callbacks) = build();

      await channel.load();

      expect(
        facade.calls.map((c) => c['method']).toList(),
        ['getAppDetail', 'scriptDetailMenu'],
      );
      expect(facade.calls.first['key'], 'js_probe');
      expect(facade.calls.first['appId'], 'com.example.one');

      // Prefill then the full typed detail.
      expect(callbacks.refreshCalls, hasLength(2));
      expect(state.detailInfo!.name, 'Full App');
      expect(state.detailInfo!.version, 'A');
      expect(state.errorMessage, isEmpty);
      expect(callbacks.errors, isEmpty);

      // detailMenu typed action mapped to a DetailAction.
      expect(channel.getActions().map((a) => a.label).toList(), ['切换版本']);
      expect(state.isLoadingDetail, isFalse);
    });
  });

  group('load — no-detail degradation keeps the prefill', () {
    test('getAppDetail not_found: prefill kept, no error, actions still loaded',
        () async {
      facade
        ..detailError = const ChannelApiException(
          'not_found',
          '脚本未返回详情数据（脚本未实现或数据获取失败）',
        )
        ..detailMenuResult = const [
          rust.ChannelDetailAction(action: '历史构建', jscall: 'jsBuildHistory'),
        ];
      final (channel, state, callbacks) = build();

      await channel.load();

      // Not a hard failure: no error, prefill applied, page not blank.
      expect(state.errorMessage, isEmpty,
          reason: 'a no-detail reply must not hard-error the detail page');
      expect(callbacks.errors, isEmpty);
      expect(callbacks.refreshCalls, hasLength(1),
          reason: 'only the prefill was applied');
      expect(state.detailInfo, isNotNull, reason: 'page must not be blank');
      expect(state.detailInfo!.appId, 'com.example.one');
      expect(state.detailInfo!.name, 'Req App');

      // The "更多" menu is independent of getAppDetail and still refreshes.
      expect(facade.calls.map((c) => c['method']).toList(),
          ['getAppDetail', 'scriptDetailMenu']);
      expect(channel.getActions().map((a) => a.label).toList(), ['历史构建']);
      expect(state.isLoadingDetail, isFalse);
      expect(state.downloadsLoading, isFalse);
    });

    test('a non-not_found failure still surfaces a typed error', () async {
      facade
        ..detailError = const ChannelApiException('invalid_argument', 'bad key')
        ..detailMenuResult = const [];
      final (channel, state, callbacks) = build();

      await channel.load();

      expect(state.errorMessage, contains('详情加载失败'));
      // The prefill had already been rendered before the failure.
      expect(callbacks.refreshCalls, hasLength(1));
      expect(state.detailInfo, isNotNull);
    });
  });

  group('versionOptions / switchVersion / buildHistory — typed mapping', () {
    test('versionOptions maps the typed options and forwards the query',
        () async {
      facade.versionOptionsResult = const rust.ScriptVersionOptions(
        title: '切换版本',
        envs: ['sit', 'prod'],
        versions: [
          rust.ScriptVersionOption(
            version: '2.0',
            envs: ['sit'],
            buildCount: 3,
          ),
        ],
        currentEnv: 'sit',
        currentVersion: '2.0',
        extraJson: '{"packKey":"keep"}',
      );
      final (channel, _, _) = build();

      final options = await channel.versionOptions('com.example.one',
          env: 'sit', currentVersion: '2.0');

      expect(facade.calls.single['method'], 'scriptVersionOptions');
      expect(facade.calls.single['env'], 'sit');
      expect(facade.calls.single['currentVersion'], '2.0');
      expect(options!['title'], '切换版本');
      expect(options['envs'], ['sit', 'prod']);
      expect(options['currentEnv'], 'sit');
      expect(options['currentVersion'], '2.0');
      expect((options['versions'] as List).single, {
        'version': '2.0',
        'envs': ['sit'],
        'buildCount': 3,
      });
      // Unknown pack keys from extra_json are preserved.
      expect(options['packKey'], 'keep');
    });

    test('switchVersion maps the typed detail and encodes the build', () async {
      facade.switchVersionResult = typedDetail(
        name: 'Switched',
        version: '2.0',
        extraJson: jsonEncode({
          'appId': 'com.example.one',
          'name': 'Switched',
          'version': '2.0',
          'extra': {'env': 'sit'},
          'downloads': <Object?>[],
        }),
      );
      final (channel, _, _) = build();

      final detail = await channel.switchVersion(
        appId: 'com.example.one',
        env: 'sit',
        version: '2.0',
        build: {'num': 7},
      );

      expect(facade.calls.single['method'], 'scriptSwitchVersion');
      expect(facade.calls.single['buildJson'], '{"num":7}');
      expect(detail!['name'], 'Switched');
      expect(detail['version'], '2.0');
    });

    test('switchVersion non-object (null) → null', () async {
      facade.switchVersionResult = null;
      final (channel, _, _) = build();

      expect(
        await channel.switchVersion(
            appId: 'a', env: 'sit', version: '1'),
        isNull,
      );
    });

    test('buildHistory maps typed builds including extra_json keys', () async {
      facade.buildHistoryResult = const [
        rust.ScriptBuild(
          num: 7,
          publishedAt: '2026-01-02 03:04:05',
          size: 123,
          changelog: 'fix',
          installTimes: 4,
          extraJson: '{"ipaName":"a.apk","builtBy":"ci"}',
        ),
      ];
      final (channel, _, _) = build();

      final history = await channel.buildHistory(
          appId: 'com.example.one', version: '2.0', env: 'sit');

      expect(facade.calls.single['method'], 'scriptBuildHistory');
      expect(facade.calls.single['version'], '2.0');
      expect(facade.calls.single['env'], 'sit');
      expect(history!['builds'], hasLength(1));
      expect((history['builds'] as List).single, {
        'num': 7,
        'publishedAt': '2026-01-02 03:04:05',
        'size': 123,
        'changelog': 'fix',
        'installTimes': 4,
        'ipaName': 'a.apk',
        'builtBy': 'ci',
      });
    });
  });

  group('detailMenu actions — top-level for version/history, facade for the rest', () {
    test('jsswitchVersion / jsBuildHistory onTap use the facade, no run()',
        () async {
      facade
        ..detailResult = typedDetail(
          extraJson: jsonEncode({'appId': 'com.example.one', 'downloads': <Object?>[]}),
        )
        ..detailMenuResult = const [
          rust.ChannelDetailAction(action: '切换版本', jscall: 'jsswitchVersion'),
          rust.ChannelDetailAction(action: '历史构建', jscall: 'jsBuildHistory'),
        ]
        ..versionOptionsResult = const rust.ScriptVersionOptions(
          envs: ['sit', 'prod'],
          versions: [
            rust.ScriptVersionOption(version: '2.0', envs: ['sit'], buildCount: 3),
          ],
          currentEnv: 'sit',
          currentVersion: '2.0',
          extraJson: '{}',
        )
        ..buildHistoryResult = const [
          rust.ScriptBuild(num: 7, extraJson: '{"ipaName":"a.apk"}'),
        ];
      final (channel, _, callbacks) = build();

      await channel.load();
      facade.calls.clear();

      await channel.getActions().first.onTap();
      await channel.getActions()[1].onTap();

      final methods = facade.calls.map((c) => c['method']).toList();
      expect(methods, ['scriptVersionOptions', 'scriptVersionOptions', 'scriptBuildHistory']);
      expect(methods, isNot(contains('run')),
          reason: 'no pack jscall may be run from the detail page');
      expect(callbacks.versionPickerCalls, hasLength(1));
      expect(callbacks.buildHistoryCalls, hasLength(1));
      expect(callbacks.buildHistoryCalls.single['version'], '2.0');
      expect(callbacks.buildHistoryCalls.single['env'], 'sit');
    });

    test('an unknown action routes to scriptDetailAction (restored 切换UA path)',
        () async {
      facade
        ..detailResult = typedDetail(
          extraJson: jsonEncode({'appId': 'com.example.one', 'downloads': <Object?>[]}),
        )
        ..detailMenuResult = const [
          rust.ChannelDetailAction(action: '切换版本', jscall: 'jsswitchVersion'),
          rust.ChannelDetailAction(action: '历史构建', jscall: 'jsBuildHistory'),
          rust.ChannelDetailAction(action: '切换UA', jscall: 'jsswitchUA'),
        ];
      final (channel, _, _) = build();

      await channel.load();
      facade.calls.clear();
      facade.actionCalls.clear();

      // The pack-driven action (切换UA) runs on a fresh per-call ScriptDetail
      // through the facade — never a shared entry runtime.
      await channel.getActions()[2].onTap();
      expect(facade.actionCalls, [
        {'key': 'js_probe', 'appId': 'com.example.one', 'jscall': 'jsswitchUA'},
      ]);

      // jsswitchVersion / jsBuildHistory are served top-level and must NOT use
      // the pack-action path.
      await channel.getActions().first.onTap();
      await channel.getActions()[1].onTap();
      expect(facade.actionCalls, hasLength(1),
          reason: 'jsswitchVersion/jsBuildHistory must not call scriptDetailAction');
    });
  });

  group('lifecycle', () {
    test('a second load re-reads the facade (idempotent resume)', () async {
      facade
        ..detailResult = typedDetail(
          extraJson: jsonEncode(
              {'appId': 'com.example.one', 'downloads': <Object?>[]}),
        )
        ..detailMenuResult = const [];
      final (channel, state, callbacks) = build();

      await channel.load();
      await channel.load();

      expect(
        facade.calls.where((c) => c['method'] == 'getAppDetail').length,
        2,
        reason: 'a second load must re-read the facade, not stay stuck',
      );
      expect(state.errorMessage, isEmpty);
      expect(callbacks.errors, isEmpty);
      expect(state.detailInfo, isNotNull);
    });

    test('dispose releases the detail runtime via ScriptApi.releaseDetail', () async {
      final (channel, _, _) = build();

      await channel.dispose();

      expect(script.calls.single, {
        'method': 'releaseDetail',
        'key': 'js_probe',
        'appId': 'com.example.one',
      });
      // dispose must not touch the channels-domain facade data path.
      expect(facade.calls, isEmpty);
    });
  });
}

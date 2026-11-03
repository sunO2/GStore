/// Todo 9 — the `_currentVersion` / `_currentEnv` self-hold, evidence-gated.
///
/// The plan asks whether the JS detail channel still has to self-track the
/// current version/env. The gate: a test must prove the version picker
/// preselects the CURRENT version using **only** the top-level `versionOptions`
/// result (which the channel already passes `currentVersion` to), and that the
/// build-history sheet requests the SWITCHED version's builds.
///
/// Ground truth (read, not assumed): the pingan pack's `main('versionOptions')`
/// dispatch (`scripts/channels/src/pingan/detail.js:1042`) forwards **only**
/// `appId`/`env` to `getVersionOptions`; it drops `params.currentVersion`. The
/// pack then falls back to the latest version
/// (`detail.js:696` `currentVersion || versions[0].version`). So the top-level
/// `versionOptions` result does **not** round-trip the current version, and the
/// picker would preselect the latest — not the current — version.
///
/// This file's fake [ChannelApiBackend] models that exactly: its
/// `scriptVersionOptions` ignores the `currentVersion` argument and returns the
/// latest version, mirroring the real pack. The assertions therefore fail if
/// the channel stops holding the current version/env (preselection/build-history
/// regress) — a faithful, non-misleading oracle.
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

/// Fake FRB `ChannelApi` backend that models the **real pingan pack**, not a
/// convenient one:
///
/// * [scriptVersionOptions] ignores the `currentVersion` argument and returns
///   the latest version — exactly like `main('versionOptions')` (`detail.js`
///   :1042) calling `getVersionOptions(appId, env)` and :696 falling back to
///   `versions[0].version`. It records the argument so the forwarding is still
///   observable.
/// * [getAppDetail] / [scriptSwitchVersion] return a detail whose typed
///   `version` and `extra.env` carry the pack's `_currentVersion` / `_currentEnv`
///   (set at `detail.js:643` / :754).
/// * [scriptBuildHistory] returns a build whose `num` encodes the requested
///   version, so a wrong version is visible in the callback payload.
class _FakeChannelApiBackend implements ChannelApiBackend {
  /// Every facade call, in order.
  final List<Map<String, Object?>> calls = [];

  /// The `currentVersion` argument each `scriptVersionOptions` call received.
  final List<String?> versionOptionsCurrentVersionArgs = [];

  @override
  Future<rust.ChannelAppDetailInfo> getAppDetail({
    required String key,
    required String appId,
    required bool forceRefresh,
  }) async {
    calls.add({'method': 'getAppDetail', 'key': key, 'appId': appId});
    // pack getAppDetail: detail.version = group.version (:642); extra.env =
    // cred.env (:539 via buildDetailFromGroup).
    return _detail(
      version: '1.0.0',
      env: 'sit',
      name: 'Entry App',
    );
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
    versionOptionsCurrentVersionArgs.add(currentVersion);
    // The pack dispatch (detail.js:1042) drops `params.currentVersion`, so the
    // reply always carries the latest version (detail.js:696 fallback).
    return const rust.ScriptVersionOptions(
      title: '切换版本',
      envs: ['sit', 'prod'],
      versions: [
        rust.ScriptVersionOption(
            version: '3.0.0', envs: ['sit'], buildCount: 3),
        rust.ScriptVersionOption(
            version: '2.0.0', envs: ['sit', 'prod'], buildCount: 2),
        rust.ScriptVersionOption(
            version: '1.0.0', envs: ['sit'], buildCount: 1),
      ],
      currentEnv: 'sit',
      // The latest version, NOT the current one the channel asked for.
      currentVersion: '3.0.0',
      extraJson: '{}',
    );
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
    });
    // pack switchVersion: detail.version carries the target version; extra.env
    // is the (overridden) credential env (:752-754).
    return _detail(version: version, env: env, name: 'Switched $version');
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
    return [
      rust.ScriptBuild(
        num: version == '2.0.0' ? 20 : (version == '1.0.0' ? 10 : 30),
        extraJson: jsonEncode({'ipaName': '$version.apk'}),
      ),
    ];
  }

  @override
  Future<List<rust.ChannelDetailAction>> scriptDetailMenu({
    required String key,
    required String appId,
  }) async {
    calls.add({'method': 'scriptDetailMenu', 'key': key, 'appId': appId});
    return const [
      rust.ChannelDetailAction(action: '切换版本', jscall: 'jsswitchVersion'),
      rust.ChannelDetailAction(action: '历史构建', jscall: 'jsBuildHistory'),
    ];
  }

  @override
  Future<void> scriptDetailAction({
    required String key,
    required String appId,
    required String jscall,
  }) async {
    calls.add({'method': 'scriptDetailAction', 'jscall': jscall});
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'unexpected facade call: ${invocation.memberName}');

  rust.ChannelAppDetailInfo _detail({
    required String version,
    required String env,
    required String name,
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
        downloads: const [],
        extraJson: jsonEncode({
          'appId': 'com.example.one',
          'name': name,
          'version': version,
          'extra': {'env': env},
          'downloads': <Object?>[],
        }),
        labels: const <rust.ChannelLabel>[],
      );
}

/// Only `releaseDetail` is retained by the channel (`dispose`).
class _NoopScriptBackend implements ScriptApiBackend {
  @override
  Future<void> releaseDetail(
      {required String key, required String appId}) async {}

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

/// Captures the picker options / build-history payload the channel hands to the
/// page, so "preselected version" and "history version" are asserted explicitly
/// (not merely "a picker opened").
class _CapturingCallbacks implements DetailCallbacks {
  final List<Map<String, dynamic>> versionPickerCalls = [];
  final List<Map<String, dynamic>> buildHistoryCalls = [];
  final List<String> errors = [];
  DetailState? state;

  @override
  Future<void> refreshDetail({required Map<String, dynamic> detailData}) async {
    state?.detailInfo = JsChannelDetailProxy(detailData);
  }

  @override
  void showError(String message, {String? title}) => errors.add(message);

  @override
  Future<void> setActionBusy({required bool visible, String? label}) async {}

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
  );

  late _FakeChannelApiBackend facade;

  setUp(() async {
    CoreFlags.installBackend(_OnFlagsBackend());
    await CoreFlags.refresh();
    facade = _FakeChannelApiBackend();
    RustChannelFacade.installBackend(facade);
    ScriptApi.installBackend(_NoopScriptBackend());
  });

  tearDown(() {
    // stale_state: restore every process-wide backend this suite replaced.
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

  /// Drives load → open version picker → switch version → open build history.
  test(
      'load → picker preselects current → switch → history uses switched version',
      () async {
    final (channel, _, callbacks) = build();

    // --- load: the pack's getAppDetail reports the entry version 1.0.0 / env sit
    await channel.load();
    expect(channel.getActions().map((a) => a.label).toList(), ['切换版本', '历史构建']);

    // --- open the version picker (tap 切换版本)
    await channel.getActions().first.onTap();

    // The channel forwarded the tracked current version to versionOptions ...
    expect(facade.versionOptionsCurrentVersionArgs.single, '1.0.0');
    // ... and the picker's preselected version is the CURRENT one (1.0.0), NOT
    // the latest the pack falls back to (3.0.0).
    expect(callbacks.versionPickerCalls, hasLength(1));
    expect(
      callbacks.versionPickerCalls.single['currentVersion'],
      '1.0.0',
      reason: 'the picker must preselect the tracked current version, '
          'not the pack latest-version fallback',
    );

    // --- switch to 2.0.0 on env prod (the picker → mixin → dc.switchVersion)
    final switched = await channel.switchVersion(
      appId: request.appId,
      env: 'prod',
      version: '2.0.0',
    );
    expect(switched, isNotNull);
    expect(switched!['version'], '2.0.0');

    // --- open build history (tap 历史构建)
    await channel.getActions()[1].onTap();

    // The build-history request uses the SWITCHED version (2.0.0) / env (prod),
    // not the latest (3.0.0) nor the entry (1.0.0) / sit.
    final bhCall = facade.calls.singleWhere(
      (c) => c['method'] == 'scriptBuildHistory',
    );
    expect(bhCall['version'], '2.0.0');
    expect(bhCall['env'], 'prod');
    expect(callbacks.buildHistoryCalls, hasLength(1));
    expect(callbacks.buildHistoryCalls.single['version'], '2.0.0');
    expect(callbacks.buildHistoryCalls.single['env'], 'prod');
    // The builds payload proves the switched version was requested.
    expect(
      (callbacks.buildHistoryCalls.single['builds'] as List).single,
      {'num': 20, 'ipaName': '2.0.0.apk'},
    );
    expect(callbacks.errors, isEmpty);
  });

  test(
      'cancel/resume: reopen the picker after a switch preselects the switched version',
      () async {
    final (channel, _, callbacks) = build();
    await channel.load();

    // Switch first (as if the user picked 2.0.0 and the sheet closed).
    await channel.switchVersion(
      appId: request.appId,
      env: 'prod',
      version: '2.0.0',
    );

    // Reopen the picker: it must now preselect the switched version 2.0.0.
    await channel.getActions().first.onTap();

    expect(callbacks.versionPickerCalls, hasLength(1));
    expect(
      callbacks.versionPickerCalls.single['currentVersion'],
      '2.0.0',
      reason: 'reopening after a switch must preselect the switched version',
    );
  });

  test(
      'stale_state: a second switch updates the tracked version for the next history',
      () async {
    final (channel, _, callbacks) = build();
    await channel.load();

    await channel.switchVersion(
      appId: request.appId,
      env: 'prod',
      version: '2.0.0',
    );
    // A second switch must overwrite the tracked version (no stale 2.0.0).
    await channel.switchVersion(
      appId: request.appId,
      env: 'sit',
      version: '1.0.0',
    );

    await channel.getActions()[1].onTap();

    final bhCall = facade.calls.singleWhere(
      (c) => c['method'] == 'scriptBuildHistory',
    );
    expect(bhCall['version'], '1.0.0');
    expect(bhCall['env'], 'sit');
    expect(callbacks.buildHistoryCalls.single['version'], '1.0.0');
    expect(
      (callbacks.buildHistoryCalls.single['builds'] as List).single,
      {'num': 10, 'ipaName': '1.0.0.apk'},
    );
  });
  test('历史构建第二次打开复用页面级缓存，不再请求 scriptBuildHistory', () async {
    final (channel, _, callbacks) = build();
    await channel.load();

    await channel.getActions()[1].onTap();
    await channel.getActions()[1].onTap();

    final historyCalls = facade.calls
        .where((call) => call['method'] == 'scriptBuildHistory')
        .length;
    expect(historyCalls, 1);
    expect(callbacks.buildHistoryCalls, hasLength(2));
  });
}

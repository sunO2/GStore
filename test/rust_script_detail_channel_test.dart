/// Regression for the JS-channel (`js_*`, Rust script lane) DETAIL page.
///
/// The Rust host collapses three different outcomes — the pack having no
/// `getAppDetail` case (undefined), a `{ok:false, data:null, error}` envelope,
/// and a JS throw — into the bare JSON `null`
/// (`rust/gstore_host/src/script_runtime_entry.rs` `ScriptEntry::run` :171 +
/// `unwrap_envelope` :301-307; `gstore_script/src/script/engine.rs` :215-216
/// maps `undefined` → `Null`). `ScriptApi.run` therefore SUCCEEDS and returns
/// the string `"null"`.
///
/// Before the fix [RustScriptDetailChannel.load] took the non-Map branch and
/// set `state.errorMessage = '详情加载失败（脚本未返回详情数据）'`, and
/// `lib/page/detail/view.dart` (:83-85) replaced the WHOLE body with the error
/// view — discarding the prefill it had just rendered (the user-visible
/// "详情页加载失败 脚本未返回详情数据").
///
/// After the fix a null reply keeps the prefill (no hard error); only a real
/// exception sets a typed `errorMessage`.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart' show JsChannelDetailProxy;
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_detail_channel.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/page/detail/state.dart';

/// In-memory `ScriptApiBackend` (the FRB seam): the raw JSON string the Rust
/// `run` would return, or a thrown exception. No FRB dylib is loaded.
class _FakeScriptBackend implements ScriptApiBackend {
  _FakeScriptBackend({this.reply = 'null', this.throwError});

  /// Raw JSON string the script reply decodes to (`'null'` = no detail).
  String reply;

  /// When non-null, [run] throws it (a typed FRB failure / pack-not-found).
  Object? throwError;

  final List<Map<String, Object?>> runCalls = [];

  @override
  Future<String> run({
    required String key,
    required String method,
    required String paramsJson,
  }) async {
    runCalls.add({'key': key, 'method': method, 'params': paramsJson});
    final err = throwError;
    if (err != null) throw err;
    return reply;
  }

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
      rust_pack.ScriptPackInfo(
        key: expectedKey ?? 'js_probe',
        name: '',
        description: '',
        icon: '',
        hasDetail: false,
      );

  @override
  Future<void> remove({required String key}) async {}

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async =>
      rust_pack.ScriptPackInfo(
        key: key,
        name: '',
        description: '',
        icon: '',
        hasDetail: false,
      );

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
  Future<List<rust_pack.ScriptPackInfo>> list() async => const [];

  @override
  Future<String> storedApps({required String key}) async => '[]';

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

/// Flags backend that turns the Rust lane on so `ScriptApi.run` does not refuse
/// with [ScriptApiDisabledException].
class _OnFlagsBackend implements CoreFlagsBackend {
  @override
  Future<CoreFlagsSnapshot> read() async =>
      const CoreFlagsSnapshot(jsChannel: true);

  @override
  Future<void> write(CoreFlagsPatch patch) async {}
}

/// Capturing callbacks mirroring `DetailLogic.refreshDetail`
/// (`state.detailInfo = JsChannelDetailProxy(detailData)`) so the assertions
/// prove the prefill reached the bound state, not a fake's invention.
class _CapturingCallbacks implements DetailCallbacks {
  final List<Map<String, dynamic>> refreshCalls = [];
  final List<String> errors = [];
  DetailState? state;

  @override
  Future<void> refreshDetail({
    required Map<String, dynamic> detailData,
  }) async {
    refreshCalls.add(Map<String, dynamic>.from(detailData));
    state?.detailInfo = JsChannelDetailProxy(detailData);
  }

  @override
  void showError(String message, {String? title}) => errors.add(message);

  // The following are not reached by `load()`; no-op stubs.
  @override
  Future<void> updateDetail({required Map<String, dynamic> partial}) async {}

  @override
  Future<void> setActionBusy({required bool visible, String? label}) async {}

  @override
  void showSuccess(String message, {String? title}) {}

  @override
  Future<void> showVersionPicker({
    required Map<String, dynamic> options,
    required String appId,
  }) async {}

  @override
  Future<void> showBuildHistory({
    required List<Map<String, dynamic>> builds,
    required String appId,
    required String version,
    required String env,
  }) async {}

  @override
  Future<String?> showUAPicker({
    required List<String>? uaOptions,
    required String appId,
    String? current,
  }) async =>
      null;

  @override
  Future<void> updateDownloadList({
    required List<DownloadInfo> downloads,
  }) async {}

  @override
  void syncDownloadToFB(DownloadInfo download) {}

  @override
  Future<void> startDownload(
    DownloadInfo download, {
    int? downloadSize,
    bool fromScript = false,
  }) async {}

  @override
  Future<bool?> showWarningDialog({
    required String title,
    required String content,
    String? confirmText,
    String? cancelText,
    bool isDangerous = false,
  }) async =>
      null;

  @override
  void startApp(String packageName) {}

  @override
  void openBrowser(String url) {}

  @override
  void openProjectBrowser() {}

  @override
  Future<void> submitAppMetadata() async {}

  @override
  Future<List<String>?> showMoreActionsSheet({
    required String appName,
    required List<String> presetTags,
    required List<String> currentTags,
    required List<DetailAction> actions,
  }) async =>
      null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    CoreFlags.installBackend(_OnFlagsBackend());
    await CoreFlags.refresh();
    expect(CoreFlags.jsChannel, isTrue);
  });

  tearDown(() {
    CoreFlags.resetBackend();
  });

  const request = AppDetailRequest(
    appId: 'com.example.one',
    name: 'Req App',
    channel: ChannelType.custom,
    channelCode: 'js_probe',
    packageName: 'com.example.one',
    icon: 'icon://req',
    description: '请求描述',
  );

  /// Builds the channel bound to a fresh state + capturing callbacks.
  (RustScriptDetailChannel, DetailState, _CapturingCallbacks) build(
    _FakeScriptBackend backend,
  ) {
    final api = ScriptApi(backend: backend);
    final channel = RustScriptDetailChannel(
      appId: request.appId,
      channelKey: 'js_probe',
      request: request,
      api: api,
    );
    final cb = _CapturingCallbacks();
    final state = DetailState()..request = request;
    cb.state = state;
    channel.bind(state, cb);
    return (channel, state, cb);
  }

  group('RustScriptDetailChannel.load — null reply keeps the prefill', () {
    test('raw "null" reply: no error, prefill applied, page not blank', () async {
      final backend = _FakeScriptBackend(reply: 'null');
      final (channel, state, cb) = build(backend);

      await channel.load();

      // The seam was reached with the documented shape.
      expect(backend.runCalls, hasLength(1));
      expect(backend.runCalls.first['method'], 'getAppDetail');
      expect(
        (jsonDecode(backend.runCalls.first['params']! as String)
            as Map)['appId'],
        'com.example.one',
      );

      // Null reply is NOT a hard failure: no error message (so view.dart's
      // `errorMessage.isNotEmpty` branch is not taken → body is not replaced).
      expect(state.errorMessage, isEmpty,
          reason: 'a null reply must not hard-error the detail page');
      expect(cb.errors, isEmpty);

      // Prefill was applied (only one refreshDetail: the prefill).
      expect(cb.refreshCalls, hasLength(1));
      expect(state.detailInfo, isNotNull, reason: 'page must not be blank');
      expect(state.detailInfo!.appId, 'com.example.one');
      expect(state.detailInfo!.name, 'Req App');
      expect(state.detailInfo!.packageName, 'com.example.one');

      // Loading flags still cleared.
      expect(state.isLoadingDetail, isFalse);
      expect(state.downloadsLoading, isFalse);
      expect(state.readmeLoading, isFalse);
      expect(state.statisticsLoading, isFalse);
    });

    test('whitespace-padded "null" reply: still no error, prefill kept',
        () async {
      final backend = _FakeScriptBackend(reply: '  null \n');
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(state.errorMessage, isEmpty);
      expect(state.detailInfo, isNotNull);
      expect(state.detailInfo!.name, 'Req App');
      expect(cb.refreshCalls, hasLength(1));
    });
  });

  group('RustScriptDetailChannel.load — Map reply applies the detail', () {
    test('object reply: detail replaced, no error', () async {
      final backend = _FakeScriptBackend(
        reply: jsonEncode({
          'appId': 'com.example.one',
          'name': 'Full App',
          'packageName': 'com.example.one',
          'downloads': <Object?>[],
          'sections': ['downloads'],
        }),
      );
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(state.errorMessage, isEmpty);
      expect(cb.refreshCalls, hasLength(2),
          reason: 'prefill then full detail');
      expect(state.detailInfo!.name, 'Full App');
      expect(state.isLoadingDetail, isFalse);
    });
  });

  group('RustScriptDetailChannel.load — real exception still errors', () {
    test('api throws: errorMessage set, prefill was still applied first',
        () async {
      final backend = _FakeScriptBackend(
        throwError: StateError('pack not found'),
      );
      final (channel, state, cb) = build(backend);

      await channel.load();

      expect(state.errorMessage, isNotEmpty,
          reason: 'a real exception must still surface a typed error');
      expect(state.errorMessage, contains('详情加载失败'));
      // The prefill had already been rendered before the throw.
      expect(cb.refreshCalls, hasLength(1));
      expect(state.detailInfo, isNotNull);
      // Flags cleared even on the error path.
      expect(state.isLoadingDetail, isFalse);
      expect(state.downloadsLoading, isFalse);
      expect(state.readmeLoading, isFalse);
      expect(state.statisticsLoading, isFalse);
    });
  });
}

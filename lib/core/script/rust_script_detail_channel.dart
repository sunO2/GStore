import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart' show JsChannelDetailProxy;
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/page/detail/state.dart';

/// Page-level detail channel for a Rust-lane script pack (`js_*`).
///
/// While `CoreFlags.jsChannel` is on there is no Dart `JsChannel`, so
/// `DetailLogic` cannot resolve `js_*` through `ChannelManager`. This channel
/// resolves the pack through [ScriptApi] instead: `getAppDetail` runs in the
/// Rust runtime and its JSON result is rendered through the same
/// [JsChannelDetailProxy] the Dart lane used, so the page loads its apps/detail
/// instead of a silent blank.
///
/// A script that returns no detail is **not** a hard failure: the Rust host
/// collapses an unimplemented `getAppDetail` (undefined), a `{ok:false}` reply
/// and a JS throw into the bare JSON `null`, so [ScriptApi.run] succeeds and
/// returns `"null"`. That null reply keeps the prefill already rendered
/// (appId/name/icon/description/packageName + empty `downloads`/`sections`) and
/// logs a non-fatal signal — the page shows the request's basic info instead of
/// a full-page error. Only a real exception (e.g. pack-not-found, a typed FRB
/// failure, or malformed JSON) sets a typed `errorMessage` on the bound state
/// (the page shows the retryable error body) — never `SizedBox.shrink()`.
class RustScriptDetailChannel implements IDetailChannel {
  RustScriptDetailChannel({
    required this.appId,
    required this.channelKey,
    required this.request,
    ScriptApi? api,
  }) : _apiOverride = api;

  @override
  final String appId;

  /// Download is host-orchestrated for the Rust lane (the detail's `downloads`
  /// are rendered by the page and the host drives the download service).
  @override
  bool get drivesOwnDownloads => false;

  /// Pack channel key (`js_<stem>`), the Rust `ScriptApi` lookup key.
  final String channelKey;

  /// Request parameters (prefill + package-name fallback).
  final AppDetailRequest request;

  final ScriptApi? _apiOverride;

  ScriptApi get _api => _apiOverride ?? ScriptApi.instance;

  DetailState? _boundState;
  DetailCallbacks? _boundCallbacks;

  @override
  void bind(DetailState state, DetailCallbacks callbacks) {
    _boundState = state;
    _boundCallbacks = callbacks;
  }

  @override
  Future<void> load() async {
    final state = _boundState;
    final callbacks = _boundCallbacks;
    if (state == null || callbacks == null) return;
    state.isLoadingDetail = true;
    state.errorMessage = '';
    try {
      // Prefill the request's basic info so the header renders immediately.
      await callbacks.refreshDetail(detailData: _buildPrefill(state));
      state.downloadsLoading = true;
      state.readmeLoading = true;
      state.statisticsLoading = true;

      final raw = await _api.run(
        key: channelKey,
        method: 'getAppDetail',
        paramsJson: jsonEncode({'appId': appId}),
      );
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        await callbacks.refreshDetail(
          detailData: Map<String, dynamic>.from(decoded),
        );
      } else {
        // Null / non-object reply = "the script has no detail for this app".
        // The Rust host folds undefined (no `getAppDetail` case), `{ok:false}`
        // and a JS throw into the bare JSON `null`, so this is NOT a failure:
        // keep the prefill already rendered (the page shows the basic info,
        // never a full-page error) and emit a non-fatal signal only.
        debugPrint(
          '[RustScriptDetailChannel] no detail from $channelKey for $appId '
          '(script returned $raw); keeping the prefill',
        );
      }
    } catch (e) {
      state.errorMessage = '详情加载失败: $e';
    } finally {
      state.isLoadingDetail = false;
      state.downloadsLoading = false;
      state.readmeLoading = false;
      state.statisticsLoading = false;
    }
  }

  /// Prefill map from the bound request (non-empty fields only), matching
  /// [JsDetailChannel]'s contract so the header shows before the script reply.
  Map<String, dynamic> _buildPrefill(DetailState state) {
    final req = state.request;
    final prefill = <String, dynamic>{
      'downloads': const <Object?>[],
      'sections': const ['downloads'],
    };
    if (req == null) return prefill;
    if (req.appId.isNotEmpty) prefill['appId'] = req.appId;
    if (req.name.isNotEmpty) prefill['name'] = req.name;
    final icon = req.icon;
    if (icon != null && icon.isNotEmpty) prefill['icon'] = icon;
    final description = req.description;
    if (description != null && description.isNotEmpty) {
      prefill['description'] = description;
    }
    final packageName = req.packageName;
    if (packageName != null && packageName.isNotEmpty) {
      prefill['packageName'] = packageName;
      prefill['extra'] = {'packageName': packageName};
    }
    return prefill;
  }

  /// Rust-lane packs expose no `detailMenu` here; the "更多" panel keeps the
  /// generic actions (host-orchestrated).
  @override
  List<DetailAction> getActions() => const [];

  /// Download is host-orchestrated for the Rust lane (the detail's `downloads`
  /// are rendered by the page and the host drives the download service).
  @override
  Future<void> startDownload(DownloadInfo info) async {}

  /// Version/env switching is not exposed through the Rust lane facade.
  @override
  Future<Map<String, dynamic>?> versionOptions(String appId,
          {String? env}) async =>
      null;

  @override
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) async =>
      null;

  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async =>
      null;

  /// The host replaces the detail's downloads directly; no channel-side cache.
  @override
  Future<void> updateDownloads(List<DownloadInfo> downloads) async {}

  /// Releases the `(key, app_id)` detail runtime (unknown ids are a no-op).
  @override
  Future<void> dispose() async {
    await _api.releaseDetail(key: channelKey, appId: appId);
  }
}

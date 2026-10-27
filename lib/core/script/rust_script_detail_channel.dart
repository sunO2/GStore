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

  /// [getActions] 返回的操作项缓存（[load] 时从脚本 detailMenu 刷新）。
  List<DetailAction> _actions = const [];

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
      // The "更多" menu is independent of `getAppDetail`: refresh it on both the
      // Map and the null reply so the page keeps its custom actions.
      await _refreshActions();
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

  /// 返回脚本 detailMenu 声明的操作项（"更多"面板展示）。
  /// 未 [load]/未 bind/脚本未实现 → 空列表（调用方兜底）。
  @override
  List<DetailAction> getActions() => _actions;

  /// 脚本 detailMenu → [DetailAction] 列表缓存（[getActions] 消费）。
  ///
  /// onTap 经 [_runAction] 分派：`jsswitchVersion`/`jsBuildHistory` 走顶层
  /// [versionOptions]/[buildHistory] + [DetailCallbacks]（避开 parked eval 死锁，
  /// 见 [_runAction]），其余动作（如 `jsswitchUA`）仍由脚本 jscall 驱动。
  /// 本方法自身绝不抛出：detailMenu 失败只清空 [getActions] 并记日志，
  /// 绝不让菜单失败污染 `errorMessage` / 白屏（详情页内容仍照常渲染）。
  Future<void> _refreshActions() async {
    try {
      final raw = await _api.run(
        key: channelKey,
        method: 'detailMenu',
        paramsJson: jsonEncode({'appId': appId}),
      );
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) {
        _actions = const [];
        return;
      }
      _actions = decoded.map((e) {
        final entry = e is Map ? e : const <Object?, Object?>{};
        final label = entry['action']?.toString() ?? '';
        final jscall = entry['jscall']?.toString() ?? '';
        return DetailAction(
          label: label.isEmpty ? (jscall.isEmpty ? '未知动作' : jscall) : label,
          onTap: () => _runAction(jscall),
        );
      }).toList();
    } catch (e) {
      debugPrint(
        '[RustScriptDetailChannel] detailMenu failed for $channelKey/$appId: $e',
      );
      _actions = const [];
    }
  }

  /// Dispatches a detailMenu action WITHOUT parking the Rust eval.
  ///
  /// Running the pack's own `jsswitchVersion`/`jsBuildHistory` jscall would hold
  /// `ScriptEntry::run`'s `op` mutex for the whole eval
  /// (`rust/gstore_host/src/script_runtime_entry.rs`) while the pack's
  /// synchronous `host.ui.call('showVersionPicker'/'showBuildHistory')`
  /// (`rust/gstore_host/src/ui_api.rs::request` → `rx.recv_timeout`) parks that
  /// eval. The Flutter handler (`detail_ui_mixins.dart`
  /// `showVersionPicker`/`showBuildHistory`) then calls back into the script via
  /// `versionOptions`/`switchVersion` → `ScriptApi.run` → `ScriptEntry::run` →
  /// `op.lock()` → DEADLOCK on the mutex held by the parked outer eval.
  ///
  /// So the two parking actions are re-dispatched to the TOP-LEVEL script
  /// methods ([versionOptions]/[buildHistory]) + the bound [DetailCallbacks]
  /// (whose `dc.*` calls are then top-level — no parked eval, no nested `run`).
  ///
  /// Every other action (e.g. `jsswitchUA`) keeps the pack-driven path: its
  /// handlers (`showUAPicker`/`refreshDetail`) only touch Flutter state, so
  /// running the pack eval never parks the script in a re-entrant call.
  Future<void> _runAction(String jscall) async {
    switch (jscall) {
      case 'jsswitchVersion':
        await _openVersionPicker();
        break;
      case 'jsBuildHistory':
        await _openBuildHistory();
        break;
      default:
        await _api.run(
          key: channelKey,
          method: jscall,
          paramsJson: jsonEncode({'appId': appId}),
        );
    }
  }

  /// 切换版本入口：顶层拉 `versionOptions` → 经 [DetailCallbacks.showVersionPicker]
  /// 弹选择器。选择后的 `switchVersion`/`refreshDetail` 与 `onEnvChanged`/
  /// `onBuildHistory` 回调均由 mixin 顶层发起（无 parked eval → 无嵌套 `run`）。
  Future<void> _openVersionPicker() async {
    final options = await versionOptions(appId);
    if (options == null) return;
    await _boundCallbacks?.showVersionPicker(options: options, appId: appId);
  }

  /// 历史构建入口：顶层拉 `versionOptions` → 取当前 `currentVersion`/`currentEnv`
  /// → 顶层拉 `buildHistory` → 经 [DetailCallbacks.showBuildHistory] 弹构建历史。
  /// builds 形状与 registry（`script_ui_handler_registry.dart`
  /// `showBuildHistory`）一致：`List<Map<String, dynamic>>`。
  Future<void> _openBuildHistory() async {
    final options = await versionOptions(appId);
    if (options == null) return;
    final version = options['currentVersion']?.toString() ?? '';
    final env = options['currentEnv']?.toString() ?? '';
    final history = await buildHistory(appId: appId, version: version, env: env);
    if (history == null) return;
    final builds = ((history['builds'] as List?) ?? <Object?>[])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    await _boundCallbacks?.showBuildHistory(
      builds: builds,
      appId: appId,
      version: version,
      env: env,
    );
  }

  /// Download is host-orchestrated for the Rust lane (the detail's `downloads`
  /// are rendered by the page and the host drives the download service).
  @override
  Future<void> startDownload(DownloadInfo info) async {}

  /// 版本/环境切换选项（脚本 detail.js 的 `versionOptions`）→ 解码后的 Map；
  /// `env` 为空时省略该键（pingan 侧会误判）。脚本未实现/失败 → null。
  @override
  Future<Map<String, dynamic>?> versionOptions(String appId,
      {String? env}) async {
    final raw = await _api.run(
      key: channelKey,
      method: 'versionOptions',
      paramsJson: jsonEncode({
        'appId': appId,
        if (env != null) 'env': env,
      }),
    );
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  /// 切换版本/环境（脚本 detail.js 的 `switchVersion`）→ 解码后的详情 Map；
  /// [build] 为空时省略该键。脚本未实现/失败 → null。
  @override
  Future<Map<String, dynamic>?> switchVersion({
    required String appId,
    required String env,
    required String version,
    Map<String, dynamic>? build,
  }) async {
    final raw = await _api.run(
      key: channelKey,
      method: 'switchVersion',
      paramsJson: jsonEncode({
        'appId': appId,
        'env': env,
        'version': version,
        if (build != null) 'build': build,
      }),
    );
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  /// 指定版本历史构建（脚本 detail.js 的 `buildHistory`）→ 解码后的 Map；
  /// 脚本未实现/失败 → null。
  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async {
    final raw = await _api.run(
      key: channelKey,
      method: 'buildHistory',
      paramsJson: jsonEncode({
        'appId': appId,
        'version': version,
        'env': env,
      }),
    );
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  }

  /// The host replaces the detail's downloads directly; no channel-side cache.
  @override
  Future<void> updateDownloads(List<DownloadInfo> downloads) async {}

  /// Releases the `(key, app_id)` detail runtime (unknown ids are a no-op).
  @override
  Future<void> dispose() async {
    await _api.releaseDetail(key: channelKey, appId: appId);
  }
}

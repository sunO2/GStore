import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gstore/core/channel/IDetailChannel.dart';
import 'package:gstore/core/channel/detail_callbacks.dart';
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/model/AppDetailRequest.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/script/rust_script_detail_mapping.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/page/detail/state.dart';

/// Page-level detail channel for a Rust-lane script pack (`js_*`).
///
/// While `CoreFlags.jsChannel` is on there is no Dart `JsChannel`, so
/// `DetailLogic` cannot resolve `js_*` through `ChannelManager`. This channel
/// resolves the pack through the unified channel entry instead: every data read
/// (`getAppDetail` on the pack's `detail.js` runtime, plus the four detail-page
/// methods) goes through
/// [RustChannelFacade] — the typed FRB `ChannelApi` surface — and the typed
/// results are adapted to the `Map<String, dynamic>` shape the page's
/// `JsChannelDetailProxy` already consumes, so the page renders identically.
///
/// A script that returns no detail is **not** a hard failure: the Rust host
/// collapses an unimplemented `getAppDetail` (undefined), a `{ok:false}` reply
/// and a JS throw into the typed `not_found` error, so [load] keeps the prefill
/// already rendered (appId/name/icon/description/packageName + empty
/// `downloads`/`sections`) and logs a non-fatal signal — the page shows the
/// request's basic info instead of a full-page error. Only a non-`not_found`
/// failure sets a typed `errorMessage` on the bound state (the page shows the
/// retryable error body) — never `SizedBox.shrink()`.
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

  /// Pack channel key (`js_<stem>`), the Rust `ChannelApi` lookup key.
  final String channelKey;

  /// Request parameters (prefill + package-name fallback).
  final AppDetailRequest request;

  final ScriptApi? _apiOverride;

  /// [ScriptApi] is retained **only** for [dispose]'s `releaseDetail`.
  ///
  /// The unified data path (below) goes through [RustChannelFacade]; the
  /// facade's Rust methods construct and dispose a one-shot `ScriptDetail` per
  /// call, so there is no Dart-side cached runtime to release. `releaseDetail`
  /// is kept because it is harmless (an unknown `(key, app_id)` is a no-op) and
  /// drops any runtime the legacy `ScriptApi` lane may still hold for this page.
  ScriptApi get _api => _apiOverride ?? ScriptApi.instance;

  /// Typed channel entry (FRB `ChannelApi`). Resolved per call so tests can
  /// install a fake backend with [RustChannelFacade.installBackend].
  RustChannelFacade get _facade => RustChannelFacade.instance;

  DetailState? _boundState;
  DetailCallbacks? _boundCallbacks;

  /// 当前版本（本通道自持，Todo 9 证据门后保留）。
  ///
  /// pack 的 `getAppDetail`/`switchVersion` 只在其**内部**记录 `_currentVersion`
  /// （`scripts/channels/src/pingan/detail.js` :643 / :754），而顶层 `versionOptions`
  /// 不回传该 pack 的当前版本：pack 的 `main('versionOptions')`（:1042）只转发
  /// `appId`/`env` 调 `getVersionOptions`（丢 `params.currentVersion`），后者缺省
  /// 回退到最新版本（:696 `currentVersion || versions[0].version`）。证据见
  /// `test/detail_version_switch_history_test.dart`：传入 `currentVersion` 后顶层
  /// 结果仍回传最新版本 → 选择器会预选错位。
  ///
  /// Rust 通道因避开 parked-eval 死锁（见 [_dispatchAction]）而不跑 pack 的
  /// `jsBuildHistory`，故必须自持当前版本供：
  /// 1. `_openVersionPicker` 覆盖选择器预选值（pack 不回传，见上）；
  /// 2. `_openBuildHistory` 取当前版本，否则切换版本后历史构建列表仍按
  ///    入口/最新版本取。
  String? _currentVersion;

  /// 当前环境（同上，来自 detail 的 `extra.env` / `switchVersion` 的 env 参数）。
  String? _currentEnv;

  /// [getActions] 返回的操作项缓存（[load] 时从脚本 detailMenu 刷新）。
  List<DetailAction> _actions = const [];

  /// Page-scoped version options cache: one script runtime is created per FRB
  /// call, so the pack's own module-level cache cannot survive across calls.
  final Map<String, Map<String, dynamic>> _versionOptionsCache = {};

  /// Page-scoped build history cache keyed by `version|env`.
  final Map<String, Map<String, dynamic>> _buildHistoryCache = {};

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

      try {
        var detail = await _facade.scriptGetAppDetail(
          key: channelKey,
          appId: appId,
        );
        if (detail == null) {
          // A pack may implement only the entry lane; keep the pre-existing
          // (entry.js) behaviour instead of dropping the detail page.
          debugPrint(
            '[RustScriptDetailChannel] detail.js has no getAppDetail for '
            '$channelKey/$appId; falling back to the entry lane',
          );
          detail = await _facade.getAppDetail(
            key: channelKey,
            appId: appId,
            forceRefresh: false,
          );
        }
        final map = _normalizeDetailMap(detailToMap(detail));
        await callbacks.refreshDetail(detailData: map);
        // 记录 pack 的当前版本/环境（pack `getAppDetail` :642-643 设
        // `detail.version`/内部 `_currentVersion`；:539 设 `_currentEnv` =
        // `cred.env`，后者经 buildDetailFromGroup 落进 detail 的 `extra.env`）。
          _currentVersion = detail.version;
          _currentEnv = (map['extra'] as Map?)?['env']?.toString();
          _cacheHistoryFromDetail(map);
          _cacheVersionOptionsFromDetail(map);
      } on ChannelApiException catch (error) {
        // "The script has no detail for this app". A JSON null / `{ok:false}` /
        // a JS throw from `detail.js` falls back to the entry lane above; an
        // unknown pack (or one without `detail.js`) surfaces as the typed
        // `not_found` here. Neither is a failure: keep the prefill already
        // rendered (the page shows the basic info, never a full-page error) and
        // emit a non-fatal signal only. A non-`not_found` typed failure
        // propagates to the outer catch and sets `errorMessage`.
        if (error.code != 'not_found') rethrow;
        debugPrint(
          '[RustScriptDetailChannel] no detail from $channelKey for $appId '
          '($error); keeping the prefill',
        );
      }
      // The "更多" menu is independent of `getAppDetail`: refresh it on both the
      // typed-detail and the no-detail reply so the page keeps its custom actions.
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
  /// onTap 经 [_dispatchAction] 分派：`jsswitchVersion`/`jsBuildHistory` 走顶层
  /// `ChannelApi` detail 方法（[versionOptions]/[buildHistory]），其余动作（如
  /// `jsswitchUA`）经 [_facade.scriptDetailAction] 在「每次新建的 ScriptDetail」上
  /// 运行 pack jscall（不共享入口 `op` → 无 deadlock）。
  /// 本方法自身绝不抛出：detailMenu 失败只清空 [getActions] 并记日志，
  /// 绝不让菜单失败污染 `errorMessage` / 白屏（详情页内容仍照常渲染）。
  Future<void> _refreshActions() async {
    try {
      final menu = await _facade.scriptDetailMenu(
        key: channelKey,
        appId: appId,
      );
      _actions = [for (final action in menu) _toAction(action)];
    } catch (e) {
      debugPrint(
        '[RustScriptDetailChannel] detailMenu failed for $channelKey/$appId: $e',
      );
      _actions = const [];
    }
  }

  /// 一个 typed [rust.ChannelDetailAction] → [DetailAction]（label + onTap）。
  DetailAction _toAction(rust.ChannelDetailAction action) {
    final jscall = action.jscall;
    final label = action.action.isNotEmpty
        ? action.action
        : (jscall.isEmpty ? '未知动作' : jscall);
    return DetailAction(label: label, onTap: () => _dispatchAction(jscall));
  }

  /// Routes a detailMenu action to its handler.
  ///
  /// `jsswitchVersion`/`jsBuildHistory` are served by the TOP-LEVEL
  /// [versionOptions]/[buildHistory] (facade `ChannelApi` detail methods) + the
  /// bound [DetailCallbacks]: running the pack's own jscall would hold
  /// `ScriptEntry::run`'s `op` mutex for the whole eval
  /// (`rust/gstore_host/src/script_runtime_entry.rs`) while the pack's
  /// synchronous `host.ui.call('showVersionPicker'/'showBuildHistory')`
  /// (`rust/gstore_host/src/ui_api.rs::request` → `rx.recv_timeout`) parks that
  /// eval; the Flutter handler (`detail_ui_mixins.dart`) then re-enters via
  /// `versionOptions`/`switchVersion` — which the Todo 7 guard rejects with the
  /// typed `CORE_E_SCRIPT_UI_REENTRANT` while the entry is parked.
  ///
  /// Every other action (e.g. `jsswitchUA`) runs the pack's own jscall through
  /// [_facade.scriptDetailAction], which executes on a FRESH per-call
  /// `ScriptDetail` (never the shared entry runtime), so a parked UI round-trip
  /// cannot contend on the entry `op` guard and cannot deadlock.
  Future<void> _dispatchAction(String jscall) async {
    switch (jscall) {
      case 'jsswitchVersion':
        await _openVersionPicker();
        break;
      case 'jsBuildHistory':
        await _openBuildHistory();
        break;
      default:
        await _facade.scriptDetailAction(
          key: channelKey,
          appId: appId,
          jscall: jscall,
        );
    }
  }

  /// 切换版本入口：顶层拉 `versionOptions` → 经 [DetailCallbacks.showVersionPicker]
  /// 弹选择器。选择后的 `switchVersion`/`refreshDetail` 与 `onEnvChanged`/
  /// `onBuildHistory` 回调均由 mixin 顶层发起（无 parked eval → 无嵌套 `run`）。
  ///
  /// 用自持的 `_currentVersion` 覆盖选择器预选值：pack 的顶层 `versionOptions`
  /// 不回传当前版本（`main('versionOptions')` :1042 只转发 appId/env；
  /// `getVersionOptions` 缺省回退最新版本 :696），故传 `currentVersion` 给
  /// `versionOptions` 无效果，必须在此显式覆盖，否则选择器预选错位到最新版本。
  Future<void> _openVersionPicker() async {
    final willFetch =
        !_versionOptionsCache.containsKey(_versionOptionsCacheKey(_currentEnv));
    if (willFetch) {
      await _boundCallbacks?.setActionBusy(
        visible: true,
        label: '正在加载版本…',
      );
    }
    Map<String, dynamic>? options;
    try {
      options = await versionOptions(
        appId,
        env: _currentEnv,
        currentVersion: _currentVersion,
      );
    } finally {
      if (willFetch) {
        await _boundCallbacks?.setActionBusy(visible: false);
      }
    }
    if (options == null) return;
    final currentVersion = _currentVersion;
    if (currentVersion != null && currentVersion.isNotEmpty) {
      options['currentVersion'] = currentVersion;
    }
    await _boundCallbacks?.showVersionPicker(options: options, appId: appId);
  }

  /// 历史构建入口：顶层拉 `versionOptions` → 取当前 `currentVersion`/`currentEnv`
  /// → 顶层拉 `buildHistory` → 经 [DetailCallbacks.showBuildHistory] 弹构建历史。
  /// builds 形状与 registry（`script_ui_handler_registry.dart`
  /// `showBuildHistory`）一致：`List<Map<String, dynamic>>`。
  ///
  /// 版本/环境优先用本通道跟踪到的 `_currentVersion`/`_currentEnv`：pack 的
  /// `versionOptions` 缺省恒回退最新版本（见 `_currentVersion` 注释），切换版本后
  /// 仍会给出入口/最新版本 → 历史构建列表陈旧的根因。仅在未跟踪到时才回退到
  /// `versionOptions` 的 `currentVersion`/`currentEnv`。
  Future<void> _openBuildHistory() async {
    var version = _currentVersion ?? '';
    var env = _currentEnv ?? '';
    final needsOptions = version.isEmpty || env.isEmpty;
    final willFetchHistory =
        !_buildHistoryCache.containsKey(_buildHistoryKey(version, env));
    final willWait = needsOptions || willFetchHistory;
    if (willWait) {
      await _boundCallbacks?.setActionBusy(
        visible: true,
        label: needsOptions ? '正在加载版本…' : '正在加载构建历史…',
      );
    }
    Map<String, dynamic>? history;
    try {
      if (needsOptions) {
        final options = await versionOptions(appId, env: _currentEnv);
        if (options == null) return;
        if (version.isEmpty) {
          version = options['currentVersion']?.toString() ?? '';
        }
        if (env.isEmpty) {
          env = options['currentEnv']?.toString() ?? '';
        }
      }
      history = await buildHistory(appId: appId, version: version, env: env);
    } finally {
      if (willWait) {
        await _boundCallbacks?.setActionBusy(visible: false);
      }
    }
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
  /// `env`/`currentVersion` 为空时省略该键（pingan 侧会误判）。脚本未实现/失败
  /// → null。
  ///
  /// `currentVersion` 是"选择器应预选的当前版本"提示：pack 顶层 `versionOptions`
  /// 不回传它（见 [_currentVersion]），故 [_openVersionPicker] 会用自持值覆盖
  /// 结果；此处仍原样转发给 facade（对支持回传的 pack 是增量、无害）。它是本类
  /// 扩展的可选参数，不改变 [IDetailChannel] 契约。
  @override
  Future<Map<String, dynamic>?> versionOptions(String appId,
      {String? env, String? currentVersion}) async {
    final cacheKey = _versionOptionsCacheKey(env);
    final cached = _versionOptionsCache[cacheKey];
    if (cached != null) return Map<String, dynamic>.from(cached);
    final options = await _facade.scriptVersionOptions(
      key: channelKey,
      appId: appId,
      env: env,
      currentVersion: currentVersion,
    );
    if (options == null) return null;
    final map = versionOptionsToMap(options);
    _versionOptionsCache[cacheKey] = map;
    return Map<String, dynamic>.from(map);
  }

  /// Warms [versionOptions] when the "更多" panel opens.
  ///
  /// The detail response normally already seeds the cache; this covers packs
  /// that do not return `extra.versionOptions`, without blocking the panel.
  Future<void> prefetchVersionOptions() async {
    if (_versionOptionsCache
        .containsKey(_versionOptionsCacheKey(_currentEnv))) {
      return;
    }
    try {
      await versionOptions(appId, env: _currentEnv);
    } catch (e) {
      debugPrint(
        '[RustScriptDetailChannel] versionOptions prefetch failed: $e',
      );
    }
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
    final detail = await _facade.scriptSwitchVersion(
      key: channelKey,
      appId: appId,
      env: env,
      version: version,
      buildJson: build == null ? null : jsonEncode(build),
    );
    if (detail == null) return null;
    // pack `switchVersion` :753-754 设其内部 `_currentEnv`/`_currentVersion`（env
    // 参数覆盖凭证默认 env）。返回的 detail 顶层未带 `version`（版本在
    // `extra.version`，由 buildDetailFromGroup 落），故回退到传入的 `version` 参数。
    _currentVersion = detail.version ?? version;
    _currentEnv = env;
    final map = _normalizeDetailMap(detailToMap(detail));
    _cacheHistoryFromDetail(map);
    _cacheVersionOptionsFromDetail(map);
    return map;
  }

  /// 指定版本历史构建（脚本 detail.js 的 `buildHistory`）→ `{builds: [...]}`；
  /// 脚本未实现/无构建 → 空 `builds` 列表。
  @override
  Future<Map<String, dynamic>?> buildHistory({
    required String appId,
    required String version,
    required String env,
  }) async {
    final cacheKey = _buildHistoryKey(version, env);
    final cached = _buildHistoryCache[cacheKey];
    if (cached != null) {
      return <String, dynamic>{
        'builds': List<Object?>.from(cached['builds'] as List? ?? const []),
      };
    }
    final builds = await _facade.scriptBuildHistory(
      key: channelKey,
      appId: appId,
      env: env,
      version: version,
    );
    final map = <String, dynamic>{
      'builds': [for (final build in builds) buildToMap(build)],
    };
    _buildHistoryCache[cacheKey] = map;
    return <String, dynamic>{
      'builds': List<Object?>.from(map['builds'] as List)
    };
  }

  /// Normalize script detail text: old pingan packs put the query appId in
  /// `description` while the real intro stayed in `des`; script detail also
  /// often has no `readme`, so surface the description as the intro section.
  ///
  /// The pack's channel-specific fields (`builtBy`, `num`, `installTimes`,
  /// `env`, ...) live in the nested `extra` object, while the page's
  /// `IDetailInfo.extra` contract is flat. Promote them without overwriting the
  /// typed top-level keys; the nested map is kept for `versionHistory` reads.
  Map<String, dynamic> _normalizeDetailMap(Map<String, dynamic> detail) {
    final nested = detail['extra'];
    if (nested is Map) {
      nested.forEach((key, value) {
        detail.putIfAbsent(key.toString(), () => value);
      });
    }
    final appId = detail['appId']?.toString() ?? '';
    final packageName = detail['packageName']?.toString() ?? '';
    final des = detail['des']?.toString() ?? '';
    var description = detail['description']?.toString() ?? '';
    if (description.isEmpty ||
        description == appId ||
        (packageName.isNotEmpty && description == packageName)) {
      if (des.isNotEmpty) description = des;
    }
    if (description.trim().isNotEmpty) {
      detail['description'] = description;
      final sections = detail['sections'];
      final hasDetailSection = sections is List &&
          sections.any(
              (section) => section == 'readme' || section == 'screenshots');
      final readme = detail['readme']?.toString() ?? '';
      if (hasDetailSection && readme.trim().isEmpty) {
        detail['readme'] = description;
      }
    }
    return detail;
  }

  String _versionOptionsCacheKey(String? env) =>
      (env == null || env.isEmpty) ? '__default__' : env;

  String _buildHistoryKey(String version, String env) =>
      '$version|${env.isEmpty ? 'sit' : env}';

  void _cacheHistoryFromDetail(Map<String, dynamic> detail) {
    final version = _currentVersion;
    final env = _currentEnv;
    if (version == null || version.isEmpty) return;
    final extra = detail['extra'];
    if (extra is! Map) return;
    final history = extra['versionHistory'];
    if (history is! List || history.isEmpty) return;
    _buildHistoryCache[_buildHistoryKey(version, env ?? '')] =
        <String, dynamic>{
      'builds': [
        for (final item in history)
          item is Map ? Map<String, dynamic>.from(item) : item,
      ],
    };
  }

  void _cacheVersionOptionsFromDetail(Map<String, dynamic> detail) {
    final extra = detail['extra'];
    if (extra is! Map) return;
    final raw = extra['versionOptions'];
    if (raw is! Map) return;
    final options = Map<String, dynamic>.from(raw);
    final versions = raw['versions'];
    if (versions is List) {
      options['versions'] =
          versions.map((entry) {
            return entry is Map
                ? Map<String, dynamic>.from(entry)
                : entry;
          }).toList();
    }
    _versionOptionsCache[_versionOptionsCacheKey(_currentEnv)] = options;
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

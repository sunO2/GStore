import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:gstore/core/catalog/catalog_facade.dart' show appSummaryFromRust;
import 'package:gstore/core/channel/rust_channel_facade.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';

/// Read-only, process-wide view of the Rust script-pack lane for the UI.
///
/// While `CoreFlags.jsChannel` is on the Rust `ScriptApi` owns script packs and
/// no Dart `JsChannel` is registered, so the discovery grid, the settings
/// "已导入渠道" list and the detail page cannot read
/// `ChannelManager.instance.dynamicChannels` (always empty after the flip).
/// This lane caches `ScriptApi.list()` so those synchronous UI reads see the
/// installed packs.
///
/// It owns no policy and writes nothing: the cache is refreshed explicitly
/// (startup load, import, delete, discovery reload, settings open) and never
/// touches the Dart channel registry. While the flag is off [packs] is empty
/// and every read falls back to the legacy `ChannelManager` list.
class RustScriptChannelLane {
  RustScriptChannelLane({ScriptApi? api}) : _apiOverride = api;

  static RustScriptChannelLane _instance = RustScriptChannelLane();

  /// Process-wide lane (production).
  static RustScriptChannelLane get instance => _instance;

  /// Replaces the process-wide lane. Tests only.
  @visibleForTesting
  static void installForTest(RustScriptChannelLane lane) => _instance = lane;

  /// Restores the production lane. Tests only.
  @visibleForTesting
  static void resetForTest() => _instance = RustScriptChannelLane();

  final ScriptApi? _apiOverride;

  List<rust_pack.ScriptPackInfo> _packs = const [];
  Object? _loadError;

  ScriptApi get _api => _apiOverride ?? ScriptApi.instance;

  /// Whether the Rust lane owns script packs right now.
  bool get enabled => CoreFlags.jsChannel;

  /// Cached installed packs (empty while the flag is off or before refresh).
  List<rust_pack.ScriptPackInfo> get packs => List.unmodifiable(_packs);

  /// Whether the last [refresh] failed to read the Rust lane.
  ///
  /// When this is true an empty [packs] means "unavailable", not "none
  /// installed" — the failure must never be indistinguishable from an empty
  /// lane. Callers that surface counts can consult this instead of silently
  /// showing zero channels.
  bool get hasLoadError => _loadError != null;

  /// The reason the last [refresh] failed, or null when it succeeded.
  String? get loadError => _loadError?.toString();

  /// Installed pack channel codes (`js_<stem>`), in the lane's key order.
  List<String> get codes =>
      _packs.map((pack) => pack.key).toList(growable: false);

  /// The cached pack for [code], or null when it is not a Rust-lane pack.
  rust_pack.ScriptPackInfo? packFor(String code) {
    for (final pack in _packs) {
      if (pack.key == code) return pack;
    }
    return null;
  }

  /// Refreshes the cache from the Rust lane. No-op (and clears the cache) while
  /// the flag is off, so the flag-off UI keeps reading only Dart channels.
  ///
  /// The Rust `ScriptApi.list()` reads the core `channel_packs` table and is only
  /// valid after `ScriptApi.init()` has opened the DB. At import time that has
  /// happened (`ScriptChannelService.importPack` initialises first), but at
  /// STARTUP nothing has — so the lane ensures the shared service is initialised
  /// before reading. Without this the read failed, the error was swallowed, and
  /// an installed pack vanished on restart ("重启之后也没有了").
  ///
  /// Best-effort: a failure is logged at error level and recorded in
  /// [hasLoadError]/[loadError] rather than thrown, and the previous cache is
  /// kept — an empty result must not masquerade as "no packs installed".
  Future<void> refresh() async {
    if (!enabled) {
      _packs = const [];
      _loadError = null;
      return;
    }
    try {
      await ScriptChannelService.instance.ensureInitialized();
      _packs = await _api.list();
      _loadError = null;
    } catch (error) {
      _loadError = error;
      appLog.error('RustScriptChannelLane: 读取 Rust 脚本通道失败: $error');
    }
  }

  /// Runs the pack's search entry point and maps the result to [AppSummary].
  ///
  /// Reads the unified channel path — `RustChannelFacade.search` (the same
  /// `ChannelApi.search` every other channel uses), mapping the typed
  /// `rust.ChannelAppInfo` result to [AppSummary] via [appSummaryFromRust].
  /// When the pack does not implement `searchApps` (the driver answers nothing,
  /// or raises), it falls back to `getAllApps` + a local name/des/appId filter —
  /// the same semantics as Dart `JsChannel.searchApps`. It never filters the
  /// saved `channel_apps` rows, so a freshly imported pack (no saved rows yet)
  /// is still searchable. While the flag is off this returns an empty list.
  Future<List<AppSummary>> searchApps(String code, String keyword) async {
    if (!enabled) return const [];
    final facade = RustChannelFacade.instance;
    List<AppSummary>? searched;
    try {
      final results = await facade.search(
        key: code,
        keyword: keyword,
        forceRefresh: false,
      );
      searched = results.map(appSummaryFromRust).toList(growable: false);
    } catch (_) {
      // The driver raised (e.g. the pack does not implement `searchApps`):
      // fall through to the `getAllApps` fallback below.
      searched = null;
    }
    if (searched != null && searched.isNotEmpty) return searched;
    // Script未实现 searchApps → 降级：跑 getAllApps 取全量后本地过滤
    // （与 JsChannel.searchApps 同一语义）。
    final List<AppSummary> all;
    try {
      final results =
          await facade.getAllApps(key: code, forceRefresh: false);
      all = results.map(appSummaryFromRust).toList(growable: false);
    } catch (_) {
      return const [];
    }
    final kw = keyword.toLowerCase();
    return all
        .where((app) =>
            app.name.toLowerCase().contains(kw) ||
            app.des.toLowerCase().contains(kw) ||
            app.appId.toLowerCase().contains(kw))
        .toList();
  }

  /// Returns the saved apps for [code] mapped to [AppSummary].
  ///
  /// Mirrors `JsChannel.getAllApps` (reads the channel's saved rows) for the
  /// Rust lane: `ScriptApi.storedApps` returns the `channel_apps` rows as a JSON
  /// array. While the flag is off this returns an empty list.
  Future<List<AppSummary>> storedApps(String code) async {
    if (!enabled) return const [];
    final raw = await _api.storedApps(key: code);
    return decodeStoredApps(raw);
  }

  /// Inserts [app] into [code]'s saved `channel_apps` rows through the Rust
  /// script lane — the same rows [storedApps] reads.
  ///
  /// Mirrors Dart `JsChannel.addApp` for the Rust lane: the row is written to
  /// the script domain's `channel_apps` table (never the channels domain), so a
  /// `js_*` pack never has to be registered as a channel. The [AppSummary] is
  /// mapped field-for-field to the FRB `ChannelAppInfo` (no invented values).
  /// While the flag is off this refuses via [ScriptApi].
  Future<void> addApp(String code, AppSummary app) async {
    if (!enabled) {
      throw const ScriptApiDisabledException();
    }
    await _api.addApp(key: code, app: channelAppInfoFromSummary(app));
  }

  /// Decodes the `ScriptApi.storedApps` JSON payload (snake_case `AppSummary`
  /// rows) into [AppSummary]. Exposed for tests.
  @visibleForTesting
  static List<AppSummary> decodeStoredApps(String raw) {
    if (raw.trim().isEmpty) return const [];
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final apps = <AppSummary>[];
    for (final item in decoded) {
      if (item is Map) apps.add(_summaryFromRustRow(item));
    }
    return apps;
  }

  static AppSummary _summaryFromRustRow(Map<Object?, Object?> row) {
    final extra = row['extra'];
    return AppSummary(
      appId: row['app_id']?.toString() ?? '',
      packageName: _nonEmpty(row['package_name']?.toString()),
      name: row['name']?.toString() ?? '',
      user: row['user']?.toString() ?? '',
      repositories: row['repositories']?.toString() ?? '',
      icon: row['icon']?.toString() ?? '',
      des: row['des']?.toString() ?? '',
      readme: _nonEmpty(row['readme']?.toString()),
      category: _categoryList(row['category']),
      extra:
          extra is Map ? extra.map((k, v) => MapEntry(k.toString(), v)) : null,
    );
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  static List<String>? _categoryList(Object? raw) {
    if (raw is List) {
      final items = raw
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty)
          .toList();
      return items.isEmpty ? null : items;
    }
    if (raw is String && raw.isNotEmpty) {
      final items = raw
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
      return items.isEmpty ? null : items;
    }
    return null;
  }
}

/// Maps [AppSummary] to the FRB `rust.ChannelAppInfo`, mirroring Rust
/// `ChannelAppInfo::from_summary`: `category` defaults to an empty list, `extra`
/// is encoded as a JSON object string (null stays null), `labels` passes through
/// field-for-field (empty stays empty), and the rest pass through verbatim — no
/// field is invented.
rust.ChannelAppInfo channelAppInfoFromSummary(AppSummary app) =>
    rust.ChannelAppInfo(
      appId: app.appId,
      packageName: app.packageName,
      name: app.name,
      user: app.user,
      repositories: app.repositories,
      icon: app.icon,
      des: app.des,
      readme: app.readme,
      category: app.category ?? const <String>[],
      extraJson: app.extra == null ? null : jsonEncode(app.extra),
      labels: app.labels
          .map((label) => rust.ChannelLabel(
                key: label.key,
                label: label.label,
                value: label.value,
                icon: label.icon,
              ))
          .toList(growable: false),
    );

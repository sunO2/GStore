import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/script_api.dart';

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

  ScriptApi get _api => _apiOverride ?? ScriptApi.instance;

  /// Whether the Rust lane owns script packs right now.
  bool get enabled => CoreFlags.jsChannel;

  /// Cached installed packs (empty while the flag is off or before refresh).
  List<rust_pack.ScriptPackInfo> get packs => List.unmodifiable(_packs);

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
  Future<void> refresh() async {
    if (!enabled) {
      _packs = const [];
      return;
    }
    try {
      _packs = await _api.list();
    } catch (error) {
      appLog.error('RustScriptChannelLane: 读取 Rust 脚本通道失败: $error');
    }
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

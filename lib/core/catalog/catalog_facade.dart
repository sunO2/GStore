/// Flag-gated facade over the core catalog.
///
/// `CoreFlags.catalog == false` routes every call to the legacy Dart
/// `LocalDbChannel`; `true` routes to the FRB `CatalogApi`. Tests install fake
/// backends through the constructor or the [backendOverride] seams, so no
/// native library is required.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/impl/LocalDbChannel.dart';
import 'package:gstore/core/channel/model/ChannelResult.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/IDetailInfo.dart';
import 'package:gstore/core/rust/RustBridge.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/db/apps/AppInfo.dart' as db;

/// One page of catalog apps plus the unpaged total.
class CatalogPageData {
  const CatalogPageData({required this.apps, required this.total});

  final List<AppSummary> apps;
  final int total;
}

/// Outcome of a catalog refresh.
class CatalogRefreshOutcome {
  const CatalogRefreshOutcome(
      {required this.changed, required this.eventsJson});

  final bool changed;

  /// Serialized `catalog.changed` event when the catalog changed, else `"null"`.
  final String eventsJson;
}

/// Injectable catalog transport seam.
abstract class CatalogBackend {
  Future<List<AppSummary>> list();

  Future<CatalogPageData> listPage({required int offset, required int limit});

  Future<List<AppSummary>> search(String keyword);

  Future<AppSummary?> getApp(String appId);

  Future<List<db.AppCategory>> categories();

  Future<List<AppSummary>> byCategory(String categoryId);

  Future<AppDetailInfo?> getAppDetail(String appId);

  Future<CatalogRefreshOutcome> refresh(String url);
}

/// Production FRB backend. The `CatalogApi` handle is created lazily.
class FrbCatalogBackend implements CatalogBackend {
  FrbCatalogBackend({this.dataDir, this.filesDir, this.cacheDir});

  final String? dataDir;
  final String? filesDir;
  final String? cacheDir;

  rust.CatalogApi? _api;
  Future<rust.CatalogApi>? _pending;

  Future<rust.CatalogApi> _ensureApi() {
    final existing = _api;
    if (existing != null) return Future.value(existing);
    return _pending ??= _create();
  }

  Future<rust.CatalogApi> _create() async {
    try {
      await RustBridge.ensureInitialized();
      final dirs = await _resolveDirs();
      final api = await rust.CatalogApi.init(
        dataDir: dirs.$1,
        filesDir: dirs.$2,
        cacheDir: dirs.$3,
      );
      _api = api;
      return api;
    } finally {
      _pending = null;
    }
  }

  Future<(String, String, String)> _resolveDirs() async {
    if (dataDir != null && filesDir != null && cacheDir != null) {
      return (dataDir!, filesDir!, cacheDir!);
    }
    final support = await getApplicationSupportDirectory();
    final root = '${support.path}/gstore_core';
    return ('$root/data', '$root/files', '$root/cache');
  }

  Future<T> _call<T>(Future<T> Function(rust.CatalogApi api) action) async {
    final api = await _ensureApi();
    return action(api);
  }

  @override
  Future<List<AppSummary>> list() => _call((api) => api.list()).then(_mapApps);

  @override
  Future<CatalogPageData> listPage({required int offset, required int limit}) =>
      _call((api) => api.listPage(offset: offset, limit: limit)).then(
        (page) => CatalogPageData(
          apps: page.apps.map(appSummaryFromRust).toList(growable: false),
          total: page.total.toInt(),
        ),
      );

  @override
  Future<List<AppSummary>> search(String keyword) =>
      _call((api) => api.search(keyword: keyword)).then(_mapApps);

  @override
  Future<AppSummary?> getApp(String appId) async {
    final info = await _call((api) => api.getApp(appId: appId));
    return info == null ? null : appSummaryFromRust(info);
  }

  @override
  Future<List<db.AppCategory>> categories() =>
      _call((api) => api.categories()).then(
        (items) => items
            .map((item) => db.AppCategory(item.id, item.description, item.icon))
            .toList(growable: false),
      );

  @override
  Future<List<AppSummary>> byCategory(String categoryId) =>
      _call((api) => api.byCategory(categoryId: categoryId)).then(_mapApps);

  @override
  Future<AppDetailInfo?> getAppDetail(String appId) async {
    final detail = await _call((api) => api.getAppDetail(appId: appId));
    return detail == null ? null : appDetailFromRust(detail);
  }

  @override
  Future<CatalogRefreshOutcome> refresh(String url) async {
    final report = await _call((api) => api.refresh(url: url));
    return CatalogRefreshOutcome(
      changed: report.changed,
      eventsJson: report.eventsJson,
    );
  }

  List<AppSummary> _mapApps(List<rust.ChannelAppInfo> apps) =>
      apps.map(appSummaryFromRust).toList(growable: false);
}

/// Legacy backend over the Dart `LocalDbChannel`.
class LegacyCatalogBackend implements CatalogBackend {
  LegacyCatalogBackend({LocalDbChannel? channel}) : _injected = channel;

  final LocalDbChannel? _injected;
  LocalDbChannel? _resolved;

  LocalDbChannel get _channel {
    final injected = _injected;
    if (injected != null) return injected;
    final resolved = _resolved;
    if (resolved != null) return resolved;
    final fromManager = ChannelManager.instance.getChannel(ChannelType.localDb);
    if (fromManager is LocalDbChannel) {
      _resolved = fromManager;
      return fromManager;
    }
    throw StateError('LocalDbChannel 尚未初始化');
  }

  static Never _failed(ChannelResult<Object?> result) =>
      throw StateError(result.error ?? 'local db channel failed');

  static T _unwrap<T>(ChannelResult<T> result) {
    if (!result.success) _failed(result);
    return result.data as T;
  }

  @override
  Future<List<AppSummary>> list() async => _unwrap(await _channel.getAllApps());

  @override
  Future<CatalogPageData> listPage(
      {required int offset, required int limit}) async {
    final all = await list();
    final total = all.length;
    final start = offset < 0 ? 0 : offset;
    if (start >= total || limit <= 0) {
      return CatalogPageData(apps: const <AppSummary>[], total: total);
    }
    final end = (start + limit).clamp(0, total);
    return CatalogPageData(apps: all.sublist(start, end), total: total);
  }

  @override
  Future<List<AppSummary>> search(String keyword) async =>
      _unwrap(await _channel.searchApps(keyword));

  @override
  Future<AppSummary?> getApp(String appId) async =>
      _unwrap(await _channel.getAppInfo(appId));

  @override
  Future<List<db.AppCategory>> categories() async =>
      _unwrap(await _channel.getAllCategories());

  @override
  Future<List<AppSummary>> byCategory(String categoryId) async =>
      _unwrap(await _channel.searchByCategory(categoryId));

  @override
  Future<AppDetailInfo?> getAppDetail(String appId) async {
    final detail = _unwrap(await _channel.getAppDetail(appId));
    return appDetailFromLegacy(detail);
  }

  @override
  Future<CatalogRefreshOutcome> refresh(String url) async {
    final changed = _unwrap(await _channel.doUpdate());
    return CatalogRefreshOutcome(changed: changed, eventsJson: 'null');
  }
}

/// Maps one FRB app summary to the Dart model (same shape as
/// `ChannelManager._toAppSummary`).
AppSummary appSummaryFromRust(rust.ChannelAppInfo info) {
  Map<String, dynamic>? extra;
  final rawExtra = info.extraJson;
  if (rawExtra != null && rawExtra.trim().isNotEmpty) {
    final decoded = jsonDecode(rawExtra);
    if (decoded is Map<String, dynamic>) extra = decoded;
  }
  return AppSummary(
    appId: info.appId,
    packageName: info.packageName,
    name: info.name,
    user: info.user,
    repositories: info.repositories,
    icon: info.icon,
    des: info.des,
    readme: info.readme,
    category: info.category.isEmpty ? null : info.category,
    extra: extra,
  );
}

/// Maps one legacy detail payload to the Dart model.
AppDetailInfo appDetailFromLegacy(IDetailInfo detail) => AppDetailInfo(
      appId: detail.appId,
      name: detail.appName,
      icon: detail.icon,
      description: detail.description,
      version: detail.version,
      developer: detail.developer,
      packageName: detail.packageName,
      projectUrl: detail.projectUrl,
      channel: detail.channelType,
      sections: detail.sections,
      downloads: detail.downloads,
      extra: detail.extra,
    );

/// Maps one FRB detail payload to the Dart model.
AppDetailInfo appDetailFromRust(rust.ChannelAppDetailInfo info) {
  Map<String, dynamic> extra = <String, dynamic>{};
  if (info.extraJson.trim().isNotEmpty) {
    final decoded = jsonDecode(info.extraJson);
    if (decoded is Map<String, dynamic>) extra = decoded;
  }
  final sections = <DetailSection>[];
  for (final code in info.sections) {
    for (final section in DetailSection.values) {
      if (section.name == code) {
        sections.add(section);
        break;
      }
    }
  }
  return AppDetailInfo(
    appId: info.appId,
    name: info.name,
    icon: info.icon,
    description: info.description,
    version: info.version,
    developer: info.developer,
    packageName: info.packageName,
    projectUrl: info.projectUrl,
    channel: ChannelType.fromCode(info.channel) ?? ChannelType.custom,
    sections: sections,
    downloads: info.downloads
        .map(
          (download) => DownloadInfo(
            url: download.url,
            name: download.name,
            size: download.size?.toInt(),
            downloadCount: download.downloadCount?.toInt(),
            version: download.version,
            versionCode: download.versionCode?.toInt(),
            publishedAt: download.publishedAt == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(
                    download.publishedAt!.toInt(),
                  ),
            platform: download.platform,
            hash: download.hash,
            hashType: download.hashType,
            downloadable: download.downloadable,
            note: download.note,
          ),
        )
        .toList(growable: false),
    extra: extra,
  );
}

/// Flag-gated catalog facade.
class CatalogFacade {
  CatalogFacade({CatalogBackend? legacy, CatalogBackend? frb})
      : _legacy = legacy ?? LegacyCatalogBackend(),
        _frb = frb ?? FrbCatalogBackend();

  static CatalogFacade instance = CatalogFacade();

  /// Test seam: replaces the FRB backend without touching the legacy one.
  @visibleForTesting
  static CatalogBackend? backendOverride;

  /// Test seam: replaces the legacy backend without touching the FRB one.
  @visibleForTesting
  static CatalogBackend? legacyBackendOverride;

  final CatalogBackend _legacy;
  final CatalogBackend _frb;

  Future<bool> _enabled() async {
    try {
      await CoreFlags.refresh();
    } catch (_) {
      // Keep the last mirror; an unavailable flag backend must not arm a flag.
    }
    return CoreFlags.catalog;
  }

  Future<CatalogBackend> _backend() async => await _enabled()
      ? (backendOverride ?? _frb)
      : (legacyBackendOverride ?? _legacy);

  Future<List<AppSummary>> list() async => (await _backend()).list();

  Future<CatalogPageData> listPage(
          {required int offset, required int limit}) async =>
      (await _backend()).listPage(offset: offset, limit: limit);

  Future<List<AppSummary>> search(String keyword) async =>
      (await _backend()).search(keyword);

  Future<AppSummary?> getApp(String appId) async =>
      (await _backend()).getApp(appId);

  Future<List<db.AppCategory>> categories() async =>
      (await _backend()).categories();

  Future<List<AppSummary>> byCategory(String categoryId) async =>
      (await _backend()).byCategory(categoryId);

  Future<AppDetailInfo?> getAppDetail(String appId) async =>
      (await _backend()).getAppDetail(appId);

  /// Refreshes the catalog and returns the `catalog.changed` event JSON
  /// (`"null"` when nothing changed / on the legacy path).
  Future<CatalogRefreshOutcome> refresh(String url) async =>
      (await _backend()).refresh(url);
}

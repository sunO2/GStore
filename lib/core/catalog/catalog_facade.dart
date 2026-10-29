/// Facade over the core catalog.
///
/// The legacy Dart `LocalDbChannel` catalog store was removed; every call
/// routes to the FRB `CatalogApi` through [FrbCatalogBackend]. Tests install a
/// fake backend through the constructor or the [backendOverride] seam, so no
/// native library is required.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/model/AppDetailInfo.dart';
import 'package:gstore/core/model/AppSummary.dart';
import 'package:gstore/core/model/detail_extra_keys.dart';
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

  // ---- 版本化目录仓库（Rust 拥有 `<data_dir>/catalog_repo`）----

  /// 当前仓库快照（当前版本、条目、apps/categories 计数）。
  Future<rust.CatalogRepoStatus> repoStatus();

  /// 登记随包 seed（Rust 校验 + sha256 内容寻址 + 去重）。
  Future<rust.CatalogRepoStatus> repoEnsureSeed({required String path});

  /// 下载远端目录库；校验失败会抛错且不切换当前版本。
  Future<rust.CatalogRepoDownload> repoDownload({required String url});

  /// 切换当前版本。
  Future<rust.CatalogRepoStatus> repoSelect({required String version});

  /// 必要时把当前版本物化进 core `apps`/`category`。
  Future<rust.CatalogMaterializeResult> repoMaterialize();
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

  @override
  Future<rust.CatalogRepoStatus> repoStatus() =>
      _call((api) => api.repoStatus());

  @override
  Future<rust.CatalogRepoStatus> repoEnsureSeed({required String path}) =>
      _call((api) => api.repoEnsureSeed(path: path));

  @override
  Future<rust.CatalogRepoDownload> repoDownload({required String url}) =>
      _call((api) => api.repoDownload(url: url));

  @override
  Future<rust.CatalogRepoStatus> repoSelect({required String version}) =>
      _call((api) => api.repoSelect(version: version));

  @override
  Future<rust.CatalogMaterializeResult> repoMaterialize() =>
      _call((api) => api.repoMaterialize());

  List<AppSummary> _mapApps(List<rust.ChannelAppInfo> apps) =>
      apps.map(appSummaryFromRust).toList(growable: false);
}

/// Maps FRB `ChannelLabel`s to the Dart [AppLabel] model — field-for-field, no
/// synthesis. Empty in ⇒ empty out.
List<AppLabel> _labelsFromRust(List<rust.ChannelLabel> labels) => labels
    .map((label) => AppLabel(
          key: label.key,
          label: label.label,
          value: label.value,
          icon: label.icon,
        ))
    .toList(growable: false);

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
    labels: _labelsFromRust(info.labels),
  );
}

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
          (download) {
            final size = download.size?.toInt();
            final count = download.downloadCount?.toInt();
            return DownloadInfo(
              url: download.url,
              name: download.name,
              size: size,
              downloadCount: count,
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
              extra: <String, DownloadTag>{
                DownloadItemExtra.size: DownloadTag(
                  text: formatFileSize(size),
                  iconName: 'sd_storage',
                ),
                DownloadItemExtra.platform: DownloadTag(
                  text: download.platform ?? '',
                  iconName: 'phone_android',
                ),
                DownloadItemExtra.version: DownloadTag(
                  text: download.version ?? '',
                  iconName: 'tag',
                ),
                DownloadItemExtra.downloadCount: DownloadTag(
                  text: formatFileCount(count),
                  iconName: 'download',
                ),
              },
            );
          },
        )
        .toList(growable: false),
    extra: extra,
    labels: _labelsFromRust(info.labels),
  );
}

/// Catalog facade over the core (FRB) backend.
class CatalogFacade {
  CatalogFacade({CatalogBackend? frb}) : _frb = frb ?? FrbCatalogBackend();

  static CatalogFacade instance = CatalogFacade();

  /// Test seam: replaces the core backend.
  @visibleForTesting
  static CatalogBackend? backendOverride;

  final CatalogBackend _frb;

  Future<CatalogBackend> _backend() async => backendOverride ?? _frb;

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
  /// (`"null"` when nothing changed).
  Future<CatalogRefreshOutcome> refresh(String url) async =>
      (await _backend()).refresh(url);

  // ---- 版本化目录仓库（Rust 拥有 `<data_dir>/catalog_repo`）----

  Future<rust.CatalogRepoStatus> repoStatus() async =>
      (await _backend()).repoStatus();

  Future<rust.CatalogRepoStatus> repoEnsureSeed({required String path}) async =>
      (await _backend()).repoEnsureSeed(path: path);

  Future<rust.CatalogRepoDownload> repoDownload({required String url}) async =>
      (await _backend()).repoDownload(url: url);

  Future<rust.CatalogRepoStatus> repoSelect({required String version}) async =>
      (await _backend()).repoSelect(version: version);

  Future<rust.CatalogMaterializeResult> repoMaterialize() async =>
      (await _backend()).repoMaterialize();
}

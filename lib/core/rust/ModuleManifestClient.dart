// 与 lib/core/rust/ 既有桥接文件命名约定一致（PascalCase）。
// `file_names` 是项目既有噪音（同目录多个文件同样触发），此处显式豁免，
// 避免新增分析诊断。
// ignore_for_file: file_names

import 'dart:async';
import 'dart:convert' show jsonDecode, utf8;
import 'dart:io';
import 'dart:typed_data' show BytesBuilder, Uint8List;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;

import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManifest.dart';

/// `it_tools.json` 的强类型视图：`{contentHash, asset, size}`。
///
/// 防御式解析：任一字段缺失/类型错误 → 返回 null（绝不抛异常）。
class ItToolsManifest {
  /// 离线包 zip 字节的 SHA-256（十六进制小写）。
  final String contentHash;

  /// Release 资产名（编译脚本固定为 `it-tools.zip`）。
  final String asset;

  /// 资产字节数。
  final int size;

  const ItToolsManifest({
    required this.contentHash,
    required this.asset,
    required this.size,
  });

  static ItToolsManifest? tryFromJson(Object? json) {
    if (json is! Map) return null;

    final contentHash = json['contentHash'];
    final asset = json['asset'];
    if (contentHash is! String || contentHash.isEmpty) return null;
    if (asset is! String || asset.isEmpty) return null;

    final size = _asInt(json['size']);
    if (size == null || size < 0) return null;

    return ItToolsManifest(
      contentHash: contentHash,
      asset: asset,
      size: size,
    );
  }
}

/// IT-Tools 离线包 zip 在 Release 中的定位结果
/// （`browser_download_url` + `it_tools.json` 的完整性元数据）。
///
/// 与 [ItToolsManifest] 的区别：后者是清单正文的强类型视图，本类是
/// 「同一 Release 资产表中命中的 zip URL」——URL **不**由 `$base/<asset>` 拼接。
class ItToolsAssetLocation {
  /// Release 资产的 `browser_download_url`。
  final String url;

  /// 清单记录的 zip SHA-256（十六进制小写）。
  final String contentHash;

  /// 清单记录的 zip 字节数。
  final int size;

  /// 清单记录的资产名（编译脚本固定为 `it-tools.zip`）。
  final String asset;

  const ItToolsAssetLocation({
    required this.url,
    required this.contentHash,
    required this.size,
    required this.asset,
  });
}

/// 当前 ABI 的模块资产定位结果（Release 资产 URL + 清单完整性元数据）。
class ModuleAssetLocation {
  /// Release 资产的 `browser_download_url`（**不**由 `$base/<abi>/<file>` 拼接）。
  final String url;

  /// 清单记录的资产名（如 `libgstore_mod_qr_1.0.0-arm64-v8a.so`）。
  final String asset;

  /// 清单记录的 SHA-256（十六进制小写）。
  final String sha256;

  /// 清单记录的字节数。
  final int size;

  /// 清单记录的模块版本。
  final String version;

  /// 解析命中的 ABI。
  final String abi;

  const ModuleAssetLocation({
    required this.url,
    required this.asset,
    required this.sha256,
    required this.size,
    required this.version,
    required this.abi,
  });
}

/// 清单信任锚 + Release 解析器（实现 [ModuleManifestSource]）。
///
/// 安全约束（见 `.omo/plans/remote-plugin-download.md` Todo 8）：
///
/// * **独立通道**：仅用 `dart:io HttpClient`，保持**默认证书校验**，
///   既不设置任何禁用证书校验的回调，也不施加任何代理前缀。
/// * **不使用**项目内基于 Dio/rhttp 且关闭了证书校验的 GitHub 客户端
///   （它们允许自签名证书并带代理逻辑，会污染信任锚）。
/// * `modules.json` 与 `it_tools.json` 均来自 `sunO2/GStore` 的同一 Release，
///   经同一未代理、校验证书的客户端获取。
/// * 仅稳定版：`releases/latest` 返回 `prerelease == true` 时视为无可用 Release。
/// * ABI 资产 URL 取自 Release 的 `assets[].browser_download_url`（按清单资产名
///   精确匹配），**不假设** `$base/<abi>/<file>`。
/// * 磁盘缓存 `…/gstore_modules/_cache/{modules.json,.etag,.fetchedAt}`，
///   TTL 24h；`If-None-Match` 304 复用；403/离线/超时回退缓存；无缓存 → null。
///   清单资产 404 → 失效缓存并**恰好重解析一次**。
/// * 任何解析/网络失败一律返回 null/缓存，**绝不抛异常**。
class ModuleManifestClient implements ModuleManifestSource {
  /// 默认 Release 解析入口（稳定版 `releases/latest`）。
  static const String defaultReleasesUrl =
      'https://api.github.com/repos/sunO2/GStore/releases/latest';

  /// 免 API 的稳定资产直链前缀（`releases/latest/download/<asset>`）。
  ///
  /// Release 资产表不可用（403 限流 / 离线 / 被拦截）时回退使用：清单正文有磁盘
  /// 缓存而资产表仅在内存，缺此回退会「清单可读但下载必失败」。
  static const String defaultDownloadsBaseUrl =
      'https://github.com/sunO2/GStore/releases/latest/download';

  /// 清单缓存 TTL（24h）。
  static const Duration defaultTtl = Duration(hours: 24);

  /// 单次 HTTP 请求默认超时。
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// `modules.json` 的 Release 资产名（精确匹配）。
  static const String modulesAssetName = 'modules.json';

  /// `it_tools.json` 的 Release 资产名（精确匹配）。
  static const String itToolsAssetName = 'it_tools.json';

  /// 清单/Release JSON 的大小上限（防止被超大响应拖垮）。
  static const int maxAssetBytes = 4 * 1024 * 1024;

  /// 缓存目录后缀：`<support>/gstore_modules/_cache`。
  static const String cacheDirRelativePath = 'gstore_modules/_cache';

  final Uri _releasesUrl;
  final String _downloadsBaseUrl;
  final HttpClient Function() _clientFactory;
  final Future<String> Function() _abiProvider;
  final Future<Directory> Function() _supportDirProvider;
  final DateTime Function() _clock;
  final Duration _ttl;
  final Duration _timeout;

  /// 最近一次成功解析的 Release 资产表（name → 资产），会话内复用。
  _ReleaseInfo? _release;

  ModuleManifestClient({
    Uri? releasesUrl,
    String? downloadsBaseUrl,
    HttpClient Function()? clientFactory,
    Future<String> Function()? abiProvider,
    Future<Directory> Function()? supportDirProvider,
    DateTime Function()? clock,
    Duration ttl = defaultTtl,
    Duration timeout = defaultTimeout,
  })  : _releasesUrl = releasesUrl ?? Uri.parse(defaultReleasesUrl),
        _downloadsBaseUrl = downloadsBaseUrl ?? defaultDownloadsBaseUrl,
        _clientFactory = clientFactory ?? HttpClient.new,
        _abiProvider =
            abiProvider ?? (() => RustModuleLoader.instance.deviceAbi()),
        _supportDirProvider = supportDirProvider ?? getApplicationSupportDirectory,
        _clock = clock ?? DateTime.now,
        _ttl = ttl,
        _timeout = timeout;

  // ---------------------------------------------------------------------------
  // ModuleManifestSource
  // ---------------------------------------------------------------------------

  /// 加载 v2 清单。缓存新鲜（未过期）且未强制刷新时**零网络**；否则按 TTL/ETag
  /// 重新校验；网络失败回退已校验缓存；无缓存 → null。绝不抛异常。
  @override
  Future<ModuleManifestV2?> load({bool forceRefresh = false}) async {
    try {
      return await _load(forceRefresh: forceRefresh);
    } catch (e) {
      debugPrint('ModuleManifestClient: 加载清单失败 - $e');
      return null;
    }
  }

  Future<ModuleManifestV2?> _load({required bool forceRefresh}) async {
    final cache = await _readManifestCache();
    final now = _clock();

    if (!forceRefresh && cache != null && _isFresh(cache.fetchedAt, now)) {
      return cache.manifest;
    }

    try {
      final result = await _fetchManifestAsset(
        modulesAssetName,
        ifNoneMatch: cache?.etag,
      );

      if (result.status == HttpStatus.notModified) {
        if (cache == null) return null;
        // 304：复用缓存正文，仅刷新 fetchedAt（不再下载 body）。
        await _writeManifestCache(cache.raw, cache.etag, now);
        return cache.manifest;
      }

      if (result.status == HttpStatus.ok && result.body != null) {
        final text = utf8.decode(result.body!);
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) {
          debugPrint('ModuleManifestClient: modules.json 不是对象');
          return cache?.manifest;
        }
        final manifest = ModuleManifestV2.fromJson(decoded);
        await _writeManifestCache(text, result.etag, now);
        return manifest;
      }

      // 404/403/超时/离线 → 回退已校验缓存；无缓存 → null。
      return cache?.manifest;
    } on ModuleManifestFormatException catch (e) {
      debugPrint('ModuleManifestClient: modules.json 格式不支持 - ${e.message}');
      return cache?.manifest;
    } catch (e) {
      debugPrint('ModuleManifestClient: modules.json 获取失败 - $e');
      return cache?.manifest;
    }
  }

  // ---------------------------------------------------------------------------
  // IT-Tools 清单
  // ---------------------------------------------------------------------------

  /// 加载并解析同 Release 的 `it_tools.json`（`{contentHash, asset, size}`）。
  /// 缓存/网络语义与 [load] 一致，失败返回 null，绝不抛异常。
  Future<ItToolsManifest?> loadItToolsManifest({bool forceRefresh = false}) async {
    try {
      return await _loadItTools(forceRefresh: forceRefresh);
    } catch (e) {
      debugPrint('ModuleManifestClient: 加载 it_tools.json 失败 - $e');
      return null;
    }
  }

  Future<ItToolsManifest?> _loadItTools({required bool forceRefresh}) async {
    final cache = await _readItToolsCache();
    final now = _clock();

    if (!forceRefresh && cache != null && _isFresh(cache.fetchedAt, now)) {
      return cache.manifest;
    }

    try {
      final result = await _fetchManifestAsset(
        itToolsAssetName,
        ifNoneMatch: cache?.etag,
      );

      if (result.status == HttpStatus.notModified) {
        if (cache == null) return null;
        await _writeItToolsCache(cache.raw, cache.etag, now);
        return cache.manifest;
      }

      if (result.status == HttpStatus.ok && result.body != null) {
        final text = utf8.decode(result.body!);
        final parsed = ItToolsManifest.tryFromJson(jsonDecode(text));
        if (parsed == null) {
          debugPrint('ModuleManifestClient: it_tools.json 字段非法');
          return cache?.manifest;
        }
        await _writeItToolsCache(text, result.etag, now);
        return parsed;
      }

      return cache?.manifest;
    } catch (e) {
      debugPrint('ModuleManifestClient: it_tools.json 获取失败 - $e');
      return cache?.manifest;
    }
  }

  /// 定位同 Release 的 IT-Tools zip 资产（`it_tools.json` 的 `asset` 名在
  /// Release `assets[]` 中精确匹配），返回 zip 的 `browser_download_url` 与
  /// 完整性元数据。任何解析/网络失败 → null，绝不抛异常。
  ///
  /// 与 [locateModuleAsset] 一样：资产名未命中（Release 元数据陈旧）时失效
  /// Release 缓存并**恰好重解析一次**。
  Future<ItToolsAssetLocation?> locateItToolsAsset({
    bool forceRefresh = false,
  }) async {
    try {
      final manifest = await loadItToolsManifest(forceRefresh: forceRefresh);
      if (manifest == null) return null;

      var release = await _resolveRelease(force: false);
      var found = release?.assets[manifest.asset];
      if (found == null) {
        _release = null;
        release = await _resolveRelease(force: true);
        found = release?.assets[manifest.asset];
        if (found == null) return null;
      }

      return ItToolsAssetLocation(
        url: found.url,
        contentHash: manifest.contentHash,
        size: manifest.size,
        asset: manifest.asset,
      );
    } catch (e) {
      debugPrint('ModuleManifestClient: 定位 it-tools 资产失败 - $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 模块资产 URL
  // ---------------------------------------------------------------------------

  /// 当前 ABI 的模块资产 `browser_download_url`；无法解析 → null。
  Future<String?> moduleAssetUrl(
    String moduleName, {
    bool forceRefresh = false,
  }) async {
    final location = await locateModuleAsset(
      moduleName,
      forceRefresh: forceRefresh,
    );
    return location?.url;
  }

  /// 当前 ABI 的模块资产定位（URL + 清单 sha256/size/version）。
  ///
  /// 清单资产名在 Release `assets[]` 中精确匹配；若未命中（Release 元数据过期），
  /// 失效 Release 缓存并**恰好重解析一次**。
  Future<ModuleAssetLocation?> locateModuleAsset(
    String moduleName, {
    bool forceRefresh = false,
  }) async {
    try {
      final manifest = await load(forceRefresh: forceRefresh);
      if (manifest == null) {
        debugPrint('ModuleManifestClient: 定位 $moduleName 失败：清单不可用');
        return null;
      }

      final entry = manifest.entry(moduleName);
      if (entry == null) {
        debugPrint('ModuleManifestClient: 定位 $moduleName 失败：清单无该模块');
        return null;
      }

      final abi = await _abiProvider();
      final abiAsset = entry.forAbi(abi);
      if (abiAsset == null) {
        debugPrint('ModuleManifestClient: 定位 $moduleName 失败：清单无 ABI $abi'
            '（可用 ${entry.abi.keys.toList()}）');
        return null;
      }

      var release = await _resolveRelease(force: false);
      var found = release?.assets[abiAsset.asset];
      if (found == null) {
        // Release 元数据可能陈旧 → 失效并只重解析一次。
        _release = null;
        release = await _resolveRelease(force: true);
        found = release?.assets[abiAsset.asset];
      }
      if (found == null) {
        if (_downloadsBaseUrl.isEmpty) return null;
        final fallback =
            '$_downloadsBaseUrl/${Uri.encodeComponent(abiAsset.asset)}';
        debugPrint('ModuleManifestClient: 定位 $moduleName 资产表未命中，'
            '回退稳定直链 $fallback');
        return ModuleAssetLocation(
          url: fallback,
          asset: abiAsset.asset,
          sha256: abiAsset.sha256,
          size: abiAsset.size,
          version: entry.version,
          abi: abi,
        );
      }

      return ModuleAssetLocation(
        url: found.url,
        asset: abiAsset.asset,
        sha256: abiAsset.sha256,
        size: abiAsset.size,
        version: entry.version,
        abi: abi,
      );
    } catch (e) {
      debugPrint('ModuleManifestClient: 定位模块资产失败 - $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Release 解析
  // ---------------------------------------------------------------------------

  /// 拉取 Release 资产表；`prerelease == true` / 结构非法 → null。
  Future<_ReleaseInfo?> _resolveRelease({required bool force}) async {
    if (!force && _release != null) return _release;

    try {
      final result = await _httpGetAsset(_releasesUrl);
      if (result.status != HttpStatus.ok || result.body == null) return null;

      final decoded = jsonDecode(utf8.decode(result.body!));
      if (decoded is! Map) return null;

      // 稳定版语义：忽略 prerelease。
      if (decoded['prerelease'] == true) {
        debugPrint('ModuleManifestClient: releases/latest 为 prerelease，忽略');
        return null;
      }

      final rawAssets = decoded['assets'];
      if (rawAssets is! List) return null;

      final assets = <String, _ReleaseAsset>{};
      for (final item in rawAssets) {
        if (item is! Map) continue;
        final name = item['name'];
        final url = item['browser_download_url'];
        if (name is! String || name.isEmpty) continue;
        if (url is! String || url.isEmpty) continue;
        assets[name] = _ReleaseAsset(name: name, url: url);
      }

      final info = _ReleaseInfo(assets: assets);
      _release = info;
      return info;
    } catch (e) {
      debugPrint('ModuleManifestClient: 解析 Release 失败 - $e');
      return null;
    }
  }

  /// 按资产名获取清单资产；404 → 失效 Release 缓存并**恰好重解析一次**。
  Future<_AssetFetchResult> _fetchManifestAsset(
    String assetName, {
    String? ifNoneMatch,
  }) async {
    var release = await _resolveRelease(force: true);
    var asset = release?.assets[assetName];
    if (asset == null) return const _AssetFetchResult(status: 0);

    var result = await _httpGetAsset(
      Uri.parse(asset.url),
      ifNoneMatch: ifNoneMatch,
    );

    if (result.status == HttpStatus.notFound) {
      _release = null;
      release = await _resolveRelease(force: true);
      asset = release?.assets[assetName];
      if (asset == null) return const _AssetFetchResult(status: 0);
      result = await _httpGetAsset(
        Uri.parse(asset.url),
        ifNoneMatch: ifNoneMatch,
      );
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // HTTP
  // ---------------------------------------------------------------------------

  /// 单次 GET（默认证书校验、无代理、默认遵循重定向）。失败以 status 0 表示。
  Future<_AssetFetchResult> _httpGetAsset(
    Uri url, {
    String? ifNoneMatch,
  }) async {
    final client = _clientFactory();
    try {
      final request = await client.getUrl(url).timeout(_timeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'GStore-App/1.0');
      request.headers
          .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      if (ifNoneMatch != null && ifNoneMatch.isNotEmpty) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, ifNoneMatch);
      }

      final response = await request.close().timeout(_timeout);
      final status = response.statusCode;

      if (status != HttpStatus.ok) {
        await _drain(response);
        return _AssetFetchResult(status: status);
      }

      final builder = BytesBuilder();
      var received = 0;
      await for (final chunk in response.timeout(_timeout)) {
        received += chunk.length;
        if (received > maxAssetBytes) {
          return const _AssetFetchResult(status: 0);
        }
        builder.add(chunk);
      }

      final etag = response.headers.value(HttpHeaders.etagHeader);
      return _AssetFetchResult(
        status: status,
        body: builder.takeBytes(),
        etag: etag,
      );
    } on TimeoutException {
      return const _AssetFetchResult(status: 0);
    } on SocketException {
      return const _AssetFetchResult(status: 0);
    } on HttpException {
      return const _AssetFetchResult(status: 0);
    } catch (_) {
      return const _AssetFetchResult(status: 0);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _drain(HttpClientResponse response) async {
    try {
      await response.drain<void>();
    } catch (_) {
      // 仅用于释放连接，忽略错误。
    }
  }

  // ---------------------------------------------------------------------------
  // 磁盘缓存
  // ---------------------------------------------------------------------------

  Future<Directory> _cacheDir() async {
    final support = await _supportDirProvider();
    return Directory(p.join(support.path, cacheDirRelativePath));
  }

  bool _isFresh(DateTime? fetchedAt, DateTime now) {
    if (fetchedAt == null) return false;
    final age = now.difference(fetchedAt);
    return age < _ttl;
  }

  Future<_ManifestCache?> _readManifestCache() async {
    try {
      final dir = await _cacheDir();
      final file = File(p.join(dir.path, 'modules.json'));
      final raw = await _readText(file);
      if (raw == null || raw.isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final manifest = ModuleManifestV2.fromJson(decoded);
      final etag = await _readText(File(p.join(dir.path, '.etag')));
      final fetchedAt = _parseTime(
        await _readText(File(p.join(dir.path, '.fetchedAt'))),
      );
      return _ManifestCache(
        raw: raw,
        manifest: manifest,
        etag: _emptyToNull(etag),
        fetchedAt: fetchedAt,
      );
    } on ModuleManifestFormatException catch (e) {
      debugPrint('ModuleManifestClient: 缓存清单格式不支持 - ${e.message}');
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeManifestCache(
    String raw,
    String? etag,
    DateTime now,
  ) async {
    try {
      final dir = await _cacheDir();
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'modules.json')).writeAsString(raw, flush: true);
      await File(p.join(dir.path, '.etag')).writeAsString(etag ?? '', flush: true);
      await File(p.join(dir.path, '.fetchedAt'))
          .writeAsString(now.toIso8601String(), flush: true);
    } catch (_) {
      // 缓存写失败不影响本次解析结果。
    }
  }

  Future<_ItToolsCache?> _readItToolsCache() async {
    try {
      final dir = await _cacheDir();
      final raw = await _readText(File(p.join(dir.path, 'it_tools.json')));
      if (raw == null || raw.isEmpty) return null;

      final parsed = ItToolsManifest.tryFromJson(jsonDecode(raw));
      if (parsed == null) return null;

      final etag = await _readText(File(p.join(dir.path, 'it_tools.etag')));
      final fetchedAt = _parseTime(
        await _readText(File(p.join(dir.path, 'it_tools.fetchedAt'))),
      );
      return _ItToolsCache(
        raw: raw,
        manifest: parsed,
        etag: _emptyToNull(etag),
        fetchedAt: fetchedAt,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeItToolsCache(
    String raw,
    String? etag,
    DateTime now,
  ) async {
    try {
      final dir = await _cacheDir();
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'it_tools.json'))
          .writeAsString(raw, flush: true);
      await File(p.join(dir.path, 'it_tools.etag'))
          .writeAsString(etag ?? '', flush: true);
      await File(p.join(dir.path, 'it_tools.fetchedAt'))
          .writeAsString(now.toIso8601String(), flush: true);
    } catch (_) {
      // 缓存写失败不影响本次解析结果。
    }
  }

  Future<String?> _readText(File file) async {
    try {
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  static DateTime? _parseTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  static String? _emptyToNull(String? value) {
    if (value == null || value.isEmpty) return null;
    return value;
  }
}

/// Release 解析结果（资产名 → 资产 URL）。
class _ReleaseInfo {
  final Map<String, _ReleaseAsset> assets;

  const _ReleaseInfo({required this.assets});
}

/// 单个 Release 资产（仅解析所需字段）。
class _ReleaseAsset {
  final String name;
  final String url;

  const _ReleaseAsset({required this.name, required this.url});
}

/// 单次资产 GET 的结果。
class _AssetFetchResult {
  /// HTTP 状态码；0 表示网络/超时/超限等失败。
  final int status;
  final Uint8List? body;
  final String? etag;

  const _AssetFetchResult({required this.status, this.body, this.etag});
}

/// `modules.json` 磁盘缓存视图。
class _ManifestCache {
  final String raw;
  final ModuleManifestV2 manifest;
  final String? etag;
  final DateTime? fetchedAt;

  const _ManifestCache({
    required this.raw,
    required this.manifest,
    this.etag,
    this.fetchedAt,
  });
}

/// `it_tools.json` 磁盘缓存视图。
class _ItToolsCache {
  final String raw;
  final ItToolsManifest manifest;
  final String? etag;
  final DateTime? fetchedAt;

  const _ItToolsCache({
    required this.raw,
    required this.manifest,
    this.etag,
    this.fetchedAt,
  });
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value);
  return null;
}

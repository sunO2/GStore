/// 代理「规则模式」geo 资产清单（本仓库内资产，非运行时下载）。
///
/// 清单本身随 APK 打包（`assets/app/proxy_geo_manifest.json`），只声明
/// `country.mmdb` / `geosite.dat` 的**原始 GitHub URL**：
/// * 不含代理前缀（运行期由 `applyProxyIfNeeded` 施加）；
/// * 不含 `sha256`（校验和在运行期从 `<url>.sha256sum` 拉取）。
///
/// [ProxyGeoManifest.load] 做严格校验（schema、必需资产、`https` + `github.com`），
/// 非法清单抛结构化的 [ProxyGeoManifestException]，由 provisioning 层捕获并降级。
library;

import 'dart:convert';

import 'package:flutter/services.dart';

/// 单个 geo 资产：目标文件名 + 原始下载 URL。
class ProxyGeoAsset {
  const ProxyGeoAsset({required this.file, required this.url});

  /// 目标文件名（如 `country.mmdb`）。
  final String file;

  /// 原始 GitHub 下载 URL（无代理前缀）。
  final String url;
}

/// 清单非法（schema 不匹配 / 缺资产 / URL 不合法）。
class ProxyGeoManifestException implements Exception {
  const ProxyGeoManifestException(this.message);

  final String message;

  @override
  String toString() => 'ProxyGeoManifestException: $message';
}

/// 已验证的 geo 资产清单。
class ProxyGeoManifest {
  const ProxyGeoManifest({required this.assets});

  /// 按 [requiredFiles] 顺序排列的资产（确定性顺序，便于测试与日志）。
  final List<ProxyGeoAsset> assets;

  /// 当前支持的清单 schema。
  static const int schemaVersion = 1;

  /// 资产在 pubspec 中的路径（`assets/app/` 已声明）。
  static const String assetPath = 'assets/app/proxy_geo_manifest.json';

  /// 规则模式必需的两个 geo 资产。
  static const List<String> requiredFiles = <String>[
    'country.mmdb',
    'geosite.dat',
  ];

  /// 从 [bundle]（默认 [rootBundle]）加载并校验清单。
  ///
  /// 校验失败抛 [ProxyGeoManifestException]。
  ///
  /// 注：[rootBundle] 是 getter 而非 const，无法作默认值，故此处用可空参数在体内
  /// 落到 [rootBundle]；调用点 `load()` / `load(bundle: fake)` 形态不变。
  static Future<ProxyGeoManifest> load({AssetBundle? bundle}) async {
    final raw = await (bundle ?? rootBundle).loadString(assetPath);
    return ProxyGeoManifest.parse(raw);
  }

  /// 解析并校验清单文本（纯 Dart，无 binding 依赖，便于单测）。
  static ProxyGeoManifest parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (error) {
      throw ProxyGeoManifestException('清单不是合法 JSON: $error');
    }
    if (decoded is! Map) {
      throw const ProxyGeoManifestException('清单根节点不是 JSON 对象');
    }
    final map = decoded.cast<String, dynamic>();

    final schema = map['schema'];
    if (schema is! int || schema != schemaVersion) {
      throw ProxyGeoManifestException(
        '不支持的 schema: $schema（期望 $schemaVersion）',
      );
    }

    final assetsRaw = map['assets'];
    if (assetsRaw is! Map) {
      throw const ProxyGeoManifestException('清单缺少 assets 对象');
    }
    final assetsMap = assetsRaw.cast<String, dynamic>();

    final assets = <ProxyGeoAsset>[];
    for (final file in requiredFiles) {
      final entry = assetsMap[file];
      if (entry is! Map) {
        throw ProxyGeoManifestException('清单缺少必需资产: $file');
      }
      final url = entry.cast<String, dynamic>()['url'];
      if (url is! String || url.trim().isEmpty) {
        throw ProxyGeoManifestException('资产 $file 缺少 url');
      }
      final trimmed = url.trim();
      if (!trimmed.startsWith('https://')) {
        throw ProxyGeoManifestException('资产 $file 的 url 必须为 https: $trimmed');
      }
      if (!trimmed.contains('github.com')) {
        throw ProxyGeoManifestException(
          '资产 $file 的 url 必须来自 github.com: $trimmed',
        );
      }
      assets.add(ProxyGeoAsset(file: file, url: trimmed));
    }

    return ProxyGeoManifest(assets: List<ProxyGeoAsset>.unmodifiable(assets));
  }
}

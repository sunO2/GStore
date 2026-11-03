import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/catalog/catalog_facade.dart';
import 'package:gstore/http/github/github_client.dart';

/// 远端 GStore 目录 release 与本地 catalog 当前版本的轻量比较。
///
/// 只读取 GitHub release 的 name/tag_name，不下载数据库；直链配置无法提供
/// release 版本，返回 null。网络/解析失败由调用方降级为“无红点”。
class CatalogUpdateChecker {
  static const String fallbackRepoUrl =
      'https://github.com/sunO2/GStore-Repositorys';

  static final RegExp _repoPattern = RegExp(
    r'^https?://(?:www\.)?github\.com/([^/?#]+)/([^/?#]+?)(?:\.git)?(?:[/?#].*)?$',
  );

  @visibleForTesting
  static Future<String?> Function(String owner, String repo)? releasesOverride;

  @visibleForTesting
  static Future<String?> Function()? currentVersionOverride;

  static Future<({String current, String latest})?> check() async {
    final configured = await _configuredUrl();
    final repo = _parseGitHubRepo(configured);
    if (repo == null) return null;

    final override = releasesOverride;
    final raw = override != null
        ? await override(repo.$1, repo.$2)
        : await ModuleManager.instance
            .require<GithubRestClient>()
            .releases(repo.$1, repo.$2, 1, CancelToken())
            .timeout(const Duration(seconds: 15));
    final release = _latestRelease(raw);
    final latest =
        (release?['name'] ?? release?['tag_name'])?.toString().trim();
    if (latest == null || latest.isEmpty) return null;

    final overrideVersion = currentVersionOverride;
    final current = overrideVersion != null
        ? await overrideVersion()
        : (await CatalogFacade.instance.repoStatus()).currentVersion;
    return (
      current: current ?? '0.0.0.0',
      latest: latest,
    );
  }

  static Future<String> _configuredUrl() async {
    try {
      final value = await ConfigService.instance.get(ConfigKeys.catalogUrl);
      if (value is String && value.trim().isNotEmpty) return value.trim();
      final fallback =
          ConfigService.instance.entry(ConfigKeys.catalogUrl)?.defaultValue;
      if (fallback is String && fallback.trim().isNotEmpty) {
        return fallback.trim();
      }
    } catch (_) {}
    return fallbackRepoUrl;
  }

  static Map<String, dynamic>? _latestRelease(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        return Map<String, dynamic>.from(decoded.first as Map);
      }
    } catch (_) {}
    return null;
  }

  static (String, String)? _parseGitHubRepo(String url) {
    final match = _repoPattern.firstMatch(url.trim());
    if (match == null) return null;
    final owner = match.group(1);
    final repo = match.group(2);
    if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
      return null;
    }
    return (owner, repo);
  }
}

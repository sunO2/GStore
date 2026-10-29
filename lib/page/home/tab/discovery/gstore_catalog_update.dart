import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tabler_icons/flutter_tabler_icons.dart';

import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/core.dart' show getProxy;
import 'package:gstore/core/design/design_tokens.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/utils/unit.dart' show applyProxyIfNeeded;
import 'package:gstore/http/github/github_client.dart';

/// `catalog_url` 配置的读取 / 录入 / 下载地址解析。
///
/// 地址绝不硬编码：默认值来自配置注册表的 GitHub 仓库地址；未配置时回退该
/// 默认值，显式清空（空串）时仍弹出统一底部弹层让用户手动输入并持久化到
/// [ConfigService]。读取/保存/解析失败都降级为「不可用」，不抛出。
///
/// 解析规则：
/// - `https://github.com/<owner>/<repo>[...]` → GitHub releases API 取最新
///   release 的 `assets[0].browser_download_url`（按全局代理安全前缀）；
/// - 其他 `http(s)://…`（含直接的 `.db` 地址）→ 原样返回。
class CatalogUrlSetting {
  CatalogUrlSetting._();

  /// 未配置时的 GitHub 仓库地址（配置注册表 `catalog_url.defaultValue`）。
  static const String fallbackRepoUrl =
      'https://github.com/sunO2/GStore-Repositorys';

  /// GitHub releases 接口测试接缝：非 null 时替身返回原始 JSON，不发真实 HTTP。
  @visibleForTesting
  static Future<String> Function(String owner, String repo)? releasesOverride;

  /// `https://github.com/<owner>/<repo>`（允许结尾 `/`、`.git` 或额外路径）。
  static final RegExp _repoPattern = RegExp(
    r'^https?://(?:www\.)?github\.com/([^/?#]+)/([^/?#]+?)(?:\.git)?(?:[/?#].*)?$',
  );

  /// 读取已保存的目录地址。
  ///
  /// - 已配置：返回保存值；
  /// - 未配置（null）：回退配置注册表默认仓库地址；
  /// - 显式清空（空串）：返回空串，保留手动录入路径；
  /// - 读取失败：返回空串（按未配置处理）。
  static Future<String> read() async {
    try {
      final value = await ConfigService.instance.get(ConfigKeys.catalogUrl);
      if (value is String) return value.trim();
      return _defaultUrl;
    } catch (error) {
      debugPrint('[GStore] 读取 catalog_url 失败（按未配置处理）: $error');
      return '';
    }
  }

  /// 配置注册表登记的默认地址（注册表未就绪时回退 [fallbackRepoUrl]）。
  static String get _defaultUrl {
    final value =
        ConfigService.instance.entry(ConfigKeys.catalogUrl)?.defaultValue;
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return fallbackRepoUrl;
  }

  /// 解析出真正可下载的 catalog DB 地址。
  ///
  /// - 配置为 GitHub 仓库地址：调用 GitHub releases API，取 `[0]` 的
  ///   `assets[0]["browser_download_url"]`，配置了代理时安全加前缀；
  /// - 配置为直接 `http(s)://…` 地址：原样返回；
  /// - 配置为空（显式清空）：走 [ensure] 手动录入路径；
  /// - 网络 / 解析 / 缺少 asset 等任何失败：返回 null 并 `debugPrint`。
  ///
  /// 默认仓库地址存在时**不会**弹输入层。
  static Future<String?> resolveDownloadUrl() async {
    final configured = await read();
    if (configured.isEmpty) {
      // 手动覆盖：显式清空配置时提示输入并保存。
      return ensure();
    }

    final repo =
        _looksLikeDirectFile(configured) ? null : _parseGitHubRepo(configured);
    if (repo == null) {
      debugPrint('[GStore] catalog_url 为直链，直接使用: $configured');
      return configured;
    }

    final json = await _fetchReleases(repo.owner, repo.repo);
    if (json == null) return null;
    final rawUrl = _downloadUrlFromRelease(json);
    if (rawUrl == null) return null;

    final proxied = applyProxyIfNeeded(rawUrl, getProxy());
    debugPrint('[GStore] 目录下载地址: $proxied');
    return proxied;
  }

  /// 确保拿到一个可用地址：已配置直接返回；否则弹层录入并保存。
  ///
  /// 取消 / 空输入 / 保存失败返回 null。
  static Future<String?> ensure() async {
    final existing = await read();
    if (existing.isNotEmpty) return existing;
    final entered = await _prompt();
    if (entered == null || entered.isEmpty) return null;
    if (!await _save(entered)) {
      AppDialogs.showError('目录地址保存失败');
      return null;
    }
    return entered;
  }

  // ---- GitHub 仓库解析 -----------------------------------------------------

  static Future<String?> _fetchReleases(String owner, String repo) async {
    try {
      final override = releasesOverride;
      if (override != null) return await override(owner, repo);
      final client = ModuleManager.instance.require<GithubRestClient>();
      return await client
          .releases(owner, repo, 1, CancelToken())
          .timeout(const Duration(seconds: 15));
    } catch (error) {
      debugPrint('[GStore] 拉取 GitHub releases 失败: $error');
      return null;
    }
  }

  /// 从 releases JSON 数组解析首个 release 的下载地址（不硬编码文件名）。
  static String? _downloadUrlFromRelease(String json) {
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (error) {
      debugPrint('[GStore] releases JSON 解析失败: $error');
      return null;
    }
    if (decoded is! List || decoded.isEmpty) {
      debugPrint('[GStore] releases 为空，无法解析目录地址');
      return null;
    }
    final release = decoded.first;
    if (release is! Map) {
      debugPrint('[GStore] release 结构异常，无法解析目录地址');
      return null;
    }
    debugPrint('[GStore] 最新 release 版本: ${release['name']}');
    final assets = release['assets'];
    if (assets is! List || assets.isEmpty) {
      debugPrint('[GStore] release 无 assets，无法解析目录地址');
      return null;
    }
    final asset = assets.first;
    if (asset is! Map) {
      debugPrint('[GStore] asset 结构异常，无法解析目录地址');
      return null;
    }
    final url = asset['browser_download_url'];
    if (url is! String || url.trim().isEmpty) {
      debugPrint('[GStore] asset 缺少 browser_download_url');
      return null;
    }
    return url.trim();
  }

  /// 解析 `https://github.com/<owner>/<repo>`；不匹配返回 null。
  static ({String owner, String repo})? _parseGitHubRepo(String url) {
    final match = _repoPattern.firstMatch(url.trim());
    if (match == null) return null;
    final owner = match.group(1);
    final repo = match.group(2);
    if (owner == null || owner.isEmpty || repo == null || repo.isEmpty) {
      return null;
    }
    return (owner: owner, repo: repo);
  }

  /// 直接的数据库文件地址（以 `.db` 结尾），按直链处理而非仓库地址。
  static bool _looksLikeDirectFile(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.db');
  }

  // ---- 手动录入 / 持久化 ---------------------------------------------------

  static Future<bool> _save(String url) async {
    try {
      final result = await ConfigService.instance.set(ConfigKeys.catalogUrl, url);
      return result.success;
    } catch (error) {
      debugPrint('[GStore] 保存 catalog_url 失败: $error');
      return false;
    }
  }

  static Future<String?> _prompt() {
    var value = '';
    return AppDialogs.showContentSheet<String>(
      title: '设置目录地址',
      subtitle: '输入 GitHub 仓库地址或 catalog 数据库下载地址',
      icon: const Icon(TablerIcons.link),
      content: TextField(
        autofocus: true,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '目录地址',
          hintText: 'https://github.com/<owner>/<repo>',
        ),
        onChanged: (text) => value = text,
        onSubmitted: (text) => AppDialogs.popSheet<String>(text.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => AppDialogs.popSheet<String>(null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => AppDialogs.popSheet<String>(value.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

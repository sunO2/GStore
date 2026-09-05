import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gstore/core/core.dart';

/// 元数据仓库读取服务
///
/// 从 GStore-Repositorys 仓库的 metadata/{owner}@{repo}/info.json 读取
/// Actions 自动提取的应用元数据（真实图标 / 包名 / 版本信息）。
/// 读取失败或不存在时返回 null，调用方回退到默认数据源。
///
/// 带缓存：内存 + SharedPreferences（TTL 24h，包含"不存在"的负缓存）。
class MetadataRepository {
  MetadataRepository._internal({http.Client? client})
      : _client = client ?? http.Client();

  static final MetadataRepository instance = MetadataRepository._internal();

  http.Client _client;

  /// 测试注入：替换 HTTP 客户端（如 MockClient）
  @visibleForTesting
  set debugClient(http.Client client) => _client = client;

  /// 元数据仓库
  static const String repoOwner = 'sunO2';
  static const String repoName = 'GStore-Repositorys';
  static const String branch = 'main';

  static const Duration _cacheTtl = Duration(hours: 24);

  /// 负缓存 TTL（未收录 404）：较短，应用被收录（提交 issue 后 Actions 生成）
  /// 后能在较短时间内重新拉取
  static const Duration _negativeCacheTtl = Duration(minutes: 15);
  static const String _prefsPrefix = 'metadata_cache_';

  final Map<String, _CacheEntry> _memoryCache = {};

  /// 元数据 info.json 的原始 URL
  String infoUrl(String owner, String repo) {
    return 'https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/'
        'metadata/${owner}@${repo}/info.json';
  }

  /// 元数据图标的原始 URL（固定地址，未收录时的兜底）
  String iconUrl(String owner, String repo) {
    return 'https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/'
        'metadata/${owner}@${repo}/icon.png';
  }

  /// 带代理前缀的图标 URL（与现有图标加载方式一致）
  String? proxiedIconUrl(String owner, String repo) {
    final url = iconUrl(owner, repo);
    return applyProxyIfNeeded(url, getProxy());
  }

  /// 解析图标完整 URL（带代理前缀）
  ///
  /// 优先使用 info.json 的 icon 字段（内容变化时 Actions 会更新为新的指纹 URL，
  /// App 端 CachedNetworkImage 按 URL 缓存即可自动失效）；
  /// 未收录或 info 无 icon 时回退固定地址。
  Future<String?> resolveIconUrl(String owner, String repo) async {
    final info = await fetchInfo(owner, repo);
    final icon = info?['icon']?.toString();
    if (icon != null && icon.isNotEmpty) {
      // icon 为相对路径（可能带 ?r= 指纹 query），拼接 raw 前缀 + 代理
      final url = 'https://raw.githubusercontent.com/$repoOwner/$repoName/$branch/$icon';
      return applyProxyIfNeeded(url, getProxy());
    }
    return proxiedIconUrl(owner, repo);
  }

  /// 获取元数据（优先缓存）
  /// [forceRefresh] 强制刷新（绕过全部缓存）
  /// [ignoreNegativeCache] 仅绕过负缓存（未收录缓存），保留正缓存——
  ///   用于"应用可能刚被收录"的场景（如提交 issue 后立即查看）
  Future<Map<String, dynamic>?> fetchInfo(
    String owner,
    String repo, {
    bool forceRefresh = false,
    bool ignoreNegativeCache = false,
  }) async {
    final key = '$owner@$repo';

    // 1. 内存缓存（负缓存且 ignoreNegativeCache 时跳过）
    if (!forceRefresh) {
      final cached = _memoryCache[key];
      if (cached != null &&
          !cached.isExpired &&
          (!ignoreNegativeCache || cached.data != null)) {
        return cached.data;
      }
    }

    // 2. 磁盘缓存（同上）
    if (!forceRefresh) {
      final disk = await _loadFromDisk(key);
      if (disk != null &&
          !disk.isExpired &&
          (!ignoreNegativeCache || disk.data != null)) {
        _memoryCache[key] = disk;
        return disk.data;
      }
    }

    // 3. 网络请求（走代理）
    final url = applyProxyIfNeeded(infoUrl(owner, repo), getProxy());
    try {
      final resp = await _client
          .get(Uri.parse(url), headers: {'User-Agent': 'GStore-App/1.0'})
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 200 && resp.body.isNotEmpty) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final entry = _CacheEntry(data, DateTime.now());
        _memoryCache[key] = entry;
        await _saveToDisk(key, entry);
        return data;
      }
      // 404：明确未收录 → 写负缓存（24h 内不重复请求）
      if (resp.statusCode == 404) {
        final none = _CacheEntry(null, DateTime.now());
        _memoryCache[key] = none;
        await _saveToDisk(key, none);
      }
      return null;
    } catch (e) {
      // 网络异常（超时/连接失败/代理失效）：不写负缓存，下次调用可重试
      appLog.error('MetadataRepository: 拉取元数据失败 - $owner/$repo - $e');
      return null;
    }
  }

  /// 清除指定应用的缓存（提交 issue 后调用，使新生成的 metadata 立即生效）
  Future<void> removeCache(String owner, String repo) async {
    final key = '$owner@$repo';
    _memoryCache.remove(key);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_prefsPrefix$key');
    } catch (e) {
      appLog.error('MetadataRepository: 清除缓存失败 - $key - $e');
    }
  }

  /// 清除全部缓存（内存 + 偏好设置中的磁盘缓存）。
  /// 供缓存管理页在用户主动清理时调用。
  Future<void> clearCache() async {
    _memoryCache.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefsPrefix)).toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (e) {
      appLog.error('MetadataRepository: 清除缓存失败 - $e');
    }
  }

  Future<_CacheEntry?> _loadFromDisk(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefsPrefix$key');
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final ts = DateTime.fromMillisecondsSinceEpoch(map['ts'] as int);
      return _CacheEntry(map['data'] as Map<String, dynamic>?, ts);
    } catch (e) {
      return null;
    }
  }

  Future<void> _saveToDisk(String key, _CacheEntry entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_prefsPrefix$key',
        jsonEncode({
          'ts': entry.timestamp.millisecondsSinceEpoch,
          'data': entry.data,
        }),
      );
    } catch (e) {
      appLog.error('MetadataRepository: 缓存写入失败 - $key - $e');
    }
  }
}

class _CacheEntry {
  final Map<String, dynamic>? data;
  final DateTime timestamp;

  _CacheEntry(this.data, this.timestamp);

  bool get isExpired {
    // 负缓存（未收录）用短 TTL，便于收录后快速生效
    final ttl = data == null ? MetadataRepository._negativeCacheTtl : MetadataRepository._cacheTtl;
    return DateTime.now().difference(timestamp) > ttl;
  }
}

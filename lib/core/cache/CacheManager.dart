/// 缓存管理器
/// 提供统一的缓存接口，支持内存缓存和磁盘缓存
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gstore/core/config/AppConfig.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/exception/AppException.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

/// 缓存条目
class CacheEntry<T> {
  final T data;
  final DateTime createdAt;
  final Duration? expireDuration;

  CacheEntry({
    required this.data,
    required this.createdAt,
    this.expireDuration,
  });

  /// 检查是否过期
  bool get isExpired {
    if (expireDuration == null) return false;
    return DateTime.now().isAfter(createdAt.add(expireDuration!));
  }

  /// 获取剩余有效时间
  Duration? get remainingTime {
    if (expireDuration == null) return null;
    final expireTime = createdAt.add(expireDuration!);
    final now = DateTime.now();
    if (now.isAfter(expireTime)) return Duration.zero;
    return expireTime.difference(now);
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'data': data,
      'createdAt': createdAt.toIso8601String(),
      'expireDuration': expireDuration?.inSeconds,
    };
  }

  /// 从 JSON 创建
  factory CacheEntry.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic) dataParser,
  ) {
    return CacheEntry(
      data: dataParser(json['data']),
      createdAt: DateTime.parse(json['createdAt'] as String),
      expireDuration: json['expireDuration'] != null
          ? Duration(seconds: json['expireDuration'] as int)
          : null,
    );
  }
}

/// 缓存统计
class CacheStats {
  int hits = 0;
  int misses = 0;
  int evictions = 0;
  int size = 0;

  double get hitRate => hits + misses > 0 ? hits / (hits + misses) : 0;

  @override
  String toString() {
    return 'CacheStats{hits: $hits, misses: $misses, hitRate: ${(hitRate * 100).toStringAsFixed(1)}%, evictions: $evictions, size: $size}';
  }
}

/// 缓存管理器
class CacheManager {
  CacheManager._internal();

  static final CacheManager _instance = CacheManager._internal();

  factory CacheManager() => _instance;

  /// 应用配置
  late final AppConfig config;

  /// 内存缓存
  final Map<String, CacheEntry> _memoryCache = {};

  /// 缓存统计
  final CacheStats _stats = CacheStats();

  /// SharedPreferences 实例
  SharedPreferences? _prefs;

  /// 数据库实例（用于磁盘缓存）
  Database? _cacheDb;

  /// 是否已初始化
  bool _isInitialized = false;

  /// 初始化缓存管理器
  Future<void> initialize({AppConfig? config}) async {
    if (_isInitialized) {
      debugPrint('CacheManager: 已初始化，跳过');
      return;
    }

    this.config = config ?? AppConfig();

    try {
      // 初始化 SharedPreferences
      _prefs = await SharedPreferences.getInstance();

      // 初始化磁盘缓存数据库
      await _initCacheDb();

      // 清理过期的内存缓存
      _cleanupExpiredMemoryCache();

      _isInitialized = true;
      appLog.info('CacheManager: 初始化完成');
    } catch (e, stackTrace) {
      throw CacheException(
        message: '缓存管理器初始化失败',
        originalError: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 初始化缓存数据库
  Future<void> _initCacheDb() async {
    final cacheDir = await getTemporaryDirectory();
    final dbPath = '${cacheDir.path}/cache.db';

    _cacheDb = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE cache_entries (
            key TEXT PRIMARY KEY,
            data TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            expire_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE INDEX idx_expire_at ON cache_entries(expire_at)
        ''');
      },
    );
  }

  /// ========== 内存缓存 ==========

  /// 设置内存缓存
  void setMemory<T>(
    String key,
    T data, {
    Duration? expireDuration,
  }) {
    if (!config.enableCache) return;

    _checkSizeLimit();

    final entry = CacheEntry(
      data: data,
      createdAt: DateTime.now(),
      expireDuration: expireDuration ??
          Duration(seconds: config.memoryCacheExpireSeconds),
    );

    _memoryCache[key] = entry;
    _stats.size = _memoryCache.length;
  }

  /// 获取内存缓存
  T? getMemory<T>(String key) {
    if (!config.enableCache) return null;

    final entry = _memoryCache[key];

    if (entry == null) {
      _stats.misses++;
      return null;
    }

    if (entry.isExpired) {
      _memoryCache.remove(key);
      _stats.misses++;
      _stats.evictions++;
      return null;
    }

    _stats.hits++;
    return entry.data as T;
  }

  /// 删除内存缓存
  void removeMemory(String key) {
    _memoryCache.remove(key);
    _stats.size = _memoryCache.length;
  }

  /// 清空内存缓存
  void clearMemory() {
    final count = _memoryCache.length;
    _memoryCache.clear();
    _stats.size = 0;
    debugPrint('CacheManager: 清空内存缓存 ($count 条)');
  }

  /// 检查内存缓存大小限制
  void _checkSizeLimit() {
    if (_memoryCache.length >= config.memoryCacheMaxSize) {
      // LRU 淘汰策略：移除最旧的条目
      final sortedKeys = _memoryCache.entries
          .toList()
          ..sort((a, b) => a.value.createdAt.compareTo(b.value.createdAt));

      // 移除 10% 的旧条目
      final removeCount = (config.memoryCacheMaxSize * 0.1).ceil();
      for (var i = 0; i < removeCount && i < sortedKeys.length; i++) {
        _memoryCache.remove(sortedKeys[i].key);
        _stats.evictions++;
      }
    }
  }

  /// 清理过期的内存缓存
  void _cleanupExpiredMemoryCache() {
    final now = DateTime.now();
    final expiredKeys = <String>[];

    for (final entry in _memoryCache.entries) {
      if (entry.value.isExpired) {
        expiredKeys.add(entry.key);
      }
    }

    for (final key in expiredKeys) {
      _memoryCache.remove(key);
      _stats.evictions++;
    }

    if (expiredKeys.isNotEmpty) {
      debugPrint('CacheManager: 清理 ${expiredKeys.length} 条过期缓存');
    }
  }

  /// ========== 磁盘缓存 ==========

  /// 设置磁盘缓存
  Future<void> setDisk<T>(
    String key,
    T data, {
    Duration? expireDuration,
  }) async {
    if (!config.enableCache) return;
    if (_cacheDb == null) return;

    try {
      final now = DateTime.now();
      final expireAt = expireDuration != null
          ? now.add(expireDuration).millisecondsSinceEpoch
          : null;

      final jsonData = jsonEncode(data);
      final batch = _cacheDb!.batch();

      batch.insert(
        'cache_entries',
        {
          'key': key,
          'data': jsonData,
          'created_at': now.millisecondsSinceEpoch,
          'expire_at': expireAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await batch.commit(noResult: true);
    } catch (e) {
      appLog.error('CacheManager: 写入磁盘缓存失败 - $e');
    }
  }

  /// 获取磁盘缓存
  Future<T?> getDisk<T>(
    String key, {
    T Function(dynamic)? parser,
  }) async {
    if (!config.enableCache) return null;
    if (_cacheDb == null) return null;

    try {
      final results = await _cacheDb!.query(
        'cache_entries',
        where: 'key = ?',
        whereArgs: [key],
      );

      if (results.isEmpty) {
        _stats.misses++;
        return null;
      }

      final row = results.first;
      final expireAt = row['expire_at'] as int?;
      final now = DateTime.now().millisecondsSinceEpoch;

      // 检查是否过期
      if (expireAt != null && now > expireAt) {
        await _cacheDb!.delete(
          'cache_entries',
          where: 'key = ?',
          whereArgs: [key],
        );
        _stats.misses++;
        _stats.evictions++;
        return null;
      }

      _stats.hits++;

      // 解析数据
      final jsonData = row['data'] as String;
      final parsed = jsonDecode(jsonData);

      if (parser != null) {
        return parser(parsed);
      }

      return parsed as T;
    } catch (e) {
      appLog.error('CacheManager: 读取磁盘缓存失败 - $e');
      _stats.misses++;
      return null;
    }
  }

  /// 删除磁盘缓存
  Future<void> removeDisk(String key) async {
    if (_cacheDb == null) return;

    await _cacheDb!.delete(
      'cache_entries',
      where: 'key = ?',
      whereArgs: [key],
    );
  }

  /// 清空磁盘缓存
  Future<void> clearDisk() async {
    if (_cacheDb == null) return;

    final count = await _cacheDb!.delete('cache_entries');
    debugPrint('CacheManager: 清空磁盘缓存 ($count 条)');
  }

  /// 清理过期的磁盘缓存
  Future<void> cleanupExpiredDiskCache() async {
    if (_cacheDb == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    final count = await _cacheDb!.delete(
      'cache_entries',
      where: 'expire_at IS NOT NULL AND expire_at < ?',
      whereArgs: [now],
    );

    if (count > 0) {
      debugPrint('CacheManager: 清理 $count 条过期磁盘缓存');
    }
  }

  /// ========== 通用缓存方法 ==========

  /// 获取缓存（优先内存，其次磁盘）
  Future<T?> get<T>(
    String key, {
    T Function(dynamic)? parser,
  }) async {
    // 先尝试内存缓存
    var data = getMemory<T>(key);
    if (data != null) {
      return data;
    }

    // 再尝试磁盘缓存
    data = await getDisk<T>(key, parser: parser);
    if (data != null) {
      // 回写到内存缓存
      setMemory(key, data);
      return data;
    }

    return null;
  }

  /// 设置缓存（同时写入内存和磁盘）
  Future<void> set<T>(
    String key,
    T data, {
    Duration? memoryExpireDuration,
    Duration? diskExpireDuration,
  }) async {
    setMemory(key, data, expireDuration: memoryExpireDuration);
    await setDisk(key, data, expireDuration: diskExpireDuration);
  }

  /// 删除缓存（同时删除内存和磁盘）
  Future<void> remove(String key) async {
    removeMemory(key);
    await removeDisk(key);
  }

  /// ========== 缓存管理 ==========

  /// 获取缓存统计
  CacheStats getStats() {
    final stats = CacheStats();
    stats.hits = _stats.hits;
    stats.misses = _stats.misses;
    stats.evictions = _stats.evictions;
    stats.size = _stats.size;
    return stats;
  }

  /// 打印缓存统计
  void printStats() {
    debugPrint('========== 缓存统计 ==========');
    debugPrint(_stats.toString());
    debugPrint('内存缓存大小: ${_memoryCache.length}/${config.memoryCacheMaxSize}');
    debugPrint('==============================');
  }

  /// 重置统计
  void resetStats() {
    _stats.hits = 0;
    _stats.misses = 0;
    _stats.evictions = 0;
  }

  /// 获取缓存大小
  Future<int> getCacheSize() async {
    int memorySize = _memoryCache.length;

    int diskSize = 0;
    if (_cacheDb != null) {
      final result = await _cacheDb!.rawQuery(
        'SELECT COUNT(*) as count FROM cache_entries',
      );
      diskSize = Sqflite.firstIntValue(result) ?? 0;
    }

    return memorySize + diskSize;
  }

  /// 清理所有缓存
  Future<void> clearAll() async {
    clearMemory();
    await clearDisk();
  }

  /// 释放资源
  Future<void> dispose() async {
    clearMemory();
    if (_cacheDb != null) {
      await _cacheDb!.close();
      _cacheDb = null;
    }
    _isInitialized = false;
    debugPrint('CacheManager: 已释放资源');
  }

  /// 缓存键工具
  static String buildKey({
    required String prefix,
    required Map<String, dynamic> params,
  }) {
    final sortedParams = params.entries
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final paramStr = sortedParams
        .map((e) => '${e.key}=${e.value}')
        .join('&');

    return '$prefix?$paramStr';
  }

  /// 生成缓存键
  static String generateKey(String type, String identifier) {
    return '$type:$identifier';
  }
}

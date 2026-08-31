/// 下载配置提供者
///
/// 管理下载相关的配置项（如多段下载开关）
library;

import 'dart:async';

import 'package:gstore/core/config/config_provider.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core.dart';

/// 下载配置
class DownloadConfig {
  /// 是否启用多段下载（默认开启）
  final bool multiSegmentEnabled;

  /// 多段下载的最大段数（默认 8）
  final int maxSegments;

  /// 单段大小（字节，默认 8MB）
  final int segmentSizeBytes;

  /// 最大并发下载数（默认 3，范围 1-10）
  final int maxConcurrentDownloads;

  /// 是否仅在 WiFi 下下载（默认关闭）
  final bool wifiOnly;

  /// 最大重试次数（默认 3，范围 0-5）
  final int maxRetryCount;

  const DownloadConfig({
    this.multiSegmentEnabled = true,
    this.maxSegments = 8,
    this.segmentSizeBytes = 8 * 1024 * 1024,
    this.maxConcurrentDownloads = 3,
    this.wifiOnly = false,
    this.maxRetryCount = 3,
  });

  /// 复制并修改
  DownloadConfig copyWith({
    bool? multiSegmentEnabled,
    int? maxSegments,
    int? segmentSizeBytes,
    int? maxConcurrentDownloads,
    bool? wifiOnly,
    int? maxRetryCount,
  }) {
    return DownloadConfig(
      multiSegmentEnabled: multiSegmentEnabled ?? this.multiSegmentEnabled,
      maxSegments: maxSegments ?? this.maxSegments,
      segmentSizeBytes: segmentSizeBytes ?? this.segmentSizeBytes,
      maxConcurrentDownloads: maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      maxRetryCount: maxRetryCount ?? this.maxRetryCount,
    );
  }

  /// 序列化
  Map<String, dynamic> toJson() {
    return {
      'multiSegmentEnabled': multiSegmentEnabled,
      'maxSegments': maxSegments,
      'segmentSizeBytes': segmentSizeBytes,
      'maxConcurrentDownloads': maxConcurrentDownloads,
      'wifiOnly': wifiOnly,
      'maxRetryCount': maxRetryCount,
    };
  }

  /// 反序列化
  factory DownloadConfig.fromJson(Map<String, dynamic> json) {
    return DownloadConfig(
      multiSegmentEnabled: json['multiSegmentEnabled'] as bool? ?? true,
      maxSegments: json['maxSegments'] as int? ?? 8,
      segmentSizeBytes: json['segmentSizeBytes'] as int? ?? 8 * 1024 * 1024,
      maxConcurrentDownloads: json['maxConcurrentDownloads'] as int? ?? 3,
      wifiOnly: json['wifiOnly'] as bool? ?? false,
      maxRetryCount: json['maxRetryCount'] as int? ?? 3,
    );
  }
}

/// 下载配置提供者
///
/// 负责下载配置的加载、保存和变化监听
class DownloadConfigProvider extends ConfigProvider<DownloadConfig> {
  DownloadConfigProvider(this._storage);

  final ConfigStorage _storage;

  /// 配置键
  @override
  String get configKey => 'download_config';

  /// 存储键
  static const String _multiSegmentKey = 'download_multi_segment';
  static const String _maxConcurrentKey = 'download_max_concurrent';
  static const String _wifiOnlyKey = 'download_wifi_only';
  static const String _maxRetryKey = 'download_max_retry';

  /// 变化控制器
  final _controller = StreamController<DownloadConfig>.broadcast();

  /// 当前配置（内存缓存）
  DownloadConfig _cached = const DownloadConfig();

  /// 获取当前配置（内存缓存，若无则加载）
  DownloadConfig get current {
    return _cached;
  }

  @override
  Future<DownloadConfig?> load() async {
    try {
      final multi = await _storage.getBool(_multiSegmentKey);
      final concurrent = await _storage.getInt(_maxConcurrentKey);
      final wifi = await _storage.getBool(_wifiOnlyKey);
      final retry = await _storage.getInt(_maxRetryKey);
      _cached = DownloadConfig(
        multiSegmentEnabled: multi ?? true,
        maxSegments: _cached.maxSegments,
        segmentSizeBytes: _cached.segmentSizeBytes,
        maxConcurrentDownloads: concurrent ?? 3,
        wifiOnly: wifi ?? false,
        maxRetryCount: retry ?? 3,
      );
      return _cached;
    } catch (e) {
      appLog.error('DownloadConfigProvider: 加载配置失败 - $e');
      return const DownloadConfig();
    }
  }

  /// 切换多段下载开关
  Future<bool> setMultiSegmentEnabled(bool enabled) async {
    _cached = _cached.copyWith(multiSegmentEnabled: enabled);
    final ok = await _storage.setBool(_multiSegmentKey, enabled);
    if (ok) {
      _controller.add(_cached);
    }
    return ok;
  }

  /// 是否启用多段下载
  Future<bool> isMultiSegmentEnabled() async {
    if (_cached.multiSegmentEnabled) {
      return true;
    }
    // 未初始化时加载一次
    final config = await load();
    return config?.multiSegmentEnabled ?? true;
  }

  /// 设置最大并发下载数
  Future<bool> setMaxConcurrentDownloads(int count) async {
    final clamped = count.clamp(1, 10);
    _cached = _cached.copyWith(maxConcurrentDownloads: clamped);
    final ok = await _storage.setInt(_maxConcurrentKey, clamped);
    if (ok) {
      _controller.add(_cached);
    }
    return ok;
  }

  /// 获取最大并发下载数
  Future<int> getMaxConcurrentDownloads() async {
    if (_cached.maxConcurrentDownloads != 3) {
      return _cached.maxConcurrentDownloads;
    }
    final config = await load();
    return config?.maxConcurrentDownloads ?? 3;
  }

  /// 设置是否仅 WiFi 下载
  Future<bool> setWifiOnly(bool enabled) async {
    _cached = _cached.copyWith(wifiOnly: enabled);
    final ok = await _storage.setBool(_wifiOnlyKey, enabled);
    if (ok) {
      _controller.add(_cached);
    }
    return ok;
  }

  /// 是否仅 WiFi 下载
  Future<bool> isWifiOnly() async {
    if (_cached.wifiOnly) {
      return true;
    }
    final config = await load();
    return config?.wifiOnly ?? false;
  }

  /// 设置最大重试次数
  Future<bool> setMaxRetryCount(int count) async {
    final clamped = count.clamp(0, 5);
    _cached = _cached.copyWith(maxRetryCount: clamped);
    final ok = await _storage.setInt(_maxRetryKey, clamped);
    if (ok) {
      _controller.add(_cached);
    }
    return ok;
  }

  /// 获取最大重试次数
  Future<int> getMaxRetryCount() async {
    if (_cached.maxRetryCount != 3) {
      return _cached.maxRetryCount;
    }
    final config = await load();
    return config?.maxRetryCount ?? 3;
  }

  @override
  Future<bool> save(DownloadConfig config) async {
    _cached = config;
    final ok1 = await _storage.setBool(_multiSegmentKey, config.multiSegmentEnabled);
    final ok2 = await _storage.setInt(_maxConcurrentKey, config.maxConcurrentDownloads);
    final ok3 = await _storage.setBool(_wifiOnlyKey, config.wifiOnly);
    final ok4 = await _storage.setInt(_maxRetryKey, config.maxRetryCount);
    final ok = ok1 && ok2 && ok3 && ok4;
    if (ok) {
      _controller.add(config);
    }
    return ok;
  }

  @override
  Future<bool> clear() async {
    _cached = const DownloadConfig();
    await _storage.remove(_multiSegmentKey);
    await _storage.remove(_maxConcurrentKey);
    await _storage.remove(_wifiOnlyKey);
    await _storage.remove(_maxRetryKey);
    _controller.add(_cached);
    return true;
  }

  @override
  Future<bool> importFromJson(Map<String, dynamic> json) async {
    try {
      final config = DownloadConfig.fromJson(json);
      return await save(config);
    } catch (e) {
      appLog.error('DownloadConfigProvider: 导入配置失败 - $e');
      return false;
    }
  }

  @override
  Stream<DownloadConfig?> watch() => _controller.stream;

  @override
  Future<DownloadConfig> getOrDefault() async {
    final config = await load();
    return config ?? const DownloadConfig();
  }
}

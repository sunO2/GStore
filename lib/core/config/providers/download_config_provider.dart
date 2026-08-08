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

  const DownloadConfig({
    this.multiSegmentEnabled = true,
    this.maxSegments = 8,
    this.segmentSizeBytes = 8 * 1024 * 1024,
  });

  /// 复制并修改
  DownloadConfig copyWith({
    bool? multiSegmentEnabled,
    int? maxSegments,
    int? segmentSizeBytes,
  }) {
    return DownloadConfig(
      multiSegmentEnabled: multiSegmentEnabled ?? this.multiSegmentEnabled,
      maxSegments: maxSegments ?? this.maxSegments,
      segmentSizeBytes: segmentSizeBytes ?? this.segmentSizeBytes,
    );
  }

  /// 序列化
  Map<String, dynamic> toJson() {
    return {
      'multiSegmentEnabled': multiSegmentEnabled,
      'maxSegments': maxSegments,
      'segmentSizeBytes': segmentSizeBytes,
    };
  }

  /// 反序列化
  factory DownloadConfig.fromJson(Map<String, dynamic> json) {
    return DownloadConfig(
      multiSegmentEnabled: json['multiSegmentEnabled'] as bool? ?? true,
      maxSegments: json['maxSegments'] as int? ?? 8,
      segmentSizeBytes: json['segmentSizeBytes'] as int? ?? 8 * 1024 * 1024,
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
      _cached = DownloadConfig(
        multiSegmentEnabled: multi ?? true,
        maxSegments: _cached.maxSegments,
        segmentSizeBytes: _cached.segmentSizeBytes,
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

  @override
  Future<bool> save(DownloadConfig config) async {
    _cached = config;
    final ok = await _storage.setBool(_multiSegmentKey, config.multiSegmentEnabled);
    if (ok) {
      _controller.add(config);
    }
    return ok;
  }

  @override
  Future<bool> clear() async {
    _cached = const DownloadConfig();
    await _storage.remove(_multiSegmentKey);
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

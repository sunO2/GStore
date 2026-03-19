/// 更新策略配置提供者
///
/// 管理应用更新相关的配置
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:json_annotation/json_annotation.dart';

import '../config_provider.dart';
import '../config_storage.dart';

part 'update_config.g.dart';

/// 更新渠道
enum UpdateChannel {
  /// 稳定版
  stable,

  /// 测试版
  beta,

  /// 开发版
  dev;

  String get displayName {
    switch (this) {
      case UpdateChannel.stable:
        return '稳定版';
      case UpdateChannel.beta:
        return '测试版';
      case UpdateChannel.dev:
        return '开发版';
    }
  }

  /// 从索引值获取枚举（使用内置 index）
  static UpdateChannel fromIndex(int index) {
    return UpdateChannel.values[index];
  }
}

/// 自动更新策略
enum AutoUpdatePolicy {
  /// 不自动更新
  never,

  /// 仅 Wi-Fi 下自动更新
  wifiOnly,

  /// 总是自动更新
  always;

  String get displayName {
    switch (this) {
      case AutoUpdatePolicy.never:
        return '从不';
      case AutoUpdatePolicy.wifiOnly:
        return '仅 Wi-Fi';
      case AutoUpdatePolicy.always:
        return '总是';
    }
  }

  /// 从索引值获取枚举（使用内置 index）
  static AutoUpdatePolicy fromIndex(int index) {
    return AutoUpdatePolicy.values[index];
  }
}

/// 更新配置
@JsonSerializable()
class UpdateConfig {
  /// 更新渠道
  final UpdateChannel channel;

  /// 自动更新策略
  final AutoUpdatePolicy autoUpdatePolicy;

  /// 是否忽略预发布版本
  final bool ignorePrerelease;

  /// 是否静默更新（不提示）
  final bool silentUpdate;

  /// 检查更新间隔（小时）
  final int checkIntervalHours;

  /// 上次检查更新时间
  final DateTime? lastCheckTime;

  /// 上次更新版本
  final String? lastUpdatedVersion;

  const UpdateConfig({
    this.channel = UpdateChannel.stable,
    this.autoUpdatePolicy = AutoUpdatePolicy.wifiOnly,
    this.ignorePrerelease = true,
    this.silentUpdate = false,
    this.checkIntervalHours = 24,
    this.lastCheckTime,
    this.lastUpdatedVersion,
  });

  /// 从 JSON 创建
  factory UpdateConfig.fromJson(Map<String, dynamic> json) =>
      _$UpdateConfigFromJson(json);

  /// 转换为 JSON
  Map<String, dynamic> toJson() => _$UpdateConfigToJson(this);

  /// 复制并修改
  UpdateConfig copyWith({
    UpdateChannel? channel,
    AutoUpdatePolicy? autoUpdatePolicy,
    bool? ignorePrerelease,
    bool? silentUpdate,
    int? checkIntervalHours,
    DateTime? lastCheckTime,
    String? lastUpdatedVersion,
    bool clearLastCheckTime = false,
    bool clearLastUpdatedVersion = false,
  }) {
    return UpdateConfig(
      channel: channel ?? this.channel,
      autoUpdatePolicy: autoUpdatePolicy ?? this.autoUpdatePolicy,
      ignorePrerelease: ignorePrerelease ?? this.ignorePrerelease,
      silentUpdate: silentUpdate ?? this.silentUpdate,
      checkIntervalHours: checkIntervalHours ?? this.checkIntervalHours,
      lastCheckTime: clearLastCheckTime ? null : (lastCheckTime ?? this.lastCheckTime),
      lastUpdatedVersion: clearLastUpdatedVersion ? null : (lastUpdatedVersion ?? this.lastUpdatedVersion),
    );
  }

  /// 默认配置
  static const UpdateConfig default_ = UpdateConfig();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UpdateConfig &&
        other.channel == channel &&
        other.autoUpdatePolicy == autoUpdatePolicy &&
        other.ignorePrerelease == ignorePrerelease &&
        other.silentUpdate == silentUpdate &&
        other.checkIntervalHours == checkIntervalHours;
  }

  @override
  int get hashCode {
    return Object.hash(
      channel,
      autoUpdatePolicy,
      ignorePrerelease,
      silentUpdate,
      checkIntervalHours,
    );
  }

  @override
  String toString() {
    return 'UpdateConfig(channel: $channel, autoUpdatePolicy: $autoUpdatePolicy, '
        'ignorePrerelease: $ignorePrerelease, silentUpdate: $silentUpdate, '
        'checkIntervalHours: $checkIntervalHours)';
  }
}

/// 更新配置提供者
///
/// 负责管理应用更新相关的配置
class UpdateConfigProvider extends ConfigProvider<UpdateConfig> {
  UpdateConfigProvider(this._storage);

  final ConfigStorage _storage;

  /// 配置键
  @override
  String get configKey => 'update_config';

  /// 配置变化控制器
  final _configController = StreamController<UpdateConfig>.broadcast();

  /// 当前配置
  UpdateConfig _currentConfig = UpdateConfig.default_;

  /// 当前配置
  UpdateConfig get currentConfig => _currentConfig;

  @override
  Future<UpdateConfig?> load() async {
    try {
      final jsonString = await _storage.getString(configKey);
      if (jsonString != null) {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final config = UpdateConfig.fromJson(json);
        _currentConfig = config;
        debugPrint('UpdateConfigProvider: 配置已加载 - $config');
        return config;
      }
      return UpdateConfig.default_;
    } catch (e, stackTrace) {
      debugPrint('UpdateConfigProvider: 加载配置失败 - $e');
      debugPrint('UpdateConfigProvider: 堆栈跟踪: $stackTrace');
      return UpdateConfig.default_;
    }
  }

  @override
  Future<bool> save(UpdateConfig config) async {
    try {
      final jsonString = jsonEncode(config.toJson());
      final success = await _storage.setString(configKey, jsonString);
      if (success) {
        _currentConfig = config;
        _configController.add(config);
        debugPrint('UpdateConfigProvider: 配置已保存');
        return true;
      } else {
        debugPrint('UpdateConfigProvider: 保存配置失败');
        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('UpdateConfigProvider: 保存配置异常 - $e');
      debugPrint('UpdateConfigProvider: 堆栈跟踪: $stackTrace');
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    final success = await _storage.remove(configKey);
    if (success) {
      _currentConfig = UpdateConfig.default_;
      _configController.add(UpdateConfig.default_);
      debugPrint('UpdateConfigProvider: 配置已清除');
    }
    return success;
  }

  @override
  Stream<UpdateConfig?> watch() {
    return _configController.stream;
  }

  /// 设置更新渠道
  Future<bool> setChannel(UpdateChannel channel) async {
    final newConfig = _currentConfig.copyWith(channel: channel);
    return await save(newConfig);
  }

  /// 设置自动更新策略
  Future<bool> setAutoUpdatePolicy(AutoUpdatePolicy policy) async {
    final newConfig = _currentConfig.copyWith(autoUpdatePolicy: policy);
    return await save(newConfig);
  }

  /// 更新最后检查时间
  Future<bool> updateLastCheckTime() async {
    final newConfig = _currentConfig.copyWith(lastCheckTime: DateTime.now());
    return await save(newConfig);
  }

  /// 更新最后更新版本
  Future<bool> updateLastUpdatedVersion(String version) async {
    final newConfig = _currentConfig.copyWith(lastUpdatedVersion: version);
    return await save(newConfig);
  }

  /// 检查是否需要更新检查
  bool shouldCheckForUpdates() {
    if (_currentConfig.lastCheckTime == null) return true;

    final now = DateTime.now();
    final lastCheck = _currentConfig.lastCheckTime!;
    final hoursSinceLastCheck = now.difference(lastCheck).inHours;

    return hoursSinceLastCheck >= _currentConfig.checkIntervalHours;
  }

  /// 释放资源
  void dispose() {
    _configController.close();
  }

  @override
  Future<bool> importFromJson(Map<String, dynamic> json) async {
    try {
      debugPrint('UpdateConfigProvider: 开始从 JSON 导入配置');
      debugPrint('UpdateConfigProvider: JSON keys: ${json.keys.toList()}');

      final config = UpdateConfig.fromJson(json);
      debugPrint('UpdateConfigProvider: 配置对象创建成功');

      final success = await save(config);
      debugPrint('UpdateConfigProvider: 保存结果 - $success');
      return success;
    } catch (e, stackTrace) {
      debugPrint('UpdateConfigProvider: 导入配置失败 - $e');
      debugPrint('UpdateConfigProvider: 堆栈跟踪: $stackTrace');
      return false;
    }
  }
}

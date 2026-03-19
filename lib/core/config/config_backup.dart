/// 配置备份相关模型
///
/// 定义配置备份的数据结构和版本管理
library;

import 'package:json_annotation/json_annotation.dart';

part 'config_backup.g.dart';

/// 配置备份数据
///
/// 包含所有配置的完整备份，支持导出和导入
@JsonSerializable(explicitToJson: true)
class ConfigBackupData {
  /// 备份版本号
  final int version;

  /// 备份时间戳
  final DateTime timestamp;

  /// 应用版本号
  final String? appVersion;

  /// 所有配置数据
  ///
  /// Key: 配置键 (configKey)
  /// Value: 配置 JSON 数据
  final Map<String, dynamic> configs;

  const ConfigBackupData({
    required this.version,
    required this.timestamp,
    this.appVersion,
    required this.configs,
  });

  /// 从 JSON 创建
  factory ConfigBackupData.fromJson(Map<String, dynamic> json) =>
      _$ConfigBackupDataFromJson(json);

  /// 转换为 JSON
  Map<String, dynamic> toJson() => _$ConfigBackupDataToJson(this);

  /// 复制并修改
  ConfigBackupData copyWith({
    int? version,
    DateTime? timestamp,
    String? appVersion,
    Map<String, dynamic>? configs,
  }) {
    return ConfigBackupData(
      version: version ?? this.version,
      timestamp: timestamp ?? this.timestamp,
      appVersion: appVersion ?? this.appVersion,
      configs: configs ?? this.configs,
    );
  }

  /// 获取指定配置
  dynamic getConfig(String key) {
    return configs[key];
  }

  /// 检查是否包含指定配置
  bool hasConfig(String key) {
    return configs.containsKey(key);
  }

  /// 添加配置
  ConfigBackupData addConfig(String key, Map<String, dynamic> config) {
    final newConfigs = Map<String, dynamic>.from(configs);
    newConfigs[key] = config;
    return copyWith(configs: newConfigs);
  }

  /// 移除配置
  ConfigBackupData removeConfig(String key) {
    final newConfigs = Map<String, dynamic>.from(configs);
    newConfigs.remove(key);
    return copyWith(configs: newConfigs);
  }

  @override
  String toString() {
    return 'ConfigBackupData(version: $version, timestamp: $timestamp, '
        'appVersion: $appVersion, configs: ${configs.keys.toList()})';
  }
}

/// 配置备份元数据
///
/// 用于描述备份文件的基本信息
class ConfigBackupMetadata {
  /// 备份文件名
  final String filename;

  /// 文件大小（字节）
  final int fileSize;

  /// 备份版本
  final int version;

  /// 备份时间
  final DateTime timestamp;

  /// 应用版本
  final String? appVersion;

  /// 配置数量
  final int configCount;

  /// 是否为加密备份
  final bool isEncrypted;

  /// 是否为压缩备份
  final bool isCompressed;

  const ConfigBackupMetadata({
    required this.filename,
    required this.fileSize,
    required this.version,
    required this.timestamp,
    this.appVersion,
    required this.configCount,
    this.isEncrypted = false,
    this.isCompressed = false,
  });

  /// 从备份数据创建元数据
  factory ConfigBackupMetadata.fromBackupData(
    ConfigBackupData data, {
    String filename = '',
    int fileSize = 0,
    bool isEncrypted = false,
    bool isCompressed = false,
  }) {
    return ConfigBackupMetadata(
      filename: filename,
      fileSize: fileSize,
      version: data.version,
      timestamp: data.timestamp,
      appVersion: data.appVersion,
      configCount: data.configs.length,
      isEncrypted: isEncrypted,
      isCompressed: isCompressed,
    );
  }

  /// 格式化文件大小
  String get formattedFileSize {
    if (fileSize < 1024) {
      return '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    } else if (fileSize < 1024 * 1024 * 1024) {
      return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  /// 格式化时间戳
  String get formattedTimestamp {
    return '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}'
        '-${timestamp.day.toString().padLeft(2, '0')} '
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}';
  }

  @override
  String toString() {
    return 'ConfigBackupMetadata(filename: $filename, fileSize: $formattedFileSize, '
        'version: $version, timestamp: $formattedTimestamp, '
        'configCount: $configCount)';
  }
}

/// 配置迁移信息
///
/// 用于跟踪配置版本的变化
class ConfigMigration {
  /// 源版本
  final int fromVersion;

  /// 目标版本
  final int toVersion;

  /// 迁移时间
  final DateTime timestamp;

  /// 迁移是否成功
  final bool success;

  /// 错误信息（如果失败）
  final String? error;

  const ConfigMigration({
    required this.fromVersion,
    required this.toVersion,
    required this.timestamp,
    required this.success,
    this.error,
  });

  /// 从 JSON 创建
  factory ConfigMigration.fromJson(Map<String, dynamic> json) {
    return ConfigMigration(
      fromVersion: json['fromVersion'] as int,
      toVersion: json['toVersion'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String),
      success: json['success'] as bool,
      error: json['error'] as String?,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'fromVersion': fromVersion,
      'toVersion': toVersion,
      'timestamp': timestamp.toIso8601String(),
      'success': success,
      if (error != null) 'error': error,
    };
  }
}

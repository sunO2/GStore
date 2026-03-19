// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'config_backup.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ConfigBackupData _$ConfigBackupDataFromJson(Map<String, dynamic> json) =>
    ConfigBackupData(
      version: (json['version'] as num).toInt(),
      timestamp: DateTime.parse(json['timestamp'] as String),
      appVersion: json['appVersion'] as String?,
      configs: json['configs'] as Map<String, dynamic>,
    );

Map<String, dynamic> _$ConfigBackupDataToJson(ConfigBackupData instance) =>
    <String, dynamic>{
      'version': instance.version,
      'timestamp': instance.timestamp.toIso8601String(),
      'appVersion': instance.appVersion,
      'configs': instance.configs,
    };

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'update_config_provider.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

UpdateConfig _$UpdateConfigFromJson(Map<String, dynamic> json) =>
    UpdateConfig(
      channel: $enumDecode(_$UpdateChannelEnumMap, json['channel']),
      autoUpdatePolicy: $enumDecode(
          _$AutoUpdatePolicyEnumMap, json['autoUpdatePolicy']),
      ignorePrerelease: json['ignorePrerelease'] as bool,
      silentUpdate: json['silentUpdate'] as bool,
      checkIntervalHours: json['checkIntervalHours'] as int,
      lastCheckTime: json['lastCheckTime'] == null
          ? null
          : DateTime.parse(json['lastCheckTime'] as String),
      lastUpdatedVersion: json['lastUpdatedVersion'] as String?,
    );

Map<String, dynamic> _$UpdateConfigToJson(UpdateConfig instance) =>
    <String, dynamic>{
      'channel': _$UpdateChannelEnumMap[instance.channel]!,
      'autoUpdatePolicy': _$AutoUpdatePolicyEnumMap[instance.autoUpdatePolicy]!,
      'ignorePrerelease': instance.ignorePrerelease,
      'silentUpdate': instance.silentUpdate,
      'checkIntervalHours': instance.checkIntervalHours,
      'lastCheckTime': instance.lastCheckTime?.toIso8601String(),
      'lastUpdatedVersion': instance.lastUpdatedVersion,
    };

const _$UpdateChannelEnumMap = {
  UpdateChannel.stable: 'stable',
  UpdateChannel.beta: 'beta',
  UpdateChannel.dev: 'dev',
};

const _$AutoUpdatePolicyEnumMap = {
  AutoUpdatePolicy.never: 'never',
  AutoUpdatePolicy.wifiOnly: 'wifiOnly',
  AutoUpdatePolicy.always: 'always',
};

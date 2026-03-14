import 'ChannelType.dart';

/// 渠道元信息
class ChannelInfo {
  /// 渠道类型
  final ChannelType type;

  /// 渠道名称
  final String name;

  /// 渠道描述
  final String description;

  /// 是否启用
  bool enabled;

  /// 优先级 (数字越小优先级越高)
  int priority;

  /// 是否支持离线
  final bool supportOffline;

  /// 最后更新时间
  DateTime? lastUpdateTime;

  /// 版本号
  String? version;

  ChannelInfo({
    required this.type,
    required this.name,
    required this.description,
    this.enabled = true,
    int? priority,
    this.supportOffline = false,
    this.lastUpdateTime,
    this.version,
  }) : priority = priority ?? type.priority;

  /// 复制并更新
  ChannelInfo copyWith({
    ChannelType? type,
    String? name,
    String? description,
    bool? enabled,
    int? priority,
    bool? supportOffline,
    DateTime? lastUpdateTime,
    String? version,
  }) {
    return ChannelInfo(
      type: type ?? this.type,
      name: name ?? this.name,
      description: description ?? this.description,
      enabled: enabled ?? this.enabled,
      priority: priority ?? this.priority,
      supportOffline: supportOffline ?? this.supportOffline,
      lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
      version: version ?? this.version,
    );
  }

  @override
  String toString() {
    return 'ChannelInfo{type: $type, name: $name, enabled: $enabled, priority: $priority}';
  }
}

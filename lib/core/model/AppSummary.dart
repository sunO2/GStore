import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/db/apps/AppInfo.dart';

/// 应用摘要（渠道传输模型，纯 Dart，不绑定持久化层）
/// 字段与 db.AppInfo 同构，packageName 从 extra 提升为一级字段
class AppSummary {
  final String appId; // 渠道内 ID（owner/repo、包名、数字 ID，语义由渠道决定）
  final String? packageName; // 真实包名（未知为 null，不再用 '' 或猜测）
  final String name;
  final String user;
  final String repositories;
  final String icon;
  final String des;
  final String? readme;
  final List<String>? category;
  final Map<String, dynamic>? extra;

  const AppSummary({
    required this.appId,
    this.packageName,
    required this.name,
    required this.user,
    required this.repositories,
    required this.icon,
    required this.des,
    this.readme,
    this.category,
    this.extra,
  });

  /// 从 extra 中获取指定字段的值（兼容既有调用，非法/缺失返回 null 不抛）
  T? getExtra<T>(String key) {
    final data = extra;
    if (data == null) return null;
    final value = data[key];
    if (value is T) return value;
    return null;
  }

  /// 复制并修改指定字段，未指定字段保持原值
  AppSummary copyWith({
    String? appId,
    String? packageName,
    String? name,
    String? user,
    String? repositories,
    String? icon,
    String? des,
    String? readme,
    List<String>? category,
    Map<String, dynamic>? extra,
  }) {
    return AppSummary(
      appId: appId ?? this.appId,
      packageName: packageName ?? this.packageName,
      name: name ?? this.name,
      user: user ?? this.user,
      repositories: repositories ?? this.repositories,
      icon: icon ?? this.icon,
      des: des ?? this.des,
      readme: readme ?? this.readme,
      category: category ?? this.category,
      extra: extra ?? this.extra,
    );
  }

  /// 从 db.AppInfo 映射（字段同构）
  /// packageName 提升规则：extra['packageName'] 非空取之，否则 null（不用 repositories 兜底）
  factory AppSummary.fromDbAppInfo(AppInfo app) {
    final raw = app.getExtra<String>('packageName');
    return AppSummary(
      appId: app.appId,
      packageName: (raw != null && raw.isNotEmpty) ? raw : null,
      name: app.name,
      user: app.user,
      repositories: app.repositories,
      icon: app.icon,
      des: app.des,
      readme: app.readme,
      category: app.category,
      extra: app.getExtraData(),
    );
  }

  /// 从渠道已添加记录（channel_added_app）映射
  /// 注意：不映射 apprepo（AppSummary 无此字段；与现状 GitHubChannel.getAllApps 行为一致，同样丢弃）
  /// category 为逗号分隔字符串，拆分为 List<String>
  factory AppSummary.fromChannelAddedApp(ChannelAddedApp c) {
    final raw = c.getExtra<String>('packageName');
    return AppSummary(
      appId: c.appId,
      packageName: (raw != null && raw.isNotEmpty) ? raw : null,
      name: c.name,
      user: c.user,
      repositories: c.repositories,
      icon: c.icon,
      des: c.description,
      category: c.category?.split(','),
      extra: c.getExtraData(),
    );
  }
}

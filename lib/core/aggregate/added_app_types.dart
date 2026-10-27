/// Plain (DB-free) added-app reference row + user-tag models.
///
/// These were Floor entities on the deleted legacy Dart catalog store
/// (`AppAddedDatabase`). After the catalog moved to the Rust core the Dart
/// layer no longer persists them — they are now inert value objects used by
/// the flag-routed [AddedAppsFacade], the pure metadata join and the backup
/// model.
///
/// Shape is unchanged (same field names / constructor defaults) so the backup
/// serialization and the FRB → Dart mapping stay byte-for-byte compatible.
library;

/// 已添加应用实体（引用行）
/// 仅保存渠道 + 应用 ID + 聚合元数据；应用信息由渠道实时查询。
class AddedAppInfo {
  /// 自增主键（核心库返回；纯 join 忽略）
  final int? id;

  /// 渠道类型
  final String channelId;

  /// 应用 ID（在对应渠道中的 ID，metadata 收录时为真实包名）
  final String appId;

  /// 添加时间（毫秒时间戳）
  final int addTime;

  /// 排序权重
  final int sortOrder;

  /// 是否启用
  final bool isEnabled;

  AddedAppInfo({
    this.id,
    required this.channelId,
    required this.appId,
    int? addTime,
    this.sortOrder = 0,
    this.isEnabled = true,
  }) : addTime = addTime ?? DateTime.now().millisecondsSinceEpoch;
}

/// 用户自定义标签实体
/// 按 (channelId, appId) 关联已添加应用，与 [AddedAppInfo] 同构；
/// 标签与渠道自带分类合并后供首页分类展示。
class AddedAppTag {
  /// 渠道类型
  final String channelId;

  /// 应用 ID（与 [AddedAppInfo.appId] 一致）
  final String appId;

  /// 用户自定义标签（可复用 AppCategory.id 或自由输入）
  final String tag;

  /// 添加时间（毫秒时间戳）
  final int addTime;

  AddedAppTag({
    required this.channelId,
    required this.appId,
    required this.tag,
    int? addTime,
  }) : addTime = addTime ?? DateTime.now().millisecondsSinceEpoch;
}

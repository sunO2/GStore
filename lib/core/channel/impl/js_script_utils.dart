import 'package:gstore/core/model/AppSummary.dart';

/// JS 脚本返回数据解析公共工具（JsChannel / JsDetailChannel 共用）。
///
/// 脚本侧 AppInfo JSON 结构（与 db.AppInfo 同构）：
/// appId/name/user/repositories/icon/des/readme/category/extra；
/// user/repositories 脚本可不提供，由渠道兜底填 channelKey；extra 透传。

/// 任意 Map → String 键 Map（JS 桥返回的键可能非 String，统一转 String）。
/// 非 Map 入参 → 空 map（不抛）。
Map<String, dynamic> stringKeyedMap(dynamic value) {
  if (value is! Map) return <String, dynamic>{};
  return value.map((k, v) => MapEntry(k.toString(), v));
}

/// 脚本 AppInfo JSON → AppSummary；user/repositories 缺省兜底 [channelKey]；
/// 校验失败（非 Map / 缺 appId / 缺 name）→ null。
AppSummary? appSummaryFromScript(dynamic raw, {required String channelKey}) {
  if (raw is! Map) return null;
  final map = stringKeyedMap(raw);

  final appId = map['appId']?.toString() ?? '';
  final name = map['name']?.toString() ?? '';
  if (appId.isEmpty || name.isEmpty) return null;

  List<String>? category;
  final categoryRaw = map['category'];
  if (categoryRaw is List) {
    final items = categoryRaw
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    if (items.isNotEmpty) category = items;
  } else if (categoryRaw is String && categoryRaw.trim().isNotEmpty) {
    category = [categoryRaw.trim()];
  }

  Map<String, dynamic>? extra;
  final extraRaw = map['extra'];
  if (extraRaw is Map) {
    extra = stringKeyedMap(extraRaw);
  }

  final packageName =
      map['packageName']?.toString() ?? extra?['packageName']?.toString();

  return AppSummary(
    appId: appId,
    packageName: (packageName != null && packageName.isNotEmpty)
        ? packageName
        : null,
    name: name,
    user: map['user']?.toString() ?? channelKey, // 兜底 channelKey
    repositories: map['repositories']?.toString() ?? channelKey,
    icon: map['icon']?.toString() ?? '',
    des: map['des']?.toString() ?? map['description']?.toString() ?? '',
    readme: map['readme']?.toString(),
    category: category,
    extra: extra,
  );
}

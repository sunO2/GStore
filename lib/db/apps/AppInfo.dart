import 'dart:convert';

import 'package:floor/floor.dart';

@entity
class AppInfo {
  @primaryKey
  final String appId;
  final String name;
  final String user;
  final String repositories;
  final String icon;
  final String des;
  final String? readme; // README 内容，支持 Markdown
  final List<String>? category;
  final String? extra; // 扩展字段，JSON 字符串格式存储额外信息

  AppInfo(
    this.appId,
    this.name,
    this.user,
    this.repositories,
    this.icon,
    this.des,
    this.category,
  ) : readme = null,
       extra = null;

  // 带 readme 的构造函数
  AppInfo.withReadme(
    this.appId,
    this.name,
    this.user,
    this.repositories,
    this.icon,
    this.des,
    this.readme,
    this.category,
  ) : extra = null;

  // 带 extra 的构造函数
  AppInfo.withExtra(
    this.appId,
    this.name,
    this.user,
    this.repositories,
    this.icon,
    this.des,
    this.category,
    this.extra,
  ) : readme = null;

  /// 从 extra 中获取 JSON 数据
  Map<String, dynamic>? getExtraData() {
    if (extra == null || extra!.isEmpty) return null;
    try {
      return jsonDecode(extra!) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// 从 extra 中获取指定字段的值
  T? getExtra<T>(String key) {
    final data = getExtraData();
    if (data == null) return null;
    final value = data[key];
    if (value is T) return value;
    return null;
  }

  @override
  String toString() {
    return '''{
      appId=$appId,
      name=$name,
      user=$user,
      repositories=$repositories,
      icon=$icon,
      des=$des,
      readme=$readme,
      category=$category,
      extra=$extra
    }''';
  }
}

@entity
class AppInfoConfig {
  @primaryKey
  final String version;
  final String? proxy;
  AppInfoConfig(this.version, this.proxy);

  @override
  String toString() {
    return '''AppInfoConfig={
      version=$version,
      proxy=$proxy,
    }''';
  }
}

@entity
class AppCategory {
  @primaryKey
  final String id;
  final String description;
  final String icon;
  AppCategory(this.id, this.description, this.icon);
}

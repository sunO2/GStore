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
  final List<String>? category;
  AppInfo(this.appId, this.name, this.user, this.repositories, this.icon,
      this.des, this.category);

  @override
  String toString() {
    return '''{
      appId=$appId,
      name=$name,
      user=$user,
      repositories=$repositories,
      icon=$icon,
      des=$des,
      category=$category
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

// required package imports
import 'dart:async';
import 'dart:io';
import 'package:floor/floor.dart';
import 'package:gstore/db/apps/AppInfoDao.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:gstore/db/apps/AppInfo.dart';

part 'AppInfoDatabase.g.dart';

@TypeConverters([CategoryConverter])
@Database(version: 1, entities: [AppInfo, AppInfoConfig])
abstract class AppInfoDatabase extends FloorDatabase {
  AppInfoDao get dao;
}

Future<AppInfoDatabase> get appInfoDatabase => Builder("apps.db").build();

class Builder extends _$AppInfoDatabaseBuilder {
  Builder(super.name);

  @override
  Future<AppInfoDatabase> build() async {
    var p = await getDownloadsDirectory();
    var path = File("${p?.path}/$name");

    final database = _$AppInfoDatabase();
    database.database = await database.open(
      path.path,
      _migrations,
      _callback,
    );
    return database;
  }
}

class CategoryConverter extends TypeConverter<List<String>?, String?> {
  @override
  List<String> decode(String? databaseValue) {
    return databaseValue?.split(",") ?? [];
  }

  @override
  String encode(List<String>? value) {
    return value?.join(",") ?? "";
  }
}

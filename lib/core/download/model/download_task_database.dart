import 'dart:async';

import 'package:floor/floor.dart';
import 'package:gstore/core/download/model/download_task_dao.dart';
import 'package:gstore/core/download/model/download_task_entity.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

part 'download_task_database.g.dart'; // the generated code will be there

@Database(
  version: 1,
  entities: [DownloadTaskEntity],
)
abstract class GStoreDownloadDatabase extends FloorDatabase {
  DownloadTaskDao get downloadTaskDao;
}

GStoreDownloadDatabase? _cachedDownloadTaskDatabase;

Future<GStoreDownloadDatabase> get downloadTaskDatabase async {
  _cachedDownloadTaskDatabase ??= await $FloorGStoreDownloadDatabase
      .databaseBuilder('download_task.db')
      .build();
  return _cachedDownloadTaskDatabase!;
}

Future<void> closeDownloadTaskDatabase() async {
  if (_cachedDownloadTaskDatabase != null) {
    await _cachedDownloadTaskDatabase!.close();
    _cachedDownloadTaskDatabase = null;
  }
}
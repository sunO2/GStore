import 'package:floor/floor.dart';
import 'package:gstore/http/download/DownloadStatusDao.dart';
import 'package:gstore/http/download/DownloadStatus.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'dart:async';

part 'DownloadStatusDataBase.g.dart'; // the generated code will be there

@Database(version: 1, entities: [DownloadStatus])
abstract class AppDatabase extends FloorDatabase {
  DownloadstatusDao get downloadStatusDao;
}

Future<AppDatabase> get downloadStatusDatabase =>
    $FloorAppDatabase.databaseBuilder('app_database.db').build();

void test() {}

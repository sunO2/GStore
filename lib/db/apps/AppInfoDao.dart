import 'package:floor/floor.dart';
import 'package:gstore/db/apps/AppInfo.dart';

@dao
abstract class AppInfoDao {
  @Query('SELECT * FROM apps')
  Future<List<AppInfo>> getAllApps();

  Future<List<AppInfo>> search(String word) {
    return searchWord('%$word%');
  }

  @Query('SELECT * FROM apps WHERE name LIKE :word OR des LIKE :word')
  Future<List<AppInfo>> searchWord(String word);

  @Query('SELECT * FROM config LIMIT 1')
  Future<AppInfoConfig?> getVersion();
}

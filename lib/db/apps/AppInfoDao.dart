import 'package:floor/floor.dart';
import 'package:gstore/db/apps/AppInfo.dart';

@dao
abstract class AppInfoDao {
  @Query('SELECT * FROM apps')
  Future<List<AppInfo>> getAllApps();

  @Query('SELECT * FROM apps WHERE appId = :appId')
  Future<AppInfo?> getAppInfo(String appId);

  Future<List<AppInfo>> search(String word) => searchWord('%$word%');

  @Query('SELECT * FROM apps WHERE name LIKE :word OR des LIKE :word')
  Future<List<AppInfo>> searchWord(String word);

  @Query('SELECT * FROM config LIMIT 1')
  Future<AppInfoConfig?> getVersion();

  @Query('SELECT * FROM category')
  Future<List<AppCategory>> getAllCategory();

  @Query('SELECT * FROM category WHERE id = :id')
  Future<AppCategory?> queryCategory(String id);

  @Query('SELECT * FROM apps WHERE category LIKE :word LIMIT :limit')
  Future<List<AppInfo>> searchCategoryLike(String word, {int limit = -1});
}

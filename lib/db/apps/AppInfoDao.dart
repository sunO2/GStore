import 'package:floor/floor.dart';
import 'package:gstore/db/apps/AppInfo.dart';

@dao
abstract class AppInfoDao {
  @Query('SELECT * FROM apps')
  Future<List<AppInfo>> getAllApps();

  @Query('SELECT * FROM apps WHERE appId = :appId')
  Future<AppInfo?> getAppInfo(String appId);

  /// FTS5 全文搜索（unicode61 + 前缀匹配）
  /// FTS5 主查询 + LIKE 兜底（保证中文等场景的匹配完整性）
  Future<List<AppInfo>> search(String word) async {
    if (word.isEmpty) return const [];

    var results = <AppInfo>[];
    try {
      // FTS5 前缀匹配（对英文/拼音/数字高效）
      final escaped = word.replaceAll('"', '""');
      results = await searchFts('"$escaped"*');
    } catch (e) {
      // FTS 查询失败（如 tokenizer 不支持）时忽略
    }

    // LIKE 兜底：合并 FTS 未覆盖的模糊匹配结果
    try {
      final likeResults = await searchWord('%$word%');
      final ftsIds = results.map((a) => a.appId).toSet();
      for (final app in likeResults) {
        if (!ftsIds.contains(app.appId)) {
          results.add(app);
        }
      }
    } catch (e) {
      // 忽略
    }
    return results;
  }

  @Query('SELECT * FROM apps WHERE name LIKE :word OR des LIKE :word')
  Future<List<AppInfo>> searchWord(String word);

  /// FTS5 全文搜索
  /// 使用 trigram tokenizer 支持中英文子串匹配
  @Query('''
    SELECT * FROM apps
    WHERE rowid IN (SELECT rowid FROM apps_fts WHERE apps_fts MATCH :word)
    ORDER BY rowid
  ''')
  Future<List<AppInfo>> searchFts(String word);

  @Query('SELECT * FROM config LIMIT 1')
  Future<AppInfoConfig?> getVersion();

  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> insertConfig(AppInfoConfig config);

  @Query('SELECT * FROM category')
  Future<List<AppCategory>> getAllCategory();

  Future<List<AppInfo>> queryCategory(String word) =>
      searchCategoryLike('%$word%');

  @Query('SELECT * FROM apps WHERE category LIKE :word')
  Future<List<AppInfo>> searchCategoryLike(String word);
}

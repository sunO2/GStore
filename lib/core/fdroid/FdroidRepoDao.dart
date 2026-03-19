import 'package:floor/floor.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';

/// F-Droid 仓库数据库 DAO
@dao
abstract class FdroidRepoDao {
  /// ==================== 应用信息 ====================

  /// 插入或更新应用
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> upsertApp(FdroidApp app);

  /// 批量插入或更新应用
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> upsertApps(List<FdroidApp> apps);

  /// 根据包名获取应用
  @Query('SELECT * FROM FdroidApp WHERE packageName = :packageName')
  Future<FdroidApp?> getApp(String packageName);

  /// 搜索应用（名称、摘要、包名）
  @Query('''
    SELECT * FROM FdroidApp
    WHERE name LIKE '%' || :keyword || '%'
       OR summary LIKE '%' || :keyword || '%'
       OR packageName LIKE '%' || :keyword || '%'
    ORDER BY name ASC
    LIMIT :limit
  ''')
  Future<List<FdroidApp>> searchApps(String keyword, int limit);

  /// 获取所有应用
  @Query('SELECT * FROM FdroidApp ORDER BY name ASC')
  Future<List<FdroidApp>> getAllApps();

  /// 按分类获取应用（由于分类不在数据库中，此方法暂时不可用）
  // TODO: 实现分类搜索功能
  // Future<List<FdroidApp>> getAppsByCategory(String category);

  /// 删除应用
  @Query('DELETE FROM FdroidApp WHERE packageName = :packageName')
  Future<void> deleteApp(String packageName);

  /// 获取应用总数
  @Query('SELECT COUNT(*) FROM FdroidApp')
  Future<int?> getAppCount();

  /// ==================== 包信息 ====================

  /// 插入或更新包
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> upsertPackage(FdroidPackage package);

  /// 批量插入或更新包
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> upsertPackages(List<FdroidPackage> packages);

  /// 获取应用的所有包
  @Query('''
    SELECT * FROM FdroidPackage
    WHERE packageName = :packageName
    ORDER BY versionCode DESC
  ''')
  Future<List<FdroidPackage>> getPackages(String packageName);

  /// 获取应用的最新包
  @Query('''
    SELECT * FROM FdroidPackage
    WHERE packageName = :packageName
    ORDER BY versionCode DESC
    LIMIT 1
  ''')
  Future<FdroidPackage?> getLatestPackage(String packageName);

  /// 删除应用的所有包
  @Query('DELETE FROM FdroidPackage WHERE packageName = :packageName')
  Future<void> deletePackages(String packageName);

  /// 获取包总数
  @Query('SELECT COUNT(*) FROM FdroidPackage')
  Future<int?> getPackageCount();

  /// ==================== 版本管理 ====================

  /// 获取版本信息
  @Query('SELECT * FROM FdroidVersionInfo WHERE repoUrl = :repoUrl')
  Future<FdroidVersionInfo?> getVersionInfo(String repoUrl);

  /// 保存或更新版本信息
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<void> upsertVersionInfo(FdroidVersionInfo info);

  /// 删除版本信息
  @Query('DELETE FROM FdroidVersionInfo WHERE repoUrl = :repoUrl')
  Future<void> deleteVersionInfo(String repoUrl);

  /// 清空所有数据
  @Query('DELETE FROM FdroidApp')
  Future<void> clearApps();

  @Query('DELETE FROM FdroidPackage')
  Future<void> clearPackages();

  /// ==================== 数据库维护 ====================

  /// 获取应用总数（数据库大小）
  @Query('SELECT COUNT(*) FROM FdroidApp')
  Future<int?> getDatabaseSize();
}

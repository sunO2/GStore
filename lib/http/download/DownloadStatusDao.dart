import 'package:floor/floor.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

@dao
abstract class DownloadstatusDao {
  /// 获取所有下载记录（按创建时间倒序）
  @Query('SELECT * FROM DownloadStatus ORDER BY createTime DESC')
  Stream<List<DownloadStatus>> getAllDownload();

  /// 按状态筛选下载记录
  @Query('SELECT * FROM DownloadStatus WHERE status = :status ORDER BY createTime DESC')
  Stream<List<DownloadStatus>> getDownloadsByStatus(int status);

  /// 获取指定文件和版本的下载记录
  @Query(
      'SELECT * FROM DownloadStatus WHERE fileName = :name AND version = :version')
  Future<DownloadStatus?> getDownloadOfName(String name, String version);

  /// 获取指定应用的下载记录
  @Query('SELECT * FROM DownloadStatus WHERE appId = :appId ORDER BY createTime DESC')
  Stream<List<DownloadStatus>> getDownloadsByAppId(String appId);

  /// 获取下载中的记录
  @Query('SELECT * FROM DownloadStatus WHERE status = 2 ORDER BY createTime DESC')
  Future<List<DownloadStatus>> getDownloadingItems();

  /// 获取已完成的记录（成功或失败）
  @Query('SELECT * FROM DownloadStatus WHERE status IN (3, -1) ORDER BY createTime DESC')
  Future<List<DownloadStatus>> getCompletedItems();

  @Insert(onConflict: OnConflictStrategy.ignore)
  Future<int> insertPerson(DownloadStatus person);

  @Update(onConflict: OnConflictStrategy.replace)
  Future<void> updateDownload(DownloadStatus person);

  /// 删除指定的下载记录
  @Query('DELETE FROM DownloadStatus WHERE id = :id')
  Future<void> deleteDownload(int id);

  /// 删除指定应用的所有下载记录
  @Query('DELETE FROM DownloadStatus WHERE appId = :appId')
  Future<void> deleteDownloadsByAppId(String appId);

  /// 删除已完成的下载记录（成功或失败）
  @Query('DELETE FROM DownloadStatus WHERE status IN (3, -1)')
  Future<void> deleteCompletedDownloads();

  /// 清空所有下载记录
  @Query('DELETE FROM DownloadStatus')
  Future<void> deleteAllDownloads();
}

import 'package:floor/floor.dart';
import 'package:gstore/core/download/model/download_task_entity.dart';

@dao
abstract class DownloadTaskDao {
  @Insert()
  Future<int> insertTask(DownloadTaskEntity task);

  @Update()
  Future<void> updateTask(DownloadTaskEntity task);

  @Query('SELECT * FROM DownloadTaskEntity WHERE id = :id LIMIT 1')
  Future<DownloadTaskEntity?> getTask(int id);

  @Query(
      'SELECT * FROM DownloadTaskEntity WHERE appId = :appId AND version = :version AND fileName = :fileName LIMIT 1')
  Future<DownloadTaskEntity?> getTaskByKey(
      String appId, String version, String fileName);

  @Query('SELECT * FROM DownloadTaskEntity')
  Future<List<DownloadTaskEntity>> getAllTasks();
}
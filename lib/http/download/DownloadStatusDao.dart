import 'package:floor/floor.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

@dao
abstract class DownloadstatusDao {
  @Query('SELECT * FROM DownloadStatus')
  Future<List<DownloadStatus>> getAllDownload();

  @Query(
      'SELECT * FROM DownloadStatus WHERE fileName = :name AND version = :version')
  Future<DownloadStatus?> getDownloadOfName(String name, String version);

  @Insert(onConflict: OnConflictStrategy.ignore)
  Future<int> insertPerson(DownloadStatus person);

  @Update(onConflict: OnConflictStrategy.replace)
  Future<void> updateDownload(DownloadStatus person);
}

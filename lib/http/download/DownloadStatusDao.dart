import 'package:floor/floor.dart';
import 'package:gstore/http/download/DownloadStatus.dart';

@dao
abstract class DownloadstatusDao {
  @Query('SELECT * FROM DownloadStatus')
  Future<List<DownloadStatus>> findAllPeople();

  @Query('SELECT name FROM DownloadStatus')
  Stream<List<DownloadStatus>> findAllPeopleName();

  @Query('SELECT * FROM DownloadStatus WHERE name = :name')
  Stream<DownloadStatus?> findPersonById(String name);

  @Insert(onConflict: OnConflictStrategy.ignore)
  Future<void> insertPerson(DownloadStatus person);

  @Update(onConflict: OnConflictStrategy.replace)
  Future<void> updateDownload(DownloadStatus person);
}

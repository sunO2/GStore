// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'DownloadStatusDataBase.dart';

// **************************************************************************
// FloorGenerator
// **************************************************************************

abstract class $DownloadDatabaseBuilderContract {
  /// Adds migrations to the builder.
  $DownloadDatabaseBuilderContract addMigrations(List<Migration> migrations);

  /// Adds a database [Callback] to the builder.
  $DownloadDatabaseBuilderContract addCallback(Callback callback);

  /// Creates the database and initializes it.
  Future<DownloadDatabase> build();
}

// ignore: avoid_classes_with_only_static_members
class $FloorDownloadDatabase {
  /// Creates a database builder for a persistent database.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $DownloadDatabaseBuilderContract databaseBuilder(String name) =>
      _$DownloadDatabaseBuilder(name);

  /// Creates a database builder for an in memory database.
  /// Information stored in an in memory database disappears when the process is killed.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $DownloadDatabaseBuilderContract inMemoryDatabaseBuilder() =>
      _$DownloadDatabaseBuilder(null);
}

class _$DownloadDatabaseBuilder implements $DownloadDatabaseBuilderContract {
  _$DownloadDatabaseBuilder(this.name);

  final String? name;

  final List<Migration> _migrations = [];

  Callback? _callback;

  @override
  $DownloadDatabaseBuilderContract addMigrations(List<Migration> migrations) {
    _migrations.addAll(migrations);
    return this;
  }

  @override
  $DownloadDatabaseBuilderContract addCallback(Callback callback) {
    _callback = callback;
    return this;
  }

  @override
  Future<DownloadDatabase> build() async {
    final path = name != null
        ? await sqfliteDatabaseFactory.getDatabasePath(name!)
        : ':memory:';
    final database = _$DownloadDatabase();
    database.database = await database.open(
      path,
      _migrations,
      _callback,
    );
    return database;
  }
}

class _$DownloadDatabase extends DownloadDatabase {
  _$DownloadDatabase([StreamController<String>? listener]) {
    changeListener = listener ?? StreamController<String>.broadcast();
  }

  DownloadstatusDao? _downloadStatusDaoInstance;

  Future<sqflite.Database> open(
    String path,
    List<Migration> migrations, [
    Callback? callback,
  ]) async {
    final databaseOptions = sqflite.OpenDatabaseOptions(
      version: 1,
      onConfigure: (database) async {
        await database.execute('PRAGMA foreign_keys = ON');
        await callback?.onConfigure?.call(database);
      },
      onOpen: (database) async {
        await callback?.onOpen?.call(database);
      },
      onUpgrade: (database, startVersion, endVersion) async {
        await MigrationAdapter.runMigrations(
            database, startVersion, endVersion, migrations);

        await callback?.onUpgrade?.call(database, startVersion, endVersion);
      },
      onCreate: (database, version) async {
        await database.execute(
            'CREATE TABLE IF NOT EXISTS `DownloadStatus` (`id` INTEGER PRIMARY KEY AUTOINCREMENT, `appId` TEXT NOT NULL, `appName` TEXT NOT NULL, `version` TEXT NOT NULL, `fileName` TEXT NOT NULL, `downloadUrl` TEXT NOT NULL, `savePath` TEXT NOT NULL, `createTime` INTEGER NOT NULL, `total` INTEGER NOT NULL, `count` INTEGER NOT NULL, `status` INTEGER NOT NULL)');

        await callback?.onCreate?.call(database, version);
      },
    );
    return sqfliteDatabaseFactory.openDatabase(path, options: databaseOptions);
  }

  @override
  DownloadstatusDao get downloadStatusDao {
    return _downloadStatusDaoInstance ??=
        _$DownloadstatusDao(database, changeListener);
  }
}

class _$DownloadstatusDao extends DownloadstatusDao {
  _$DownloadstatusDao(
    this.database,
    this.changeListener,
  )   : _queryAdapter = QueryAdapter(database, changeListener),
        _downloadStatusInsertionAdapter = InsertionAdapter(
            database,
            'DownloadStatus',
            (DownloadStatus item) => <String, Object?>{
                  'id': item.id,
                  'appId': item.appId,
                  'appName': item.appName,
                  'version': item.version,
                  'fileName': item.fileName,
                  'downloadUrl': item.downloadUrl,
                  'savePath': item.savePath,
                  'createTime': item.createTime,
                  'total': item.total,
                  'count': item.count,
                  'status': item.status
                },
            changeListener),
        _downloadStatusUpdateAdapter = UpdateAdapter(
            database,
            'DownloadStatus',
            ['id'],
            (DownloadStatus item) => <String, Object?>{
                  'id': item.id,
                  'appId': item.appId,
                  'appName': item.appName,
                  'version': item.version,
                  'fileName': item.fileName,
                  'downloadUrl': item.downloadUrl,
                  'savePath': item.savePath,
                  'createTime': item.createTime,
                  'total': item.total,
                  'count': item.count,
                  'status': item.status
                },
            changeListener);

  final sqflite.DatabaseExecutor database;

  final StreamController<String> changeListener;

  final QueryAdapter _queryAdapter;

  final InsertionAdapter<DownloadStatus> _downloadStatusInsertionAdapter;

  final UpdateAdapter<DownloadStatus> _downloadStatusUpdateAdapter;

  @override
  Stream<List<DownloadStatus>> getAllDownload() {
    return _queryAdapter.queryListStream(
        'SELECT * FROM DownloadStatus ORDER BY createTime DESC',
        mapper: (Map<String, Object?> row) => DownloadStatus(
            row['appId'] as String,
            row['appName'] as String,
            row['version'] as String,
            row['fileName'] as String,
            row['downloadUrl'] as String,
            row['savePath'] as String,
            total: row['total'] as int,
            count: row['count'] as int,
            status: row['status'] as int,
            id: row['id'] as int?,
            createTime: row['createTime'] as int),
        queryableName: 'DownloadStatus',
        isView: false);
  }

  @override
  Future<DownloadStatus?> getDownloadOfName(
    String name,
    String version,
  ) async {
    return _queryAdapter.query(
        'SELECT * FROM DownloadStatus WHERE fileName = ?1 AND version = ?2',
        mapper: (Map<String, Object?> row) => DownloadStatus(
            row['appId'] as String,
            row['appName'] as String,
            row['version'] as String,
            row['fileName'] as String,
            row['downloadUrl'] as String,
            row['savePath'] as String,
            total: row['total'] as int,
            count: row['count'] as int,
            status: row['status'] as int,
            id: row['id'] as int?,
            createTime: row['createTime'] as int),
        arguments: [name, version]);
  }

  @override
  Future<int> insertPerson(DownloadStatus person) {
    return _downloadStatusInsertionAdapter.insertAndReturnId(
        person, OnConflictStrategy.ignore);
  }

  @override
  Future<void> updateDownload(DownloadStatus person) async {
    await _downloadStatusUpdateAdapter.update(
        person, OnConflictStrategy.replace);
  }
}

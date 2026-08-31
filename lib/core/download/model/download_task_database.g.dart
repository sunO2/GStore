// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_task_database.dart';

// **************************************************************************
// FloorGenerator
// **************************************************************************

abstract class $GStoreDownloadDatabaseBuilderContract {
  /// Adds migrations to the builder.
  $GStoreDownloadDatabaseBuilderContract addMigrations(
      List<Migration> migrations);

  /// Adds a database [Callback] to the builder.
  $GStoreDownloadDatabaseBuilderContract addCallback(Callback callback);

  /// Creates the database and initializes it.
  Future<GStoreDownloadDatabase> build();
}

// ignore: avoid_classes_with_only_static_members
class $FloorGStoreDownloadDatabase {
  /// Creates a database builder for a persistent database.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $GStoreDownloadDatabaseBuilderContract databaseBuilder(String name) =>
      _$GStoreDownloadDatabaseBuilder(name);

  /// Creates a database builder for an in memory database.
  /// Information stored in an in memory database disappears when the process is killed.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $GStoreDownloadDatabaseBuilderContract inMemoryDatabaseBuilder() =>
      _$GStoreDownloadDatabaseBuilder(null);
}

class _$GStoreDownloadDatabaseBuilder
    implements $GStoreDownloadDatabaseBuilderContract {
  _$GStoreDownloadDatabaseBuilder(this.name);

  final String? name;

  final List<Migration> _migrations = [];

  Callback? _callback;

  @override
  $GStoreDownloadDatabaseBuilderContract addMigrations(
      List<Migration> migrations) {
    _migrations.addAll(migrations);
    return this;
  }

  @override
  $GStoreDownloadDatabaseBuilderContract addCallback(Callback callback) {
    _callback = callback;
    return this;
  }

  @override
  Future<GStoreDownloadDatabase> build() async {
    final path = name != null
        ? await sqfliteDatabaseFactory.getDatabasePath(name!)
        : ':memory:';
    final database = _$GStoreDownloadDatabase();
    database.database = await database.open(
      path,
      _migrations,
      _callback,
    );
    return database;
  }
}

class _$GStoreDownloadDatabase extends GStoreDownloadDatabase {
  _$GStoreDownloadDatabase([StreamController<String>? listener]) {
    changeListener = listener ?? StreamController<String>.broadcast();
  }

  DownloadTaskDao? _downloadTaskDaoInstance;

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
            'CREATE TABLE IF NOT EXISTS `DownloadTaskEntity` (`id` INTEGER PRIMARY KEY AUTOINCREMENT, `appId` TEXT NOT NULL, `appName` TEXT NOT NULL, `version` TEXT NOT NULL, `fileName` TEXT NOT NULL, `url` TEXT NOT NULL, `filePath` TEXT NOT NULL, `total` INTEGER NOT NULL, `received` INTEGER NOT NULL, `status` INTEGER NOT NULL, `speedBps` INTEGER NOT NULL, `etaSec` INTEGER, `error` TEXT, `segments` TEXT, `createdAt` INTEGER NOT NULL, `updatedAt` INTEGER NOT NULL)');

        await callback?.onCreate?.call(database, version);
      },
    );
    return sqfliteDatabaseFactory.openDatabase(path, options: databaseOptions);
  }

  @override
  DownloadTaskDao get downloadTaskDao {
    return _downloadTaskDaoInstance ??=
        _$DownloadTaskDao(database, changeListener);
  }
}

class _$DownloadTaskDao extends DownloadTaskDao {
  _$DownloadTaskDao(
    this.database,
    this.changeListener,
  )   : _queryAdapter = QueryAdapter(database),
        _downloadTaskEntityInsertionAdapter = InsertionAdapter(
            database,
            'DownloadTaskEntity',
            (DownloadTaskEntity item) => <String, Object?>{
                  'id': item.id,
                  'appId': item.appId,
                  'appName': item.appName,
                  'version': item.version,
                  'fileName': item.fileName,
                  'url': item.url,
                  'filePath': item.filePath,
                  'total': item.total,
                  'received': item.received,
                  'status': item.status,
                  'speedBps': item.speedBps,
                  'etaSec': item.etaSec,
                  'error': item.error,
                  'segments': item.segments,
                  'createdAt': item.createdAt,
                  'updatedAt': item.updatedAt
                }),
        _downloadTaskEntityUpdateAdapter = UpdateAdapter(
            database,
            'DownloadTaskEntity',
            ['id'],
            (DownloadTaskEntity item) => <String, Object?>{
                  'id': item.id,
                  'appId': item.appId,
                  'appName': item.appName,
                  'version': item.version,
                  'fileName': item.fileName,
                  'url': item.url,
                  'filePath': item.filePath,
                  'total': item.total,
                  'received': item.received,
                  'status': item.status,
                  'speedBps': item.speedBps,
                  'etaSec': item.etaSec,
                  'error': item.error,
                  'segments': item.segments,
                  'createdAt': item.createdAt,
                  'updatedAt': item.updatedAt
                });

  final sqflite.DatabaseExecutor database;

  final StreamController<String> changeListener;

  final QueryAdapter _queryAdapter;

  final InsertionAdapter<DownloadTaskEntity>
      _downloadTaskEntityInsertionAdapter;

  final UpdateAdapter<DownloadTaskEntity> _downloadTaskEntityUpdateAdapter;

  @override
  Future<DownloadTaskEntity?> getTask(int id) async {
    return _queryAdapter.query(
        'SELECT * FROM DownloadTaskEntity WHERE id = ?1 LIMIT 1',
        mapper: (Map<String, Object?> row) => DownloadTaskEntity(
            id: row['id'] as int?,
            appId: row['appId'] as String,
            appName: row['appName'] as String,
            version: row['version'] as String,
            fileName: row['fileName'] as String,
            url: row['url'] as String,
            filePath: row['filePath'] as String,
            total: row['total'] as int,
            received: row['received'] as int,
            status: row['status'] as int,
            speedBps: row['speedBps'] as int,
            etaSec: row['etaSec'] as int?,
            error: row['error'] as String?,
            segments: row['segments'] as String?,
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int),
        arguments: [id]);
  }

  @override
  Future<DownloadTaskEntity?> getTaskByKey(
    String appId,
    String version,
    String fileName,
  ) async {
    return _queryAdapter.query(
        'SELECT * FROM DownloadTaskEntity WHERE appId = ?1 AND version = ?2 AND fileName = ?3 LIMIT 1',
        mapper: (Map<String, Object?> row) => DownloadTaskEntity(id: row['id'] as int?, appId: row['appId'] as String, appName: row['appName'] as String, version: row['version'] as String, fileName: row['fileName'] as String, url: row['url'] as String, filePath: row['filePath'] as String, total: row['total'] as int, received: row['received'] as int, status: row['status'] as int, speedBps: row['speedBps'] as int, etaSec: row['etaSec'] as int?, error: row['error'] as String?, segments: row['segments'] as String?, createdAt: row['createdAt'] as int, updatedAt: row['updatedAt'] as int),
        arguments: [appId, version, fileName]);
  }

  @override
  Future<List<DownloadTaskEntity>> getAllTasks() async {
    return _queryAdapter.queryList('SELECT * FROM DownloadTaskEntity',
        mapper: (Map<String, Object?> row) => DownloadTaskEntity(
            id: row['id'] as int?,
            appId: row['appId'] as String,
            appName: row['appName'] as String,
            version: row['version'] as String,
            fileName: row['fileName'] as String,
            url: row['url'] as String,
            filePath: row['filePath'] as String,
            total: row['total'] as int,
            received: row['received'] as int,
            status: row['status'] as int,
            speedBps: row['speedBps'] as int,
            etaSec: row['etaSec'] as int?,
            error: row['error'] as String?,
            segments: row['segments'] as String?,
            createdAt: row['createdAt'] as int,
            updatedAt: row['updatedAt'] as int));
  }

  @override
  Future<int> insertTask(DownloadTaskEntity task) {
    return _downloadTaskEntityInsertionAdapter.insertAndReturnId(
        task, OnConflictStrategy.abort);
  }

  @override
  Future<void> updateTask(DownloadTaskEntity task) async {
    await _downloadTaskEntityUpdateAdapter.update(
        task, OnConflictStrategy.abort);
  }
}

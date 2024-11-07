// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'DownloadStatusDataBase.dart';

// **************************************************************************
// FloorGenerator
// **************************************************************************

abstract class $AppDatabaseBuilderContract {
  /// Adds migrations to the builder.
  $AppDatabaseBuilderContract addMigrations(List<Migration> migrations);

  /// Adds a database [Callback] to the builder.
  $AppDatabaseBuilderContract addCallback(Callback callback);

  /// Creates the database and initializes it.
  Future<AppDatabase> build();
}

// ignore: avoid_classes_with_only_static_members
class $FloorAppDatabase {
  /// Creates a database builder for a persistent database.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $AppDatabaseBuilderContract databaseBuilder(String name) =>
      _$AppDatabaseBuilder(name);

  /// Creates a database builder for an in memory database.
  /// Information stored in an in memory database disappears when the process is killed.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $AppDatabaseBuilderContract inMemoryDatabaseBuilder() =>
      _$AppDatabaseBuilder(null);
}

class _$AppDatabaseBuilder implements $AppDatabaseBuilderContract {
  _$AppDatabaseBuilder(this.name);

  final String? name;

  final List<Migration> _migrations = [];

  Callback? _callback;

  @override
  $AppDatabaseBuilderContract addMigrations(List<Migration> migrations) {
    _migrations.addAll(migrations);
    return this;
  }

  @override
  $AppDatabaseBuilderContract addCallback(Callback callback) {
    _callback = callback;
    return this;
  }

  @override
  Future<AppDatabase> build() async {
    final path = name != null
        ? await sqfliteDatabaseFactory.getDatabasePath(name!)
        : ':memory:';
    final database = _$AppDatabase();
    database.database = await database.open(
      path,
      _migrations,
      _callback,
    );
    return database;
  }
}

class _$AppDatabase extends AppDatabase {
  _$AppDatabase([StreamController<String>? listener]) {
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
            'CREATE TABLE IF NOT EXISTS `DownloadStatus` (`total` INTEGER NOT NULL, `count` INTEGER NOT NULL, `status` INTEGER NOT NULL, `name` TEXT NOT NULL, `downloadUrl` TEXT NOT NULL, `savePath` TEXT NOT NULL, PRIMARY KEY (`name`))');

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
                  'total': item.total,
                  'count': item.count,
                  'status': item.status,
                  'name': item.name,
                  'downloadUrl': item.downloadUrl,
                  'savePath': item.savePath
                },
            changeListener),
        _downloadStatusUpdateAdapter = UpdateAdapter(
            database,
            'DownloadStatus',
            ['name'],
            (DownloadStatus item) => <String, Object?>{
                  'total': item.total,
                  'count': item.count,
                  'status': item.status,
                  'name': item.name,
                  'downloadUrl': item.downloadUrl,
                  'savePath': item.savePath
                },
            changeListener);

  final sqflite.DatabaseExecutor database;

  final StreamController<String> changeListener;

  final QueryAdapter _queryAdapter;

  final InsertionAdapter<DownloadStatus> _downloadStatusInsertionAdapter;

  final UpdateAdapter<DownloadStatus> _downloadStatusUpdateAdapter;

  @override
  Future<List<DownloadStatus>> findAllPeople() async {
    return _queryAdapter.queryList('SELECT * FROM DownloadStatus',
        mapper: (Map<String, Object?> row) => DownloadStatus(
            row['name'] as String,
            row['downloadUrl'] as String,
            row['savePath'] as String));
  }

  @override
  Stream<List<DownloadStatus>> findAllPeopleName() {
    return _queryAdapter.queryListStream('SELECT name FROM DownloadStatus',
        mapper: (Map<String, Object?> row) => DownloadStatus(
            row['name'] as String,
            row['downloadUrl'] as String,
            row['savePath'] as String),
        queryableName: 'DownloadStatus',
        isView: false);
  }

  @override
  Stream<DownloadStatus?> findPersonById(String name) {
    return _queryAdapter.queryStream(
        'SELECT * FROM DownloadStatus WHERE name = ?1',
        mapper: (Map<String, Object?> row) => DownloadStatus(
            row['name'] as String,
            row['downloadUrl'] as String,
            row['savePath'] as String),
        arguments: [name],
        queryableName: 'DownloadStatus',
        isView: false);
  }

  @override
  Future<void> insertPerson(DownloadStatus person) async {
    await _downloadStatusInsertionAdapter.insert(
        person, OnConflictStrategy.ignore);
  }

  @override
  Future<void> updateDownload(DownloadStatus person) async {
    await _downloadStatusUpdateAdapter.update(
        person, OnConflictStrategy.replace);
  }
}

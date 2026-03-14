// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'AppAggregatorDatabase.dart';

// **************************************************************************
// FloorGenerator
// **************************************************************************

abstract class $AppAggregatorDatabaseBuilderContract {
  /// Adds migrations to the builder.
  $AppAggregatorDatabaseBuilderContract addMigrations(
      List<Migration> migrations);

  /// Adds a database [Callback] to the builder.
  $AppAggregatorDatabaseBuilderContract addCallback(Callback callback);

  /// Creates the database and initializes it.
  Future<AppAggregatorDatabase> build();
}

// ignore: avoid_classes_with_only_static_members
class $FloorAppAggregatorDatabase {
  /// Creates a database builder for a persistent database.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $AppAggregatorDatabaseBuilderContract databaseBuilder(String name) =>
      _$AppAggregatorDatabaseBuilder(name);

  /// Creates a database builder for an in memory database.
  /// Information stored in an in memory database disappears when the process is killed.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $AppAggregatorDatabaseBuilderContract inMemoryDatabaseBuilder() =>
      _$AppAggregatorDatabaseBuilder(null);
}

class _$AppAggregatorDatabaseBuilder
    implements $AppAggregatorDatabaseBuilderContract {
  _$AppAggregatorDatabaseBuilder(this.name);

  final String? name;

  final List<Migration> _migrations = [];

  Callback? _callback;

  @override
  $AppAggregatorDatabaseBuilderContract addMigrations(
      List<Migration> migrations) {
    _migrations.addAll(migrations);
    return this;
  }

  @override
  $AppAggregatorDatabaseBuilderContract addCallback(Callback callback) {
    _callback = callback;
    return this;
  }

  @override
  Future<AppAggregatorDatabase> build() async {
    final path = name != null
        ? await sqfliteDatabaseFactory.getDatabasePath(name!)
        : ':memory:';
    final database = _$AppAggregatorDatabase();
    database.database = await database.open(
      path,
      _migrations,
      _callback,
    );
    return database;
  }
}

class _$AppAggregatorDatabase extends AppAggregatorDatabase {
  _$AppAggregatorDatabase([StreamController<String>? listener]) {
    changeListener = listener ?? StreamController<String>.broadcast();
  }

  AddedAppDao? _addedAppDaoInstance;

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
            'CREATE TABLE IF NOT EXISTS `added_apps` (`channelId` TEXT NOT NULL, `appId` TEXT NOT NULL, `appName` TEXT NOT NULL, `iconUrl` TEXT, `description` TEXT, `category` TEXT, `addTime` INTEGER NOT NULL, `sortOrder` INTEGER NOT NULL, PRIMARY KEY (`channelId`, `appId`))');

        await callback?.onCreate?.call(database, version);
      },
    );
    return sqfliteDatabaseFactory.openDatabase(path, options: databaseOptions);
  }

  @override
  AddedAppDao get addedAppDao {
    return _addedAppDaoInstance ??= _$AddedAppDao(database, changeListener);
  }
}

class _$AddedAppDao extends AddedAppDao {
  _$AddedAppDao(
    this.database,
    this.changeListener,
  )   : _queryAdapter = QueryAdapter(database),
        _addedAppInfoInsertionAdapter = InsertionAdapter(
            database,
            'added_apps',
            (AddedAppInfo item) => <String, Object?>{
                  'channelId': item.channelId,
                  'appId': item.appId,
                  'appName': item.appName,
                  'iconUrl': item.iconUrl,
                  'description': item.description,
                  'category': item.category,
                  'addTime': item.addTime,
                  'sortOrder': item.sortOrder
                });

  final sqflite.DatabaseExecutor database;

  final StreamController<String> changeListener;

  final QueryAdapter _queryAdapter;

  final InsertionAdapter<AddedAppInfo> _addedAppInfoInsertionAdapter;

  @override
  Future<void> removeApp(
    String channelId,
    String appId,
  ) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM added_apps WHERE channelId = ?1 AND appId = ?2',
        arguments: [channelId, appId]);
  }

  @override
  Future<List<AddedAppInfo>> getAllAddedApps() async {
    return _queryAdapter.queryList(
        'SELECT * FROM added_apps ORDER BY addTime DESC',
        mapper: (Map<String, Object?> row) => AddedAppInfo(
            channelId: row['channelId'] as String,
            appId: row['appId'] as String,
            appName: row['appName'] as String,
            iconUrl: row['iconUrl'] as String?,
            description: row['description'] as String?,
            category: row['category'] as String?,
            addTime: row['addTime'] as int?,
            sortOrder: row['sortOrder'] as int));
  }

  @override
  Future<List<AddedAppInfo>> getAppsByChannel(String channelId) async {
    return _queryAdapter.queryList(
        'SELECT * FROM added_apps WHERE channelId = ?1 ORDER BY addTime DESC',
        mapper: (Map<String, Object?> row) => AddedAppInfo(
            channelId: row['channelId'] as String,
            appId: row['appId'] as String,
            appName: row['appName'] as String,
            iconUrl: row['iconUrl'] as String?,
            description: row['description'] as String?,
            category: row['category'] as String?,
            addTime: row['addTime'] as int?,
            sortOrder: row['sortOrder'] as int),
        arguments: [channelId]);
  }

  @override
  Future<AddedAppInfo?> getApp(
    String channelId,
    String appId,
  ) async {
    return _queryAdapter.query(
        'SELECT * FROM added_apps WHERE channelId = ?1 AND appId = ?2 LIMIT 1',
        mapper: (Map<String, Object?> row) => AddedAppInfo(
            channelId: row['channelId'] as String,
            appId: row['appId'] as String,
            appName: row['appName'] as String,
            iconUrl: row['iconUrl'] as String?,
            description: row['description'] as String?,
            category: row['category'] as String?,
            addTime: row['addTime'] as int?,
            sortOrder: row['sortOrder'] as int),
        arguments: [channelId, appId]);
  }

  @override
  Future<void> clearChannel(String channelId) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM added_apps WHERE channelId = ?1',
        arguments: [channelId]);
  }

  @override
  Future<void> clearAll() async {
    await _queryAdapter.queryNoReturn('DELETE FROM added_apps');
  }

  @override
  Future<int?> getTotalCount() async {
    return _queryAdapter.query('SELECT COUNT(*) FROM added_apps',
        mapper: (Map<String, Object?> row) => row.values.first as int);
  }

  @override
  Future<int?> getCountByChannel(String channelId) async {
    return _queryAdapter.query(
        'SELECT COUNT(*) FROM added_apps WHERE channelId = ?1',
        mapper: (Map<String, Object?> row) => row.values.first as int,
        arguments: [channelId]);
  }

  @override
  Future<void> insertApp(AddedAppInfo app) async {
    await _addedAppInfoInsertionAdapter.insert(app, OnConflictStrategy.replace);
  }

  @override
  Future<void> insertApps(List<AddedAppInfo> apps) async {
    await _addedAppInfoInsertionAdapter.insertList(
        apps, OnConflictStrategy.replace);
  }
}

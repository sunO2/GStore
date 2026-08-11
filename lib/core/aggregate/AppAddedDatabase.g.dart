// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'AppAddedDatabase.dart';

// **************************************************************************
// FloorGenerator
// **************************************************************************

abstract class $AppAddedDatabaseBuilderContract {
  /// Adds migrations to the builder.
  $AppAddedDatabaseBuilderContract addMigrations(List<Migration> migrations);

  /// Adds a database [Callback] to the builder.
  $AppAddedDatabaseBuilderContract addCallback(Callback callback);

  /// Creates the database and initializes it.
  Future<AppAddedDatabase> build();
}

// ignore: avoid_classes_with_only_static_members
class $FloorAppAddedDatabase {
  /// Creates a database builder for a persistent database.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $AppAddedDatabaseBuilderContract databaseBuilder(String name) =>
      _$AppAddedDatabaseBuilder(name);

  /// Creates a database builder for an in memory database.
  /// Information stored in an in memory database disappears when the process is killed.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $AppAddedDatabaseBuilderContract inMemoryDatabaseBuilder() =>
      _$AppAddedDatabaseBuilder(null);
}

class _$AppAddedDatabaseBuilder implements $AppAddedDatabaseBuilderContract {
  _$AppAddedDatabaseBuilder(this.name);

  final String? name;

  final List<Migration> _migrations = [];

  Callback? _callback;

  @override
  $AppAddedDatabaseBuilderContract addMigrations(List<Migration> migrations) {
    _migrations.addAll(migrations);
    return this;
  }

  @override
  $AppAddedDatabaseBuilderContract addCallback(Callback callback) {
    _callback = callback;
    return this;
  }

  @override
  Future<AppAddedDatabase> build() async {
    final path = name != null
        ? await sqfliteDatabaseFactory.getDatabasePath(name!)
        : ':memory:';
    final database = _$AppAddedDatabase();
    database.database = await database.open(
      path,
      _migrations,
      _callback,
    );
    return database;
  }
}

class _$AppAddedDatabase extends AppAddedDatabase {
  _$AppAddedDatabase([StreamController<String>? listener]) {
    changeListener = listener ?? StreamController<String>.broadcast();
  }

  AddedAppDao? _addedAppDaoInstance;

  AppTagDao? _appTagDaoInstance;

  Future<sqflite.Database> open(
    String path,
    List<Migration> migrations, [
    Callback? callback,
  ]) async {
    final databaseOptions = sqflite.OpenDatabaseOptions(
      version: 5,
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
            'CREATE TABLE IF NOT EXISTS `added_apps` (`id` INTEGER PRIMARY KEY AUTOINCREMENT, `channelId` TEXT NOT NULL, `appId` TEXT NOT NULL, `addTime` INTEGER NOT NULL, `sortOrder` INTEGER NOT NULL, `isEnabled` INTEGER NOT NULL)');
        await database.execute(
            'CREATE TABLE IF NOT EXISTS `added_app_tags` (`channelId` TEXT NOT NULL, `appId` TEXT NOT NULL, `tag` TEXT NOT NULL, `addTime` INTEGER NOT NULL, PRIMARY KEY (`channelId`, `appId`, `tag`))');
        await database.execute(
            'CREATE UNIQUE INDEX `index_added_apps_channelId_appId` ON `added_apps` (`channelId`, `appId`)');

        await callback?.onCreate?.call(database, version);
      },
    );
    return sqfliteDatabaseFactory.openDatabase(path, options: databaseOptions);
  }

  @override
  AddedAppDao get addedAppDao {
    return _addedAppDaoInstance ??= _$AddedAppDao(database, changeListener);
  }

  @override
  AppTagDao get appTagDao {
    return _appTagDaoInstance ??= _$AppTagDao(database, changeListener);
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
                  'id': item.id,
                  'channelId': item.channelId,
                  'appId': item.appId,
                  'addTime': item.addTime,
                  'sortOrder': item.sortOrder,
                  'isEnabled': item.isEnabled ? 1 : 0
                }),
        _addedAppInfoUpdateAdapter = UpdateAdapter(
            database,
            'added_apps',
            ['id'],
            (AddedAppInfo item) => <String, Object?>{
                  'id': item.id,
                  'channelId': item.channelId,
                  'appId': item.appId,
                  'addTime': item.addTime,
                  'sortOrder': item.sortOrder,
                  'isEnabled': item.isEnabled ? 1 : 0
                });

  final sqflite.DatabaseExecutor database;

  final StreamController<String> changeListener;

  final QueryAdapter _queryAdapter;

  final InsertionAdapter<AddedAppInfo> _addedAppInfoInsertionAdapter;

  final UpdateAdapter<AddedAppInfo> _addedAppInfoUpdateAdapter;

  @override
  Future<List<AddedAppInfo>> getAllAddedApps() async {
    return _queryAdapter.queryList(
        'SELECT * FROM added_apps ORDER BY addTime DESC',
        mapper: (Map<String, Object?> row) => AddedAppInfo(
            id: row['id'] as int?,
            channelId: row['channelId'] as String,
            appId: row['appId'] as String,
            addTime: row['addTime'] as int?,
            sortOrder: row['sortOrder'] as int,
            isEnabled: (row['isEnabled'] as int) != 0));
  }

  @override
  Future<List<AddedAppInfo>> getAppsByChannel(String channelId) async {
    return _queryAdapter.queryList(
        'SELECT * FROM added_apps WHERE channelId = ?1 ORDER BY addTime DESC',
        mapper: (Map<String, Object?> row) => AddedAppInfo(
            id: row['id'] as int?,
            channelId: row['channelId'] as String,
            appId: row['appId'] as String,
            addTime: row['addTime'] as int?,
            sortOrder: row['sortOrder'] as int,
            isEnabled: (row['isEnabled'] as int) != 0),
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
            id: row['id'] as int?,
            channelId: row['channelId'] as String,
            appId: row['appId'] as String,
            addTime: row['addTime'] as int?,
            sortOrder: row['sortOrder'] as int,
            isEnabled: (row['isEnabled'] as int) != 0),
        arguments: [channelId, appId]);
  }

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
  Future<void> updateSortOrder(
    int id,
    int sortOrder,
  ) async {
    await _queryAdapter.queryNoReturn(
        'UPDATE added_apps SET sortOrder = ?2 WHERE id = ?1',
        arguments: [id, sortOrder]);
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
  Future<int> insertApp(AddedAppInfo app) {
    return _addedAppInfoInsertionAdapter.insertAndReturnId(
        app, OnConflictStrategy.replace);
  }

  @override
  Future<List<int>> insertApps(List<AddedAppInfo> apps) {
    return _addedAppInfoInsertionAdapter.insertListAndReturnIds(
        apps, OnConflictStrategy.replace);
  }

  @override
  Future<void> updateApp(AddedAppInfo app) async {
    await _addedAppInfoUpdateAdapter.update(app, OnConflictStrategy.replace);
  }
}

class _$AppTagDao extends AppTagDao {
  _$AppTagDao(
    this.database,
    this.changeListener,
  )   : _queryAdapter = QueryAdapter(database),
        _addedAppTagInsertionAdapter = InsertionAdapter(
            database,
            'added_app_tags',
            (AddedAppTag item) => <String, Object?>{
                  'channelId': item.channelId,
                  'appId': item.appId,
                  'tag': item.tag,
                  'addTime': item.addTime
                });

  final sqflite.DatabaseExecutor database;

  final StreamController<String> changeListener;

  final QueryAdapter _queryAdapter;

  final InsertionAdapter<AddedAppTag> _addedAppTagInsertionAdapter;

  @override
  Future<List<AddedAppTag>> getTags(
    String channelId,
    String appId,
  ) async {
    return _queryAdapter.queryList(
        'SELECT * FROM added_app_tags WHERE channelId = ?1 AND appId = ?2 ORDER BY addTime',
        mapper: (Map<String, Object?> row) => AddedAppTag(channelId: row['channelId'] as String, appId: row['appId'] as String, tag: row['tag'] as String, addTime: row['addTime'] as int?),
        arguments: [channelId, appId]);
  }

  @override
  Future<List<AddedAppTag>> getTagsByChannel(String channelId) async {
    return _queryAdapter.queryList(
        'SELECT * FROM added_app_tags WHERE channelId = ?1',
        mapper: (Map<String, Object?> row) => AddedAppTag(
            channelId: row['channelId'] as String,
            appId: row['appId'] as String,
            tag: row['tag'] as String,
            addTime: row['addTime'] as int?),
        arguments: [channelId]);
  }

  @override
  Future<List<AddedAppTag>> getAllTags() async {
    return _queryAdapter.queryList('SELECT * FROM added_app_tags',
        mapper: (Map<String, Object?> row) => AddedAppTag(
            channelId: row['channelId'] as String,
            appId: row['appId'] as String,
            tag: row['tag'] as String,
            addTime: row['addTime'] as int?));
  }

  @override
  Future<void> removeTag(
    String channelId,
    String appId,
    String tag,
  ) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM added_app_tags WHERE channelId = ?1 AND appId = ?2 AND tag = ?3',
        arguments: [channelId, appId, tag]);
  }

  @override
  Future<void> removeTagsOfApp(
    String channelId,
    String appId,
  ) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM added_app_tags WHERE channelId = ?1 AND appId = ?2',
        arguments: [channelId, appId]);
  }

  @override
  Future<void> clearChannel(String channelId) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM added_app_tags WHERE channelId = ?1',
        arguments: [channelId]);
  }

  @override
  Future<void> clearAll() async {
    await _queryAdapter.queryNoReturn('DELETE FROM added_app_tags');
  }

  @override
  Future<void> insertTag(AddedAppTag tag) async {
    await _addedAppTagInsertionAdapter.insert(tag, OnConflictStrategy.replace);
  }

  @override
  Future<void> insertTags(List<AddedAppTag> tags) async {
    await _addedAppTagInsertionAdapter.insertList(
        tags, OnConflictStrategy.replace);
  }
}

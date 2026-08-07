// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'channel_database.dart';

// **************************************************************************
// FloorGenerator
// **************************************************************************

abstract class $ChannelDatabaseBuilderContract {
  /// Adds migrations to the builder.
  $ChannelDatabaseBuilderContract addMigrations(List<Migration> migrations);

  /// Adds a database [Callback] to the builder.
  $ChannelDatabaseBuilderContract addCallback(Callback callback);

  /// Creates the database and initializes it.
  Future<ChannelDatabase> build();
}

// ignore: avoid_classes_with_only_static_members
class $FloorChannelDatabase {
  /// Creates a database builder for a persistent database.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $ChannelDatabaseBuilderContract databaseBuilder(String name) =>
      _$ChannelDatabaseBuilder(name);

  /// Creates a database builder for an in memory database.
  /// Information stored in an in memory database disappears when the process is killed.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $ChannelDatabaseBuilderContract inMemoryDatabaseBuilder() =>
      _$ChannelDatabaseBuilder(null);
}

class _$ChannelDatabaseBuilder implements $ChannelDatabaseBuilderContract {
  _$ChannelDatabaseBuilder(this.name);

  final String? name;

  final List<Migration> _migrations = [];

  Callback? _callback;

  @override
  $ChannelDatabaseBuilderContract addMigrations(List<Migration> migrations) {
    _migrations.addAll(migrations);
    return this;
  }

  @override
  $ChannelDatabaseBuilderContract addCallback(Callback callback) {
    _callback = callback;
    return this;
  }

  @override
  Future<ChannelDatabase> build() async {
    final path = name != null
        ? await sqfliteDatabaseFactory.getDatabasePath(name!)
        : ':memory:';
    final database = _$ChannelDatabase();
    database.database = await database.open(
      path,
      _migrations,
      _callback,
    );
    return database;
  }
}

class _$ChannelDatabase extends ChannelDatabase {
  _$ChannelDatabase([StreamController<String>? listener]) {
    changeListener = listener ?? StreamController<String>.broadcast();
  }

  ChannelAddedAppDao? _daoInstance;

  Future<sqflite.Database> open(
    String path,
    List<Migration> migrations, [
    Callback? callback,
  ]) async {
    final databaseOptions = sqflite.OpenDatabaseOptions(
      version: 3,
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
            'CREATE TABLE IF NOT EXISTS `channel_added_app` (`appId` TEXT NOT NULL, `name` TEXT NOT NULL, `user` TEXT NOT NULL, `repositories` TEXT NOT NULL, `apprepo` TEXT, `icon` TEXT NOT NULL, `description` TEXT NOT NULL, `category` TEXT, `addTime` INTEGER NOT NULL, `channelCode` TEXT NOT NULL, `extra` TEXT, PRIMARY KEY (`appId`))');

        await callback?.onCreate?.call(database, version);
      },
    );
    return sqfliteDatabaseFactory.openDatabase(path, options: databaseOptions);
  }

  @override
  ChannelAddedAppDao get dao {
    return _daoInstance ??= _$ChannelAddedAppDao(database, changeListener);
  }
}

class _$ChannelAddedAppDao extends ChannelAddedAppDao {
  _$ChannelAddedAppDao(
    this.database,
    this.changeListener,
  )   : _queryAdapter = QueryAdapter(database),
        _channelAddedAppInsertionAdapter = InsertionAdapter(
            database,
            'channel_added_app',
            (ChannelAddedApp item) => <String, Object?>{
                  'appId': item.appId,
                  'name': item.name,
                  'user': item.user,
                  'repositories': item.repositories,
                  'apprepo': item.apprepo,
                  'icon': item.icon,
                  'description': item.description,
                  'category': item.category,
                  'addTime': item.addTime,
                  'channelCode': item.channelCode,
                  'extra': item.extra
                });

  final sqflite.DatabaseExecutor database;

  final StreamController<String> changeListener;

  final QueryAdapter _queryAdapter;

  final InsertionAdapter<ChannelAddedApp> _channelAddedAppInsertionAdapter;

  @override
  Future<void> removeApp(
    String appId,
    String channelCode,
  ) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM channel_added_app WHERE appId = ?1 AND channelCode = ?2',
        arguments: [appId, channelCode]);
  }

  @override
  Future<List<ChannelAddedApp>> getAppsByChannel(String channelCode) async {
    return _queryAdapter.queryList(
        'SELECT * FROM channel_added_app WHERE channelCode = ?1 ORDER BY addTime DESC',
        mapper: (Map<String, Object?> row) => ChannelAddedApp(appId: row['appId'] as String, name: row['name'] as String, user: row['user'] as String, repositories: row['repositories'] as String, apprepo: row['apprepo'] as String?, icon: row['icon'] as String, description: row['description'] as String, category: row['category'] as String?, addTime: row['addTime'] as int, channelCode: row['channelCode'] as String, extra: row['extra'] as String?),
        arguments: [channelCode]);
  }

  @override
  Future<int?> getCountByChannel(String channelCode) async {
    return _queryAdapter.query(
        'SELECT COUNT(*) FROM channel_added_app WHERE channelCode = ?1',
        mapper: (Map<String, Object?> row) => row.values.first as int,
        arguments: [channelCode]);
  }

  @override
  Future<ChannelAddedApp?> getApp(
    String appId,
    String channelCode,
  ) async {
    return _queryAdapter.query(
        'SELECT * FROM channel_added_app WHERE appId = ?1 AND channelCode = ?2 LIMIT 1',
        mapper: (Map<String, Object?> row) => ChannelAddedApp(appId: row['appId'] as String, name: row['name'] as String, user: row['user'] as String, repositories: row['repositories'] as String, apprepo: row['apprepo'] as String?, icon: row['icon'] as String, description: row['description'] as String, category: row['category'] as String?, addTime: row['addTime'] as int, channelCode: row['channelCode'] as String, extra: row['extra'] as String?),
        arguments: [appId, channelCode]);
  }

  @override
  Future<void> clearChannel(String channelCode) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM channel_added_app WHERE channelCode = ?1',
        arguments: [channelCode]);
  }

  @override
  Future<List<ChannelAddedApp>> getAllApps() async {
    return _queryAdapter.queryList(
        'SELECT * FROM channel_added_app ORDER BY addTime DESC',
        mapper: (Map<String, Object?> row) => ChannelAddedApp(
            appId: row['appId'] as String,
            name: row['name'] as String,
            user: row['user'] as String,
            repositories: row['repositories'] as String,
            apprepo: row['apprepo'] as String?,
            icon: row['icon'] as String,
            description: row['description'] as String,
            category: row['category'] as String?,
            addTime: row['addTime'] as int,
            channelCode: row['channelCode'] as String,
            extra: row['extra'] as String?));
  }

  @override
  Future<int?> getTotalCount() async {
    return _queryAdapter.query('SELECT COUNT(*) FROM channel_added_app',
        mapper: (Map<String, Object?> row) => row.values.first as int);
  }

  @override
  Future<void> insertApp(ChannelAddedApp app) async {
    await _channelAddedAppInsertionAdapter.insert(
        app, OnConflictStrategy.replace);
  }

  @override
  Future<void> insertApps(List<ChannelAddedApp> apps) async {
    await _channelAddedAppInsertionAdapter.insertList(
        apps, OnConflictStrategy.replace);
  }
}

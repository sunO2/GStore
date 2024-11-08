// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'AppInfoDatabase.dart';

// **************************************************************************
// FloorGenerator
// **************************************************************************

abstract class $AppInfoDatabaseBuilderContract {
  /// Adds migrations to the builder.
  $AppInfoDatabaseBuilderContract addMigrations(List<Migration> migrations);

  /// Adds a database [Callback] to the builder.
  $AppInfoDatabaseBuilderContract addCallback(Callback callback);

  /// Creates the database and initializes it.
  Future<AppInfoDatabase> build();
}

// ignore: avoid_classes_with_only_static_members
class $FloorAppInfoDatabase {
  /// Creates a database builder for a persistent database.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $AppInfoDatabaseBuilderContract databaseBuilder(String name) =>
      _$AppInfoDatabaseBuilder(name);

  /// Creates a database builder for an in memory database.
  /// Information stored in an in memory database disappears when the process is killed.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $AppInfoDatabaseBuilderContract inMemoryDatabaseBuilder() =>
      _$AppInfoDatabaseBuilder(null);
}

class _$AppInfoDatabaseBuilder implements $AppInfoDatabaseBuilderContract {
  _$AppInfoDatabaseBuilder(this.name);

  final String? name;

  final List<Migration> _migrations = [];

  Callback? _callback;

  @override
  $AppInfoDatabaseBuilderContract addMigrations(List<Migration> migrations) {
    _migrations.addAll(migrations);
    return this;
  }

  @override
  $AppInfoDatabaseBuilderContract addCallback(Callback callback) {
    _callback = callback;
    return this;
  }

  @override
  Future<AppInfoDatabase> build() async {
    final path = name != null
        ? await sqfliteDatabaseFactory.getDatabasePath(name!)
        : ':memory:';
    final database = _$AppInfoDatabase();
    database.database = await database.open(
      path,
      _migrations,
      _callback,
    );
    return database;
  }
}

class _$AppInfoDatabase extends AppInfoDatabase {
  _$AppInfoDatabase([StreamController<String>? listener]) {
    changeListener = listener ?? StreamController<String>.broadcast();
  }

  AppInfoDao? _daoInstance;

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
            'CREATE TABLE IF NOT EXISTS `AppInfo` (`appId` TEXT NOT NULL, `name` TEXT NOT NULL, `user` TEXT NOT NULL, `repositories` TEXT NOT NULL, `icon` TEXT NOT NULL, `des` TEXT NOT NULL, `category` TEXT, PRIMARY KEY (`appId`))');
        await database.execute(
            'CREATE TABLE IF NOT EXISTS `AppInfoConfig` (`version` TEXT NOT NULL, PRIMARY KEY (`version`))');
        await database.execute(
            'CREATE TABLE IF NOT EXISTS `AppCategory` (`id` TEXT NOT NULL, `description` TEXT NOT NULL, `icon` TEXT NOT NULL, PRIMARY KEY (`id`))');

        await callback?.onCreate?.call(database, version);
      },
    );
    return sqfliteDatabaseFactory.openDatabase(path, options: databaseOptions);
  }

  @override
  AppInfoDao get dao {
    return _daoInstance ??= _$AppInfoDao(database, changeListener);
  }
}

class _$AppInfoDao extends AppInfoDao {
  _$AppInfoDao(
    this.database,
    this.changeListener,
  ) : _queryAdapter = QueryAdapter(database);

  final sqflite.DatabaseExecutor database;

  final StreamController<String> changeListener;

  final QueryAdapter _queryAdapter;

  @override
  Future<List<AppInfo>> getAllApps() async {
    return _queryAdapter.queryList('SELECT * FROM apps',
        mapper: (Map<String, Object?> row) => AppInfo(
            row['appId'] as String,
            row['name'] as String,
            row['user'] as String,
            row['repositories'] as String,
            row['icon'] as String,
            row['des'] as String,
            _categoryConverter.decode(row['category'] as String?)));
  }

  @override
  Future<List<AppInfo>> searchWord(String word) async {
    return _queryAdapter.queryList(
        'SELECT * FROM apps WHERE name LIKE ?1 OR des LIKE ?1',
        mapper: (Map<String, Object?> row) => AppInfo(
            row['appId'] as String,
            row['name'] as String,
            row['user'] as String,
            row['repositories'] as String,
            row['icon'] as String,
            row['des'] as String,
            _categoryConverter.decode(row['category'] as String?)),
        arguments: [word]);
  }

  @override
  Future<AppInfoConfig?> getVersion() async {
    return _queryAdapter.query('SELECT * FROM config LIMIT 1',
        mapper: (Map<String, Object?> row) =>
            AppInfoConfig(row['version'] as String));
  }

  @override
  Future<List<AppCategory>> getAllCategory() async {
    return _queryAdapter.queryList('SELECT * FROM category',
        mapper: (Map<String, Object?> row) => AppCategory(row['id'] as String,
            row['description'] as String, row['icon'] as String));
  }

  @override
  Future<List<AppInfo>> searchCategoryLike(String word) async {
    return _queryAdapter.queryList('SELECT * FROM apps WHERE category LIKE ?1',
        mapper: (Map<String, Object?> row) => AppInfo(
            row['appId'] as String,
            row['name'] as String,
            row['user'] as String,
            row['repositories'] as String,
            row['icon'] as String,
            row['des'] as String,
            _categoryConverter.decode(row['category'] as String?)),
        arguments: [word]);
  }
}

// ignore_for_file: unused_element
final _categoryConverter = CategoryConverter();

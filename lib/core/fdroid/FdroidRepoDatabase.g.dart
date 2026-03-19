// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'FdroidRepoDatabase.dart';

// **************************************************************************
// FloorGenerator
// **************************************************************************

abstract class $FdroidRepoDatabaseBuilderContract {
  /// Adds migrations to the builder.
  $FdroidRepoDatabaseBuilderContract addMigrations(List<Migration> migrations);

  /// Adds a database [Callback] to the builder.
  $FdroidRepoDatabaseBuilderContract addCallback(Callback callback);

  /// Creates the database and initializes it.
  Future<FdroidRepoDatabase> build();
}

// ignore: avoid_classes_with_only_static_members
class $FloorFdroidRepoDatabase {
  /// Creates a database builder for a persistent database.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $FdroidRepoDatabaseBuilderContract databaseBuilder(String name) =>
      _$FdroidRepoDatabaseBuilder(name);

  /// Creates a database builder for an in memory database.
  /// Information stored in an in memory database disappears when the process is killed.
  /// Once a database is built, you should keep a reference to it and re-use it.
  static $FdroidRepoDatabaseBuilderContract inMemoryDatabaseBuilder() =>
      _$FdroidRepoDatabaseBuilder(null);
}

class _$FdroidRepoDatabaseBuilder
    implements $FdroidRepoDatabaseBuilderContract {
  _$FdroidRepoDatabaseBuilder(this.name);

  final String? name;

  final List<Migration> _migrations = [];

  Callback? _callback;

  @override
  $FdroidRepoDatabaseBuilderContract addMigrations(List<Migration> migrations) {
    _migrations.addAll(migrations);
    return this;
  }

  @override
  $FdroidRepoDatabaseBuilderContract addCallback(Callback callback) {
    _callback = callback;
    return this;
  }

  @override
  Future<FdroidRepoDatabase> build() async {
    final path = name != null
        ? await sqfliteDatabaseFactory.getDatabasePath(name!)
        : ':memory:';
    final database = _$FdroidRepoDatabase();
    database.database = await database.open(
      path,
      _migrations,
      _callback,
    );
    return database;
  }
}

class _$FdroidRepoDatabase extends FdroidRepoDatabase {
  _$FdroidRepoDatabase([StreamController<String>? listener]) {
    changeListener = listener ?? StreamController<String>.broadcast();
  }

  FdroidRepoDao? _daoInstance;

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
            'CREATE TABLE IF NOT EXISTS `FdroidApp` (`packageName` TEXT NOT NULL, `name` TEXT NOT NULL, `summary` TEXT NOT NULL, `description` TEXT, `icon` TEXT NOT NULL, `license` TEXT, `authorName` TEXT, `sourceCode` TEXT, `projectUrl` TEXT, `webSite` TEXT, `donate` TEXT, PRIMARY KEY (`packageName`))');
        await database.execute(
            'CREATE TABLE IF NOT EXISTS `FdroidPackage` (`id` INTEGER PRIMARY KEY AUTOINCREMENT, `packageName` TEXT NOT NULL, `apkName` TEXT NOT NULL, `versionName` TEXT NOT NULL, `versionCode` INTEGER NOT NULL, `size` INTEGER NOT NULL, `hash` TEXT, `hashType` TEXT, `signer` TEXT, `nativecode` TEXT)');
        await database.execute(
            'CREATE TABLE IF NOT EXISTS `FdroidVersionInfo` (`indexVersion` INTEGER NOT NULL, `repoUrl` TEXT NOT NULL, `lastModified` TEXT, `entityTag` TEXT, PRIMARY KEY (`repoUrl`))');

        await callback?.onCreate?.call(database, version);
      },
    );
    return sqfliteDatabaseFactory.openDatabase(path, options: databaseOptions);
  }

  @override
  FdroidRepoDao get dao {
    return _daoInstance ??= _$FdroidRepoDao(database, changeListener);
  }
}

class _$FdroidRepoDao extends FdroidRepoDao {
  _$FdroidRepoDao(
    this.database,
    this.changeListener,
  )   : _queryAdapter = QueryAdapter(database),
        _fdroidAppInsertionAdapter = InsertionAdapter(
            database,
            'FdroidApp',
            (FdroidApp item) => <String, Object?>{
                  'packageName': item.packageName,
                  'name': item.name,
                  'summary': item.summary,
                  'description': item.description,
                  'icon': item.icon,
                  'license': item.license,
                  'authorName': item.authorName,
                  'sourceCode': item.sourceCode,
                  'projectUrl': item.projectUrl,
                  'webSite': item.webSite,
                  'donate': item.donate
                }),
        _fdroidPackageInsertionAdapter = InsertionAdapter(
            database,
            'FdroidPackage',
            (FdroidPackage item) => <String, Object?>{
                  'id': item.id,
                  'packageName': item.packageName,
                  'apkName': item.apkName,
                  'versionName': item.versionName,
                  'versionCode': item.versionCode,
                  'size': item.size,
                  'hash': item.hash,
                  'hashType': item.hashType,
                  'signer': item.signer,
                  'nativecode': item.nativecode
                }),
        _fdroidVersionInfoInsertionAdapter = InsertionAdapter(
            database,
            'FdroidVersionInfo',
            (FdroidVersionInfo item) => <String, Object?>{
                  'indexVersion': item.indexVersion,
                  'repoUrl': item.repoUrl,
                  'lastModified': item.lastModified,
                  'entityTag': item.entityTag
                });

  final sqflite.DatabaseExecutor database;

  final StreamController<String> changeListener;

  final QueryAdapter _queryAdapter;

  final InsertionAdapter<FdroidApp> _fdroidAppInsertionAdapter;

  final InsertionAdapter<FdroidPackage> _fdroidPackageInsertionAdapter;

  final InsertionAdapter<FdroidVersionInfo> _fdroidVersionInfoInsertionAdapter;

  @override
  Future<FdroidApp?> getApp(String packageName) async {
    return _queryAdapter.query('SELECT * FROM FdroidApp WHERE packageName = ?1',
        mapper: (Map<String, Object?> row) => FdroidApp(
            packageName: row['packageName'] as String,
            name: row['name'] as String,
            summary: row['summary'] as String,
            description: row['description'] as String?,
            icon: row['icon'] as String,
            license: row['license'] as String?,
            authorName: row['authorName'] as String?,
            sourceCode: row['sourceCode'] as String?,
            projectUrl: row['projectUrl'] as String?,
            webSite: row['webSite'] as String?,
            donate: row['donate'] as String?),
        arguments: [packageName]);
  }

  @override
  Future<List<FdroidApp>> searchApps(
    String keyword,
    int limit,
  ) async {
    return _queryAdapter.queryList(
        'SELECT * FROM FdroidApp     WHERE name LIKE \'%\' || ?1 || \'%\'        OR summary LIKE \'%\' || ?1 || \'%\'        OR packageName LIKE \'%\' || ?1 || \'%\'     ORDER BY name ASC     LIMIT ?2',
        mapper: (Map<String, Object?> row) => FdroidApp(packageName: row['packageName'] as String, name: row['name'] as String, summary: row['summary'] as String, description: row['description'] as String?, icon: row['icon'] as String, license: row['license'] as String?, authorName: row['authorName'] as String?, sourceCode: row['sourceCode'] as String?, projectUrl: row['projectUrl'] as String?, webSite: row['webSite'] as String?, donate: row['donate'] as String?),
        arguments: [keyword, limit]);
  }

  @override
  Future<List<FdroidApp>> getAllApps() async {
    return _queryAdapter.queryList('SELECT * FROM FdroidApp ORDER BY name ASC',
        mapper: (Map<String, Object?> row) => FdroidApp(
            packageName: row['packageName'] as String,
            name: row['name'] as String,
            summary: row['summary'] as String,
            description: row['description'] as String?,
            icon: row['icon'] as String,
            license: row['license'] as String?,
            authorName: row['authorName'] as String?,
            sourceCode: row['sourceCode'] as String?,
            projectUrl: row['projectUrl'] as String?,
            webSite: row['webSite'] as String?,
            donate: row['donate'] as String?));
  }

  @override
  Future<void> deleteApp(String packageName) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM FdroidApp WHERE packageName = ?1',
        arguments: [packageName]);
  }

  @override
  Future<int?> getAppCount() async {
    return _queryAdapter.query('SELECT COUNT(*) FROM FdroidApp',
        mapper: (Map<String, Object?> row) => row.values.first as int);
  }

  @override
  Future<List<FdroidPackage>> getPackages(String packageName) async {
    return _queryAdapter.queryList(
        'SELECT * FROM FdroidPackage     WHERE packageName = ?1     ORDER BY versionCode DESC',
        mapper: (Map<String, Object?> row) => FdroidPackage(id: row['id'] as int?, packageName: row['packageName'] as String, apkName: row['apkName'] as String, versionName: row['versionName'] as String, versionCode: row['versionCode'] as int, size: row['size'] as int, hash: row['hash'] as String?, hashType: row['hashType'] as String?, signer: row['signer'] as String?, nativecode: row['nativecode'] as String?),
        arguments: [packageName]);
  }

  @override
  Future<FdroidPackage?> getLatestPackage(String packageName) async {
    return _queryAdapter.query(
        'SELECT * FROM FdroidPackage     WHERE packageName = ?1     ORDER BY versionCode DESC     LIMIT 1',
        mapper: (Map<String, Object?> row) => FdroidPackage(id: row['id'] as int?, packageName: row['packageName'] as String, apkName: row['apkName'] as String, versionName: row['versionName'] as String, versionCode: row['versionCode'] as int, size: row['size'] as int, hash: row['hash'] as String?, hashType: row['hashType'] as String?, signer: row['signer'] as String?, nativecode: row['nativecode'] as String?),
        arguments: [packageName]);
  }

  @override
  Future<void> deletePackages(String packageName) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM FdroidPackage WHERE packageName = ?1',
        arguments: [packageName]);
  }

  @override
  Future<int?> getPackageCount() async {
    return _queryAdapter.query('SELECT COUNT(*) FROM FdroidPackage',
        mapper: (Map<String, Object?> row) => row.values.first as int);
  }

  @override
  Future<FdroidVersionInfo?> getVersionInfo(String repoUrl) async {
    return _queryAdapter.query(
        'SELECT * FROM FdroidVersionInfo WHERE repoUrl = ?1',
        mapper: (Map<String, Object?> row) => FdroidVersionInfo(
            indexVersion: row['indexVersion'] as int,
            repoUrl: row['repoUrl'] as String,
            lastModified: row['lastModified'] as String?,
            entityTag: row['entityTag'] as String?),
        arguments: [repoUrl]);
  }

  @override
  Future<void> deleteVersionInfo(String repoUrl) async {
    await _queryAdapter.queryNoReturn(
        'DELETE FROM FdroidVersionInfo WHERE repoUrl = ?1',
        arguments: [repoUrl]);
  }

  @override
  Future<void> clearApps() async {
    await _queryAdapter.queryNoReturn('DELETE FROM FdroidApp');
  }

  @override
  Future<void> clearPackages() async {
    await _queryAdapter.queryNoReturn('DELETE FROM FdroidPackage');
  }

  @override
  Future<int?> getDatabaseSize() async {
    return _queryAdapter.query('SELECT COUNT(*) FROM FdroidApp',
        mapper: (Map<String, Object?> row) => row.values.first as int);
  }

  @override
  Future<void> upsertApp(FdroidApp app) async {
    await _fdroidAppInsertionAdapter.insert(app, OnConflictStrategy.replace);
  }

  @override
  Future<void> upsertApps(List<FdroidApp> apps) async {
    await _fdroidAppInsertionAdapter.insertList(
        apps, OnConflictStrategy.replace);
  }

  @override
  Future<void> upsertPackage(FdroidPackage package) async {
    await _fdroidPackageInsertionAdapter.insert(
        package, OnConflictStrategy.replace);
  }

  @override
  Future<void> upsertPackages(List<FdroidPackage> packages) async {
    await _fdroidPackageInsertionAdapter.insertList(
        packages, OnConflictStrategy.replace);
  }

  @override
  Future<void> upsertVersionInfo(FdroidVersionInfo info) async {
    await _fdroidVersionInfoInsertionAdapter.insert(
        info, OnConflictStrategy.replace);
  }
}

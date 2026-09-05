import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:get/get.dart';
import 'package:gstore/core/aggregate/AppAddedDatabase.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/channel/impl/JsChannel.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:gstore/core/webdav/webdav_config.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

/// 假 PathProvider：ChannelDatabase.create() 依赖 getApplicationDocumentsDirectory
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

/// BackupService JS 脚本渠道备份测试
///
/// 验证（方案 B：channels/<key>.zip 原样打包进 tar.gz + extras 携带 env）：
/// - 导出：渠道包目录下的 *.zip 以 `channels/<name>.zip` 归档条目打包
///   （tar 原生二进制，无 base64）
/// - 导出：已注册 JsChannel 的环境变量进 apps.json 的 extras['js_envs']
/// - 导入：tar 中 channels/ 条目写回渠道包目录 → ChannelLoader 可重新注册
/// - 导入：extras['js_envs'] 恢复进 ConfigJsChannelEnvStore
/// - 老备份（无 channels/ 条目）导入不崩
void main() {
  setUpAll(() {
    open.overrideFor(OperatingSystem.linux,
        () => DynamicLibrary.open('libsqlite3.so.0'));
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PackageInfo.setMockInitialValues(
      appName: 'GStore',
      packageName: 'com.gstore',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
      installerStore: null,
    );
    Get.put(DatabaseEventBus());
  });

  late AppAddedDatabase aggregatorDb;
  late BackupService service;
  late Directory channelsDir;

  setUp(() async {
    await ChannelManager.instance.disposeAll(); // 清空单例渠道

    SharedPreferences.setMockInitialValues({});
    // 全程使用内存存储（避免 SecureStorage 插件依赖——js_env 键标记敏感会路由 secure）
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(storages: [
      MemoryConfigStorage(),
      MemoryConfigStorage(),
    ]);
    ConfigService.instance.registerModule(AppCoreConfigModule());

    final dbFile = p.join(await databaseFactory.getDatabasesPath(),
        'backup_js_channel_test.db');
    await databaseFactory.deleteDatabase(dbFile);
    aggregatorDb = await AppAddedDatabase.create(dbPath: dbFile);

    // 隔离渠道包目录（path_provider mock 会失败，注入真实临时目录）
    channelsDir = await Directory.systemTemp.createTemp('js_channel_backup');
    addTearDown(() => channelsDir.delete(recursive: true));

    service = BackupService.instance;
    service.setTestDatabases(aggregatorDb);
    service.debugChannelsDirectory = channelsDir;
  });

  tearDown(() async {
    await aggregatorDb.close();
    final dbFile = p.join(await databaseFactory.getDatabasesPath(),
        'backup_js_channel_test.db');
    await databaseFactory.deleteDatabase(dbFile);
  });

  /// 构造内存 zip 渠道包字节
  Uint8List buildZip({
    String entry = 'function main(method, params) { return null; }',
    String? detail,
    String? meta,
  }) {
    final archive = Archive();
    archive.addFile(ArchiveFile.string('entry.js', entry));
    if (detail != null) archive.addFile(ArchiveFile.string('detail.js', detail));
    if (meta != null) archive.addFile(ArchiveFile.string('meta.json', meta));
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  }

  /// 从 tar.gz 字节提取指定归档文件内容
  Uint8List? extractArchiveFile(Uint8List bytes, String name) {
    final archive = TarDecoder().decodeBytes(gzip.decode(bytes));
    for (final f in archive.files) {
      if (f.name == name) return Uint8List.fromList(f.content as List<int>);
    }
    return null;
  }

  /// 从 tar.gz 字节提取 apps.json 并反序列化
  Map<String, dynamic> decodeAppsJson(Uint8List bytes) {
    final raw = extractArchiveFile(bytes, 'apps.json')!;
    return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
  }

  test('导出：channels/*.zip 以 tar 条目打包（无 base64，含原始 zip 字节）', () async {
    // 渠道包目录放入两个 zip（模拟 js_pingan / js_vivo）
    final pinganZip = buildZip(
      entry: 'function main(method, params) { return {channel: "pingan"}; }',
    );
    await File('${channelsDir.path}/pingan.zip').writeAsBytes(pinganZip);
    await File('${channelsDir.path}/vivo.zip')
        .writeAsBytes(buildZip());

    final bytes = await service.exportCompressedBackup();

    // gzip magic
    expect(bytes[0], 0x1f);
    expect(bytes[1], 0x8b);

    // channels/ 条目存在，内容 = 原始 zip 字节（逐字节相等）
    final archived = extractArchiveFile(bytes, 'channels/pingan.zip');
    expect(archived, isNotNull, reason: 'pingan.zip 应以 channels/pingan.zip 条目打包');
    expect(archived, equals(pinganZip), reason: 'tar 条目 = 原始 zip 字节（非 base64）');
    expect(extractArchiveFile(bytes, 'channels/vivo.zip'), isNotNull);
  });

  test('导出：空渠道包目录 → 无 channels/ 条目，导出正常', () async {
    final bytes = await service.exportCompressedBackup();
    expect(extractArchiveFile(bytes, 'channels/pingan.zip'), isNull);
    expect(decodeAppsJson(bytes), isNotEmpty);
  });

  test("导出：已注册 JsChannel 的 env 进 extras['js_envs']", () async {
    // 注册 JsChannel（env 经 ConfigJsChannelEnvStore 持久化，dynamicChannels 可枚举）
    final js = JsChannel(
      channelKey: 'js_pingan',
      script: 'function main(method, params) { return null; }',
    );
    ChannelManager.instance.registerChannel(js);
    await js.setEnv('PINGAN_USER', 'u');
    await js.setEnv('PINGAN_PASS', 'p');

    final bytes = await service.exportCompressedBackup();
    final appsJson = decodeAppsJson(bytes);
    final extras = appsJson['extras'] as Map<String, dynamic>?;
    expect(extras, isNotNull);
    final jsEnvs = extras!['js_envs'] as Map<String, dynamic>?;
    expect(jsEnvs, isNotNull,
        reason: 'env 应以 extras.js_envs 携带');
    expect(jsEnvs!['js_pingan'], {'PINGAN_USER': 'u', 'PINGAN_PASS': 'p'});
  });

  test('导入：channels/ 条目写回渠道包目录 + env 恢复', () async {
    // 1. 预置渠道包 + env，导出备份
    final pinganZip = buildZip(
      entry: 'function main(method, params) { return {channel: "pingan"}; }',
    );
    await File('${channelsDir.path}/pingan.zip').writeAsBytes(pinganZip);
    final js = JsChannel(
      channelKey: 'js_pingan',
      script: 'function main(method, params) { return null; }',
    );
    ChannelManager.instance.registerChannel(js);
    await js.setEnv('PINGAN_USER', 'backup-user');
    final backupBytes = await service.exportCompressedBackup();

    // 2. 清空渠道包目录 + env，制造"恢复前状态"
    await File('${channelsDir.path}/pingan.zip').delete();
    await ConfigJsChannelEnvStore('js_pingan').save(const {});
    expect(await ConfigJsChannelEnvStore('js_pingan').load(), isEmpty);

    // 3. 导入字节
    final result = await service.importBackupBytes(backupBytes);
    expect(result.success, isTrue);

    // 4. zip 写回（字节一致）
    final restoredFile = File('${channelsDir.path}/pingan.zip');
    expect(await restoredFile.exists(), isTrue);
    expect(await restoredFile.readAsBytes(), pinganZip);

    // 5. env 恢复
    final restoredEnv = await ConfigJsChannelEnvStore('js_pingan').load();
    expect(restoredEnv['PINGAN_USER'], 'backup-user');
  });

  test('导入：老备份（无 channels/ 条目）不崩且数据正常恢复', () async {
    await aggregatorDb.addedAppDao.insertApp(
      AddedAppInfo(channelId: 'github', appId: 'a/b', addTime: 1000),
    );
    final bytes = await service.exportCompressedBackup();

    await aggregatorDb.addedAppDao.clearAll();
    final result = await service.importBackupBytes(bytes);
    expect(result.success, isTrue);
    expect(await aggregatorDb.addedAppDao.getTotalCount(), 1);
  });

  test('通过 JS 渠道添加的应用（聚合 + 渠道库）进备份', () async {
    // 聚合库：js 渠道应用引用（channelId = channelKey）
    await aggregatorDb.addedAppDao.insertApp(
      AddedAppInfo(channelId: 'js_pingan', appId: 'com.pingan.app', addTime: 1000),
    );

    // 渠道库：js 渠道应用详情（channelCode = channelKey）
    final channelDomainDir =
        await Directory.systemTemp.createTemp('js_channel_db');
    addTearDown(() => channelDomainDir.delete(recursive: true));
    final originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(channelDomainDir.path);
    addTearDown(() => PathProviderPlatform.instance = originalPathProvider);
    final channelDb = await ChannelDatabase.create();
    addTearDown(channelDb.close);
    service.setTestChannelDatabase(channelDb);
    await channelDb.dao.insertApp(ChannelAddedApp(
      channelCode: 'js_pingan',
      appId: 'com.pingan.app',
      name: '平安应用',
      user: '',
      repositories: '',
      icon: '',
      description: '通过 JS 渠道添加',
      addTime: 1000,
    ));

    final bytes = await service.exportCompressedBackup();
    final appsJson = decodeAppsJson(bytes);

    // 聚合应用包含 js_pingan
    final apps = appsJson['apps'] as List;
    expect(
      apps.any((a) =>
          (a as Map)['channelId'] == 'js_pingan' &&
          a['appId'] == 'com.pingan.app'),
      isTrue,
      reason: '通过 JS 渠道添加的聚合应用应在备份 apps 中',
    );

    // 渠道库数据包含 js_pingan
    final channelApps = appsJson['channelApps'] as Map? ?? const {};
    expect(
      channelApps.containsKey('js_pingan'),
      isTrue,
      reason: 'JS 渠道应用详情应在备份 channelApps 中',
    );
  });

  test('WebDAV 配置进备份（B 轨：WebDavConfigManager 直写存储并入 appConfig）', () async {
    // mock flutter_secure_storage：预置 webdav 配置（与 WebDavConfigManager 同 key）
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      const {
        'webdav_url': 'https://example.com/dav',
        'webdav_username': 'user',
        'webdav_password': 'pass',
        'webdav_backup_path': '/GStore',
        'webdav_enable_https': 'true',
      },
    );
    addTearDown(() => FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(const {}));

    final bytes = await service.exportCompressedBackup(includeAppConfig: true);
    final appsJson = decodeAppsJson(bytes);
    final appConfig = appsJson['appConfig'] as Map? ?? const {};
    expect(
      appConfig.containsKey('webdav_config'),
      isTrue,
      reason: 'WebDAV 配置应并入 appConfig 备份',
    );
    final wd = appConfig['webdav_config'] as Map;
    expect(wd['url'], 'https://example.com/dav');
    expect(wd['username'], 'user');
    expect(wd['password'], 'pass');
  });
}
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/aggregate/added_apps_facade.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/database/channel_added_app.dart';
import 'package:gstore/core/channel/database/channel_database.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/config_store.dart';
import 'package:gstore/core/config/config_storage.dart';
import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/event/database_event.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/script_pack.dart' as rust_pack;
import 'package:gstore/core/script/rust_script_lane.dart';
import 'package:gstore/core/script/script_api.dart';
import 'package:gstore/core/script/script_channel_service.dart';
import 'package:gstore/core/service/backup_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqlite3/open.dart';

import 'support/added_apps_read_seams.dart';

/// 假 PathProvider：ChannelDatabase.create() 依赖 getApplicationDocumentsDirectory
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

/// In-memory `ScriptApiBackend` (FRB seam): the Rust script lane owns the pack
/// env (`channel_env` + FileSecretStore) after the Dart `JsChannel` removal.
class _FakeScriptBackend implements ScriptApiBackend {
  final Map<String, rust_pack.ScriptPackInfo> packs = {};
  final Map<String, Map<String, String>> lastEnv = {};

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {}

  @override
  Future<rust_pack.ScriptPackInfo> import_({
    required List<int> packZipBytes,
    String? expectedKey,
  }) async {
    final key = expectedKey ?? 'js_unknown';
    return packs[key] ??= rust_pack.ScriptPackInfo(
      key: key,
      name: '',
      description: '',
      icon: '',
      hasDetail: false,
    );
  }

  @override
  Future<void> remove({required String key}) async {
    packs.remove(key);
    lastEnv.remove(key);
  }

  @override
  Future<rust_pack.ScriptPackInfo> refresh({required String key}) async =>
      packs[key] ??
      rust_pack.ScriptPackInfo(
        key: key,
        name: '',
        description: '',
        icon: '',
        hasDetail: false,
      );

  @override
  Future<void> setEnv({
    required String key,
    required Map<String, String> env,
  }) async =>
      lastEnv[key] = Map.of(env);

  @override
  Future<Map<String, String>> getEnv({required String key}) async =>
      Map.of(lastEnv[key] ?? const {});

  @override
  Future<void> setConfig({
    required String key,
    required Map<String, String> config,
  }) async {}

  @override
  Future<List<rust_pack.ScriptPackInfo>> list() async => packs.values.toList();

  @override
  Future<String> storedApps({required String key}) async => '[]';

  @override
  Future<void> addApp({
    required String key,
    required rust.ChannelAppInfo app,
  }) async {}

  @override
  Future<void> releaseDetail({
    required String key,
    required String appId,
  }) async {}
}

class _FakeFlagsBackend implements CoreFlagsBackend {
  _FakeFlagsBackend(this.snapshot);

  CoreFlagsSnapshot snapshot;

  @override
  Future<CoreFlagsSnapshot> read() async => snapshot;

  @override
  Future<void> write(CoreFlagsPatch patch) async {
    snapshot = CoreFlagsSnapshot(
      channels: patch.channel ?? snapshot.channels,
      catalog: patch.catalog ?? snapshot.catalog,
      update: patch.update ?? snapshot.update,
      download: patch.download ?? snapshot.download,
      install: patch.install ?? snapshot.install,
      jsChannel: patch.jsChannel ?? snapshot.jsChannel,
      coreWrites: snapshot.coreWrites,
    );
  }
}

/// BackupService JS 脚本渠道备份测试
///
/// 验证（方案 B：channels/<key>.zip 原样打包进 tar.gz + extras 携带 env）：
/// - 导出：渠道包目录下的 *.zip 以 `channels/<name>.zip` 归档条目打包
///   （tar 原生二进制，无 base64）
/// - 导出：Rust 脚本通道的渠道 env 进 apps.json 的 extras['js_envs']
/// - 导入：tar 中 channels/ 条目写回渠道包目录
/// - 导入：extras['js_envs'] 恢复经 ScriptApi.setEnv
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
    DatabaseEventBus.instance;
  });

  late InMemoryAddedAppsBackend addedBackend;
  late BackupService service;
  late Directory channelsDir;
  late _FakeScriptBackend backend;

  setUp(() async {
    await ChannelManager.instance.disposeAll(); // 清空单例渠道

    SharedPreferences.setMockInitialValues({});
    // 全程使用内存存储（避免 SecureStorage 插件依赖）
    ConfigStore.instance.resetForTest();
    await ConfigStore.instance.initialize(storages: [
      MemoryConfigStorage(),
      MemoryConfigStorage(),
    ]);
    ConfigService.instance.registerModule(AppCoreConfigModule());

    // Rust 脚本通道（生产默认）：env 存 Rust channel_env + FileSecretStore。
    CoreFlags.installBackend(
        _FakeFlagsBackend(const CoreFlagsSnapshot(jsChannel: true)));
    await CoreFlags.refresh();
    backend = _FakeScriptBackend();
    ScriptApi.installBackend(backend);
    ScriptChannelService.installForTest(ScriptChannelService(
      coreDirs: () async => ('/tmp/bk/data', '/tmp/bk/files', '/tmp/bk/cache'),
      ensureRust: () async {},
    ));
    RustScriptChannelLane.resetForTest();

    // The added-apps store is core-only now: inject an in-memory backend
    // instead of the deleted Floor DB.
    addedBackend = InMemoryAddedAppsBackend();
    AddedAppsFacade.backendOverride = addedBackend;

    // 隔离渠道包目录（path_provider mock 会失败，注入真实临时目录）
    channelsDir = await Directory.systemTemp.createTemp('js_channel_backup');
    addTearDown(() => channelsDir.delete(recursive: true));

    service = BackupService.instance;
    service.setTestInitialized();
    service.debugChannelsDirectory = channelsDir;
  });

  tearDown(() async {
    CoreFlags.resetBackend();
    ScriptApi.resetBackend();
    ScriptChannelService.resetForTest();
    RustScriptChannelLane.resetForTest();
    AddedAppsFacade.backendOverride = null;
  });

  /// 注册一个 Rust 脚本通道 pack 及其 env，并刷新 UI lane 缓存。
  Future<void> seedRustPack(
    String key,
    Map<String, String> env,
  ) async {
    backend.packs[key] = rust_pack.ScriptPackInfo(
      key: key,
      name: 'Pingan',
      description: '',
      icon: '',
      hasDetail: false,
    );
    if (env.isNotEmpty) backend.lastEnv[key] = Map.of(env);
    await RustScriptChannelLane.instance.refresh();
  }

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

  test("导出：Rust 脚本通道的 env 进 extras['js_envs']", () async {
    // 注册 Rust 脚本通道 pack + env（ScriptApi.getEnv 读取）
    await seedRustPack('js_pingan', {
      'PINGAN_USER': 'u',
      'PINGAN_PASS': 'p',
    });

    final bytes = await service.exportCompressedBackup(includeAppConfig: true);
    final appsJson = decodeAppsJson(bytes);
    final extras = appsJson['extras'] as Map<String, dynamic>?;
    expect(extras, isNotNull);
    final jsEnvs = extras!['js_envs'] as Map<String, dynamic>?;
    expect(jsEnvs, isNotNull,
        reason: 'env 应以 extras.js_envs 携带');
    expect(jsEnvs!['js_pingan'], {'PINGAN_USER': 'u', 'PINGAN_PASS': 'p'});
  });

  test('导入：channels/ 条目写回渠道包目录 + env 恢复（Rust lane）', () async {
    // 1. 预置渠道包 + Rust env，导出备份
    final pinganZip = buildZip(
      entry: 'function main(method, params) { return {channel: "pingan"}; }',
    );
    await File('${channelsDir.path}/pingan.zip').writeAsBytes(pinganZip);
    await seedRustPack('js_pingan', {'PINGAN_USER': 'backup-user'});
    // C16: config-bearing extras are gated behind includeAppConfig.
    final backupBytes =
        await service.exportCompressedBackup(includeAppConfig: true);

    // 2. 清空渠道包目录 + env，制造"恢复前状态"
    await File('${channelsDir.path}/pingan.zip').delete();
    backend.lastEnv.remove('js_pingan');
    expect(backend.lastEnv['js_pingan'], isNull);

    // 3. 导入字节
    final result = await service.importBackupBytes(backupBytes);
    expect(result.success, isTrue);

    // 4. zip 写回（字节一致）
    final restoredFile = File('${channelsDir.path}/pingan.zip');
    expect(await restoredFile.exists(), isTrue);
    expect(await restoredFile.readAsBytes(), pinganZip);

    // 5. env 恢复（ScriptApi.setEnv）
    expect(backend.lastEnv['js_pingan']?['PINGAN_USER'], 'backup-user');
  });

  test('导入：老备份（无 channels/ 条目）不崩且数据正常恢复', () async {
    addedBackend.seed('github', 'a/b', addTime: 1000);
    final bytes = await service.exportCompressedBackup();

    await addedBackend.clearAll();
    final result = await service.importBackupBytes(bytes);
    expect(result.success, isTrue);
    expect(await addedBackend.totalCount(), 1);
  });

  test('通过 JS 渠道添加的应用（聚合 + 渠道库）进备份', () async {
    // 聚合库：js 渠道应用引用（channelId = channelKey）
    addedBackend.seed('js_pingan', 'com.pingan.app', addTime: 1000);

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

  test('WebDAV 配置进备份（统一 ConfigService 存储并入 appConfig）', () async {
    // Todo 31：WebDAV 只有一个存储（Rust 分组 webdav.* 经 ConfigService）。
    // 这里按 UI/迁移后的真实写入路径预置，不再 mock 已删除的直写安全存储。
    await ConfigService.instance.set(
      ConfigKeys.webdavUrl,
      'https://example.com/dav',
    );
    await ConfigService.instance.set(ConfigKeys.webdavUsername, 'user');
    await ConfigService.instance.set(ConfigKeys.webdavPassword, 'pass');
    await ConfigService.instance.set(ConfigKeys.webdavBackupPath, '/GStore');
    await ConfigService.instance.set(ConfigKeys.webdavEnableHttps, true);

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
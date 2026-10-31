import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/config/rust/config_api.dart';
import 'package:gstore/core/rust/generated/config_api.dart' as generated;
import 'package:gstore/core/webdav/webdav_client.dart';
import 'package:gstore/core/webdav/webdav_config.dart';

import 'support/grouped_config_fake.dart';

void main() {
  group('WebDavConfig', () {
    test('默认 backupPath 为 /GStore', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
      );
      expect(config.backupPath, '/GStore');
      expect(config.enableHttps, true);
    });

    test('isValid：完整配置有效', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
      );
      expect(config.isValid, true);
    });

    test('isValid：缺密码无效', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: '',
      );
      expect(config.isValid, false);
    });

    test('isValid：缺用户名无效', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: '',
        password: 'pass',
      );
      expect(config.isValid, false);
    });

    test('baseUrl：无协议时默认 https', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
        enableHttps: true,
      );
      expect(config.baseUrl, 'https://dav.example.com');
    });

    test('baseUrl：enableHttps=false 时用 http', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
        enableHttps: false,
      );
      expect(config.baseUrl, 'http://dav.example.com');
    });

    test('baseUrl：已带协议不重复添加', () {
      final config = WebDavConfig(
        url: 'https://dav.example.com/dav',
        username: 'user',
        password: 'pass',
      );
      expect(config.baseUrl, 'https://dav.example.com/dav');
    });

    test('baseUrl：带协议时移除末尾斜杠', () {
      final config = WebDavConfig(
        url: 'https://dav.example.com/',
        username: 'user',
        password: 'pass',
      );
      expect(config.baseUrl, 'https://dav.example.com');
    });

    test('baseUrl：无协议时保留路径原样拼接', () {
      final config = WebDavConfig(
        url: 'dav.example.com/',
        username: 'user',
        password: 'pass',
      );
      expect(config.baseUrl, 'https://dav.example.com/');
    });

    test('fromJson / toJson 往返', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
        backupPath: '/MyBackup',
        enableHttps: false,
      );
      final json = config.toJson();
      expect(json['url'], 'dav.example.com');
      expect(json['username'], 'user');
      expect(json['password'], 'pass');
      expect(json['backupPath'], '/MyBackup');
      expect(json['enableHttps'], false);

      final restored = WebDavConfig.fromJson(json);
      expect(restored.url, config.url);
      expect(restored.username, config.username);
      expect(restored.password, config.password);
      expect(restored.backupPath, config.backupPath);
      expect(restored.enableHttps, config.enableHttps);
    });

    test('fromJson：缺省字段使用默认值', () {
      final config = WebDavConfig.fromJson({
        'url': 'dav.example.com',
        'username': 'user',
        'password': 'pass',
      });
      expect(config.backupPath, '/GStore');
      expect(config.enableHttps, true);
    });

    test('copyWith：只改部分字段', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'pass',
        backupPath: '/A',
        enableHttps: true,
      );
      final updated = config.copyWith(backupPath: '/B');
      expect(updated.url, 'dav.example.com');
      expect(updated.username, 'user');
      expect(updated.password, 'pass');
      expect(updated.backupPath, '/B');
      expect(updated.enableHttps, true);
    });

    test('toString 不含密码', () {
      final config = WebDavConfig(
        url: 'dav.example.com',
        username: 'user',
        password: 'secret',
      );
      expect(config.toString(), isNot(contains('secret')));
      expect(config.toString(), contains('dav.example.com'));
    });
  });

  group('WebDavFile.formattedSize', () {
    test('B 单位', () {
      expect(
          WebDavFile(
                  name: 'a',
                  path: '/a',
                  size: 512,
                  modified: DateTime.now(),
                  isDirectory: false)
              .formattedSize,
          '512 B');
    });

    test('KB 单位', () {
      expect(
          WebDavFile(
                  name: 'a',
                  path: '/a',
                  size: 2048,
                  modified: DateTime.now(),
                  isDirectory: false)
              .formattedSize,
          '2.0 KB');
    });

    test('MB 单位', () {
      expect(
          WebDavFile(
                  name: 'a',
                  path: '/a',
                  size: 5 * 1024 * 1024,
                  modified: DateTime.now(),
                  isDirectory: false)
              .formattedSize,
          '5.0 MB');
    });

    test('边界：1024 显示 1.0 KB', () {
      expect(
          WebDavFile(
                  name: 'a',
                  path: '/a',
                  size: 1024,
                  modified: DateTime.now(),
                  isDirectory: false)
              .formattedSize,
          '1.0 KB');
    });
  });
  _webDavManagerTests();
}

// ---------------------------------------------------------------------------
// Todo 31: WebDavConfigManager is a thin, rollback-safe facade over
// ConfigService. These tests use an in-memory ConfigApiClient seam; no
// FlutterSecureStorage plugin is involved.
// ---------------------------------------------------------------------------

List<generated.ConfigEntryDto> _webDavEntries() {
  return <generated.ConfigEntryDto>[
    groupedEntry(
      wireKey: ConfigKeys.webdavUrl,
      valueType: 'string',
      defaultJson: '""',
      sensitive: true,
      category: 'webdav',
    ),
    groupedEntry(
      wireKey: ConfigKeys.webdavUsername,
      valueType: 'string',
      defaultJson: '""',
      sensitive: true,
      category: 'webdav',
    ),
    groupedEntry(
      wireKey: ConfigKeys.webdavPassword,
      valueType: 'string',
      defaultJson: '""',
      sensitive: true,
      agentAccessible: false,
      category: 'webdav',
    ),
    groupedEntry(
      wireKey: ConfigKeys.webdavBackupPath,
      valueType: 'string',
      defaultJson: '"/GStore"',
      sensitive: true,
      category: 'webdav',
    ),
    groupedEntry(
      wireKey: ConfigKeys.webdavEnableHttps,
      valueType: 'bool',
      defaultJson: 'true',
      sensitive: true,
      category: 'webdav',
    ),
  ];
}

/// Minimal in-memory [ConfigApiClient] with masked reads, a call log and an
/// injectable single-key write failure.
class _WebDavFakeClient implements ConfigApiClient {
  _WebDavFakeClient(List<generated.ConfigEntryDto> entries)
      : _entries = <String, generated.ConfigEntryDto>{
          for (final entry in entries) entry.wireKey: entry,
        };

  final Map<String, generated.ConfigEntryDto> _entries;
  final Map<String, Object?> values = <String, Object?>{};
  final List<String> getCalls = <String>[];
  final List<String> setCalls = <String>[];

  /// When set, [set] for this wire key returns `success: false` without writing.
  String? failWireKey;

  generated.ConfigEntryDto _require(String module, String key) {
    final entry = _entries['$module.$key'];
    if (entry == null) throw StateError('config_unknown: $module.$key');
    return entry;
  }

  generated.ConfigOpResultDto _result(
    String action,
    generated.ConfigEntryDto entry,
    Object? value, {
    required bool success,
  }) {
    return generated.ConfigOpResultDto(
      success: success,
      message: success
          ? '$action ${entry.wireKey}'
          : '$action failed: ${entry.wireKey}',
      module: entry.module,
      key: entry.key,
      wireKey: entry.wireKey,
      valueJson: value == null ? null : jsonEncode(value),
      defaultJson: entry.defaultJson,
    );
  }

  @override
  Future<List<generated.ConfigEntryDto>> list({String? module}) async {
    return _entries.values
        .where((entry) => module == null || entry.module == module)
        .toList();
  }

  @override
  Future<generated.ConfigSnapshotDto?> snapshot({
    required String module,
    required String key,
  }) async {
    final entry = _require(module, key);
    if (!values.containsKey(entry.wireKey)) return null;
    return generated.ConfigSnapshotDto(
      module: entry.module,
      key: entry.key,
      wireKey: entry.wireKey,
      valueJson: jsonEncode(
        entry.sensitive ? '***' : values[entry.wireKey],
      ),
      masked: entry.sensitive,
      revision: BigInt.zero,
      updatedAt: 0,
      updatedBy: 'test',
    );
  }

  @override
  Future<List<generated.ConfigSnapshotDto>> snapshots({String? module}) async {
    final result = <generated.ConfigSnapshotDto>[];
    for (final entry in _entries.values) {
      if (module != null && entry.module != module) continue;
      final snap = await snapshot(module: entry.module, key: entry.key);
      if (snap != null) result.add(snap);
    }
    return result;
  }

  @override
  Future<String> get({
    required String module,
    required String key,
    required bool masked,
  }) async {
    final entry = _require(module, key);
    getCalls.add('${entry.wireKey}:masked=$masked');
    if (!values.containsKey(entry.wireKey)) return entry.defaultJson;
    if (masked && entry.sensitive) return jsonEncode('***');
    return jsonEncode(values[entry.wireKey]);
  }

  @override
  Future<generated.ConfigOpResultDto> set({
    required String module,
    required String key,
    required String valueJson,
    required String source,
  }) async {
    final entry = _require(module, key);
    setCalls.add(entry.wireKey);
    if (entry.wireKey == failWireKey) {
      return _result('set', entry, null, success: false);
    }
    final value = jsonDecode(valueJson);
    values[entry.wireKey] = value;
    return _result('set', entry, value, success: true);
  }

  @override
  Future<generated.ConfigOpResultDto> clear({
    required String module,
    required String key,
    required String source,
  }) async {
    final entry = _require(module, key);
    values.remove(entry.wireKey);
    return _result('clear', entry, null, success: true);
  }

  @override
  Future<generated.ConfigOpResultDto> reset({
    required String module,
    required String key,
    required String source,
  }) async {
    final entry = _require(module, key);
    values.remove(entry.wireKey);
    return _result('reset', entry, null, success: true);
  }

  @override
  Stream<generated.ConfigChangeDto> watch({
    required String module,
    String? key,
  }) {
    return const Stream<generated.ConfigChangeDto>.empty();
  }
}

Future<_WebDavFakeClient> _installFakeConfigApi() async {
  final fake = _WebDavFakeClient(_webDavEntries());
  ConfigService.instance.debugSetApi(ConfigRustApi(fake));
  await ConfigService.instance.ensureReady();
  return fake;
}

WebDavConfig _config({
  String url = 'https://dav.example.com/dav',
  String username = 'alice',
  String password = 's3cret',
  String backupPath = '/Backups',
  bool enableHttps = false,
}) {
  return WebDavConfig(
    url: url,
    username: username,
    password: password,
    backupPath: backupPath,
    enableHttps: enableHttps,
  );
}

void _webDavManagerTests() {
  setUp(() async {
    await ConfigService.instance.resetForTest();
  });

  tearDown(() async {
    await ConfigService.instance.resetForTest();
  });

  test('save (UI style) → load raw → Agent read masked', () async {
    final fake = await _installFakeConfigApi();
    final manager = WebDavConfigManager.instance;

    await manager.saveConfig(_config());

    // Trusted raw read (facade) keeps the password.
    final loaded = await manager.loadConfig();
    expect(loaded, isNotNull);
    expect(loaded!.url, 'https://dav.example.com/dav');
    expect(loaded.username, 'alice');
    expect(loaded.password, 's3cret');
    expect(loaded.backupPath, '/Backups');
    expect(loaded.enableHttps, isFalse);
    expect(fake.values[ConfigKeys.webdavPassword], 's3cret');

    // Agent/UI surface goes through ConfigService.get → masked.
    expect(await ConfigService.instance.get(ConfigKeys.webdavPassword), '***');
    expect(await ConfigService.instance.get(ConfigKeys.webdavUrl), '***');
    expect(
      await ConfigService.instance.getRaw(ConfigKeys.webdavPassword),
      's3cret',
    );
  });

  test('loadConfig uses getRaw (masked:false) for all five fields', () async {
    final fake = await _installFakeConfigApi();
    await WebDavConfigManager.instance.loadConfig();

    final rawReads = fake.getCalls.toSet();
    for (final key in <String>[
      ConfigKeys.webdavUrl,
      ConfigKeys.webdavUsername,
      ConfigKeys.webdavPassword,
      ConfigKeys.webdavBackupPath,
      ConfigKeys.webdavEnableHttps,
    ]) {
      expect(rawReads, contains('$key:masked=false'),
          reason: '$key must be read raw');
    }
  });

  test('one field write fails → previous config remains (rollback)', () async {
    final fake = await _installFakeConfigApi();
    final manager = WebDavConfigManager.instance;
    final previous = _config(
      url: 'https://old.example.com/dav',
      username: 'old-user',
      password: 'old-pass',
      backupPath: '/OldBackups',
      enableHttps: true,
    );
    await manager.saveConfig(previous);

    fake.failWireKey = ConfigKeys.webdavBackupPath;
    await expectLater(
      manager.saveConfig(_config(
        url: 'https://new.example.com/dav',
        username: 'new-user',
        password: 'new-pass',
        backupPath: '/NewBackups',
        enableHttps: false,
      )),
      throwsA(isA<StateError>()),
    );

    final restored = await manager.loadConfig();
    expect(restored, isNotNull);
    expect(restored!.url, previous.url);
    expect(restored.username, previous.username);
    expect(restored.password, previous.password);
    expect(restored.backupPath, previous.backupPath);
    expect(restored.enableHttps, previous.enableHttps);
  });

  test('clearConfig clears all five backing values, not just load == null',
      () async {
    final fake = await _installFakeConfigApi();
    final manager = WebDavConfigManager.instance;
    await manager.saveConfig(_config());

    await manager.clearConfig();

    // No webdav.* value remains in the backing store.
    for (final key in <String>[
      ConfigKeys.webdavUrl,
      ConfigKeys.webdavUsername,
      ConfigKeys.webdavPassword,
      ConfigKeys.webdavBackupPath,
      ConfigKeys.webdavEnableHttps,
    ]) {
      expect(fake.values.containsKey(key), isFalse,
          reason: '$key must be cleared from the backing store');
    }

    // Raw reads fall back to each registered default.
    expect(await ConfigService.instance.getRaw(ConfigKeys.webdavUrl), '');
    expect(await ConfigService.instance.getRaw(ConfigKeys.webdavUsername), '');
    expect(await ConfigService.instance.getRaw(ConfigKeys.webdavPassword), '');
    expect(
      await ConfigService.instance.getRaw(ConfigKeys.webdavBackupPath),
      '/GStore',
    );
    expect(
      await ConfigService.instance.getRaw(ConfigKeys.webdavEnableHttps),
      isTrue,
    );

    expect(await manager.loadConfig(), isNull);
    expect(await manager.hasConfig(), isFalse);
  });

  test('webdav_config.dart has no direct FlutterSecureStorage', () {
    final source =
        File('lib/core/webdav/webdav_config.dart').readAsStringSync();
    expect(source, isNot(contains('FlutterSecureStorage')));
    expect(source, isNot(contains('flutter_secure_storage')));
  });
}

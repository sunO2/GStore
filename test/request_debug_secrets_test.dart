/// todo 9：密钥安全存储 + 脱敏。
///
/// 覆盖验收：
/// - 敏感值（auth 密码 / token / apiKey、被标记为密钥的环境变量）**不落明文**
///   于 `request_debug_store.json`（断言真实序列化字符串）；
/// - 旧明文文件迁移后读取一致，且迁移后磁盘不再含明文；
/// - cURL / 历史导出前脱敏（不残留部分密钥）；
/// - 无任何密钥的 store 正常加载（不破坏无密钥用户）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:gstore/core/request_debug/curl_codec.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_secrets.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';

/// 内存假安全存储（单测无平台通道，绝不触碰 `flutter_secure_storage`）。
class _InMemorySecureStorage implements DebugSecureStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('request_debug_secrets_test_');

File _storeFile(Directory dir) =>
    File(p.join(dir.path, RequestDebugStore.fileName));

RequestDebugStore _storeFor(Directory dir, {DebugSecureStorage? secure}) =>
    RequestDebugStore(
      directoryProvider: () async => dir,
      secureStorage: secure,
    );

const String _basicSecret = 's3cr3t-pw-do-not-leak';
const String _bearerSecret = 'top-secret-token-do-not-leak';
const String _apiKeySecret = 'api-key-value-do-not-leak';
const String _envSecret = 'env-secret-value-do-not-leak';

void main() {
  group('磁盘不落明文（真实序列化字符串）', () {
    test('auth 与标记为密钥的环境变量都不出现在 store 文件', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final vault = _InMemorySecureStorage();
      final store = _storeFor(dir, secure: vault);

      final col = store.addCollection(name: 'API');
      store.addRequest(
        col.id,
        DebugRequest(
          id: 'r-1',
          name: 'login',
          method: 'POST',
          url: 'https://api.example/login',
          auth: const DebugAuth(
            type: DebugAuthType.basic,
            username: 'alice',
            password: _basicSecret,
          ),
        ),
      );
      store.addEnvironment(
        id: 'env-1',
        name: 'prod',
        vars: const {'API_KEY': _envSecret, 'host': 'https://api.example'},
        secretVars: const {'API_KEY'},
      );

      expect(await store.save(), isTrue);
      final raw = await _storeFile(dir).readAsString();

      expect(raw.contains(_basicSecret), isFalse,
          reason: 'auth 密码绝不能以明文落盘');
      expect(raw.contains(_envSecret), isFalse,
          reason: '标记为密钥的环境变量绝不能以明文落盘');
      // 非敏感值仍应可读（不是把所有东西都删掉）。
      expect(raw.contains('https://api.example'), isTrue);
      // 引用必须存在，否则无法恢复。
      expect(raw.contains(DebugSecretReference.prefix), isTrue);
      // 密钥确实进了安全存储。
      expect(vault.values.values, contains(_basicSecret));
      expect(vault.values.values, contains(_envSecret));
    });

    test('round-trip：重新加载后读回与原始一致', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final vault = _InMemorySecureStorage();
      final store = _storeFor(dir, secure: vault);

      final col = store.addCollection(name: 'API');
      store.addRequest(
        col.id,
        DebugRequest(
          id: 'r-1',
          name: 'login',
          method: 'POST',
          url: 'https://api.example/login',
          auth: const DebugAuth(
            type: DebugAuthType.bearer,
            token: _bearerSecret,
          ),
        ),
      );
      store.addEnvironment(
        id: 'env-1',
        name: 'prod',
        vars: const {'API_KEY': _envSecret},
        secretVars: const {'API_KEY'},
      );
      expect(await store.save(), isTrue);

      final reloaded = _storeFor(dir, secure: vault);
      await reloaded.load();

      expect(reloaded.requestById('r-1')!.auth!.token, _bearerSecret);
      expect(reloaded.environments.single.vars['API_KEY'], _envSecret);
    });
  });

  group('旧明文迁移', () {
    test('加载旧明文文件 → 内存读回一致，且迁移后磁盘无明文', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final vault = _InMemorySecureStorage();

      // 旧格式 fixture：auth 明文 + 无 secretVars 标记的旧数据（auth 可迁移）。
      final legacy = <String, dynamic>{
        'version': 1,
        'activeEnvironmentId': null,
        'collections': [
          {
            'id': 'c-1',
            'name': 'Legacy',
            'requests': [
              {
                'id': 'r-legacy',
                'name': 'legacy',
                'method': 'GET',
                'url': 'https://api.example/legacy',
                'headers': <dynamic>[],
                'query': <dynamic>[],
                'body': '',
                'bodyKind': 'none',
                'cookies': <dynamic>[],
                'auth': {
                  'type': 'basic',
                  'username': 'bob',
                  'password': _basicSecret,
                },
              },
            ],
          },
        ],
        'environments': <dynamic>[],
        'history': <dynamic>[],
        'rules': <dynamic>[],
      };
      await _storeFile(dir).writeAsString(jsonEncode(legacy));

      final store = _storeFor(dir, secure: vault);
      await store.load();

      // 内存读回一致（用户可继续使用旧数据）。
      expect(store.requestById('r-legacy')!.auth!.password, _basicSecret);
      // 已写入安全存储。
      expect(vault.values.values, contains(_basicSecret));

      // 迁移后磁盘不再含明文；引用已生成。
      final raw = await _storeFile(dir).readAsString();
      expect(raw.contains(_basicSecret), isFalse,
          reason: '加载迁移后文件不得再含明文密钥');
      expect(raw.contains(DebugSecretReference.prefix), isTrue);
    });

    test('旧明文 + 标记密钥的环境变量 → 迁移后一致且无明文', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final vault = _InMemorySecureStorage();

      final legacy = <String, dynamic>{
        'version': 1,
        'collections': <dynamic>[],
        'environments': [
          {
            'id': 'e-1',
            'name': 'legacy-env',
            'vars': {'TOKEN': _envSecret},
            'secretVars': ['TOKEN'],
          },
        ],
        'history': <dynamic>[],
        'rules': <dynamic>[],
      };
      await _storeFile(dir).writeAsString(jsonEncode(legacy));

      final store = _storeFor(dir, secure: vault);
      await store.load();

      expect(store.environments.single.vars['TOKEN'], _envSecret);
      final raw = await _storeFile(dir).readAsString();
      expect(raw.contains(_envSecret), isFalse);
    });
  });

  group('导出脱敏', () {
    DebugRequest secretRequest() => DebugRequest(
          id: 'r-export',
          name: 'export',
          method: 'POST',
          url: 'https://api.example/secure',
          auth: const DebugAuth(
            type: DebugAuthType.basic,
            username: 'alice',
            password: _basicSecret,
          ),
        );

    test('cURL 导出脱敏且不残留部分密钥', () {
      final curl = toCurl(redactRequest(secretRequest()));
      expect(curl.contains(_basicSecret), isFalse);
      expect(curl.contains('s3cr3t'), isFalse, reason: '不得残留部分密钥');
      expect(curl, contains(debugSecretMask));
    });

    test('Bearer / APIKey 导出脱敏', () {
      final bearer = toCurl(redactRequest(DebugRequest(
        id: 'r-b',
        name: 'b',
        method: 'GET',
        url: 'https://api.example/b',
        auth: const DebugAuth(type: DebugAuthType.bearer, token: _bearerSecret),
      )));
      expect(bearer.contains(_bearerSecret), isFalse);
      expect(bearer, contains(debugSecretMask));

      final api = toCurl(redactRequest(DebugRequest(
        id: 'r-a',
        name: 'a',
        method: 'GET',
        url: 'https://api.example/a',
        auth: const DebugAuth(
          type: DebugAuthType.apiKey,
          apiKeyName: 'X-Api-Key',
          apiKeyValue: _apiKeySecret,
          apiKeyIn: 'header',
        ),
      )));
      expect(api.contains(_apiKeySecret), isFalse);
      expect(api, contains(debugSecretMask));
    });

    test('历史导出脱敏', () {
      final entry = DebugHistoryEntry(
        id: 'h-1',
        tsMs: 1710000000000,
        request: secretRequest(),
        responseSummary: const DebugResponseSummary(statusCode: 200),
      );
      final exported =
          jsonEncode(redactedHistoryEntryJson(entry));
      expect(exported.contains(_basicSecret), isFalse);
      expect(exported.contains('s3cr3t'), isFalse);
      expect(exported, contains(debugSecretMask));
    });
  });

  group('无密钥用户不被破坏', () {
    test('无密钥 store 正常保存 / 加载', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final vault = _InMemorySecureStorage();
      final store = _storeFor(dir, secure: vault);

      final col = store.addCollection(name: 'Plain');
      store.addRequest(
        col.id,
        DebugRequest(
          id: 'r-plain',
          name: 'plain',
          method: 'GET',
          url: 'https://api.example/plain',
        ),
      );
      expect(await store.save(), isTrue);

      final reloaded = _storeFor(dir, secure: vault);
      await reloaded.load();
      expect(reloaded.requestById('r-plain')!.url, 'https://api.example/plain');
      expect(reloaded.collections, hasLength(1));
    });

    test('无安全存储注入时（默认）加载不抛，且无密钥请求可用', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = _storeFor(dir);

      final col = store.addCollection(name: 'Plain');
      store.addRequest(
        col.id,
        DebugRequest(
          id: 'r-plain',
          name: 'plain',
          method: 'GET',
          url: 'https://api.example/plain',
        ),
      );
      expect(await store.save(), isTrue);
      final reloaded = _storeFor(dir);
      await reloaded.load();
      expect(reloaded.requestById('r-plain')!.url, 'https://api.example/plain');
    });
  });
}

/// todo 20：环境作用域 / 默认值 / 密钥 + 集合级变量与鉴权。
///
/// 覆盖验收：
/// - `{{var:-default}}` 默认值语法：变量缺失时用默认值，命中时忽略默认值；
/// - 作用域继承顺序 `global → collection → environment → local`（后者覆盖前者）；
/// - 集合 / 文件夹级变量与鉴权：子请求无自身鉴权时继承最近集合鉴权；
/// - 密钥不泄露：环境导出 / 集合级密钥与鉴权在序列化与导出时脱敏；
/// - **不破坏单环境语义**：仅激活环境（无 global / collection / local）时行为不变。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:gstore/core/request_debug/auth_apply.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/debug_secrets.dart';
import 'package:gstore/core/request_debug/env_resolver.dart';
import 'package:gstore/core/request_debug/import_export/import_export.dart';
import 'package:gstore/core/request_debug/request_debug_store.dart';
import 'package:gstore/core/request_debug/scope_resolver.dart';

/// 内存假安全存储（单测无平台通道）。
class _InMemorySecureStorage implements DebugSecureStorage {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> delete(String key) async => values.remove(key);
}

Directory _tempDir() =>
    Directory.systemTemp.createTempSync('request_debug_env_scope_test_');

Future<Directory> _dirProvider() async => _tempDir();

File _storeFile(Directory dir) =>
    File(p.join(dir.path, RequestDebugStore.fileName));

RequestDebugStore _storeFor(Directory dir, {DebugSecureStorage? secure}) =>
    RequestDebugStore(
      directoryProvider: () async => dir,
      secureStorage: secure,
    );

void main() {
  // ==================== 默认值语法 ====================

  group('默认值语法 {{var:-default}}', () {
    test('缺失变量用默认值且不计为 missing', () {
      final r = resolveEnv('{{host:-localhost}}/{{path}}', {'path': 'v1'});
      expect(r.text, 'localhost/v1');
      expect(r.missing, isEmpty);
    });

    test('已定义变量时忽略默认值', () {
      final r = resolveEnv('{{host:-localhost}}', {'host': 'api.test'});
      expect(r.text, 'api.test');
      expect(r.missing, isEmpty);
    });

    test('变量存在但为空串时仍命中（不使用默认值）', () {
      final r = resolveEnv('{{host:-localhost}}', {'host': ''});
      expect(r.text, '');
      expect(r.missing, isEmpty);
    });

    test('无默认值且缺失：保留占位符并标记 missing（既有语义）', () {
      final r = resolveEnv('{{token}}', <String, String>{});
      expect(r.text, '{{token}}');
      expect(r.missing, unorderedEquals(<String>['token']));
    });

    test('默认值可包含冒号与连字符', () {
      final r = resolveEnv('{{url:-http://a-b:8080}}', <String, String>{});
      expect(r.text, 'http://a-b:8080');
      expect(r.missing, isEmpty);
    });
  });

  // ==================== 继承顺序 ====================

  group('作用域继承 global → collection → environment → local', () {
    test('后者覆盖前者', () {
      final vars = resolveEffectiveVars(
        globalVars: {'a': 'g', 'b': 'g', 'c': 'g', 'd': 'g'},
        collectionChain: <Map<String, String>>[
          {'b': 'c', 'c': 'c', 'd': 'c'},
        ],
        environmentVars: {'c': 'e', 'd': 'e'},
        localVars: {'d': 'l'},
      );
      expect(vars, {'a': 'g', 'b': 'c', 'c': 'e', 'd': 'l'});
    });

    test('嵌套集合：叶子集合覆盖祖先集合', () {
      final vars = resolveEffectiveVars(
        collectionChain: <Map<String, String>>[
          {'host': 'root', 'x': 'root'},
          {'host': 'leaf'},
        ],
      );
      expect(vars, {'host': 'leaf', 'x': 'root'});
    });

    test('空作用域返回空表（不破坏单环境语义）', () {
      expect(resolveEffectiveVars(), isEmpty);
    });
  });

  group('集合级鉴权 resolveEffectiveAuth', () {
    test('子请求无自身鉴权时继承集合鉴权', () {
      final auth = resolveEffectiveAuth(
        collectionAuthChain: <DebugAuth?>[
          const DebugAuth(type: DebugAuthType.bearer, token: 'col-token'),
        ],
      );
      expect(auth, isNotNull);
      expect(auth!.type, DebugAuthType.bearer);
      expect(auth.token, 'col-token');
    });

    test('请求自身鉴权优先于集合与全局', () {
      final auth = resolveEffectiveAuth(
        requestAuth: const DebugAuth(type: DebugAuthType.apiKey, apiKeyValue: 'r'),
        collectionAuthChain: <DebugAuth?>[
          const DebugAuth(type: DebugAuthType.bearer, token: 'col'),
        ],
        globalAuth: const DebugAuth(type: DebugAuthType.basic, username: 'g'),
      );
      expect(auth!.type, DebugAuthType.apiKey);
    });

    test('最近集合覆盖祖先集合，集合覆盖全局', () {
      final auth = resolveEffectiveAuth(
        collectionAuthChain: <DebugAuth?>[
          const DebugAuth(type: DebugAuthType.basic, username: 'root'),
          const DebugAuth(type: DebugAuthType.bearer, token: 'leaf'),
        ],
        globalAuth: const DebugAuth(type: DebugAuthType.apiKey, apiKeyValue: 'g'),
      );
      expect(auth!.type, DebugAuthType.bearer);
      expect(auth.token, 'leaf');
    });

    test('全部 none 时返回 null', () {
      final auth = resolveEffectiveAuth(
        requestAuth: const DebugAuth(type: DebugAuthType.none),
        collectionAuthChain: <DebugAuth?>[
          const DebugAuth(type: DebugAuthType.none),
        ],
      );
      expect(auth, isNull);
    });
  });

  // ==================== store 继承集成 ====================

  group('store.effective*ForRequest', () {
    test('变量按 global → 集合祖先→叶子 → environment → local 合并', () {
      final store = RequestDebugStore(directoryProvider: _dirProvider);
      store.globalVars['a'] = 'g';
      store.globalVars['b'] = 'g';
      store.globalVars['c'] = 'g';

      final parent = store.addCollection(name: 'parent', vars: {'b': 'p'});
      final child = store.addCollection(
        name: 'child',
        parentId: parent.id,
        vars: {'c': 'child'},
      );
      final env = store.addEnvironment(
        name: 'dev',
        vars: {'c': 'env'},
      );
      store.setActiveEnvironment(env.id);

      final request = DebugRequest(
        id: 'r1',
        name: 'r',
        collectionId: child.id,
      );

      expect(
        store.effectiveVarsForRequest(request),
        {'a': 'g', 'b': 'p', 'c': 'env'},
      );
      expect(
        store.effectiveVarsForRequest(request, localVars: {'c': 'local'}),
        {'a': 'g', 'b': 'p', 'c': 'local'},
      );
    });

    test('集合级鉴权在子请求生效（applyAuth 产出 Authorization 头）', () {
      final store = RequestDebugStore(directoryProvider: _dirProvider);
      final col = store.addCollection(
        name: 'api',
        auth: const DebugAuth(
          type: DebugAuthType.bearer,
          token: 'col-token',
        ),
      );
      final child = store.addRequest(
        col.id,
        DebugRequest(id: 'r2', name: 'child', url: 'https://api.test'),
      )!;

      final auth = store.effectiveAuthForRequest(child);
      final applied = applyAuth(auth: auth);
      expect(applied.headers, hasLength(1));
      expect(applied.headers.single.name, 'Authorization');
      expect(applied.headers.single.value, 'Bearer col-token');
    });

    test('请求自身鉴权覆盖集合鉴权', () {
      final store = RequestDebugStore(directoryProvider: _dirProvider);
      final col = store.addCollection(
        name: 'api',
        auth: const DebugAuth(type: DebugAuthType.bearer, token: 'col'),
      );
      final child = store.addRequest(
        col.id,
        DebugRequest(
          id: 'r3',
          name: 'child',
          auth: const DebugAuth(
            type: DebugAuthType.bearer,
            token: 'own',
          ),
        ),
      )!;
      expect(store.effectiveAuthForRequest(child)!.token, 'own');
    });
  });

  // ==================== 密钥不泄露 ====================

  group('密钥不泄露（导出 / 序列化脱敏）', () {
    test('环境导出脱敏 secretVars 值', () {
      final text = DebugImportExport.encodeEnvironmentsJson(<DebugEnvironment>[
        DebugEnvironment(
          id: 'e1',
          name: 'prod',
          vars: {'API_KEY': 'env-secret-do-not-leak', 'host': 'api.test'},
          secretVars: <String>{'API_KEY'},
        ),
      ]);
      expect(text.contains('env-secret-do-not-leak'), isFalse);
      expect(text.contains(debugSecretMask), isTrue);
      expect(text.contains('api.test'), isTrue);
    });

    test('集合级密钥变量与鉴权密码不落 store 文件明文', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final vault = _InMemorySecureStorage();
      final store = _storeFor(dir, secure: vault);

      store.globalVars['GLOBAL_TOKEN'] = 'global-secret-do-not-leak';
      store.globalSecretVars.add('GLOBAL_TOKEN');
      store.globalAuth = const DebugAuth(
        type: DebugAuthType.basic,
        username: 'g',
        password: 'global-auth-do-not-leak',
      );

      store.addCollection(
        name: 'api',
        vars: {'COL_TOKEN': 'col-secret-do-not-leak', 'host': 'api.test'},
        secretVars: <String>{'COL_TOKEN'},
        auth: const DebugAuth(
          type: DebugAuthType.bearer,
          token: 'col-auth-do-not-leak',
        ),
      );

      expect(await store.save(), isTrue);
      final raw = await _storeFile(dir).readAsString();
      expect(raw.contains('global-secret-do-not-leak'), isFalse);
      expect(raw.contains('global-auth-do-not-leak'), isFalse);
      expect(raw.contains('col-secret-do-not-leak'), isFalse);
      expect(raw.contains('col-auth-do-not-leak'), isFalse);
      // 非密钥内容仍在。
      expect(raw.contains('api.test'), isTrue);
      expect(raw.contains(DebugSecretReference.prefix), isTrue);
    });

    test('集合级密钥 round-trip：重新加载读回一致', () async {
      final dir = _tempDir();
      addTearDown(() => dir.deleteSync(recursive: true));
      final vault = _InMemorySecureStorage();
      final store = _storeFor(dir, secure: vault);
      store.addCollection(
        name: 'api',
        vars: {'TOKEN': 'col-secret-roundtrip'},
        secretVars: <String>{'TOKEN'},
        auth: const DebugAuth(type: DebugAuthType.bearer, token: 'col-auth-rt'),
      );
      expect(await store.save(), isTrue);

      final reloaded = _storeFor(dir, secure: vault);
      await reloaded.load();
      final col = reloaded.collections.single;
      expect(col.vars['TOKEN'], 'col-secret-roundtrip');
      expect(col.auth!.token, 'col-auth-rt');
    });

    test('redactEnvironment / redactCollection 掩码密钥但保留其余', () {
      final env = DebugEnvironment(
        id: 'e',
        name: 'n',
        vars: {'S': 'secret', 'P': 'plain'},
        secretVars: <String>{'S'},
      );
      final redacted = redactEnvironment(env);
      expect(redacted.vars['S'], debugSecretMask);
      expect(redacted.vars['P'], 'plain');

      final col = DebugCollection(
        id: 'c',
        name: 'c',
        vars: {'S': 'secret', 'P': 'plain'},
        secretVars: <String>{'S'},
        auth: const DebugAuth(type: DebugAuthType.basic, password: 'pw'),
      );
      final redactedCol = redactCollection(col);
      expect(redactedCol.vars['S'], debugSecretMask);
      expect(redactedCol.vars['P'], 'plain');
      expect(redactedCol.auth!.password, debugSecretMask);
    });
  });

  // ==================== 单环境语义不回归 ====================

  group('不破坏单环境语义', () {
    test('仅激活环境时，解析结果与 resolveEnvIn 一致', () {
      final store = RequestDebugStore(directoryProvider: _dirProvider);
      final env = store.addEnvironment(
        name: 'dev',
        vars: {'host': 'api.test', 'path': 'v1'},
      );
      store.setActiveEnvironment(env.id);
      final request = DebugRequest(id: 'r', name: 'r');

      final effective = store.effectiveVarsForRequest(request);
      expect(effective, {'host': 'api.test', 'path': 'v1'});
      expect(
        resolveEnv('https://{{host}}/{{path}}', effective).text,
        resolveEnvIn('https://{{host}}/{{path}}', env).text,
      );
    });

    test('无环境无集合变量时有效变量表为空', () {
      final store = RequestDebugStore(directoryProvider: _dirProvider);
      expect(store.effectiveVarsForRequest(DebugRequest(id: 'r', name: 'r')),
          isEmpty);
      expect(store.effectiveAuthForRequest(DebugRequest(id: 'r', name: 'r')),
          isNull);
    });
  });

  // ==================== 持久化保留 ====================

  group('集合级变量/鉴权持久化', () {
    test('moveCollection 保留 vars/secretVars/auth', () {
      final store = RequestDebugStore(directoryProvider: _dirProvider);
      final parent = store.addCollection(name: 'p');
      final child = store.addCollection(
        name: 'c',
        vars: {'a': '1'},
        secretVars: <String>{'a'},
        auth: const DebugAuth(type: DebugAuthType.bearer, token: 't'),
      );
      expect(store.moveCollection(child.id, parent.id), isTrue);
      final moved = store.collectionById(child.id)!;
      expect(moved.vars, {'a': '1'});
      expect(moved.secretVars, contains('a'));
      expect(moved.auth!.token, 't');
    });

    test('duplicateCollection 复制 vars/secretVars/auth', () {
      final store = RequestDebugStore(directoryProvider: _dirProvider);
      final src = store.addCollection(
        name: 'src',
        vars: {'a': '1'},
        secretVars: <String>{'a'},
        auth: const DebugAuth(type: DebugAuthType.bearer, token: 't'),
      );
      final clone = store.duplicateCollection(src.id)!;
      expect(clone.vars, {'a': '1'});
      expect(clone.secretVars, contains('a'));
      expect(clone.auth!.token, 't');
    });

    test('collection toJson/fromJson 往返', () {
      final col = DebugCollection(
        id: 'c1',
        name: 'c',
        vars: {'a': '1'},
        secretVars: <String>{'a'},
        auth: const DebugAuth(type: DebugAuthType.apiKey, apiKeyValue: 'k'),
      );
      final json = jsonDecode(jsonEncode(col.toJson())) as Map<String, dynamic>;
      final back = DebugCollection.fromJson(json);
      expect(back.vars, {'a': '1'});
      expect(back.secretVars, contains('a'));
      expect(back.auth!.type, DebugAuthType.apiKey);
      expect(back.auth!.apiKeyValue, 'k');
    });
  });
}

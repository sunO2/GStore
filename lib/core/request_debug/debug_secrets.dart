/// 「请求调试」密钥安全存储 + 脱敏（plan todo 9，纯逻辑层，无 UI）。
///
/// 设计目标（见 `.omo/plans/net-req-debug-enhancement.md` todo 9）：
/// - **不落明文**：auth 的 `password` / `token` / `apiKeyValue`，以及被
///   [DebugEnvironment.secretVars] 标记的环境变量值，写入
///   `request_debug_store.json` 时替换为**引用**（[DebugSecretReference]），
///   真实值存于 [DebugSecureStorage]（生产为 `flutter_secure_storage`）；
/// - **可迁移**：加载旧明文文件时，明文照旧读入内存（用户可继续使用），
///   同时写入安全存储并在下次保存时改写为引用；
/// - **可测试**：安全存储是抽象接缝 [DebugSecureStorage]，单测注入内存假实现，
///   纯逻辑层不直接调用插件；
/// - **脱敏**：cURL / 历史导出前用 [redactRequest] / [redactedHistoryEntryJson]
///   把密钥替换为 [debugSecretMask]，不残留任何部分密钥。
///
/// **范围**：本文件只负责密钥引用与脱敏，**不**定义 store 的版本迁移表
/// （由 todo 10 负责）。
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'debug_models.dart';

/// 脱敏掩码：整值替换，绝不保留原值任何片段。
const String debugSecretMask = '***';

/// auth 中属于密钥的字段名（用户名 / apiKeyName / apiKeyIn 不是密钥）。
const List<String> _secretAuthFields = <String>['password', 'token', 'apiKeyValue'];

// ==================== 安全存储接缝 ====================

/// 小型安全存储抽象：仅存 / 取 / 删字符串。
///
/// 生产用 [FlutterDebugSecureStorage]；单测注入内存假实现（无平台通道）。
/// 纯逻辑层只依赖本抽象，绝不直接 `import` 插件调用。
abstract class DebugSecureStorage {
  /// 写入（覆盖）[key] 对应的 [value]。
  Future<void> write(String key, String value);

  /// 读取 [key]；不存在 / 读取失败返回 `null`。
  Future<String?> read(String key);

  /// 删除 [key]。
  Future<void> delete(String key);
}

/// `flutter_secure_storage` 生产实现。
///
/// 复用项目既有安全存储约定（`AndroidOptions(encryptedSharedPreferences: true)`，
/// 见 `lib/core/config/config_storage.dart`）；键统一加 [keyPrefix] 前缀，
/// 与其它模块的 `secure_config_` 命名空间隔离。
class FlutterDebugSecureStorage implements DebugSecureStorage {
  const FlutterDebugSecureStorage();

  /// 安全存储键前缀（调试密钥命名空间）。
  static const String keyPrefix = 'debug_secret_';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: '$keyPrefix$key', value: value);

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: '$keyPrefix$key');
    } catch (_) {
      // 平台读取失败（如密钥库损坏）→ 视为缺失，不抛。
      return null;
    }
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: '$keyPrefix$key');
}

// ==================== 引用编码 ====================

/// 磁盘上的密钥引用编码：`secretref:<vaultKey>`。
///
/// 引用本身**不含**任何明文片段；仅用于在加载时回查安全存储。
class DebugSecretReference {
  const DebugSecretReference._();

  /// 引用前缀。
  static const String prefix = 'secretref:';

  /// 是否为引用字符串。
  static bool isReference(Object? value) =>
      value is String && value.startsWith(prefix);

  /// 用安全存储键 [key] 生成引用字符串。
  static String encode(String key) => '$prefix$key';

  /// 从引用字符串解出安全存储键；非引用返回 `null`。
  static String? keyOf(String value) =>
      isReference(value) ? value.substring(prefix.length) : null;
}

// ==================== 打开结果 ====================

/// [DebugSecretCodec.open] 的结果。
class DebugSecretOpenResult {
  const DebugSecretOpenResult({required this.root, required this.migrated});

  /// 已把引用解析为明文的根 JSON（供模型 `fromJson` 使用）。
  final Map<String, dynamic> root;

  /// 是否发现旧明文并将其写入安全存储（调用方据此触发一次迁移保存）。
  final bool migrated;
}

// ==================== 编解码 ====================

/// 把 store 的 JSON 根在「明文 ⇄ 引用」之间转换。
///
/// - [seal]：保存前调用；把明文密钥写入 [storage] 并以引用替换；
/// - [open]：加载后调用；把引用解析回明文（内存），并识别旧明文以迁移。
class DebugSecretCodec {
  const DebugSecretCodec(this.storage);

  /// 安全存储接缝。
  final DebugSecureStorage storage;

  /// 保存前密封：返回**新**根 JSON，其中密钥值改为引用。
  Future<Map<String, dynamic>> seal(Map<String, dynamic> root) async {
    final out = _deepCopy(root);
    await _sealGlobals(out['globals']);
    await _sealEnvironments(out['environments']);
    await _sealCollections(out['collections']);
    await _sealHistory(out['history']);
    return out;
  }

  /// 加载后打开：解析引用为明文并报告是否发生旧明文迁移。
  Future<DebugSecretOpenResult> open(Map<String, dynamic> root) async {
    final out = _deepCopy(root);
    var migrated = false;

    if (await _openGlobals(out['globals'])) migrated = true;
    if (await _openEnvironments(out['environments'])) migrated = true;
    if (await _openCollections(out['collections'])) migrated = true;
    if (await _openHistory(out['history'])) migrated = true;

    return DebugSecretOpenResult(root: out, migrated: migrated);
  }

  // ---------- 密封 ----------

  Future<void> _sealGlobals(Object? raw) async {
    if (raw is! Map) return;
    final globals = raw.cast<String, dynamic>();
    await _sealSecretVars(globals, 'global');
    await _sealAuthIn(globals, 'global');
  }

  Future<void> _sealEnvironments(Object? raw) async {
    if (raw is! List) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final env = item.cast<String, dynamic>();
      final envId = env['id']?.toString() ?? '';
      await _sealSecretVars(env, 'env:$envId');
    }
  }

  Future<void> _sealCollections(Object? raw) async {
    if (raw is! List) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final col = item.cast<String, dynamic>();
      final colId = col['id']?.toString() ?? '';
      // 集合 / 文件夹级变量（含密钥标记）与集合级鉴权。
      await _sealSecretVars(col, 'col:$colId');
      await _sealAuthIn(col, 'col:$colId');
      final requests = col['requests'];
      if (requests is! List) continue;
      for (final requestItem in requests) {
        if (requestItem is! Map) continue;
        final request = requestItem.cast<String, dynamic>();
        await _sealAuthIn(request, 'col:$colId:req:${request['id']}');
      }
    }
  }

  Future<void> _sealHistory(Object? raw) async {
    if (raw is! List) return;
    for (final item in raw) {
      if (item is! Map) continue;
      final entry = item.cast<String, dynamic>();
      final request = entry['request'];
      if (request is! Map) continue;
      await _sealAuthIn(
        request.cast<String, dynamic>(),
        'hist:${entry['id']}',
      );
    }
  }

  /// 密封一个容器（环境 / 集合 / 全局）的 `vars` 中的 `secretVars` 值。
  ///
  /// 键格式：`<scope>:var:<name>`。
  Future<void> _sealSecretVars(
    Map<String, dynamic> holder,
    String scope,
  ) async {
    final secretVars = holder['secretVars'];
    final vars = holder['vars'];
    if (secretVars is! List || vars is! Map) return;
    for (final name in secretVars) {
      final key = name.toString();
      final value = vars[key];
      if (value is String && value.isNotEmpty &&
          !DebugSecretReference.isReference(value)) {
        final refKey = '$scope:var:$key';
        await _store(refKey, value);
        vars[key] = DebugSecretReference.encode(refKey);
      }
    }
  }

  /// 密封一个容器 / 请求的 `auth` 中的密钥字段。
  ///
  /// 键格式：`<scope>:auth:<field>`。
  Future<void> _sealAuthIn(
    Map<String, dynamic> holder,
    String scope,
  ) async {
    final auth = holder['auth'];
    if (auth is! Map) return;
    for (final field in _secretAuthFields) {
      final value = auth[field];
      if (value is String && value.isNotEmpty &&
          !DebugSecretReference.isReference(value)) {
        final key = '$scope:auth:$field';
        await _store(key, value);
        auth[field] = DebugSecretReference.encode(key);
      }
    }
  }

  // ---------- 打开 ----------

  Future<bool> _openGlobals(Object? raw) async {
    if (raw is! Map) return false;
    final globals = raw.cast<String, dynamic>();
    var migrated = false;
    if (await _openSecretVars(globals, 'global')) migrated = true;
    if (await _openAuthIn(globals, 'global')) migrated = true;
    return migrated;
  }

  Future<bool> _openEnvironments(Object? raw) async {
    if (raw is! List) return false;
    var migrated = false;
    for (final item in raw) {
      if (item is! Map) continue;
      final env = item.cast<String, dynamic>();
      final envId = env['id']?.toString() ?? '';
      if (await _openSecretVars(env, 'env:$envId')) migrated = true;
    }
    return migrated;
  }

  Future<bool> _openCollections(Object? raw) async {
    if (raw is! List) return false;
    var migrated = false;
    for (final item in raw) {
      if (item is! Map) continue;
      final col = item.cast<String, dynamic>();
      final colId = col['id']?.toString() ?? '';
      if (await _openSecretVars(col, 'col:$colId')) migrated = true;
      if (await _openAuthIn(col, 'col:$colId')) migrated = true;
      final requests = col['requests'];
      if (requests is! List) continue;
      for (final requestItem in requests) {
        if (requestItem is! Map) continue;
        final request = requestItem.cast<String, dynamic>();
        if (await _openAuthIn(request, 'col:$colId:req:${request['id']}')) {
          migrated = true;
        }
      }
    }
    return migrated;
  }

  Future<bool> _openHistory(Object? raw) async {
    if (raw is! List) return false;
    var migrated = false;
    for (final item in raw) {
      if (item is! Map) continue;
      final entry = item.cast<String, dynamic>();
      final request = entry['request'];
      if (request is! Map) continue;
      if (await _openAuthIn(
        request.cast<String, dynamic>(),
        'hist:${entry['id']}',
      )) {
        migrated = true;
      }
    }
    return migrated;
  }

  /// 打开一个容器的 `vars` 中的 `secretVars` 值：引用 → 明文；旧明文 → 迁移。
  Future<bool> _openSecretVars(
    Map<String, dynamic> holder,
    String scope,
  ) async {
    final secretVars = holder['secretVars'];
    final vars = holder['vars'];
    if (secretVars is! List || vars is! Map) return false;
    var migrated = false;
    for (final name in secretVars) {
      final key = name.toString();
      final value = vars[key];
      if (DebugSecretReference.isReference(value)) {
        vars[key] = await _resolve(value as String) ?? '';
      } else if (value is String && value.isNotEmpty) {
        // 旧明文：写入安全存储并标记迁移（保留明文供本次读取）。
        await _store('$scope:var:$key', value);
        migrated = true;
      }
    }
    return migrated;
  }

  /// 打开一个容器 / 请求的 `auth` 密钥字段：引用 → 明文；旧明文 → 迁移。
  Future<bool> _openAuthIn(
    Map<String, dynamic> holder,
    String scope,
  ) async {
    final auth = holder['auth'];
    if (auth is! Map) return false;
    var migrated = false;
    for (final field in _secretAuthFields) {
      final value = auth[field];
      if (DebugSecretReference.isReference(value)) {
        auth[field] = await _resolve(value as String) ?? '';
      } else if (value is String && value.isNotEmpty) {
        await _store('$scope:auth:$field', value);
        migrated = true;
      }
    }
    return migrated;
  }

  Future<void> _store(String key, String value) async {
    try {
      await storage.write(key, value);
    } catch (_) {
      // 写入失败不阻断保存 / 加载（引用写入后读取会得到空值而非崩溃）。
    }
  }

  Future<String?> _resolve(String reference) async {
    final key = DebugSecretReference.keyOf(reference);
    if (key == null) return null;
    try {
      return await storage.read(key);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _deepCopy(Map<String, dynamic> root) =>
      (jsonDecode(jsonEncode(root)) as Map).cast<String, dynamic>();
}

// ==================== 脱敏 ====================

/// 脱敏 [auth] 中的密钥字段；非密钥字段（type / username / apiKeyName /
/// apiKeyIn）保留。`none` 或密钥字段为 `null` 时原样返回。
DebugAuth redactAuth(DebugAuth auth) {
  switch (auth.type) {
    case DebugAuthType.basic:
      return auth.password == null
          ? auth
          : auth.copyWith(password: debugSecretMask);
    case DebugAuthType.bearer:
      return auth.token == null ? auth : auth.copyWith(token: debugSecretMask);
    case DebugAuthType.apiKey:
      return auth.apiKeyValue == null
          ? auth
          : auth.copyWith(apiKeyValue: debugSecretMask);
    case DebugAuthType.none:
      return auth;
  }
}

/// 返回 [request] 的脱敏副本（用于 cURL / 导出）。
///
/// 非密钥字段（URL / 头 / 查询 / body）**原样保留**，仅 auth 密钥替换为
/// [debugSecretMask]。无 auth 时原样返回。
DebugRequest redactRequest(DebugRequest request) {
  final auth = request.auth;
  return auth == null ? request : request.copyWith(auth: redactAuth(auth));
}

/// 返回 [env] 的脱敏副本：`secretVars` 标记的变量值替换为 [debugSecretMask]，
/// 其余变量原样保留（用于环境导出）。
DebugEnvironment redactEnvironment(DebugEnvironment env) => DebugEnvironment(
      id: env.id,
      name: env.name,
      vars: <String, String>{
        for (final entry in env.vars.entries)
          entry.key: env.secretVars.contains(entry.key)
              ? debugSecretMask
              : entry.value,
      },
      secretVars: env.secretVars,
    );

/// 返回 [collection] 的脱敏副本：集合级密钥变量值与集合级鉴权密钥替换为
/// [debugSecretMask]；请求列表**原样保留**（逐请求脱敏由调用方按需处理）。
DebugCollection redactCollection(DebugCollection collection) =>
    DebugCollection(
      id: collection.id,
      name: collection.name,
      parentId: collection.parentId,
      requests: collection.requests,
      vars: <String, String>{
        for (final entry in collection.vars.entries)
          entry.key: collection.secretVars.contains(entry.key)
              ? debugSecretMask
              : entry.value,
      },
      secretVars: collection.secretVars,
      auth: collection.auth == null ? null : redactAuth(collection.auth!),
    );

/// 历史条目的导出 JSON（请求中的 auth 密钥已脱敏）。
///
/// [DebugHistoryEntry.toJson] 每次返回新映射，直接在其中脱敏不污染内存模型。
Map<String, dynamic> redactedHistoryEntryJson(DebugHistoryEntry entry) {
  final json = entry.toJson();
  final request = json['request'];
  if (request is Map) _redactRequestJson(request);
  return json;
}

/// 请求模型 JSON 的脱敏副本。
Map<String, dynamic> redactedRequestJson(DebugRequest request) =>
    redactRequest(request).toJson();

void _redactRequestJson(Map<dynamic, dynamic> request) {
  final auth = request['auth'];
  if (auth is! Map) return;
  for (final field in _secretAuthFields) {
    final value = auth[field];
    if (value is String && value.isNotEmpty) {
      auth[field] = debugSecretMask;
    }
  }
}

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:gstore/core/request_debug/request_debug.dart';

/// Agent-facing CRUD over the app's Request Debug library.
///
/// This is intentionally storage-only: replaying a saved request is still the
/// `httpRequest` tool's job, while this tool keeps discovered APIs organised in
/// the same collections the Request Debug page shows.
class RequestDebugToolService {
  RequestDebugToolService({RequestDebugFacade? facade})
      : _facadeOverride = facade;

  static RequestDebugToolService instance = RequestDebugToolService();

  @visibleForTesting
  static void debugSetInstance(RequestDebugToolService? service) {
    instance = service ?? RequestDebugToolService();
  }

  static const String _defaultCollection = 'AI 收藏';
  static const int _maxBodyPreview = 8000;

  final RequestDebugFacade? _facadeOverride;

  RequestDebugFacade get _facade =>
      _facadeOverride ?? RequestDebugShared.instance;

  Future<String> handle(Map<String, dynamic> params) async {
    final action = params['action']?.toString().trim() ?? '';
    try {
      await _ensureLoaded();
      switch (action) {
        case 'list':
          return _list(params);
        case 'get':
          return _get(params);
        case 'save':
          return await _save(params);
        case 'delete':
          return await _delete(params);
        default:
          return '未知 action：$action（支持 list/get/save/delete）';
      }
    } on FormatException catch (error) {
      return '请求调试参数错误：${error.message}';
    } catch (error) {
      return '请求调试失败：$error';
    }
  }

  Future<void> _ensureLoaded() async {
    final facade = _facade;
    if (!facade.store.loaded) {
      await facade.store.load();
    }
  }

  String _list(Map<String, dynamic> params) {
    final store = _facade.store;
    final limit = _int(params['limit'], 50, 1, 200);
    final filter = params['collection']?.toString().trim().toLowerCase() ?? '';
    final collections = <DebugCollection>[
      for (final collection in store.collections)
        if (filter.isEmpty ||
            collection.id.toLowerCase() == filter ||
            collection.name.toLowerCase() == filter)
          collection,
    ];
    if (collections.isEmpty) {
      return filter.isEmpty
          ? '[请求调试] 库为空。用 save 保存第一个接口。'
          : '[请求调试] 没有匹配的集合：${params['collection']}';
    }

    var total = 0;
    for (final collection in collections) {
      total += collection.requests.length;
    }
    final buf = StringBuffer()
      ..writeln('[请求调试] ${collections.length} 个集合，$total 个接口');
    var shown = 0;
    for (final collection in collections) {
      buf.writeln('- ${collection.name} (${collection.id})：'
          '${collection.requests.length} 个');
      for (final request in collection.requests) {
        if (shown >= limit) break;
        final label = request.displayName;
        final suffix =
            request.hasCustomName ? ' — ${_clip(request.url, 300)}' : '';
        buf.writeln(
          '  • ${request.id} ${request.method} ${_clip(label, 300)}$suffix',
        );
        shown++;
      }
      if (shown >= limit) break;
    }
    if (total > shown) {
      buf.writeln('…（还有 ${total - shown} 个，可用 collection/limit 收窄）');
    }
    return buf.toString().trimRight();
  }

  String _get(Map<String, dynamic> params) {
    final id = params['requestId']?.toString().trim() ?? '';
    if (id.isEmpty) return 'get 需要 requestId';
    final store = _facade.store;
    final request = store.requestById(id);
    if (request == null) return '未找到接口：$id';
    final collection = request.collectionId == null
        ? null
        : store.collectionById(request.collectionId!);
    final includeSecrets = params['includeSecrets'] == true;

    final buf = StringBuffer()
      ..writeln('[请求调试] ${request.displayName} (${request.id})')
      ..writeln('集合：${collection?.name ?? '未分组'}')
      ..writeln('${request.method} ${request.url}');
    if (request.headers.isNotEmpty) {
      buf.writeln('Headers：');
      for (final header in request.headers) {
        final value = _shouldMaskHeader(header.name) && !includeSecrets
            ? '***'
            : header.value;
        buf.writeln('  ${header.name}: $value'
            '${header.enabled ? '' : '（未启用）'}');
      }
    }
    if (request.query.isNotEmpty) {
      buf.writeln('Query：');
      for (final query in request.query) {
        buf.writeln('  ${query.name}=${query.value}'
            '${query.enabled ? '' : '（未启用）'}');
      }
    }
    if (request.auth != null && request.auth!.type != DebugAuthType.none) {
      buf.writeln('Auth：${request.auth!.type.wire}');
      if (!includeSecrets) {
        buf.writeln('  凭证已脱敏（includeSecrets=true 可显示）');
      } else {
        final auth = request.auth!;
        if (auth.username != null) buf.writeln('  username: ${auth.username}');
        if (auth.password != null) buf.writeln('  password: ${auth.password}');
        if (auth.token != null) buf.writeln('  token: ${auth.token}');
        if (auth.apiKeyName != null) {
          buf.writeln('  apiKeyName: ${auth.apiKeyName}');
        }
        if (auth.apiKeyValue != null) {
          buf.writeln('  apiKeyValue: ${auth.apiKeyValue}');
        }
      }
    }
    if (request.body.isNotEmpty) {
      buf.writeln('Body（${request.bodyKind.wire}）：');
      buf.writeln(_clip(request.body, _maxBodyPreview));
    }
    return buf.toString().trimRight();
  }

  Future<String> _save(Map<String, dynamic> params) async {
    final store = _facade.store;
    final requestId = params['requestId']?.toString().trim() ?? '';
    final existing = requestId.isEmpty ? null : store.requestById(requestId);
    if (requestId.isNotEmpty && existing == null) {
      return '未找到要更新的接口：$requestId';
    }

    final collectionKey = params['collection']?.toString().trim() ?? '';
    DebugCollection? collection;
    if (collectionKey.isNotEmpty) {
      collection = _findCollection(store, collectionKey) ??
          store.addCollection(name: collectionKey);
    } else if (existing?.collectionId != null) {
      collection = store.collectionById(existing!.collectionId!);
    }
    collection ??= _findCollection(store, _defaultCollection) ??
        store.addCollection(name: _defaultCollection);

    final method = (params['method']?.toString().trim().isNotEmpty ?? false)
        ? params['method'].toString().trim().toUpperCase()
        : (existing?.method ?? 'GET');
    final url = (params['url']?.toString().trim().isNotEmpty ?? false)
        ? params['url'].toString().trim()
        : (existing?.url ?? '');
    if (url.isEmpty) return 'save 需要 url';
    // name 是可选“名称 / 描述”：显式传入空串表示清除名称；
    // 不传则保留更新前的名称（新建时为空，列表回退显示 URL）。
    final name = params.containsKey('name')
        ? (params['name']?.toString().trim() ?? '')
        : (existing?.name ?? '');
    final body = params.containsKey('body')
        ? _bodyText(params['body'])
        : (existing?.body ?? '');
    final bodyKind = _bodyKind(
      params['bodyKind']?.toString(),
      body,
      existing?.bodyKind,
    );
    final headers = params.containsKey('headers')
        ? _parseHeaders(params['headers'])
        : (existing?.headers ?? const <DebugHeader>[]);
    final query = params.containsKey('query')
        ? _parseQuery(params['query'])
        : (existing?.query ?? const <DebugQueryParam>[]);
    final auth = params.containsKey('auth')
        ? _parseAuth(params['auth'])
        : existing?.auth;

    final DebugRequest request;
    if (existing == null) {
      request = DebugRequest(
        id: generateDebugId('req'),
        name: name,
        method: method,
        url: url,
        headers: headers,
        query: query,
        body: body,
        bodyKind: bodyKind,
        auth: auth,
        collectionId: collection.id,
      );
      final added = store.addRequest(collection.id, request);
      if (added == null) return '保存失败：集合不存在';
    } else {
      request = existing.copyWith(
        name: name,
        method: method,
        url: url,
        headers: headers,
        query: query,
        body: body,
        bodyKind: bodyKind,
        auth: auth,
        collectionId: collection.id,
      );
      final moved = existing.collectionId != collection.id;
      if (moved) {
        store.removeRequest(existing.id);
        store.addRequest(collection.id, request);
      } else {
        store.updateRequest(request);
      }
    }

    final saved = await _facade.save();
    if (!saved) {
      return '已更新内存，但写入磁盘失败（请求调试库可能已满）';
    }
    return '已保存接口：${request.displayName}\n'
        '${request.method} ${request.url}\n'
        '集合：${collection.name}\n'
        'id：${request.id}';
  }

  Future<String> _delete(Map<String, dynamic> params) async {
    final id = params['requestId']?.toString().trim() ?? '';
    if (id.isEmpty) return 'delete 需要 requestId';
    final store = _facade.store;
    final request = store.requestById(id);
    if (request == null) return '未找到接口：$id';
    store.removeRequest(id);
    final saved = await _facade.save();
    return saved
        ? '已删除接口：${request.displayName} (${request.id})'
        : '已从内存删除，但写入磁盘失败';
  }

  static DebugCollection? _findCollection(RequestDebugStore store, String key) {
    final needle = key.toLowerCase();
    for (final collection in store.collections) {
      if (collection.id.toLowerCase() == needle ||
          collection.name.toLowerCase() == needle) {
        return collection;
      }
    }
    return null;
  }

  static List<DebugHeader> _parseHeaders(Object? raw) {
    var value = _decodeJsonIfString(raw);
    if (value is String) {
      final headers = <DebugHeader>[];
      for (final line in value.split('\n')) {
        final text = line.trim();
        if (text.isEmpty || text.startsWith('#')) continue;
        final index = text.indexOf(':');
        if (index <= 0) {
          throw const FormatException('Headers 行格式应为 Name: value');
        }
        headers.add(DebugHeader(
          name: text.substring(0, index).trim(),
          value: text.substring(index + 1).trim(),
        ));
      }
      return headers;
    }
    if (value is Map) {
      return [
        for (final entry in value.entries)
          if (entry.value != null)
            DebugHeader(
              name: entry.key.toString(),
              value: entry.value.toString(),
            ),
      ];
    }
    if (value is List) {
      final headers = <DebugHeader>[];
      for (final item in value) {
        if (item is Map) {
          headers.add(DebugHeader(
            name: item['name']?.toString() ?? '',
            value: item['value']?.toString() ?? '',
            enabled: item['enabled'] != false,
          ));
        }
      }
      return headers;
    }
    return const <DebugHeader>[];
  }

  static List<DebugQueryParam> _parseQuery(Object? raw) {
    final value = _decodeJsonIfString(raw);
    if (value is Map) {
      return [
        for (final entry in value.entries)
          if (entry.value != null)
            DebugQueryParam(
              name: entry.key.toString(),
              value: entry.value.toString(),
            ),
      ];
    }
    if (value is List) {
      final query = <DebugQueryParam>[];
      for (final item in value) {
        if (item is Map) {
          query.add(DebugQueryParam(
            name: item['name']?.toString() ?? '',
            value: item['value']?.toString() ?? '',
            enabled: item['enabled'] != false,
          ));
        }
      }
      return query;
    }
    if (value is String && value.trim().isNotEmpty) {
      final query = <DebugQueryParam>[];
      for (final pair in value.split('&')) {
        if (pair.isEmpty) continue;
        final index = pair.indexOf('=');
        query.add(DebugQueryParam(
          name: index < 0 ? pair : pair.substring(0, index),
          value: index < 0 ? '' : pair.substring(index + 1),
        ));
      }
      return query;
    }
    return const <DebugQueryParam>[];
  }

  static DebugAuth? _parseAuth(Object? raw) {
    final value = _decodeJsonIfString(raw);
    if (value is Map) {
      return DebugAuth.fromJson(
        value.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    return null;
  }

  static Object? _decodeJsonIfString(Object? raw) {
    if (raw is! String) return raw;
    final text = raw.trim();
    if (!text.startsWith('{') && !text.startsWith('[')) return raw;
    try {
      return jsonDecode(text);
    } catch (_) {
      return raw;
    }
  }

  static String _bodyText(Object? raw) {
    if (raw == null) return '';
    if (raw is String) return raw;
    try {
      return jsonEncode(raw);
    } catch (_) {
      return raw.toString();
    }
  }

  static DebugBodyKind _bodyKind(
    String? raw,
    String body,
    DebugBodyKind? fallback,
  ) {
    if (raw != null && raw.trim().isNotEmpty) {
      return DebugBodyKind.fromWire(raw.trim());
    }
    if (body.isEmpty) return fallback ?? DebugBodyKind.none;
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return DebugBodyKind.json;
    }
    return DebugBodyKind.text;
  }

  static bool _shouldMaskHeader(String name) {
    const sensitive = {
      'authorization',
      'cookie',
      'set-cookie',
      'proxy-authorization',
      'x-api-key',
      'x-auth-token',
      'api-key',
      'token',
    };
    return sensitive.contains(name.toLowerCase());
  }

  static int _int(Object? raw, int fallback, int min, int max) {
    final parsed = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
    if (parsed == null) return fallback;
    return parsed.clamp(min, max);
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…<截断>';
}

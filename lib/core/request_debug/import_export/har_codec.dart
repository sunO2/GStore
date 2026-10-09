/// 「请求调试」HAR 1.2 编解码（plan todo 16）。
///
/// **纯函数**：`List<DebugCollection>` ⇄ HAR 1.2 JSON 文本。为标准探测节点
/// （`log.entries[].request`）填入 method / url / headers / queryString /
/// postData；同时在 `log._gstoreCollections` 与 `entry._gstore` 里写入无损
/// 往返扩展（HAR 允许 `_` 前缀私有字段），使集合树 / 禁用头 / bodyKind 等
/// 完整还原。无扩展的**外部 HAR** 也能按标准字段导入为一个集合。
library;

import 'dart:convert';

import 'package:gstore/core/request_debug/debug_models.dart';

import 'codec_utils.dart';
import 'import_export_types.dart';

/// 集合列表 → HAR 1.2 JSON 文本。
String encodeHar(List<DebugCollection> collections) {
  final entries = <Map<String, dynamic>>[];
  for (final collection in collections) {
    for (final request in collection.requests) {
      entries.add(_entry(request, collection.id));
    }
  }
  final document = <String, dynamic>{
    'log': <String, dynamic>{
      'version': '1.2',
      'creator': <String, dynamic>{
        'name': 'GStore Request Debug',
        'version': '1.0',
      },
      'entries': entries,
      '_gstoreCollections': <Map<String, dynamic>>[
        for (final c in collections)
          <String, dynamic>{
            'id': c.id,
            'name': c.name,
            if (c.parentId != null) 'parentId': c.parentId,
          },
      ],
    },
  };
  return const JsonEncoder.withIndent('  ').convert(document);
}

Map<String, dynamic> _entry(DebugRequest request, String collectionId) {
  final fullUrl = debugFullUrl(request.url, request.query);
  final postData = _postData(request);
  return <String, dynamic>{
    'startedDateTime': DateTime.now().toUtc().toIso8601String(),
    'time': 0,
    'request': <String, dynamic>{
      'method': request.method,
      'url': fullUrl,
      'httpVersion': 'HTTP/1.1',
      'cookies': <Map<String, dynamic>>[
        for (final c in request.cookies)
          <String, dynamic>{
            'name': c.name,
            'value': c.value,
            if (c.domain != null) 'domain': c.domain,
            if (c.path != null) 'path': c.path,
          },
      ],
      'headers': <Map<String, dynamic>>[
        for (final h in request.headers)
          <String, dynamic>{'name': h.name, 'value': h.value},
      ],
      'queryString': <Map<String, dynamic>>[
        for (final q in request.query)
          <String, dynamic>{'name': q.name, 'value': q.value},
      ],
      if (postData != null) 'postData': postData,
      'headersSize': -1,
      'bodySize': request.body.isEmpty ? 0 : utf8.encode(request.body).length,
    },
    'response': <String, dynamic>{
      'status': 0,
      'statusText': '',
      'httpVersion': 'HTTP/1.1',
      'cookies': <Map<String, dynamic>>[],
      'headers': <Map<String, dynamic>>[],
      'content': <String, dynamic>{'size': 0, 'mimeType': ''},
      'redirectURL': '',
      'headersSize': -1,
      'bodySize': -1,
    },
    'cache': <String, dynamic>{},
    'timings': <String, dynamic>{'send': 0, 'wait': 0, 'receive': 0},
    '_gstore': <String, dynamic>{
      'collectionId': collectionId,
      'request': request.toJson(),
    },
  };
}

Map<String, dynamic>? _postData(DebugRequest request) {
  if (request.bodyKind == DebugBodyKind.none &&
      request.body.isEmpty &&
      request.multipartFields.isEmpty) {
    return null;
  }
  return <String, dynamic>{
    'mimeType': debugMimeOf(request.bodyKind),
    if (request.body.isNotEmpty) 'text': request.body,
  };
}

/// HAR 1.2 JSON 文本 → 集合列表（非法 / 截断 → 结构化失败）。
DebugTransferResult<List<DebugCollection>> decodeHar(String text) {
  if (text.trim().isEmpty) {
    return const DebugTransferResult.failure(
      DebugTransferError(DebugTransferErrorKind.empty, 'HAR 内容为空'),
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    return DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidJson,
        'HAR JSON 解析失败：${e.message}',
      ),
    );
  }
  if (decoded is! Map) {
    return const DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidStructure,
        'HAR 根节点必须是对象',
      ),
    );
  }
  final root = decoded.cast<String, dynamic>();
  final log = root['log'];
  if (log is! Map) {
    return const DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidStructure,
        'HAR 缺少 log 节点',
      ),
    );
  }
  final logMap = log.cast<String, dynamic>();
  final entries = logMap['entries'];
  if (entries is! List) {
    return const DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidStructure,
        'HAR 缺少 log.entries 数组',
      ),
    );
  }

  final byId = <String, DebugCollection>{};
  final order = <String>[];

  final defs = logMap['_gstoreCollections'];
  if (defs is List) {
    for (final def in defs) {
      if (def is! Map) continue;
      final map = def.cast<String, dynamic>();
      final id = debugStr(map['id']);
      if (id.isEmpty) continue;
      byId[id] = DebugCollection(
        id: id,
        name: debugStr(map['name']),
        parentId: debugStrOrNull(map['parentId']),
      );
      order.add(id);
    }
  }

  for (final entry in entries) {
    if (entry is! Map) continue;
    final entryMap = entry.cast<String, dynamic>();
    final g = entryMap['_gstore'];
    DebugRequest? request;
    String? collectionId;
    if (g is Map) {
      final gm = g.cast<String, dynamic>();
      collectionId = debugStrOrNull(gm['collectionId']);
      final raw = gm['request'];
      if (raw is Map) {
        request = _tryParseRequest(raw.cast<String, dynamic>());
      }
    }
    if (request == null) {
      final raw = entryMap['request'];
      if (raw is! Map) continue;
      request = _requestFromHar(raw.cast<String, dynamic>());
      collectionId ??= debugStrOrNull(entryMap['_gstoreCollectionId']);
    }

    final id = (collectionId == null || collectionId.isEmpty)
        ? '__default__'
        : collectionId;
    final collection = byId.putIfAbsent(id, () {
      order.add(id);
      return DebugCollection(id: id, name: '导入');
    });
    collection.requests.add(request);
  }

  return DebugTransferResult.success(
    <DebugCollection>[for (final id in order) byId[id]!],
  );
}

DebugRequest? _tryParseRequest(Map<String, dynamic> json) {
  try {
    return DebugRequest.fromJson(json);
  } catch (_) {
    return null;
  }
}

DebugRequest _requestFromHar(Map<String, dynamic> request) {
  final split = debugSplitUrl(debugStr(request['url']));
  final postData = request['postData'];
  final body = postData is Map ? debugStr(postData['text']) : '';
  final mime = postData is Map ? debugStr(postData['mimeType']) : null;
  return DebugRequest(
    id: generateDebugId('req'),
    name: '',
    method: debugStr(request['method'], fallback: 'GET'),
    url: split.url,
    query: split.query,
    headers: _headers(request['headers']),
    cookies: _cookies(request['cookies']),
    body: body,
    bodyKind: debugBodyKindFromMime(mime),
  );
}

List<DebugHeader> _headers(Object? value) {
  if (value is! List) return <DebugHeader>[];
  return <DebugHeader>[
    for (final item in value)
      if (item is Map)
        DebugHeader(
          name: debugStr(item['name']),
          value: debugStr(item['value']),
        ),
  ];
}

List<DebugCookie> _cookies(Object? value) {
  if (value is! List) return <DebugCookie>[];
  return <DebugCookie>[
    for (final item in value)
      if (item is Map)
        DebugCookie(
          name: debugStr(item['name']),
          value: debugStr(item['value']),
          domain: debugStrOrNull(item['domain']),
          path: debugStrOrNull(item['path']),
        ),
  ];
}

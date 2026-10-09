/// 「请求调试」Postman Collection v2.1 编解码（plan todo 16）。
///
/// **纯函数**：`List<DebugCollection>` ⇄ Postman v2.1 JSON 文本。集合 / 子文件夹
/// 映射为嵌套 `item`；请求映射为标准 `request`（method / header / url / body）。
/// 每个请求附带 `x-gstore-request` 无损扩展，使禁用头 / bodyKind / 认证等完整
/// 还原；无扩展的外部 Postman 集合也能按标准字段导入。
library;

import 'dart:convert';

import 'package:gstore/core/request_debug/debug_models.dart';

import 'codec_utils.dart';
import 'import_export_types.dart';

/// 集合列表 → Postman v2.1 JSON 文本。
String encodePostman(List<DebugCollection> collections) {
  final roots = collections.where((c) => c.parentId == null).toList();
  final document = <String, dynamic>{
    'info': <String, dynamic>{
      'name': 'GStore Request Debug',
      'schema':
          'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
    },
    'item': <Map<String, dynamic>>[
      for (final c in roots) _folderItem(c, collections),
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(document);
}

Map<String, dynamic> _folderItem(
  DebugCollection collection,
  List<DebugCollection> all,
) {
  final children = all.where((c) => c.parentId == collection.id).toList();
  return <String, dynamic>{
    'name': collection.name,
    'x-gstore-id': collection.id,
    if (collection.parentId != null) 'x-gstore-parent': collection.parentId,
    'item': <Map<String, dynamic>>[
      for (final r in collection.requests) _requestItem(r),
      for (final child in children) _folderItem(child, all),
    ],
  };
}

Map<String, dynamic> _requestItem(DebugRequest request) {
  return <String, dynamic>{
    'name': request.name.isEmpty ? request.url : request.name,
    'x-gstore-id': request.id,
    'x-gstore-request': request.toJson(),
    'request': <String, dynamic>{
      'method': request.method,
      'header': <Map<String, dynamic>>[
        for (final h in request.headers)
          <String, dynamic>{
            'key': h.name,
            'value': h.value,
            if (!h.enabled) 'disabled': true,
          },
      ],
      'url': <String, dynamic>{
        'raw': debugFullUrl(request.url, request.query),
        'query': <Map<String, dynamic>>[
          for (final q in request.query)
            <String, dynamic>{
              'key': q.name,
              'value': q.value,
              if (!q.enabled) 'disabled': true,
            },
        ],
      },
      if (_body(request) != null) 'body': _body(request),
    },
  };
}

Map<String, dynamic>? _body(DebugRequest request) {
  switch (request.bodyKind) {
    case DebugBodyKind.none:
      if (request.body.isEmpty && request.multipartFields.isEmpty) return null;
      return <String, dynamic>{'mode': 'raw', 'raw': request.body};
    case DebugBodyKind.json:
      return <String, dynamic>{
        'mode': 'raw',
        'raw': request.body,
        'options': <String, dynamic>{
          'raw': <String, dynamic>{'language': 'json'},
        },
      };
    case DebugBodyKind.text:
      return <String, dynamic>{'mode': 'raw', 'raw': request.body};
    case DebugBodyKind.formUrlEncoded:
      return <String, dynamic>{
        'mode': 'urlencoded',
        'urlencoded': <Map<String, dynamic>>[
          for (final pair in debugParseFormPairs(request.body))
            <String, dynamic>{'key': pair.key, 'value': pair.value},
        ],
      };
    case DebugBodyKind.multipart:
      return <String, dynamic>{
        'mode': 'formdata',
        'formdata': <Map<String, dynamic>>[
          for (final f in request.multipartFields)
            <String, dynamic>{
              if (f.isFile) 'type': 'file' else 'type': 'text',
              'key': f.name,
              if (!f.isFile) 'value': f.value,
              if (f.isFile) 'src': f.filePath,
              if (!f.enabled) 'disabled': true,
            },
        ],
      };
    case DebugBodyKind.binary:
      return <String, dynamic>{
        'mode': 'file',
        'file': <String, dynamic>{'src': request.binaryFilePath ?? ''},
      };
  }
}

/// Postman v2.1 JSON 文本 → 集合列表（非法 / 截断 → 结构化失败）。
DebugTransferResult<List<DebugCollection>> decodePostman(String text) {
  if (text.trim().isEmpty) {
    return const DebugTransferResult.failure(
      DebugTransferError(DebugTransferErrorKind.empty, 'Postman 内容为空'),
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    return DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidJson,
        'Postman JSON 解析失败：${e.message}',
      ),
    );
  }
  if (decoded is! Map) {
    return const DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidStructure,
        'Postman 根节点必须是对象',
      ),
    );
  }
  final root = decoded.cast<String, dynamic>();
  final items = root['item'];
  if (items is! List) {
    return const DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidStructure,
        'Postman 缺少 item 数组',
      ),
    );
  }

  final out = <DebugCollection>[];
  DebugCollection? rootSink;

  void walk(List<dynamic> list, DebugCollection? parent) {
    for (final raw in list) {
      if (raw is! Map) continue;
      final item = raw.cast<String, dynamic>();
      if (item['request'] is Map) {
        final request = _requestFromPostman(item);
        final sink = parent ?? (rootSink ??= _rootCollection(out));
        sink.requests.add(request);
      } else if (item['item'] is List) {
        final id = debugStrOrNull(item['x-gstore-id']) ??
            generateDebugId('col');
        final collection = DebugCollection(
          id: id,
          name: debugStr(item['name']),
          parentId: parent?.id,
        );
        out.add(collection);
        walk(item['item'] as List, collection);
      }
    }
  }

  walk(items, null);
  return DebugTransferResult.success(out);
}

DebugCollection _rootCollection(List<DebugCollection> out) {
  final collection = DebugCollection(id: generateDebugId('col'), name: '导入');
  out.add(collection);
  return collection;
}

DebugRequest _requestFromPostman(Map<String, dynamic> item) {
  final extension = item['x-gstore-request'];
  if (extension is Map) {
    final parsed = _tryParseRequest(extension.cast<String, dynamic>());
    if (parsed != null) return parsed;
  }
  final request = item['request'];
  final map = request is Map ? request.cast<String, dynamic>() : <String, dynamic>{};

  final urlField = map['url'];
  String rawUrl = '';
  List<DebugQueryParam> query = const <DebugQueryParam>[];
  if (urlField is Map) {
    final um = urlField.cast<String, dynamic>();
    rawUrl = debugStr(um['raw']);
    query = _queries(um['query']);
  } else {
    rawUrl = debugStr(urlField);
  }
  final split = debugSplitUrl(rawUrl);
  if (query.isEmpty) query = split.query;

  final headers = _headers(map['header']);
  final body = map['body'];
  final parsedBody = _bodyFromPostman(body, headers);
  return DebugRequest(
    id: debugStrOrNull(item['x-gstore-id']) ?? generateDebugId('req'),
    name: debugStr(item['name']),
    method: debugStr(map['method'], fallback: 'GET'),
    url: split.url,
    query: query,
    headers: headers,
    body: parsedBody.body,
    bodyKind: parsedBody.kind,
    multipartFields: parsedBody.multipart,
  );
}

({String body, DebugBodyKind kind, List<DebugMultipartField> multipart})
    _bodyFromPostman(Object? value, List<DebugHeader> headers) {
  if (value is! Map) {
    return (body: '', kind: DebugBodyKind.none, multipart: const []);
  }
  final map = value.cast<String, dynamic>();
  switch (debugStr(map['mode'])) {
    case 'raw':
      final text = debugStr(map['raw']);
      final options = map['options'];
      var kind = DebugBodyKind.text;
      if (options is Map && options['raw'] is Map) {
        if (debugStr((options['raw'] as Map)['language']) == 'json') {
          kind = DebugBodyKind.json;
        }
      }
      if (kind != DebugBodyKind.json) {
        kind = debugBodyKindFromMime(debugHeaderValue(headers, 'content-type'));
        if (kind == DebugBodyKind.none) kind = DebugBodyKind.text;
      }
      return (body: text, kind: kind, multipart: const []);
    case 'urlencoded':
      final pairs = debugParseFormPairs(
        (map['urlencoded'] as List? ?? <dynamic>[])
            .whereType<Map>()
            .map((e) => '${debugStr(e['key'])}=${debugStr(e['value'])}')
            .join('&'),
      );
      return (
        body: pairs.map((p) => '${p.key}=${p.value}').join('&'),
        kind: DebugBodyKind.formUrlEncoded,
        multipart: const [],
      );
    case 'formdata':
      final fields = <DebugMultipartField>[
        for (final raw in map['formdata'] as List? ?? <dynamic>[])
          if (raw is Map)
            DebugMultipartField(
              name: debugStr(raw['key']),
              value: debugStr(raw['value']),
              filePath: debugStrOrNull(raw['src']),
              enabled: raw['disabled'] != true,
            ),
      ];
      return (body: '', kind: DebugBodyKind.multipart, multipart: fields);
    case 'file':
      return (
        body: '',
        kind: DebugBodyKind.binary,
        multipart: const [],
      );
    default:
      return (body: '', kind: DebugBodyKind.none, multipart: const []);
  }
}

DebugRequest? _tryParseRequest(Map<String, dynamic> json) {
  try {
    return DebugRequest.fromJson(json);
  } catch (_) {
    return null;
  }
}

List<DebugHeader> _headers(Object? value) {
  if (value is! List) return <DebugHeader>[];
  return <DebugHeader>[
    for (final item in value)
      if (item is Map)
        DebugHeader(
          name: debugStr(item['key']),
          value: debugStr(item['value']),
          enabled: item['disabled'] != true,
        ),
  ];
}

List<DebugQueryParam> _queries(Object? value) {
  if (value is! List) return <DebugQueryParam>[];
  return <DebugQueryParam>[
    for (final item in value)
      if (item is Map)
        DebugQueryParam(
          name: debugStr(item['key']),
          value: debugStr(item['value']),
          enabled: item['disabled'] != true,
        ),
  ];
}

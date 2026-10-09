/// 「请求调试」OpenAPI 3 编解码（plan todo 16）。
///
/// **纯函数**：`List<DebugCollection>` ⇄ OpenAPI 3 JSON 文本。**仅支持 JSON**
/// 输入，刻意不引入 YAML 依赖；需要 YAML 的用户可自行转换后再导入。
///
/// 导出为标准文档：每个请求映射为一个 `paths.<path>.<method>` 操作，含
/// `summary` / `parameters`（query / header）/ `requestBody`；并在操作里写入
/// `x-gstore-debug` 无损扩展、在根节点写入 `x-gstore-collections`，使集合树与
/// 全部字段完整往返。**外部 OpenAPI**（无扩展）按 `servers` + `paths` 重建请求。
library;

import 'dart:convert';

import 'package:gstore/core/request_debug/debug_models.dart';

import 'codec_utils.dart';
import 'import_export_types.dart';

const Set<String> _httpMethods = <String>{
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
};

/// 集合列表 → OpenAPI 3 JSON 文本。
String encodeOpenApi(List<DebugCollection> collections) {
  final paths = <String, dynamic>{};
  String? serverOrigin;
  final used = <String>{};

  for (final collection in collections) {
    for (final request in collection.requests) {
      final fullUrl = debugFullUrl(request.url, request.query);
      final uri = Uri.tryParse(fullUrl);
      final origin = (uri != null && uri.hasScheme)
          ? '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}'
          : '';
      serverOrigin ??= origin.isEmpty ? null : origin;
      final path = (uri == null || uri.path.isEmpty) ? '/' : uri.path;
      final method = request.method.toLowerCase();
      var key = path;
      var suffix = 2;
      while (used.contains('$key\u0000$method')) {
        key = '$path~$suffix';
        suffix++;
      }
      used.add('$key\u0000$method');
      (paths[key] ??= <String, dynamic>{})[method] =
          _operation(request, collection, fullUrl);
    }
  }

  final document = <String, dynamic>{
    'openapi': '3.0.3',
    'info': <String, dynamic>{
      'title': 'GStore Request Debug',
      'version': '1.0.0',
    },
    'servers': <Map<String, dynamic>>[
      <String, dynamic>{'url': serverOrigin ?? 'http://localhost'},
    ],
    'paths': paths,
    'x-gstore-collections': <Map<String, dynamic>>[
      for (final c in collections)
        <String, dynamic>{
          'id': c.id,
          'name': c.name,
          if (c.parentId != null) 'parentId': c.parentId,
        },
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(document);
}

Map<String, dynamic> _operation(
  DebugRequest request,
  DebugCollection collection,
  String fullUrl,
) {
  final parameters = <Map<String, dynamic>>[
    for (final q in request.query)
      if (q.name.isNotEmpty)
        <String, dynamic>{
          'name': q.name,
          'in': 'query',
          'required': false,
          'schema': <String, dynamic>{'type': 'string'},
        },
    for (final h in request.headers)
      if (h.name.isNotEmpty)
        <String, dynamic>{
          'name': h.name,
          'in': 'header',
          'required': false,
          'schema': <String, dynamic>{'type': 'string'},
        },
  ];
  return <String, dynamic>{
    'operationId': request.id.isEmpty
        ? generateDebugId('op')
        : 'op_${request.id.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}',
    if (request.name.isNotEmpty) 'summary': request.name,
    'tags': <String>[collection.name],
    if (parameters.isNotEmpty) 'parameters': parameters,
    if (request.bodyKind != DebugBodyKind.none || request.body.isNotEmpty)
      'requestBody': <String, dynamic>{
        'content': <String, dynamic>{
          (debugMimeOf(request.bodyKind).isEmpty
                  ? 'application/octet-stream'
                  : debugMimeOf(request.bodyKind)
              .split(';')
              .first):
              <String, dynamic>{
            if (request.body.isNotEmpty) 'example': debugTryJson(request.body),
          },
        },
      },
    'responses': <String, dynamic>{
      '200': <String, dynamic>{'description': 'OK'},
    },
    'x-gstore-debug': request.toJson(),
    'x-gstore-collection': collection.id,
    'x-gstore-url': fullUrl,
  };
}

/// OpenAPI 3 JSON 文本 → 集合列表（非法 / 截断 → 结构化失败）。
DebugTransferResult<List<DebugCollection>> decodeOpenApi(String text) {
  if (text.trim().isEmpty) {
    return const DebugTransferResult.failure(
      DebugTransferError(DebugTransferErrorKind.empty, 'OpenAPI 内容为空'),
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    return DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidJson,
        'OpenAPI JSON 解析失败：${e.message}',
      ),
    );
  }
  if (decoded is! Map) {
    return const DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidStructure,
        'OpenAPI 根节点必须是对象',
      ),
    );
  }
  final root = decoded.cast<String, dynamic>();
  final openapi = root['openapi'];
  if (openapi is! String || !openapi.startsWith('3.')) {
    return const DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidStructure,
        'OpenAPI 缺少 openapi: 3.x 字段',
      ),
    );
  }
  final paths = root['paths'];
  if (paths is! Map) {
    return const DebugTransferResult.failure(
      DebugTransferError(
        DebugTransferErrorKind.invalidStructure,
        'OpenAPI 缺少 paths 节点',
      ),
    );
  }

  final byId = <String, DebugCollection>{};
  final order = <String>[];

  final defs = root['x-gstore-collections'];
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

  final serverUrl = _serverUrl(root);

  paths.forEach((rawPath, rawItem) {
    if (rawItem is! Map) return;
    final path = rawPath.toString();
    final item = rawItem.cast<String, dynamic>();
    for (final method in _httpMethods) {
      final rawOperation = item[method];
      if (rawOperation is! Map) continue;
      final operation = rawOperation.cast<String, dynamic>();
      final request = _requestFromOperation(
        operation,
        method,
        path,
        serverUrl,
      );
      final collectionId = debugStrOrNull(operation['x-gstore-collection']);
      final id = (collectionId == null || collectionId.isEmpty)
          ? '__default__'
          : collectionId;
      final collection = byId.putIfAbsent(id, () {
        order.add(id);
        return DebugCollection(id: id, name: '导入');
      });
      collection.requests.add(request);
    }
  });

  return DebugTransferResult.success(
    <DebugCollection>[for (final id in order) byId[id]!],
  );
}

String _serverUrl(Map<String, dynamic> root) {
  final servers = root['servers'];
  if (servers is List && servers.isNotEmpty && servers.first is Map) {
    final url = debugStr((servers.first as Map)['url']);
    if (url.isNotEmpty) return url;
  }
  return '';
}

DebugRequest _requestFromOperation(
  Map<String, dynamic> operation,
  String method,
  String path,
  String serverUrl,
) {
  final extension = operation['x-gstore-debug'];
  if (extension is Map) {
    final parsed = _tryParseRequest(extension.cast<String, dynamic>());
    if (parsed != null) return parsed;
  }

  final parameters = operation['parameters'];
  final query = <DebugQueryParam>[];
  final headers = <DebugHeader>[];
  if (parameters is List) {
    for (final raw in parameters) {
      if (raw is! Map) continue;
      final name = debugStr(raw['name']);
      if (name.isEmpty) continue;
      final location = debugStr(raw['in']);
      if (location == 'query') {
        query.add(DebugQueryParam(name: name));
      } else if (location == 'header') {
        headers.add(DebugHeader(name: name));
      }
    }
  }

  final full = debugStrOrNull(operation['x-gstore-url']) ??
      '${serverUrl.trimRight().replaceAll(RegExp(r'/$'), '')}$path';
  final split = debugSplitUrl(full);
  return DebugRequest(
    id: debugStrOrNull(operation['operationId']) ??
        generateDebugId('req'),
    name: debugStr(operation['summary']),
    method: method.toUpperCase(),
    url: split.url,
    query: query.isEmpty ? split.query : query,
    headers: headers,
  );
}

DebugRequest? _tryParseRequest(Map<String, dynamic> json) {
  try {
    return DebugRequest.fromJson(json);
  } catch (_) {
    return null;
  }
}

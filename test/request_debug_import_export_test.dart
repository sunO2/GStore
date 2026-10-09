/// 「请求调试」导入 / 导出编解码（plan todo 16）测试。
///
/// 覆盖验收标准：
/// - 纯编解码：HAR 1.2 / Postman v2.1 / OpenAPI 3 / 原始 HTTP 的
///   `encode → decode → 等价` 往返；环境与改写规则导出 / 导入 JSON。
/// - 非法 / 截断文件返回**结构化错误**（`DebugTransferResult.failure`），绝不抛异常。
/// - 导出样例含关键字段（method / url / headers / body）。
///
/// 全程零 IO / 零 UI：编解码只依赖 `dart:convert` 与纯模型。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/request_debug/import_export/import_export.dart';

// ==================== 夹具 ====================

DebugRequest _sampleRequest({
  String id = 'r1',
  String name = 'Get users',
  String method = 'POST',
  String url = 'https://api.example.com/users',
}) =>
    DebugRequest(
      id: id,
      name: name,
      method: method,
      url: url,
      headers: <DebugHeader>[
        const DebugHeader(name: 'Accept', value: 'application/json'),
        const DebugHeader(name: 'X-Trace', value: 'abc', enabled: false),
      ],
      query: <DebugQueryParam>[
        const DebugQueryParam(name: 'page', value: '2'),
        const DebugQueryParam(name: 'debug', value: '1', enabled: false),
      ],
      body: '{"hello":"world"}',
      bodyKind: DebugBodyKind.json,
    );

/// 两级集合树：顶层 `Alpha`（含请求）+ 子文件夹 `Nested`（含请求）。
List<DebugCollection> _tree() => <DebugCollection>[
      DebugCollection(
        id: 'c1',
        name: 'Alpha',
        requests: <DebugRequest>[_sampleRequest()],
      ),
      DebugCollection(
        id: 'c2',
        name: 'Nested',
        parentId: 'c1',
        requests: <DebugRequest>[
          _sampleRequest(id: 'r2', name: 'Health', method: 'GET', url: 'https://api.example.com/health'),
        ],
      ),
    ];

List<DebugEnvironment> _envs() => <DebugEnvironment>[
      DebugEnvironment(id: 'e1', name: 'dev', vars: {'host': 'a', 'token': 't'}),
      DebugEnvironment(
        id: 'e2',
        name: 'prod',
        vars: {'host': 'b'},
        secretVars: <String>{'host'},
      ),
    ];

List<DebugRewriteRule> _rules() => <DebugRewriteRule>[
      const DebugRewriteRule(
        id: 'w1',
        enabled: true,
        method: 'GET',
        url: 'https://api.example.com/users',
        kind: DebugRewriteKind.replaceResponse,
        remark: 'beta',
        statusCode: 201,
        respHeaders: <DebugHeader>[
          DebugHeader(name: 'X-Mock', value: '1'),
        ],
        respBody: '{"ok":true}',
        hitCount: 3,
      ),
      const DebugRewriteRule(
        id: 'w2',
        url: 'https://api.example.com/local',
        kind: DebugRewriteKind.localResponse,
      ),
    ];

// ==================== 等价断言 ====================

/// 有效 URL：把启用的 query 并入 URL（忽略禁用项）。
String _effectiveUrl(DebugRequest r) {
  final q = r.query
      .where((p) => p.enabled && p.name.isNotEmpty)
      .map((p) => '${p.name}=${p.value}')
      .join('&');
  if (q.isEmpty) return r.url;
  return r.url.contains('?') ? '${r.url}&$q' : '${r.url}?$q';
}

List<String> _enabledHeaders(DebugRequest r) => <String>[
      for (final h in r.headers.where((h) => h.enabled && h.name.isNotEmpty))
        '${h.name}: ${h.value}',
    ];

void _expectRequestEquivalent(DebugRequest a, DebugRequest b) {
  expect(b.method.toUpperCase(), a.method.toUpperCase(), reason: 'method');
  expect(_effectiveUrl(b), _effectiveUrl(a), reason: 'url');
  expect(_enabledHeaders(b), _enabledHeaders(a), reason: 'headers');
  expect(b.body, a.body, reason: 'body');
  expect(b.bodyKind, a.bodyKind, reason: 'bodyKind');
}

void _expectTreeEquivalent(
  List<DebugCollection> a,
  List<DebugCollection> b,
) {
  expect(b.length, a.length, reason: 'collection count');
  final byId = <String, DebugCollection>{for (final c in b) c.id: c};
  for (final ca in a) {
    final cb = byId[ca.id];
    expect(cb, isNotNull, reason: 'collection ${ca.id} missing');
    expect(cb!.name, ca.name, reason: 'name ${ca.id}');
    expect(cb.parentId, ca.parentId, reason: 'parentId ${ca.id}');
    expect(cb.requests.length, ca.requests.length, reason: 'requests ${ca.id}');
    for (var i = 0; i < ca.requests.length; i++) {
      _expectRequestEquivalent(ca.requests[i], cb.requests[i]);
    }
  }
}

// ==================== 测试 ====================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==================== HAR 1.2 ====================

  group('HAR 1.2', () {
    test('集合树 round-trip 等价', () {
      final text = DebugImportExport.encodeCollections(
        DebugTransferFormat.har,
        _tree(),
      );
      final result = DebugImportExport.decodeCollections(
        DebugTransferFormat.har,
        text,
      );
      expect(result.isSuccess, isTrue, reason: '${result.error?.message}');
      _expectTreeEquivalent(_tree(), result.value!);
    });

    test('导出样例含关键字段（method/url/headers/body）', () {
      final text = DebugImportExport.encodeCollections(
        DebugTransferFormat.har,
        _tree(),
      );
      final root = jsonDecode(text) as Map<String, dynamic>;
      final log = root['log'] as Map<String, dynamic>;
      expect(log['version'], '1.2');
      final entries = log['entries'] as List<dynamic>;
      expect(entries, isNotEmpty);
      final request =
          (entries.first as Map<String, dynamic>)['request'] as Map<String, dynamic>;
      expect(request['method'], 'POST');
      expect(request['url'], contains('api.example.com/users'));
      expect(request['headers'], isA<List<dynamic>>());
      expect(
        (request['postData'] as Map<String, dynamic>)['text'],
        '{"hello":"world"}',
      );
    });
  });

  // ==================== Postman v2.1 ====================

  group('Postman v2.1', () {
    test('集合树 round-trip 等价（含嵌套文件夹）', () {
      final text = DebugImportExport.encodeCollections(
        DebugTransferFormat.postman,
        _tree(),
      );
      final result = DebugImportExport.decodeCollections(
        DebugTransferFormat.postman,
        text,
      );
      expect(result.isSuccess, isTrue, reason: '${result.error?.message}');
      _expectTreeEquivalent(_tree(), result.value!);
    });

    test('导出样例含关键字段', () {
      final text = DebugImportExport.encodeCollections(
        DebugTransferFormat.postman,
        _tree(),
      );
      final root = jsonDecode(text) as Map<String, dynamic>;
      expect(
        (root['info'] as Map<String, dynamic>)['schema'],
        contains('postman'),
      );
      final items = root['item'] as List<dynamic>;
      // 顶层文件夹 Alpha → 内含请求 + 子文件夹 Nested。
      final alpha = items.firstWhere(
        (e) => (e as Map<String, dynamic>)['name'] == 'Alpha',
      ) as Map<String, dynamic>;
      final alphaItems = alpha['item'] as List<dynamic>;
      final reqItem = alphaItems.firstWhere(
        (e) => (e as Map<String, dynamic>).containsKey('request'),
      ) as Map<String, dynamic>;
      final request = reqItem['request'] as Map<String, dynamic>;
      expect(request['method'], 'POST');
      expect((request['url'] as Map<String, dynamic>)['raw'],
          contains('api.example.com/users'));
      expect(request['header'], isA<List<dynamic>>());
      expect(
        (request['body'] as Map<String, dynamic>)['raw'],
        '{"hello":"world"}',
      );
    });
  });

  // ==================== OpenAPI 3 ====================

  group('OpenAPI 3', () {
    test('集合树 round-trip 等价', () {
      final text = DebugImportExport.encodeCollections(
        DebugTransferFormat.openapi,
        _tree(),
      );
      final result = DebugImportExport.decodeCollections(
        DebugTransferFormat.openapi,
        text,
      );
      expect(result.isSuccess, isTrue, reason: '${result.error?.message}');
      _expectTreeEquivalent(_tree(), result.value!);
    });

    test('导出样例含关键字段（paths/operation/requestBody）', () {
      final text = DebugImportExport.encodeCollections(
        DebugTransferFormat.openapi,
        _tree(),
      );
      final root = jsonDecode(text) as Map<String, dynamic>;
      expect(root['openapi'], startsWith('3.'));
      final paths = root['paths'] as Map<String, dynamic>;
      expect(paths, isNotEmpty);
      final pathKey = paths.keys.first;
      final op = (paths[pathKey] as Map<String, dynamic>)['post'] as Map<String, dynamic>;
      expect(op['requestBody'], isA<Map<String, dynamic>>());
      expect(op['x-gstore-debug'], isA<Map<String, dynamic>>());
    });

    test('外部 OpenAPI（无扩展）也能解码出请求', () {
      const external = '''
      {
        "openapi": "3.0.0",
        "info": {"title": "Sample", "version": "1.0.0"},
        "servers": [{"url": "https://api.example.com"}],
        "paths": {
          "/users": {
            "get": {
              "operationId": "listUsers",
              "summary": "List users",
              "parameters": [
                {"name": "page", "in": "query", "schema": {"type": "integer"}}
              ],
              "responses": {"200": {"description": "OK"}}
            }
          }
        }
      }''';
      final result = DebugImportExport.decodeCollections(
        DebugTransferFormat.openapi,
        external,
      );
      expect(result.isSuccess, isTrue, reason: '${result.error?.message}');
      final requests = result.value!
          .expand((c) => c.requests)
          .toList();
      expect(requests, hasLength(1));
      expect(requests.single.method.toUpperCase(), 'GET');
      expect(requests.single.url, contains('https://api.example.com/users'));
    });
  });

  // ==================== 原始 HTTP ====================

  group('原始 HTTP', () {
    test('请求列表 round-trip 等价', () {
      final requests = <DebugRequest>[
        _sampleRequest(),
        _sampleRequest(id: 'r2', name: 'Health', method: 'GET', url: 'https://api.example.com/health'),
      ];
      final text = encodeRawHttp(requests);
      final result = decodeRawHttp(text);
      expect(result.isSuccess, isTrue, reason: '${result.error?.message}');
      final out = result.value!;
      expect(out, hasLength(2));
      for (var i = 0; i < requests.length; i++) {
        _expectRequestEquivalent(requests[i], out[i]);
      }
    });

    test('导出样例含关键字段', () {
      final text = encodeRawHttp(<DebugRequest>[_sampleRequest()]);
      expect(text, contains('POST '));
      expect(text, contains('https://api.example.com/users'));
      expect(text, contains('Accept: application/json'));
      expect(text, contains('{"hello":"world"}'));
    });
  });

  // ==================== 环境 / 规则 JSON ====================

  group('环境 / 规则 JSON 导出导入', () {
    test('环境 round-trip 等价', () {
      final text = DebugImportExport.encodeEnvironmentsJson(_envs());
      final result = DebugImportExport.decodeEnvironmentsJson(text);
      expect(result.isSuccess, isTrue, reason: '${result.error?.message}');
      final out = result.value!;
      expect(out, hasLength(2));
      expect(out[0].id, 'e1');
      expect(out[0].name, 'dev');
      expect(out[0].vars, {'host': 'a', 'token': 't'});
      expect(out[1].secretVars, contains('host'));
    });

    test('改写规则 round-trip 等价', () {
      final text = DebugImportExport.encodeRulesJson(_rules());
      final result = DebugImportExport.decodeRulesJson(text);
      expect(result.isSuccess, isTrue, reason: '${result.error?.message}');
      final out = result.value!;
      expect(out, hasLength(2));
      expect(out[0].id, 'w1');
      expect(out[0].enabled, isTrue);
      expect(out[0].remark, 'beta');
      expect(out[0].statusCode, 201);
      expect(out[0].respBody, '{"ok":true}');
      expect(out[0].hitCount, 3);
      expect(out[1].kind, DebugRewriteKind.localResponse);
    });
  });

  // ==================== 结构化错误（不崩） ====================

  group('非法 / 截断文件返回结构化错误', () {
    final badJson = <String>[
      '',
      '   ',
      '{',
      '{"log": {"entries": [',
      'not json at all',
      '[]',
    ];

    for (final format in <DebugTransferFormat>[
      DebugTransferFormat.har,
      DebugTransferFormat.postman,
      DebugTransferFormat.openapi,
    ]) {
      test('${format.wire}: 空 / 截断 / 非法 JSON 返回 failure', () {
        for (final input in badJson) {
          final result =
              DebugImportExport.decodeCollections(format, input);
          expect(result.isSuccess, isFalse, reason: 'input=<$input>');
          expect(result.error, isNotNull, reason: 'input=<$input>');
          expect(result.error!.message, isNotEmpty);
        }
      });
    }

    test('原始 HTTP：空 / 无请求行返回 failure', () {
      for (final input in <String>['', '   ', 'this is not a request']) {
        final result = decodeRawHttp(input);
        expect(result.isSuccess, isFalse, reason: 'input=<$input>');
        expect(result.error, isNotNull);
      }
    });

    test('环境 / 规则：非法 JSON 返回 failure', () {
      expect(
        DebugImportExport.decodeEnvironmentsJson('{oops').isSuccess,
        isFalse,
      );
      expect(
        DebugImportExport.decodeRulesJson('{oops').isSuccess,
        isFalse,
      );
    });
  });

  // ==================== 格式识别 ====================

  group('detectFormat', () {
    test('按内容识别四种格式', () {
      expect(
        DebugImportExport.detectFormat(
          DebugImportExport.encodeCollections(DebugTransferFormat.har, _tree()),
        ),
        DebugTransferFormat.har,
      );
      expect(
        DebugImportExport.detectFormat(
          DebugImportExport.encodeCollections(
            DebugTransferFormat.postman,
            _tree(),
          ),
        ),
        DebugTransferFormat.postman,
      );
      expect(
        DebugImportExport.detectFormat(
          DebugImportExport.encodeCollections(
            DebugTransferFormat.openapi,
            _tree(),
          ),
        ),
        DebugTransferFormat.openapi,
      );
      expect(
        DebugImportExport.detectFormat(encodeRawHttp(<DebugRequest>[_sampleRequest()])),
        DebugTransferFormat.rawHttp,
      );
    });

    test('无法识别返回 null', () {
      expect(DebugImportExport.detectFormat('hello world'), isNull);
      expect(DebugImportExport.detectFormat(''), isNull);
    });
  });
}

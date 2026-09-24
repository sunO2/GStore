// Todo 35 tests：「抓包记录（CaptureDetail）→ DebugRequest」映射函数单测。
//
// 反向断言每个映射字段（method / url / headers / body / cookies / bodyKind），
// 杜绝「字段漏映射仍全绿」的误导性成功。纯函数，不触碰 FFI / 网络 / UI。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/request_debug/capture_mapping.dart';
import 'package:gstore/core/request_debug/debug_models.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';

CaptureDetail _detail({
  String method = 'POST',
  String scheme = 'https',
  String host = 'api.example.com',
  String url = 'https://api.example.com/login?x=1',
  String reqHeaders =
      'Content-Type: application/json\r\nX-Token: abc\r\nCookie: sid=xyz; theme=dark',
  List<int> reqBody = const <int>[],
  String contentType = 'application/json',
}) =>
    CaptureDetail(
      method: method,
      scheme: scheme,
      host: host,
      url: url,
      reqHeaders: reqHeaders,
      reqBody: reqBody,
      contentType: contentType,
    );

void main() {
  test('映射 method / url / headers / body / cookies（逐字段）', () {
    final request = debugRequestFromCapture(
      _detail(
        reqBody: utf8.encode('{"u":"1"}'),
      ),
    );

    // 方法大写化。
    expect(request.method, 'POST');
    // URL 原样保留（含查询串）。
    expect(request.url, 'https://api.example.com/login?x=1');

    // 头：逐条解析 `Name: value`。
    final headers = <String, String>{
      for (final h in request.headers) h.name: h.value,
    };
    expect(headers['Content-Type'], 'application/json');
    expect(headers['X-Token'], 'abc');
    expect(headers['Cookie'], 'sid=xyz; theme=dark');
    expect(request.headers.every((h) => h.enabled), isTrue);

    // Body：UTF-8 解码 + 类型推断。
    expect(request.body, '{"u":"1"}');
    expect(request.bodyKind, DebugBodyKind.json);

    // Cookies：从 `Cookie` 头解析。
    final cookies = <String, String>{
      for (final c in request.cookies) c.name: c.value,
    };
    expect(cookies, <String, String>{'sid': 'xyz', 'theme': 'dark'});

    // 标识 / 名称非空且可读。
    expect(request.id, isNotEmpty);
    expect(request.name, contains('POST'));
  });

  test('URL 为空 → 按 scheme://host+path 回退', () {
    final request = debugRequestFromCapture(
      _detail(
        method: 'get',
        url: '',
        scheme: 'http',
        host: 'plain.test',
        reqHeaders: '',
      ),
    );

    expect(request.method, 'GET', reason: '空/小写方法归一化为大写');
    expect(request.url, 'http://plain.test');
  });

  test('空 Body → bodyKind=none；form-urlencoded 推断正确', () {
    final empty = debugRequestFromCapture(
      _detail(reqHeaders: '', reqBody: const <int>[], contentType: ''),
    );
    expect(empty.body, isEmpty);
    expect(empty.bodyKind, DebugBodyKind.none);
    expect(empty.headers, isEmpty);
    expect(empty.cookies, isEmpty);

    final form = debugRequestFromCapture(
      _detail(
        reqHeaders: 'Content-Type: application/x-www-form-urlencoded',
        reqBody: utf8.encode('a=1&b=2'),
        contentType: 'application/x-www-form-urlencoded',
      ),
    );
    expect(form.bodyKind, DebugBodyKind.formUrlEncoded);
    expect(form.body, 'a=1&b=2');
  });

  test('头部续行并入上一行；无冒号行忽略', () {
    final request = debugRequestFromCapture(
      _detail(
        reqHeaders: 'X-Fold: part1\\n part2\\nnot-a-header',
        reqBody: const <int>[],
        contentType: '',
      ),
    );
    final headers = <String, String>{
      for (final h in request.headers) h.name: h.value,
    };
    expect(headers['X-Fold'], contains('part1'));
    expect(headers['X-Fold'], contains('part2'));
    expect(request.headers.any((h) => h.name == 'not-a-header'), isFalse);
  });

  test('可显式指定 id / name / collectionId', () {
    final request = debugRequestFromCapture(
      _detail(reqHeaders: ''),
      id: 'req-fixed',
      name: '我的请求',
      collectionId: 'col-1',
    );
    expect(request.id, 'req-fixed');
    expect(request.name, '我的请求');
    expect(request.collectionId, 'col-1');
  });
}

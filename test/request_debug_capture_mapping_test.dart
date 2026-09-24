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

  // ==================== 保存重发编码（R5a，反向断言） ====================
  //
  // 抓包 `reqBody` 是**已解码明文**；若重发时继续带上游 `Content-Encoding`
  // 并按压缩前长度填 `Content-Length`，请求无效。此处逐头断言最终形态。

  test('保存重发：剥离 Content-Encoding，Content-Length 修正为明文实际字节数', () {
    final request = debugRequestFromCapture(
      _detail(
        reqHeaders: 'Content-Type: application/json\r\n'
            'Content-Encoding: gzip\r\n'
            'Content-Length: 999\r\n'
            'X-Keep: yes',
        reqBody: utf8.encode('{"u":"1"}'),
      ),
    );

    final headers = <String, String>{
      for (final h in request.headers) h.name.toLowerCase(): h.value,
    };

    expect(headers.containsKey('content-encoding'), isFalse,
        reason: '明文 body 绝不能保留上游 Content-Encoding（否则被二次解压）');
    expect(headers['content-length'], '9',
        reason: 'Content-Length 必须等于实际发送明文的 UTF-8 字节数（9）');
    expect(headers['content-type'], 'application/json');
    expect(headers['x-keep'], 'yes', reason: '无关头必须原样保留');

    // 与 body 字段自洽：body 是明文，头部长度与之匹配。
    expect(utf8.encode(request.body).length, 9);
  });

  test('保存重发：identity 编码同样剥离；未提供 Content-Length 时不新增', () {
    final request = debugRequestFromCapture(
      _detail(
        reqHeaders: 'Content-Type: text/plain\r\nContent-Encoding: identity',
        reqBody: utf8.encode('hello'),
        contentType: 'text/plain',
      ),
    );

    final names = request.headers.map((h) => h.name.toLowerCase()).toSet();
    expect(names.contains('content-encoding'), isFalse,
        reason: 'identity 声明也须剥离（重发方自行处理编码）');
    expect(names.contains('content-length'), isFalse,
        reason: '抓包未提供 Content-Length 时不得凭空新增（由发送器计算即可）');
    expect(request.body, 'hello');
  });
}

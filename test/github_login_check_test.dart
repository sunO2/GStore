import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/service/github_login_check.dart';
import 'package:gstore/http/github/dio_client.dart';

/// 轻量 Dio 适配器：按测试给定响应返回，不触网。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.status, this.body, {this.headers = const {}});

  final int status;
  final String body;
  final Map<String, List<String>> headers;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        ...headers,
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dio(int status, Object body, {Map<String, List<String>> headers = const {}}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://api.github.com',
      headers: {'Accept': 'application/vnd.github+json'},
    ),
  )..httpClientAdapter = _StubAdapter(status, jsonEncode(body), headers: headers);
  return dio;
}

void main() {
  test('200：输出 Token 掩码/用户/速率限制/Rust 通道，结论正常', () async {
    final logs = <String>[];
    var channelCalls = 0;
    final dio = _dio(
      200,
      {
        'login': 'octocat',
        'id': 1,
        'type': 'User',
        'name': 'The Octocat',
        'public_repos': 8,
      },
      headers: {
        'x-oauth-scopes': ['repo, read:user'],
        'x-ratelimit-limit': ['5000'],
        'x-ratelimit-remaining': ['4999'],
        'x-ratelimit-reset': [
          '${DateTime.now().add(const Duration(minutes: 30)).millisecondsSinceEpoch ~/ 1000}',
        ],
      },
    );
    dio.options.headers['Authorization'] =
        'Bearer ghp_abcdefghijklmnopqrstuvwxyz0123456789';

    await GithubLoginCheck.run(
      (message, {bool isError = false}) => logs.add(message),
      tokenReader: () async => 'ghp_abcdefghijklmnopqrstuvwxyz0123456789',
      dio: dio,
      channelProbe: () async {
        channelCalls++;
        return (ok: true, count: 3, error: null);
      },
    );

    final text = logs.join('\n');
    expect(channelCalls, 1);
    expect(text, contains('本地 Token：存在'));
    expect(text, contains('ghp_abc…6789'), reason: 'Token 应掩码输出');
    expect(text, isNot(contains('ghp_abcdefghijklmnopqrstuvwxyz0123456789')));
    expect(text, contains('classic PAT'));
    expect(text, contains('Dio 授权头：已设置，与本地 Token 一致'));
    expect(text, contains('HTTP 状态：200'));
    expect(text, contains('Token Scopes：repo, read:user'));
    expect(text, contains('速率限制：剩余 4999/5000'));
    expect(text, contains('用户：octocat'));
    expect(text, contains('Rust 通道：正常（返回 3 条）'));
    expect(text, contains('登录状态正常'));
  });

  test('401：输出建议并抛异常（面板显示失败）', () async {
    final logs = <String>[];
    await expectLater(
      GithubLoginCheck.run(
        (message, {bool isError = false}) => logs.add(message),
        tokenReader: () async => 'ghp_expired',
        dio: _dio(401, {'message': 'Bad credentials'}),
        channelProbe: () async => (ok: false, count: 0, error: '401 Unauthorized'),
      ),
      throwsA(isA<GithubLoginCheckException>()),
    );
    final text = logs.join('\n');
    expect(text, contains('HTTP 状态：401'));
    expect(text, contains('Token 无效'));
    expect(text, contains('建议：退出登录后重新授权'));
    expect(text, contains('Rust 侧 Token 未同步或已失效'));
  });

  test('无 Token：直接失败，不发起请求', () async {
    final logs = <String>[];
    var requested = false;
    await expectLater(
      GithubLoginCheck.run(
        (message, {bool isError = false}) => logs.add(message),
        tokenReader: () async => null,
        dio: _dio(200, {'login': 'x'}),
        channelProbe: () async {
          requested = true;
          return (ok: true, count: 0, error: null);
        },
      ),
      throwsA(isA<GithubLoginCheckException>()),
    );
    expect(requested, isFalse);
    expect(logs.join('\n'), contains('本地 Token：不存在'));
  });

  test('Dio 授权头与 Token 不一致时告警', () async {
    final logs = <String>[];
    final dio = _dio(200, {'login': 'octocat'});
    dio.options.headers['Authorization'] = 'Bearer old-token';
    await GithubLoginCheck.run(
      (message, {bool isError = false}) => logs.add(message),
      tokenReader: () async => 'ghp_new',
      dio: dio,
      channelProbe: () async => (ok: true, count: 1, error: null),
    );
    expect(logs.join('\n'), contains('Dio 授权头：与本地 Token 不一致'));
  });

  test('403 且速率用尽：提示稍后重试', () async {
    final logs = <String>[];
    await expectLater(
      GithubLoginCheck.run(
        (message, {bool isError = false}) => logs.add(message),
        tokenReader: () async => 'ghp_x',
        dio: _dio(
          403,
          {'message': 'API rate limit exceeded'},
          headers: {
            'x-ratelimit-limit': ['60'],
            'x-ratelimit-remaining': ['0'],
          },
        ),
        channelProbe: () async => (ok: true, count: 0, error: null),
      ),
      throwsA(isA<GithubLoginCheckException>()),
    );
    expect(logs.join('\n'), contains('速率限制已用尽'));
  });

  test('DioClient 退出登录时清除授权头（避免旧 Token 继续请求 → 401）', () {
    final client = DioClient.instance;
    client.authorization = 'abc123';
    expect(client.authorizationHeader, 'Bearer abc123');
    client.authorization = null;
    expect(client.authorizationHeader, isEmpty);
    client.authorization = '';
    expect(client.authorizationHeader, isEmpty);
    client.authorization = '  ';
    expect(client.authorizationHeader, isEmpty);
  });
}

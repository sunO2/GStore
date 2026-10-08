/// 「请求调试」认证应用（plan todo 1，纯函数，无 IO / 无 UI）。
///
/// 把 [DebugAuth] 的配置**确定性地**合并进请求头与查询参数：
/// - Basic  → `Authorization: Basic <base64(user:pass)>` 头；
/// - Bearer → `Authorization: Bearer <token>` 头；
/// - APIKey → 命名头（[DebugAuth.apiKeyIn] 非 `query`）或查询参数（`query`，
///   经 [mergeParams] 与既有查询规则一致：同名**覆盖**而非追加）。
///
/// 关键约定：
/// - **绝不解** `{{var}}` 占位符（由环境解析在发送前单独负责）；
/// - 认证为 `null` 或 [DebugAuthType.none] 时**原样返回**传入集合（内容不变）；
/// - 纯函数：不修改入参，返回新的 [AuthApplication]。
library;

import 'dart:convert';

import 'debug_models.dart';
import 'query_codec.dart';

/// [applyAuth] 的结果：认证应用后的请求头与查询参数。
class AuthApplication {
  const AuthApplication({required this.headers, required this.query});

  /// 应用认证后的请求头（可能新增 / 覆盖 `Authorization` 或 APIKey 头）。
  final List<DebugHeader> headers;

  /// 应用认证后的查询参数（APIKey-query 时合并入内）。
  final List<DebugQueryParam> query;
}

/// 把 [auth] 应用到 [headers] / [query]，返回新的集合。
///
/// [auth] 为 `null` 或 [DebugAuthType.none] 时不做任何改动；APIKey 且
/// `apiKeyName` 为空时同样不改动（避免注入无名头 / 空名查询键）。
AuthApplication applyAuth({
  DebugAuth? auth,
  List<DebugHeader> headers = const <DebugHeader>[],
  List<DebugQueryParam> query = const <DebugQueryParam>[],
}) {
  final effective = auth;
  if (effective == null || effective.type == DebugAuthType.none) {
    return AuthApplication(headers: headers, query: query);
  }

  switch (effective.type) {
    case DebugAuthType.none:
      return AuthApplication(headers: headers, query: query);

    case DebugAuthType.basic:
      final encoded = base64Encode(
        utf8.encode('${effective.username ?? ''}:${effective.password ?? ''}'),
      );
      return AuthApplication(
        headers: _setHeader(headers, 'Authorization', 'Basic $encoded'),
        query: query,
      );

    case DebugAuthType.bearer:
      return AuthApplication(
        headers: _setHeader(
          headers,
          'Authorization',
          'Bearer ${effective.token ?? ''}',
        ),
        query: query,
      );

    case DebugAuthType.apiKey:
      final name = effective.apiKeyName ?? '';
      if (name.isEmpty) {
        return AuthApplication(headers: headers, query: query);
      }
      final value = effective.apiKeyValue ?? '';
      if (effective.apiKeyIn == 'query') {
        // 与既有查询规则一致：同名覆盖（mergeParams 语义）。
        final merged = mergeParams(
          query,
          <DebugQueryParam>[DebugQueryParam(name: name, value: value)],
        );
        return AuthApplication(headers: headers, query: merged);
      }
      return AuthApplication(
        headers: _setHeader(headers, name, value),
        query: query,
      );
  }
}

/// 就地**覆盖**同名头（大小写不敏感），无同名则追加。
///
/// 覆盖时保留原位置与原 `name` 大小写，仅替换值与启用态。
List<DebugHeader> _setHeader(
  List<DebugHeader> headers,
  String name,
  String value,
) {
  final lower = name.toLowerCase();
  final next = <DebugHeader>[];
  var replaced = false;
  for (final header in headers) {
    if (!replaced && header.name.toLowerCase() == lower) {
      next.add(DebugHeader(name: header.name, value: value, enabled: true));
      replaced = true;
    } else {
      next.add(header);
    }
  }
  if (!replaced) {
    next.add(DebugHeader(name: name, value: value));
  }
  return next;
}

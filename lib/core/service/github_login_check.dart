/// GitHub 登录状态自检（诊断用）
///
/// 输出内容与备份/WebDAV 进度面板同风格：逐行日志 + 分级颜色。
/// 检查项：
/// 1. 本地 Token 是否存在、长度/掩码/类型（绝不打印完整 Token）
/// 2. Dio 全局授权头是否已设置、是否与 Token 一致
/// 3. 直接请求 GitHub `GET /user`：状态码、Scopes、速率限制、用户信息
/// 4. Rust 通道实测（GitHub 渠道搜索）：定位"Dart 有 Token 但渠道 401"
/// 5. 结论 + 可操作建议
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:gstore/core/channel/ChannelManager.dart';
import 'package:gstore/core/channel/model/ChannelType.dart';
import 'package:gstore/core/core.dart' show BackupLogCallback, appLog;
import 'package:gstore/core/service/user_manager.dart';
import 'package:gstore/http/github/dio_client.dart';

class GithubLoginCheck {
  GithubLoginCheck._();

  static const String _userEndpoint = 'https://api.github.com/user';

  /// 执行检查；严重问题会抛 [GithubLoginCheckException]（面板显示失败/重试）。
  static Future<void> run(
    BackupLogCallback onLog, {
    Future<String?> Function()? tokenReader,
    Dio? dio,
    Future<({bool ok, int count, String? error})> Function()? channelProbe,
  }) async {
    // 同时写系统日志：用户导日志时也能看到自检结果（Token 只出现掩码）
    void log(String message, {bool isError = false}) {
      onLog(message, isError: isError);
      if (isError) {
        appLog.error('GithubLoginCheck: $message');
      } else {
        appLog.info('GithubLoginCheck: $message');
      }
    }

    log('开始检查 GitHub 登录状态...');

    // ---- 1. 本地 Token ----
    String? token;
    try {
      token = await (tokenReader ?? UserManager.instance.getToken)();
    } catch (error) {
      log('读取本地 Token 失败：$error', isError: true);
      throw GithubLoginCheckException('无法读取本地登录状态');
    }
    if (token == null || token.trim().isEmpty) {
      log('本地 Token：不存在（未登录或已退出）', isError: true);
      throw GithubLoginCheckException('未登录：请先登录 GitHub');
    }
    final trimmed = token.trim();
    log('本地 Token：存在（长度 ${trimmed.length}，${_maskToken(trimmed)}）');
    log('Token 类型：${_tokenKind(trimmed)}');

    // ---- 2. 全局授权头 ----
    final client = dio ?? DioClient.instance.get();
    final header =
        client.options.headers['Authorization']?.toString().trim() ?? '';
    if (header.isEmpty) {
      log('Dio 授权头：未设置（本次检查会显式携带 Token）');
    } else if (header == 'Bearer $trimmed') {
      log('Dio 授权头：已设置，与本地 Token 一致');
    } else {
      log('Dio 授权头：与本地 Token 不一致（其余请求可能仍用旧 Token）',
          isError: true);
    }

    // ---- 3. GET /user ----
    log('请求 GitHub API：GET $_userEndpoint');
    Response<dynamic> response;
    try {
      response = await client.get<dynamic>(
        _userEndpoint,
        options: Options(
          headers: {'Authorization': 'Bearer $trimmed'},
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (error) {
      log('请求失败：${_brief(error.message ?? error.toString())}',
          isError: true);
      throw GithubLoginCheckException('网络异常：无法连接 GitHub API');
    }

    final status = response.statusCode ?? 0;
    final headers = response.headers.map;
    String headerOf(String name) {
      final values = headers[name];
      if (values == null || values.isEmpty) return '';
      return values.first.trim();
    }

    log('HTTP 状态：$status ${_statusText(status)}');

    final scopes = headerOf('x-oauth-scopes');
    final accepted = headerOf('x-accepted-github-permissions');
    if (scopes.isNotEmpty) log('Token Scopes：$scopes');
    if (accepted.isNotEmpty) log('已接受权限：${_brief(accepted, max: 160)}');
    if (scopes.isEmpty && accepted.isEmpty) {
      log('Token Scopes：未返回（fine-grained Token 可能不返回该头）');
    }

    final limit = headerOf('x-ratelimit-limit');
    final remaining = headerOf('x-ratelimit-remaining');
    final reset = headerOf('x-ratelimit-reset');
    if (limit.isNotEmpty || remaining.isNotEmpty) {
      final resetText = _formatReset(reset);
      log('速率限制：剩余 $remaining/$limit${resetText.isEmpty ? '' : '，重置 $resetText'}');
    }

    var githubOk = false;
    if (status == 200) {
      githubOk = true;
      final body = _asMap(response.data);
      log('用户：${body['login'] ?? '-'}'
          '（id=${body['id'] ?? '-'}，type=${body['type'] ?? '-'}）');
      final name = (body['name'] ?? '').toString().trim();
      if (name.isNotEmpty) log('昵称：$name');
      final repos = body['public_repos'];
      if (repos != null) log('公开仓库：$repos');
      log('结论（Dart 侧）：Token 有效');
    } else if (status == 401) {
      log('GitHub 返回 401：Token 无效、已过期或被撤销', isError: true);
      log('建议：退出登录后重新授权（设置页 → 我的 → 退出登录）', isError: true);
    } else if (status == 403) {
      final rateLimited = headerOf('x-ratelimit-remaining') == '0';
      log(
        rateLimited
            ? 'GitHub 返回 403：速率限制已用尽，请稍后重试'
            : 'GitHub 返回 403：权限不足或被拒绝（可能缺少 scope）',
        isError: true,
      );
    } else {
      final message = _errorMessage(response.data);
      log('GitHub 返回 $status${message.isEmpty ? '' : '：$message'}',
          isError: true);
    }

    // ---- 4. Rust 通道实测（真正触发 401 的路径） ----
    log('检查 Rust 通道（GitHub 渠道搜索：termux）...');
    var rustOk = false;
    try {
      final probe = channelProbe ?? _defaultChannelProbe;
      final result = await probe();
      rustOk = result.ok;
      if (result.ok) {
        log('Rust 通道：正常（返回 ${result.count} 条）');
      } else {
        log('Rust 通道：失败 - ${_brief(result.error ?? '未知错误')}',
            isError: true);
        final error = (result.error ?? '').toLowerCase();
        if (error.contains('401') || error.contains('unauthorized')) {
          log('Rust 侧 Token 未同步或已失效（渠道用的是 Rust 配置里的 Token）',
              isError: true);
        }
      }
    } catch (error) {
      log('Rust 通道：调用异常 - ${_brief(error.toString())}', isError: true);
    }

    // ---- 5. 结论 ----
    if (githubOk && rustOk) {
      log('结论：登录状态正常，Dart 请求与 Rust 渠道均可用');
      return;
    }
    if (githubOk && !rustOk) {
      log('结论：Token 本身有效，但 Rust 渠道调用失败', isError: true);
      log('建议：重新登录以同步 Token，或检查代理/GitHub 渠道配置', isError: true);
      throw GithubLoginCheckException('Rust 渠道调用失败（Token 可能未同步）');
    }
    if (!githubOk && rustOk) {
      log('结论：渠道可用，但 Dart 直连 GitHub API 失败', isError: true);
      throw GithubLoginCheckException('GitHub API 校验失败');
    }
    throw GithubLoginCheckException('Token 无效：请重新登录 GitHub');
  }

  /// 默认探针：用真实 GitHub 渠道搜一次（走 Rust core，带 Token）。
  static Future<({bool ok, int count, String? error})>
      _defaultChannelProbe() async {
    final result = await ChannelManager.instance.searchApps(
      'termux',
      from: ChannelType.github,
      forceRefresh: true,
    );
    return (
      ok: result.success,
      count: result.data?.length ?? 0,
      error: result.error,
    );
  }

  // -------------------------------------------------------------------------
  // 辅助
  // -------------------------------------------------------------------------

  /// Token 掩码：只保留前缀特征与末 4 位。
  static String _maskToken(String token) {
    if (token.length <= 10) return '****';
    final head = token.startsWith('github_pat_')
        ? token.substring(0, 11)
        : token.substring(0, 7);
    final tail = token.substring(token.length - 4);
    return '$head…$tail';
  }

  static String _tokenKind(String token) {
    if (token.startsWith('github_pat_')) return 'fine-grained PAT';
    if (token.startsWith('ghp_')) return 'classic PAT';
    if (token.startsWith('gho_')) return 'OAuth access token';
    if (token.startsWith('ghu_')) return 'GitHub App user token';
    if (token.startsWith('ghs_')) return 'GitHub App server token';
    return '未知类型（长度 ${token.length}）';
  }

  static String _statusText(int status) {
    switch (status) {
      case 200:
        return 'OK';
      case 401:
        return 'Unauthorized';
      case 403:
        return 'Forbidden';
      case 404:
        return 'Not Found';
      default:
        return '';
    }
  }

  static String _formatReset(String epochSeconds) {
    final seconds = int.tryParse(epochSeconds);
    if (seconds == null || seconds <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final now = DateTime.now();
    final diff = time.difference(now);
    final mins = diff.inMinutes;
    String two(int v) => v.toString().padLeft(2, '0');
    final clock = '${two(time.hour)}:${two(time.minute)}';
    if (mins <= 0) return clock;
    return '$clock（约 $mins 分钟后）';
  }

  static Map<String, dynamic> _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {
        // 非 JSON 响应
      }
    }
    return const {};
  }

  static String _errorMessage(Object? data) {
    final map = _asMap(data);
    return (map['message'] ?? '').toString().trim();
  }

  static String _brief(String text, {int max = 300}) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= max) return oneLine;
    return '${oneLine.substring(0, max)}…';
  }
}

class GithubLoginCheckException implements Exception {
  GithubLoginCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

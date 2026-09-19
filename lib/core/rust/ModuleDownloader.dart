// 与 lib/core/rust/ 既有桥接文件命名约定一致（PascalCase）。
// `file_names` 是项目既有噪音（同目录多个文件同样触发），此处显式豁免，
// 避免新增分析诊断。
// ignore_for_file: file_names

import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import 'package:gstore/core/config/AppConfig.dart';
import 'package:gstore/core/core.dart' show getProxy;
import 'package:gstore/core/rust/ModuleManifest.dart';

/// 内部自举下载器（实现 [ModuleFetcher]）。
///
/// 设计约束（见 `.omo/plans/remote-plugin-download.md` Todo 3）：
///
/// * **只依赖 `dart:io HttpClient`**：不走用户下载管线、不产生下载任务/通知/
///   安装，也不调用 Rust 下载内核。
/// * **严格来源校验在本模块内完成**：**代理前的原始 URL** host 必须命中
///   资产域白名单（点边界匹配），不依赖 `AppConfig.isValidUrl`。
/// * **代理仅在原始 URL 通过校验后作为固定前缀施加**：代理 host 不参与白名单
///   判定，也不被视为可信来源；代理为空时直连已校验的原始 URL。
/// * **手工重定向**（`followRedirects = false`）：每一跳目标 host 都必须再次
///   通过白名单校验，跳数有界。
/// * **有限重试 + 退避**：仅对 403/408/429/5xx 与超时/连接错误重试；
///   整体大小有上限（`maxBytes`），超限即拒绝。
/// * **并发去重**：同一 URL 的并发 `fetch` 共享同一个 `Future`，只发一次网络请求。
///
/// 本模块**不做**完整性校验（SHA-256/签名）——代理返回的字节一律不可信，
/// 由调用方按清单 sha256 复核（Todo 4/5）。
class ModuleDownloader implements ModuleFetcher {
  /// 资产域白名单（**裸 host**，点边界匹配：`host == w || host.endsWith('.$w')`）。
  ///
  /// 代理 host（如 `gh-proxy.org`）绝不加入此集合，也不得被视为可信来源。
  static const Set<String> defaultAssetHosts = {
    'github.com',
    'api.github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'githubusercontent.com',
  };

  /// 未显式指定 `maxBytes` 时的下载上限（100 MiB）。
  static const int defaultMaxBytes = 100 * 1024 * 1024;

  /// 单次请求的默认超时（连接 + 响应）。
  static const Duration defaultTimeout = Duration(seconds: 30);

  final Set<String> _allowedHosts;
  final String Function() _proxyProvider;
  final HttpClient Function() _clientFactory;
  final Duration _timeout;
  final int _maxAttempts;
  final int _maxRedirects;
  final Duration _initialBackoff;
  final Directory _tmpRoot;
  final Future<void> Function(Duration) _sleep;

  /// 在途下载去重表：key → 共享 Future。
  final Map<String, Future<Uint8List?>> _inFlight = {};

  ModuleDownloader({
    Set<String>? allowedHosts,
    String Function()? proxyProvider,
    HttpClient Function()? clientFactory,
    Duration timeout = defaultTimeout,
    int maxAttempts = 3,
    int maxRedirects = 5,
    Duration initialBackoff = const Duration(milliseconds: 400),
    Directory? tmpRoot,
    Future<void> Function(Duration)? sleep,
  })  : _allowedHosts = allowedHosts ?? defaultAssetHosts,
        _proxyProvider = proxyProvider ?? _readConfiguredProxy,
        _clientFactory = clientFactory ?? HttpClient.new,
        _timeout = timeout,
        _maxAttempts = maxAttempts < 1 ? 1 : maxAttempts,
        _maxRedirects = maxRedirects < 0 ? 0 : maxRedirects,
        _initialBackoff = initialBackoff,
        _tmpRoot = tmpRoot ?? Directory.systemTemp,
        _sleep = sleep ?? Future<void>.delayed;

  /// 生产默认代理来源：优先 [AppConfig.githubProxyUrl]（若被显式设置），
  /// 否则回退到全局 [getProxy]（`''` 表示不使用代理）。
  static String _readConfiguredProxy() {
    final configured = AppConfig().githubProxyUrl;
    if (configured != null && configured.trim().isNotEmpty) {
      return configured.trim();
    }
    return getProxy();
  }

  /// 生产代理前缀（供其它 fetcher 复用同一读取规则，避免两套代理语义）。
  static String configuredProxy() => _readConfiguredProxy();

  /// 下载 [url] 并返回字节；失败（校验/网络/超限）返回 `null`，**绝不抛异常**。
  ///
  /// 同一 URL（且相同的有效 `maxBytes`）的并发调用共享同一个 Future，
  /// 保证恰好一次网络请求。
  @override
  Future<Uint8List?> fetch(String url, {int? maxBytes}) {
    final limit = _normalizeLimit(maxBytes);
    final key = '$url\u0000$limit';
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _fetchInternal(url, limit).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// 供 Todo 4 使用的写盘入口：把字节流写入**调用方提供的 `.tmp`**，
  /// 成功后由调用方负责原子 rename（本方法不会 rename）。
  ///
  /// 失败时删除 [targetTmp] 并返回 `false`；绝不抛异常。
  Future<bool> downloadToFile(String url, File targetTmp, {int? maxBytes}) async {
    final limit = _normalizeLimit(maxBytes);
    try {
      final status = await _download(url, targetTmp, limit);
      if (status != _AttemptStatus.success) {
        await _deleteQuietly(targetTmp);
        return false;
      }
      return true;
    } catch (_) {
      await _deleteQuietly(targetTmp);
      return false;
    }
  }

  Future<Uint8List?> _fetchInternal(String url, int limit) async {
    Directory? tmpDir;
    try {
      tmpDir = await _tmpRoot.createTemp('gstore_mod_dl_');
      final dest = File(p.join(tmpDir.path, 'asset.tmp'));
      final status = await _download(url, dest, limit);
      if (status != _AttemptStatus.success) return null;
      return await dest.readAsBytes();
    } catch (_) {
      return null;
    } finally {
      final dir = tmpDir;
      if (dir != null) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {
          // 清理失败不影响结果
        }
      }
    }
  }

  int _normalizeLimit(int? maxBytes) {
    if (maxBytes == null || maxBytes <= 0) return defaultMaxBytes;
    return maxBytes;
  }

  /// 校验原始 URL → 施加代理前缀（仅在通过校验后）→ 有界重试下载到 [dest]。
  Future<_AttemptStatus> _download(String url, File dest, int limit) async {
    final plan = _buildPlan(url);
    if (plan == null) return _AttemptStatus.fatal;

    var offset = 0;
    var last = _AttemptStatus.fatal;
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      final (status, received) = await _runAttempt(plan, dest, limit, offset);
      last = status;
      if (last != _AttemptStatus.retryable) return last;
      offset = received;
      if (offset > 0) {
        debugPrint('ModuleDownloader: 第 $attempt 次中断，已收 $offset 字节，将从此处续传');
      }
      if (attempt < _maxAttempts) {
        await _sleep(_backoffFor(attempt));
      }
    }
    debugPrint('ModuleDownloader: 下载失败 原始=$url 实际请求=${plan.target} '
        '末次状态=$last（$_maxAttempts 次尝试，已收 $offset 字节）');
    return last;
  }

  Duration _backoffFor(int attempt) {
    final factor = 1 << (attempt - 1);
    return Duration(milliseconds: _initialBackoff.inMilliseconds * factor);
  }

  /// 解析并校验请求计划。
  ///
  /// **先校验原始 URL host**；只有通过后才把 `getProxy()` 作为固定前缀拼接。
  /// 代理本身非 http/https 或格式非法 → 直接拒绝（绝不退化为意外通道）。
  _RequestPlan? _buildPlan(String url) {
    final original = Uri.tryParse(url);
    if (original == null) return null;
    if (!_isAllowed(original)) {
      debugPrint('ModuleDownloader: 原始 URL host 不在白名单，拒绝 - $url');
      return null;
    }

    final proxy = _proxyProvider().trim();
    debugPrint('ModuleDownloader: 代理="${proxy.isEmpty ? '(直连)' : proxy}" <- $url');
    if (proxy.isEmpty) {
      return _RequestPlan(original: original, target: original, proxied: false);
    }

    final proxyUri = Uri.tryParse(proxy);
    if (proxyUri == null ||
        !_isHttpScheme(proxyUri.scheme) ||
        proxyUri.host.isEmpty) {
      debugPrint('ModuleDownloader: 代理前缀格式非法，拒绝 - $proxy');
      return null;
    }

    final normalizedProxy = proxy.endsWith('/') ? proxy : '$proxy/';
    final target = Uri.tryParse('$normalizedProxy$url');
    if (target == null || target.host.isEmpty) return null;
    return _RequestPlan(original: original, target: target, proxied: true);
  }

  /// 逐跳校验：协议必须是 https（环回测试地址允许 http），host 必须命中白名单。
  bool _isAllowed(Uri uri) {
    if (uri.host.isEmpty) return false;
    if (uri.scheme == 'https') {
      return _isAllowedHost(uri.host);
    }
    if (uri.scheme == 'http' && _isLoopbackHost(uri.host)) {
      return _isAllowedHost(uri.host);
    }
    return false;
  }

  bool _isAllowedHost(String host) {
    final normalized = host.toLowerCase();
    for (final allowed in _allowedHosts) {
      final w = allowed.toLowerCase();
      if (normalized == w || normalized.endsWith('.$w')) return true;
    }
    return false;
  }

  static bool _isHttpScheme(String scheme) => scheme == 'http' || scheme == 'https';

  static bool _isLoopbackHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == '127.0.0.1' ||
        normalized == 'localhost' ||
        normalized == '::1' ||
        normalized == '[::1]';
  }

  /// 单次尝试：手工跟重定向（每跳校验），成功则流式写入 [dest]。
  Future<(_AttemptStatus, int)> _runAttempt(
    _RequestPlan plan,
    File dest,
    int limit,
    int offset,
  ) async {
    final client = _clientFactory();
    try {
      client.connectionTimeout = _timeout;

      var current = plan.target;
      var hops = 0;

      while (true) {
        final HttpClientRequest request;
        try {
          request = await client.getUrl(current).timeout(_timeout);
          request.followRedirects = false; // 手工逐跳校验
          if (offset > 0) {
            request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
          }
        } on TimeoutException catch (e) {
          debugPrint('ModuleDownloader: 请求超时 - $e');
          return (_AttemptStatus.retryable, offset);
        } on SocketException catch (e) {
          debugPrint('ModuleDownloader: 套接字错误 - $e');
          return (_AttemptStatus.retryable, offset);
        } on HttpException catch (e) {
          debugPrint('ModuleDownloader: HTTP 异常 - $e');
          return (_AttemptStatus.retryable, offset);
        } catch (e) {
          debugPrint('ModuleDownloader: 请求致命错误 - $e');
          return (_AttemptStatus.fatal, offset);
        }

        final HttpClientResponse response;
        try {
          response = await request.close().timeout(_timeout);
        } on TimeoutException catch (e) {
          request.abort();
          debugPrint('ModuleDownloader: 响应超时 - $e');
          return (_AttemptStatus.retryable, offset);
        } on SocketException catch (e) {
          request.abort();
          debugPrint('ModuleDownloader: 响应套接字错误 - $e');
          return (_AttemptStatus.retryable, offset);
        } on HttpException catch (e) {
          request.abort();
          debugPrint('ModuleDownloader: 响应 HTTP 异常 - $e');
          return (_AttemptStatus.retryable, offset);
        } catch (e) {
          request.abort();
          debugPrint('ModuleDownloader: 响应致命错误 - $e');
          return (_AttemptStatus.fatal, offset);
        }

        final code = response.statusCode;

        if (_isRedirect(code)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await _drainQuietly(response);
          if (location == null || location.isEmpty) {
            return (_AttemptStatus.fatal, offset);
          }
          if (hops >= _maxRedirects) return (_AttemptStatus.fatal, offset);
          final next = current.resolve(location);
          // 逐跳校验：重定向目标 host 必须在资产白名单内，否则拒绝。
          if (!_isAllowed(next)) {
            debugPrint('ModuleDownloader: 重定向目标不在白名单，拒绝 - $next');
            return (_AttemptStatus.fatal, offset);
          }
          current = next;
          hops++;
          continue;
        }

        if (code == HttpStatus.ok || code == HttpStatus.partialContent) {
          final startOffset = code == HttpStatus.partialContent ? offset : 0;
          return _receiveToFile(response, dest, limit, startOffset);
        }

        await _drainQuietly(response);
        debugPrint('ModuleDownloader: HTTP $code hop=$hops url=$current');
        if (code == HttpStatus.forbidden ||
            code == HttpStatus.requestTimeout ||
            code == HttpStatus.tooManyRequests ||
            code >= 500) {
          return (_AttemptStatus.retryable, offset);
        }
        return (_AttemptStatus.fatal, offset);
      }
    } finally {
      client.close(force: true);
    }
  }

  /// 流式落盘并强制大小上限；超限视为**致命**（不重试）。
  Future<(_AttemptStatus, int)> _receiveToFile(
    HttpClientResponse response,
    File dest,
    int limit,
    int startOffset,
  ) async {
    final declared = response.contentLength;
    if (declared > 0 && startOffset + declared > limit) {
      await _drainQuietly(response);
      return (_AttemptStatus.fatal, startOffset);
    }

    final sink = dest.openWrite(
      mode: startOffset > 0 ? FileMode.append : FileMode.write,
    );
    var received = startOffset;
    try {
      await for (final chunk in response.timeout(_timeout)) {
        received += chunk.length;
        if (received > limit) {
          return (_AttemptStatus.fatal, received);
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      return (_AttemptStatus.success, received);
    } on TimeoutException catch (e) {
      debugPrint('ModuleDownloader: 落盘超时 - $e');
      return (_AttemptStatus.retryable, received);
    } on SocketException catch (e) {
      debugPrint('ModuleDownloader: 落盘套接字错误 - $e');
      return (_AttemptStatus.retryable, received);
    } on HttpException catch (e) {
      debugPrint('ModuleDownloader: 落盘 HTTP 异常 - $e');
      return (_AttemptStatus.retryable, received);
    } catch (e) {
      debugPrint('ModuleDownloader: 落盘致命错误 - $e');
      return (_AttemptStatus.fatal, received);
    } finally {
      try {
        await sink.close();
      } catch (_) {
        // 已关闭/写失败 → 忽略
      }
    }
  }

  static bool _isRedirect(int code) =>
      code == HttpStatus.movedPermanently ||
      code == HttpStatus.found ||
      code == HttpStatus.seeOther ||
      code == HttpStatus.temporaryRedirect ||
      code == HttpStatus.permanentRedirect;

  Future<void> _drainQuietly(Stream<List<int>> stream) async {
    try {
      await stream.drain<void>();
    } catch (_) {
      // 仅用于释放连接，忽略错误
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 忽略清理失败
    }
  }
}

/// 单次尝试的结果状态（成功 / 可重试 / 致命）。
enum _AttemptStatus { success, retryable, fatal }

/// 校验后的请求计划：[original] 为已通过白名单校验的原始 URL，
/// [target] 为实际请求 URL（可能已施加代理前缀）。
class _RequestPlan {
  final Uri original;
  final Uri target;
  final bool proxied;

  const _RequestPlan({
    required this.original,
    required this.target,
    required this.proxied,
  });
}

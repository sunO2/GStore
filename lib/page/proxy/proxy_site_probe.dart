/// 代理首页「网站连通性检测」核心（纯 Dart，无 Flutter UI / 无原生模块）。
///
/// 设计要点：
///
/// * **普通 Dart HTTP 客户端**：生产实现 [DioSiteProbeSender] 使用全新 `Dio()` 的
///   默认 `dart:io` 适配器（**不**挂 rhttp / curl）。GStore 的 Dart socket 未被保护，
///   因此请求路径自动跟随当前代理状态：
///   - 未开代理（无 TUN）→ 请求直连；
///   - 全量分流模式开代理 → 请求被 TUN 捕获，由内核**按当前规则策略**路由
///     （规则 → CN 直连 / 国外走节点；全局 → 走节点；直连 → 直连）。
///
///   本文件**不**调用 `node.delay_test`、**不**强制 / 指定代理节点、**不**新增
///   Rust RPC，也**不**对目标 URL 套 GitHub 代理前缀（必须命中真实目标）。
/// * 延迟口径为 **TTFB**（响应头到达即停表），而非整包下载耗时。
/// * [SiteProbe.probeAll] / [SiteProbe.probeAllStream] **绝不抛异常**：每个站点的
///   失败都会转成判定结果。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';

/// 一个待探测站点：展示名 + 目标 URL + HTTP 方法。
class SiteProbeTarget {
  const SiteProbeTarget({
    required this.label,
    required this.url,
    required this.method,
  });

  /// 展示名（如 `Claude`）。
  final String label;

  /// 目标 URL（**真实目标**，绝不套 GitHub 代理前缀）。
  final String url;

  /// HTTP 方法：`GET` / `HEAD`。
  final String method;
}

/// 站点可达性判定。
enum SiteProbeVerdict {
  /// 收到 2xx / 3xx 响应。
  ok,

  /// 收到 4xx 响应：**仍然可达**（如 403 / 404 代表连通但受限），绝不能当死站。
  restricted,

  /// 超时内未收到任何响应。
  timeout,

  /// 传输层错误 / 5xx。
  unreachable,
}

/// 单个站点的探测结果。
class SiteProbeResult {
  const SiteProbeResult({
    required this.target,
    required this.verdict,
    this.statusCode,
    this.latencyMs,
    this.error,
  });

  /// 对应站点。
  final SiteProbeTarget target;

  /// 判定。
  final SiteProbeVerdict verdict;

  /// 若收到 HTTP 响应则为状态码，否则 `null`。
  final int? statusCode;

  /// 测量样本的中位 TTFB（毫秒）；无成功响应时为 `null`。
  final int? latencyMs;

  /// 失败原因（超时 / 传输错误），成功时为 `null`。
  final String? error;

  /// 是否完全可达（2xx / 3xx）。
  bool get ok => verdict == SiteProbeVerdict.ok;

  /// 是否收到过 HTTP 响应（2xx-4xx 均视为「连通」）。
  bool get reachable =>
      verdict == SiteProbeVerdict.ok || verdict == SiteProbeVerdict.restricted;
}

/// [SiteProbeSender] 的响应：状态码 + TTFB（毫秒）。
class ProbeHttpResponse {
  const ProbeHttpResponse({required this.statusCode, required this.latencyMs});

  /// HTTP 状态码。
  final int statusCode;

  /// 响应头到达耗时（毫秒）。
  final int latencyMs;
}

/// 发送超时（与其它传输错误区分，映射为 [SiteProbeVerdict.timeout]）。
class ProbeTimeoutException implements Exception {
  const ProbeTimeoutException([this.message = '探测超时']);

  final String message;

  @override
  String toString() => 'ProbeTimeoutException: $message';
}

/// 探测发送接缝：生产走 [DioSiteProbeSender]；测试注入假实现，无需网络。
abstract class SiteProbeSender {
  /// 向 [target] 发起一次请求，[timeout] 内未拿到响应头则抛
  /// [ProbeTimeoutException]；其它失败抛任意异常。
  Future<ProbeHttpResponse> send(SiteProbeTarget target, Duration timeout);
}

/// 固定探测清单（真实目标，不套代理前缀）。
const List<SiteProbeTarget> kSiteProbeCatalog = <SiteProbeTarget>[
  SiteProbeTarget(
    label: 'Claude',
    url: 'https://claude.ai/robots.txt',
    method: 'GET',
  ),
  SiteProbeTarget(
    label: 'OpenAI',
    url: 'https://openai.com/robots.txt',
    method: 'GET',
  ),
  SiteProbeTarget(
    label: 'Google',
    url: 'https://www.gstatic.com/generate_204',
    method: 'HEAD',
  ),
  SiteProbeTarget(
    label: 'YouTube',
    url: 'https://www.youtube.com/robots.txt',
    method: 'GET',
  ),
  SiteProbeTarget(
    label: 'GitHub',
    url: 'https://github.com/robots.txt',
    method: 'GET',
  ),
  SiteProbeTarget(
    label: 'Baidu',
    url: 'https://www.baidu.com/robots.txt',
    method: 'GET',
  ),
  SiteProbeTarget(
    label: 'Cloudflare',
    url: 'https://cp.cloudflare.com/generate_204',
    method: 'HEAD',
  ),
  SiteProbeTarget(
    label: 'Apple',
    url: 'http://captive.apple.com/hotspot-detect.html',
    method: 'GET',
  ),
  SiteProbeTarget(
    label: '国内基线',
    url: 'http://connect.rom.miui.com/generate_204',
    method: 'HEAD',
  ),
];

/// 对清单内站点做延迟探测并给出可达性判定。
///
/// * 每个站点发送 [warmupCount] 个**丢弃**的预热样本 + [sampleCount] 个**测量**
///   样本；延迟取测量样本中位 TTFB；
/// * 并发上限 [maxConcurrency]（默认 3）；
/// * [probeAll] 绝不抛异常。
class SiteProbe {
  SiteProbe({
    SiteProbeSender? sender,
    List<SiteProbeTarget>? targets,
    this.sampleCount = 3,
    this.warmupCount = 1,
    this.timeout = const Duration(seconds: 8),
    this.maxConcurrency = 3,
  })  : _sender = sender,
        targets =
            List<SiteProbeTarget>.unmodifiable(targets ?? kSiteProbeCatalog) {
    assert(sampleCount >= 1, 'sampleCount must be >= 1');
    assert(warmupCount >= 0, 'warmupCount must be >= 0');
    assert(maxConcurrency >= 1, 'maxConcurrency must be >= 1');
  }

  final SiteProbeSender? _sender;

  /// 探测清单（默认 [kSiteProbeCatalog]）。
  final List<SiteProbeTarget> targets;

  /// 测量样本数（默认 3）。
  final int sampleCount;

  /// 预热样本数（默认 1，丢弃不计入中位数）。
  final int warmupCount;

  /// 单次请求超时（默认 8s）。
  final Duration timeout;

  /// 同时在飞的站点数上限（默认 3）。
  final int maxConcurrency;

  SiteProbeSender? _cachedSender;

  /// 懒创建生产发送器：构造 [SiteProbe] 时不触碰网络栈。
  SiteProbeSender get _effectiveSender =>
      _sender ?? (_cachedSender ??= DioSiteProbeSender());

  /// 探测全部站点；并发受限、逐站失败转为判定，**绝不抛异常**。
  Future<List<SiteProbeResult>> probeAll() async {
    if (targets.isEmpty) return const <SiteProbeResult>[];
    final List<SiteProbeResult?> results =
        List<SiteProbeResult?>.filled(targets.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final int index = next;
        next++;
        if (index >= targets.length) return;
        results[index] = await _probeTarget(targets[index]);
      }
    }

    final int workerCount = math.min(maxConcurrency, targets.length);
    await Future.wait<void>(
      List<Future<void>>.generate(workerCount, (_) => worker()),
    );
    return <SiteProbeResult>[for (final r in results) r!];
  }

  /// 与 [probeAll] 相同的限流探测，但**逐站发射**：任一站点一完成就立即
  /// 推出它的 [SiteProbeResult]（**完成顺序**，非清单顺序），无需等待其余站点。
  ///
  /// * 并发上限仍为 [maxConcurrency]，复用 [_probeTarget]（预热 + 中位采样）；
  /// * 绝不抛异常：发送器失败已在 [_probeTarget] 内转成判定；此处再兜底一次；
  /// * 全部完成后关闭；空清单立即关闭；
  /// * 订阅被取消后不再发射，也不会因「已取消 / 已关闭」而抛错。
  Stream<SiteProbeResult> probeAllStream() {
    if (targets.isEmpty) return const Stream<SiteProbeResult>.empty();

    final StreamController<SiteProbeResult> controller =
        StreamController<SiteProbeResult>();
    var cancelled = false;
    var next = 0;

    Future<void> worker() async {
      while (!cancelled) {
        final int index = next;
        next++;
        if (index >= targets.length) return;
        SiteProbeResult result;
        try {
          result = await _probeTarget(targets[index]);
        } catch (_) {
          // _probeTarget 设计上绝不抛错；此处仅作最后兜底。
          result = SiteProbeResult(
            target: targets[index],
            verdict: SiteProbeVerdict.unreachable,
          );
        }
        if (cancelled || controller.isClosed) return;
        controller.add(result);
      }
    }

    final int workerCount = math.min(maxConcurrency, targets.length);
    unawaited(
      Future.wait<void>(
        List<Future<void>>.generate(workerCount, (_) => worker()),
      ).whenComplete(() {
        if (!cancelled && !controller.isClosed) {
          controller.close();
        }
      }),
    );

    controller.onCancel = () {
      cancelled = true;
    };
    return controller.stream;
  }

  /// 探测单站：先预热后测量，聚合为一条 [SiteProbeResult]。绝不抛出。
  Future<SiteProbeResult> _probeTarget(SiteProbeTarget target) async {
    final List<int> statuses = <int>[];
    final List<int> latencies = <int>[];
    var sawTimeout = false;
    String? lastError;

    final int total = warmupCount + sampleCount;
    for (var i = 0; i < total; i++) {
      final bool measured = i >= warmupCount;
      try {
        final ProbeHttpResponse response =
            await _effectiveSender.send(target, timeout);
        if (measured) {
          statuses.add(response.statusCode);
          latencies.add(response.latencyMs);
        }
      } on ProbeTimeoutException catch (error) {
        if (measured) sawTimeout = true;
        lastError = error.message;
      } catch (error) {
        if (measured) lastError = '$error';
      }
    }

    if (statuses.isNotEmpty) {
      final int status = statuses.first;
      return SiteProbeResult(
        target: target,
        verdict: classifyStatus(status),
        statusCode: status,
        latencyMs: medianOf(latencies),
      );
    }
    return SiteProbeResult(
      target: target,
      verdict:
          sawTimeout ? SiteProbeVerdict.timeout : SiteProbeVerdict.unreachable,
      error: lastError,
    );
  }
}

/// 状态码 → 判定：2xx/3xx = ok；4xx = restricted（**仍可达**）；其余 = unreachable。
SiteProbeVerdict classifyStatus(int status) {
  if (status >= 200 && status < 400) return SiteProbeVerdict.ok;
  if (status >= 400 && status < 500) return SiteProbeVerdict.restricted;
  return SiteProbeVerdict.unreachable;
}

/// 中位数：空列表返回 `null`；偶数个取中间两值均值四舍五入。
int? medianOf(List<int> values) {
  if (values.isEmpty) return null;
  final List<int> sorted = List<int>.of(values)..sort();
  final int mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return ((sorted[mid - 1] + sorted[mid]) / 2).round();
}

/// 生产发送器：全新 [Dio]（**默认 `dart:io` 适配器**），TTFB 口径（停在响应头）。
///
/// `ResponseType.stream` 让 `send` 一拿到响应头就停表，随后取消响应体，避免把
/// 整包下载耗时算进延迟。
class DioSiteProbeSender implements SiteProbeSender {
  DioSiteProbeSender({Dio? dio}) : _dio = dio ?? _defaultDio();

  final Dio _dio;

  static const String _userAgent = 'GStore-App/1.0';

  /// 全新 [Dio]：**默认 `dart:io` 适配器**（不挂 rhttp），请求因此受 TUN 路由。
  ///
  /// `connectTimeout` 只能配置在 [BaseOptions]，生产默认 8s；每次请求的
  /// [SiteProbe.timeout] 通过 `sendTimeout` / `receiveTimeout` 生效。
  static Dio _defaultDio() => Dio(
        BaseOptions(
          headers: const <String, String>{'User-Agent': _userAgent},
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 8),
          sendTimeout: const Duration(seconds: 8),
          connectTimeout: const Duration(seconds: 8),
          validateStatus: (int? status) => status != null,
        ),
      );

  @override
  Future<ProbeHttpResponse> send(
    SiteProbeTarget target,
    Duration timeout,
  ) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      final Response<ResponseBody> response = await _dio.request<ResponseBody>(
        target.url,
        options: Options(
          method: target.method,
          responseType: ResponseType.stream,
          followRedirects: true,
          validateStatus: (int? status) => status != null,
          receiveTimeout: timeout,
          sendTimeout: timeout,
        ),
      );
      stopwatch.stop();
      final ResponseBody? body = response.data;
      if (body != null) {
        try {
          final subscription = body.stream.listen((_) {});
          await subscription.cancel();
        } catch (_) {
          // 取消响应体失败不影响 TTFB 结果。
        }
      }
      return ProbeHttpResponse(
        statusCode: response.statusCode ?? 0,
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on DioException catch (error) {
      stopwatch.stop();
      if (_isTimeout(error.type)) {
        throw ProbeTimeoutException('${error.message ?? error}');
      }
      throw StateError('${error.message ?? error}');
    }
  }

  static bool _isTimeout(DioExceptionType type) =>
      type == DioExceptionType.connectionTimeout ||
      type == DioExceptionType.receiveTimeout ||
      type == DioExceptionType.sendTimeout;
}

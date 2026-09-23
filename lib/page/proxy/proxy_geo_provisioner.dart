/// 代理「规则模式」geo provisioning 核心（纯 Dart，无 UI）。
///
/// 当生成配置含 `GEOIP,CN` / `GEOSITE,cn` 规则时，Rust 引擎需要
/// `country.mmdb` / `geosite.dat` 才能编译对应规则。本文件负责在**连接前**快速
/// 触发一次 geo 下载：
/// 1. `rules.get` 探测当前 geo 是否已就绪；
/// 2. 未就绪则 `config.generate` 拿到含 geo 规则的配置；
/// 3. 对每个资产拉取 `<url>.sha256sum`（Rust 下载器**拒绝**无 sha256 的资产）；
/// 4. 套上代理前缀后 `rules.reload(config, geo:{download:true, assets})`；
/// 5. [waitReady] 轮询 `rules.get().geo.status` 至 ready / failed / 超时。
///
/// 所有失败 best-effort：记录日志、返回 `false`，绝不向上抛。并发 kickoff 去重，
/// 失败后 60s 内重复调用被节流。
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:gstore/core/core.dart' show getProxy;
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/utils/unit.dart' show applyProxyIfNeeded;
import 'package:gstore/http/rhttp_adapter.dart';
import 'package:gstore/page/proxy/proxy_geo_manifest.dart';

/// 代理只读门面（生产转发 [ProxyModule] 单例；测试注入假实现）。
abstract class ProxyGeoFacade {
  /// `rules.get`：只读规则快照（含 geo 状态）。
  Future<RulesSnapshot> rulesGet();

  /// `config.generate`：渲染含 geo 规则的受控配置。
  Future<GeneratedConfig> configGenerate(GenerateRequest request);

  /// `rules.reload`：传入配置 + geo 下载请求，触发引擎下载。
  Future<RulesSnapshot> rulesReload(RulesReloadRequest request);
}

/// 校验和客户端：拉取 `<assetUrl>.sha256sum` 并解析首个 64-hex；失败返回 `null`。
abstract class ProxyGeoChecksumClient {
  /// 返回 [assetUrl] 对应文件的 sha256（小写/大写均可，Rust 侧忽略大小写）。
  Future<String?> fetchSha256(String assetUrl);
}

/// geo provisioning 编排器。
class ProxyGeoProvisioner {
  ProxyGeoProvisioner({
    required ProxyGeoFacade facade,
    required ProxyGeoManifest manifest,
    required ProxyGeoChecksumClient checksumClient,
    String Function()? proxyPrefix,
    DateTime Function()? clock,
    this.pollInterval = const Duration(seconds: 2),
    this.timeout = const Duration(seconds: 90),
  })  : _facade = facade,
        _manifest = manifest,
        _checksumClient = checksumClient,
        _proxyPrefix = proxyPrefix ?? getProxy,
        _clock = clock ?? DateTime.now;

  final ProxyGeoFacade _facade;
  final ProxyGeoManifest _manifest;
  final ProxyGeoChecksumClient _checksumClient;
  final String Function() _proxyPrefix;
  final DateTime Function() _clock;

  /// [waitReady] 轮询间隔。
  final Duration pollInterval;

  /// [waitReady] 默认超时。
  final Duration timeout;

  /// geo 就绪状态（Rust `geo_overall`）。
  static const String readyStatus = 'ready';

  /// geo 失败状态（Rust `geo_overall`，含 checksum_mismatch / checksum_required）。
  static const String failedStatus = 'failed';

  /// 失败后重复 kickoff 的节流窗口。
  static const Duration failureThrottle = Duration(seconds: 60);

  Future<bool>? _inflight;
  DateTime? _lastFailureAt;

  /// 快速 kickoff：探测 geo → 生成配置 → 拉校验和 → 触发下载。
  ///
  /// 返回 `true` 表示「geo 已就绪」或「下载已成功触发」。任何失败返回 `false`，
  /// 绝不抛异常。并发调用复用同一 in-flight Future；失败后 [failureThrottle] 内
  /// 的重复调用（非 [force]）被直接拒绝。
  Future<bool> kickoff({String? profileId, bool force = false}) {
    final inflight = _inflight;
    if (inflight != null) return inflight;

    final lastFailure = _lastFailureAt;
    if (!force &&
        lastFailure != null &&
        _clock().difference(lastFailure) < failureThrottle) {
      debugPrint('ProxyGeoProvisioner: kickoff 节流（距上次失败 < 60s）');
      return Future<bool>.value(false);
    }

    final future = _doKickoff(profileId: profileId, force: force);
    _inflight = future;
    return future.whenComplete(() {
      _inflight = null;
    });
  }

  /// 轮询 `rules.get().geo.status` 直到 ready/failed/超时。
  ///
  /// * ready → `true`
  /// * failed → `false`
  /// * 超时（或 [rulesGet] 持续异常）→ `false`
  Future<bool> waitReady({Duration? timeout}) async {
    final limit = timeout ?? this.timeout;
    final start = _clock();
    final deadline = start.add(limit);

    while (true) {
      try {
        final snapshot = await _facade.rulesGet();
        final status = snapshot.geo.status;
        if (status == readyStatus) return true;
        if (status == failedStatus) return false;
      } catch (error) {
        debugPrint('ProxyGeoProvisioner: waitReady 轮询失败 - $error');
      }

      if (!_clock().isBefore(deadline)) return false;
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<bool> _doKickoff({String? profileId, bool force = false}) async {
    try {
      final snapshot = await _facade.rulesGet();
      if (!force && snapshot.geo.status == readyStatus) {
        debugPrint('ProxyGeoProvisioner: geo 已就绪，跳过下载');
        return true;
      }

      final generated = await _facade.configGenerate(
        GenerateRequest(profileId: profileId),
      );

      final proxy = _proxyPrefix().trim();
      final assets = <String, Map<String, String>>{};
      for (final asset in _manifest.assets) {
        final sha = await _checksumClient.fetchSha256(asset.url);
        final normSha = sha?.trim();
        if (normSha == null || normSha.isEmpty) {
          debugPrint('ProxyGeoProvisioner: 跳过 ${asset.file}（sha256 不可用）');
          continue;
        }
        assets[asset.file] = <String, String>{
          'url': applyProxyIfNeeded(asset.url, proxy),
          'sha256': normSha,
        };
      }

      if (assets.isEmpty) {
        debugPrint('ProxyGeoProvisioner: 无可下载资产，放弃');
        _markFailure();
        return false;
      }

      await _facade.rulesReload(
        RulesReloadRequest(
          config: generated.config,
          geo: <String, dynamic>{
            'download': true,
            'assets': assets,
          },
        ),
      );
      debugPrint('ProxyGeoProvisioner: 已触发 geo 下载（${assets.length} 个资产）');
      return true;
    } catch (error, stack) {
      debugPrint('ProxyGeoProvisioner: kickoff 失败 - $error\n$stack');
      _markFailure();
      return false;
    }
  }

  void _markFailure() {
    _lastFailureAt = _clock();
  }
}

/// 生产校验和客户端：经 app 既有 Dio(rhttp/curl) 传输栈拉取 `<url>.sha256sum`。
///
/// 请求 URL 会套上代理前缀（[applyProxyIfNeeded] 幂等）；失败一律返回 `null`，
/// 绝不抛异常。可注入 [Dio] / 代理提供者便于测试。
class DioProxyGeoChecksumClient implements ProxyGeoChecksumClient {
  DioProxyGeoChecksumClient({
    Dio? dio,
    String Function()? proxyPrefix,
    this.timeout = const Duration(seconds: 20),
  })  : _dio = dio ?? _rhttpDio(),
        _proxyPrefix = proxyPrefix ?? getProxy;

  final Dio _dio;
  final String Function() _proxyPrefix;
  final Duration timeout;

  static const String _userAgent = 'GStore-App/1.0';

  static Dio _rhttpDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 20),
        sendTimeout: const Duration(seconds: 30),
      ),
    )..httpClientAdapter = RhttpAdapter(allowBadCertificate: true);
    return dio;
  }

  @override
  Future<String?> fetchSha256(String assetUrl) async {
    final target =
        applyProxyIfNeeded('$assetUrl.sha256sum', _proxyPrefix().trim());
    try {
      final response = await _dio.get<String>(
        target,
        options: Options(
          responseType: ResponseType.plain,
          receiveTimeout: timeout,
          headers: const <String, String>{'User-Agent': _userAgent},
          validateStatus: (code) => code != null && code >= 200 && code < 300,
        ),
      );
      final body = response.data;
      if (body == null) return null;
      final match = RegExp(r'[0-9a-fA-F]{64}').firstMatch(body);
      return match?.group(0);
    } catch (error) {
      debugPrint('DioProxyGeoChecksumClient: 获取 sha256 失败 ($assetUrl) - $error');
      return null;
    }
  }
}

/// Core bootstrap: one idempotent, non-fatal hand-off of platform facts and the
/// installed-app inventory to the Rust core.
///
/// Boundary (plan Decision 1/6): the core never queries the platform. The
/// Flutter app collects `PlatformFacts` + `InventorySnapshot` from the Android
/// side (`gstore/platform`, Todo 4) and pushes them in before any
/// `UpdateApi` / `InstallApi` use. This file owns that one-time push.
///
/// Why a separate file (plan Decision 10): the facades lazily create their own
/// `UpdateApi` / `InstallApi` handles, so the push must happen in the startup
/// sequence, not inside either facade. `lib/main.dart` awaits [start] right
/// after `WidgetsFlutterBinding.ensureInitialized()`; a failure is logged and
/// leaves [ready] `false` so the update/install UI can degrade instead of
/// crashing the app.
library;

import 'dart:io';

import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, kDebugMode, visibleForTesting;

import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/logger/LogManager.dart' show appLog;
import 'package:gstore/core/catalog/catalog_seed_bootstrap.dart';
import 'package:gstore/core/design/app_dialogs.dart';
import 'package:gstore/core/migration/cutover_paths.dart';
import 'package:gstore/core/platform/platform_channel.dart';
import 'package:gstore/core/rust/CoreApiFacade.dart';
import 'package:gstore/core/rust/core_cutover.dart';
import 'package:gstore/core/rust/core_cutover_backend.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/service/localdb_gstore_cleanup.dart';
import 'package:gstore/core/service/localdb_gstore_migration.dart';

/// Inventory/facts source identity pinned by the plan (`android_frontend`).
const String kCoreSourceId = 'android_frontend';

/// Narrow seam over the FRB `CoreApi` handle: init + the two pushes.
///
/// Tests inject a fake so the bootstrap needs no native library.
abstract class CoreBootstrapBackend {
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  });

  Future<void> pushPlatformFacts(rust.PlatformFactsDto facts);

  Future<rust.InventoryPushResultDto> pushInventory(
    rust.InventorySnapshotDto snapshot,
  );
}

/// Production backend over [CoreApiFacade] (which owns `RustLib.init` +
/// `LegacyWriteGuard` binding).
class FrbCoreBootstrapBackend implements CoreBootstrapBackend {
  rust.CoreApi? _api;

  @override
  Future<void> init({
    required String dataDir,
    required String filesDir,
    required String cacheDir,
  }) async {
    _api = await CoreApiFacade.init(
      dataDir: dataDir,
      filesDir: filesDir,
      cacheDir: cacheDir,
    );
  }

  rust.CoreApi get _handle {
    final api = _api;
    if (api == null) {
      throw StateError('CoreBootstrapBackend.init must run before any push');
    }
    return api;
  }

  @override
  Future<void> pushPlatformFacts(rust.PlatformFactsDto facts) =>
      _handle.pushPlatformFacts(facts: facts);

  @override
  Future<rust.InventoryPushResultDto> pushInventory(
    rust.InventorySnapshotDto snapshot,
  ) =>
      _handle.pushInventory(snapshot: snapshot);
}

/// Platform probe seam: the two reads the bootstrap needs.
abstract class CorePlatformProbe {
  Future<Map<String, Object?>> deviceInfo();

  Future<List<Map<String, Object?>>> listInstalled();
}

/// Production probe over `gstore/platform` ([PlatformChannelClient]).
class ChannelCorePlatformProbe implements CorePlatformProbe {
  ChannelCorePlatformProbe({PlatformChannelClient? client})
      : _client = client ?? PlatformChannelClient();

  final PlatformChannelClient _client;

  @override
  Future<Map<String, Object?>> deviceInfo() => _client.deviceInfo();

  @override
  Future<List<Map<String, Object?>>> listInstalled() => _client.listInstalled();
}

/// One-shot core bootstrap.
///
/// * [start] is single-flight and idempotent: once [ready] is true it is a
///   no-op, and concurrent callers share the same run.
/// * A failure is **non-fatal**: it is logged and [ready] stays false, so the
///   app still starts with the legacy paths (flags stay false).
class CoreBootstrap {
  CoreBootstrap._();

  static bool _ready = false;
  static Future<void>? _pending;
  static int _lastSeq = 0;

  static CoreBootstrapBackend? _backendOverride;
  static CorePlatformProbe? _probeOverride;
  static CoreCutoverBackend? _cutoverOverride;
  static int Function() _nowMillis = _defaultNowMillis;
  static String? _osOverride;
  static (String, String, String)? _dirsOverride;
  static String? _legacyDirOverride;

  /// Whether the facts + inventory push completed successfully.
  static bool get ready => _ready;

  /// Runs the bootstrap once. Never throws.
  static Future<void> start() {
    if (_ready) return Future<void>.value();
    final pending = _pending;
    if (pending != null) return pending;
    final future = _run();
    _pending = future;
    return future;
  }

  /// Test-only: inject the backend/probe/clock (and the `os` label, which the
  /// host cannot infer off-device).
  @visibleForTesting
  static void debugConfigure({
    CoreBootstrapBackend? backend,
    CorePlatformProbe? probe,
    CoreCutoverBackend? cutover,
    int Function()? nowMillis,
    String? os,
    (String, String, String)? dirs,
    String? legacyDir,
  }) {
    _backendOverride = backend;
    _probeOverride = probe;
    _cutoverOverride = cutover;
    _nowMillis = nowMillis ?? _defaultNowMillis;
    _osOverride = os;
    _dirsOverride = dirs;
    _legacyDirOverride = legacyDir;
  }

  /// Test-only: clear readiness, the in-flight future and every injected seam.
  @visibleForTesting
  static void reset() {
    _ready = false;
    _pending = null;
    _lastSeq = 0;
    _backendOverride = null;
    _probeOverride = null;
    _cutoverOverride = null;
    _nowMillis = _defaultNowMillis;
    _osOverride = null;
    _dirsOverride = null;
    _legacyDirOverride = null;
  }

  static Future<void> _run() async {
    // 分段计时（只加日志，不改顺序/逻辑）：把 ~700ms 的自举拆成可归因的步骤，
    // 便于下一次优化按数据下刀。
    Future<T> timed<T>(String step, Future<T> Function() run) async {
      final sw = Stopwatch()..start();
      try {
        return await run();
      } finally {
        appLog.info(
          '⏱️ core-bootstrap: $step elapsedMs=${sw.elapsedMilliseconds}',
        );
      }
    }

    try {
      final dirs = await timed('dirs', _resolveDirs);
      final backend = _backendOverride ?? FrbCoreBootstrapBackend();
      final probe = _probeOverride ?? ChannelCorePlatformProbe();

      await timed(
        'backend-init',
        () => backend.init(
          dataDir: dirs.$1,
          filesDir: dirs.$2,
          cacheDir: dirs.$3,
        ),
      );

      // Pull the Rust-owned flag snapshot before any consumer reads it. A flag
      // failure is non-fatal: the mirror keeps its last (all-false) value and
      // the legacy paths stay in charge, exactly like every other bootstrap
      // failure (see the catch below).
      try {
        await timed('flags', CoreFlags.refresh);
      } catch (error) {
        debugPrint('[CoreBootstrap] 读取特性开关失败（保持镜像原值）: $error');
      }

      final device = await timed('device-info', probe.deviceInfo);
      final apps = await timed('list-installed', probe.listInstalled);
      final capturedAt = _nowMillis();

      await timed(
        'push-facts',
        () => backend.pushPlatformFacts(
          _buildFacts(dirs: dirs, device: device, capturedAt: capturedAt),
        ),
      );
      await timed(
        'push-inventory',
        () => backend.pushInventory(
          rust.InventorySnapshotDto(
            sourceId: kCoreSourceId,
            seq: _nextSeq(capturedAt),
            capturedAt: capturedAt,
            apps: <rust.InstalledAppDto>[
              for (final app in apps)
                if (_installedApp(app) case final dto?) dto,
            ],
          ),
        ),
      );

      // Durable one-time closeout, after facts + inventory so the `update`
      // resync has a real inventory to judge against. A failure is non-fatal
      // and leaves `cutover_v6.done` absent, so the next launch retries.
      //
      // An injected bootstrap backend is a test seam; the production cutover is
      // only armed with the production backend unless a cutover seam is passed
      // explicitly (same convention as `UpdateFacade`'s `_frbInjected`).
      await timed('cutover', () async {
        final cutover = _cutoverOverride ??
            (_backendOverride == null
                ? FrbCoreCutoverBackend(
                    paths: await CutoverPaths.resolve(
                      dirs: dirs,
                      legacyRoot: _legacyDirOverride,
                    ),
                    dataDir: dirs.$1,
                    cacheDir: dirs.$3,
                  )
                : null);
        if (cutover != null) {
          try {
            final result = await CoreCutover.run(
              filesDir: dirs.$2,
              backend: cutover,
              nowMillis: _nowMillis,
            );
            debugPrint('[CoreBootstrap] 一次性切流: $result');
          } catch (error) {
            // Never fatal: the marker was not written, so the next launch retries.
            debugPrint('[CoreBootstrap] 一次性切流失败（下次启动重试）: $error');
          }
        }
      });

      // 随包 catalog seed：写 `<files_dir>/catalog_seed.db`，交给 Rust 校验 +
      // 内容寻址去重（repoEnsureSeed），并按需物化进 core catalog
      // （repoMaterialize）。失败在 ensure 内部已捕获，永不阻塞启动。
      //
      // 与 cutover 相同的测试约定：注入的 bootstrap backend 是测试 seam，
      // 只有生产 backend 才真正跑 seed 自举。
      if (_backendOverride == null) {
        await timed(
          'catalog-seed',
          () => CatalogSeedBootstrap.ensure(filesDir: dirs.$2),
        );
      }

      _ready = true;
    } catch (error, stackTrace) {
      debugPrint('[CoreBootstrap] 核心自举失败（降级继续启动）: $error');
      if (kDebugMode) {
        debugPrint('[CoreBootstrap] stack: $stackTrace');
      }
    } finally {
      _pending = null;
    }
  }

  /// 运行「需要导航已挂载」的一次性迁移。
  ///
  /// `local_db → gstore` 迁移在 UI 上展示不可取消的进度框，而
  /// [AppDialogs.showProgress] 依赖 `appNavigatorKey`；`main()` 在 `runApp`
  /// 之前 await 了 [start]，此时没有 navigator，进度框会被静默跳过。因此该
  /// 迁移改由 [main] 在首帧后调用本方法执行（生产 backend 才会真正跑）。
  ///
  /// 先执行修复后的迁移（只移动既有 `added_apps('local_db')` 成员），再执行
  /// 一次性清理（移除历史缺陷误加入 `gstore` 的应用；危险操作需用户确认）。
  /// 失败非致命：内部已吞错，这里再兜一层，绝不影响已启动的 UI。
  static Future<void> runDeferredMigrations() async {
    if (_backendOverride != null) return;
    if (!_ready) return;
    await _runLocalDbMigration();
    await _runLocalDbCleanup();
  }

  /// 一次性 `local_db` → `gstore` 迁移，带不可取消的进度遮罩。
  ///
  /// navigator 尚未挂载时 [AppDialogs.showProgress] / [AppDialogs.dismissLoading]
  /// 静默跳过；迁移本身失败也绝不阻塞启动。
  static Future<void> _runLocalDbMigration() async {
    final progress = ValueNotifier<({int done, int total, String message})>(
      (done: 0, total: 0, message: '正在迁移本地库数据…'),
    );
    AppDialogs.showProgress(progress: progress);
    try {
      final report = await LocalDbGStoreMigration.run(
        onProgress: (done, total) => progress.value = (
          done: done,
          total: total,
          message: '正在迁移本地库数据…',
        ),
      );
      debugPrint('[CoreBootstrap] local_db → gstore 迁移: $report');
    } catch (error) {
      debugPrint('[CoreBootstrap] local_db → gstore 迁移失败（不影响启动）: $error');
    } finally {
      AppDialogs.dismissLoading();
      progress.dispose();
    }
  }

  /// 一次性清理：移除历史缺陷误加入 `gstore` 的应用（确认 + 确定进度）。
  ///
  /// 合法集来自迁移前 Rust 自动备份（`<data_dir>/gstore_core.db.bak-v4-*`），
  /// 因此绝不会误删用户真正添加的应用；`local_db` 与目录库从不改动。
  static Future<void> _runLocalDbCleanup() async {
    try {
      final dirs = await _resolveDirs();
      final report = await LocalDbGStoreCleanup.run(dataDir: dirs.$1);
      debugPrint('[CoreBootstrap] gstore 错误数据清理: $report');
    } catch (error) {
      debugPrint('[CoreBootstrap] gstore 错误数据清理失败（不影响启动）: $error');
    }
  }

  static rust.PlatformFactsDto _buildFacts({
    required (String, String, String) dirs,
    required Map<String, Object?> device,
    required int capturedAt,
  }) {
    final abis = _asStringList(device['abis']);
    return rust.PlatformFactsDto(
      sourceId: kCoreSourceId,
      os: _osOverride ??
          (Platform.isAndroid ? 'android' : Platform.operatingSystem),
      arch: _archFrom(abis),
      abis: abis,
      sdk: _asInt(device['sdk_int']) ?? 0,
      device: rust.DeviceFactsDto(
        model: _asString(device['model']) ?? '',
        manufacturer: _asString(device['manufacturer']) ?? '',
      ),
      paths: rust.CorePathsDto(
        data: dirs.$1,
        files: dirs.$2,
        cache: dirs.$3,
      ),
      // No existing core-scoped Keystore key: the webdav/debug secret stores are
      // unrelated domains, and inventing one here would be a new scheme.
      cryptoKey: null,
      // The crate clock is MILLISECONDS (facts::PlatformFacts::captured_at).
      capturedAt: capturedAt,
    );
  }

  /// Maps one `InventoryInspector.installedAppJson` entry; a payload without a
  /// package name is skipped (malformed input never crashes the bootstrap).
  static rust.InstalledAppDto? _installedApp(Map<String, Object?> app) {
    final packageName = _asString(app['package_name']);
    if (packageName == null) return null;
    return rust.InstalledAppDto(
      packageName: packageName,
      appName: _asString(app['app_name']),
      versionName: _asString(app['version_name']) ?? '',
      versionCode: _asInt(app['version_code']) ?? 0,
      signatureSha256: _asString(app['signature_sha256']),
      sourceDir: _asString(app['source_dir']),
      installer: _asString(app['installer']),
      isSystem: _asBool(app['is_system']),
      targetSdk: _asInt(app['target_sdk']) ?? 0,
      minSdk: _asInt(app['min_sdk']) ?? 0,
      abis: _asStringList(app['abis']),
    );
  }

  /// `seq` is a monotonic millisecond stamp: the plan allows persisted state or
  /// ms, and same-ms pushes would otherwise be dropped as `unchanged`.
  static int _nextSeq(int nowMs) {
    _lastSeq = nowMs > _lastSeq ? nowMs : _lastSeq + 1;
    return _lastSeq;
  }

  static Future<(String, String, String)> _resolveDirs() async {
    final override = _dirsOverride;
    if (override != null) return override;
    return CutoverPaths.defaultCoreDirs();
  }

  static int _defaultNowMillis() => DateTime.now().millisecondsSinceEpoch;

  static String _archFrom(List<String> abis) {
    if (abis.isEmpty) return _platformFallbackArch();
    final first = abis.first;
    if (first.contains('arm64') && first.contains('v8a')) return 'arm64-v8a';
    if (first.contains('armeabi-v7a')) return 'armeabi-v7a';
    if (first.contains('x86_64')) return 'x86_64';
    if (first.contains('x86')) return 'x86';
    return first;
  }

  static String _platformFallbackArch() {
    switch (Platform.operatingSystem) {
      case 'android':
        return 'arm64-v8a';
      case 'macos':
        return 'macos';
      default:
        return 'x86_64';
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String? _asString(Object? value) {
    if (value is! String) return null;
    return value.isEmpty ? null : value;
  }

  static bool _asBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final text = value.trim().toLowerCase();
      return text == 'true' || text == '1';
    }
    return false;
  }

  static List<String> _asStringList(Object? value) {
    if (value is! List) return const <String>[];
    return <String>[
      for (final item in value)
        if (item is String) item,
    ];
  }
}

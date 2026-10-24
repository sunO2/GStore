import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/core_download_builder.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/download_module_unavailable_exception.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// [IDownloadService] 的 **Rust 内核实现**。
///
/// 这是 [`DownloadFacade`] 之上的薄 Dart 适配层：参数整形、结果映射与
/// `DownloadTask` 模型转换。**没有任何 module-direct 分支**——所有启动、
/// 查询、变更、事件都经 [DownloadFacade] 走宿主创建的核心实例，因此不存在
/// "模块实例 / 核心实例" 两套状态混跑。
///
/// 边界（明确不做的事，避免出现"看起来能用"的静默空实现）：
/// - **不负责 APK 安装**：`installAfterDownload` 由 Dart 侧既有安装流程处理，
///   本实现只在请求时记录并告警，不假装已支持。
/// - **不负责通知/前台保活**：进程级前台服务不属于这层。
///
/// 模块不可用（未打包 / ABI 不符 / 挂载失败）由 [DownloadFacade] 统一映射成
/// `DownloadModuleUnavailableException`（`CORE_E_DOWNLOAD_MODULE_UNAVAILABLE`）；
/// 下载只有 Rust 一个实现，**绝不静默回落到 Dart**。
class RustDownloadService implements IDownloadService {
  RustDownloadService._();

  static final RustDownloadService instance = RustDownloadService._();

  /// 模块名（对应 `libgstore_mod_download.so`）
  static const String moduleName = 'download';

  /// Memoized one-shot gate: mount the `download` module, then import legacy.
  ///
  /// Every core entry point (start, read, watch, pause/resume/...) must wait
  /// for this before touching the core database, otherwise a fresh core DB
  /// looks empty until the first download is started — **and** the host
  /// `HostDownloadPort` cannot resolve the native module.
  Future<void>? _coreReady;

  Future<void> _ensureCoreReady() =>
      _coreReady ??= _mountModuleThenImportLegacy();

  /// Ensures the Rust `download` module is installed+mounted, then runs the
  /// one-shot legacy import.
  ///
  /// The mount **must** precede every core read/start: [DownloadModule.onRegister]
  /// binds [IDownloadService] to this Rust-only service with no Dart fallback,
  /// but the host `HostDownloadPort` resolves the native module by name
  /// (`module_id_by_name("download")`) and returns
  /// `CORE_E_DOWNLOAD_MODULE_UNAVAILABLE` when it was never mounted. Mirroring
  /// the qr/repo consumers ([ModuleBootstrap.acquire]), we mount it on first use.
  ///
  /// [acquire] (not bare `ensureOnly`) is deliberate: `ensureOnly` leaves the
  /// observable phase at `downloading` (it publishes no terminal state), which
  /// the app-wide `ModuleInstallBanner` would render forever. `acquire` drives
  /// `initializing → ready`, so the banner clears. It never awaits a path the
  /// ensure itself needs, so it cannot deadlock.
  Future<void> _mountModuleThenImportLegacy() async {
    await _ensureDownloadModule();
    try {
      await DownloadFacade.instance.importLegacyOnce();
    } catch (error) {
      // The import is best-effort by contract: it must never block a download.
      debugPrint(
          'RustDownloadService: legacy import failed (non-fatal) - $error');
    }
  }

  /// Mounts the Rust `download` module or throws the typed unavailability error.
  ///
  /// A genuinely failed acquire surfaces [DownloadModuleUnavailableException]
  /// (`CORE_E_DOWNLOAD_MODULE_UNAVAILABLE`); there is **no** Dart fallback.
  Future<void> _ensureDownloadModule() async {
    try {
      await ModuleBootstrap.instance.acquire(moduleName);
    } on ModuleInstallFailedException catch (error) {
      throw DownloadModuleUnavailableException(error);
    }
  }

  /// Test seam: forces the next path to run the import gate again.
  @visibleForTesting
  void resetCoreReadyForTest() {
    _coreReady = null;
  }

  @override
  Future<DownloadTask> download(
    String appid,
    String appName,
    String version,
    String url,
    String fileName, {
    int? downloadSize,
    bool breakPoint = true,
    String? saveFileName,
    bool forceDownload = false,
    bool installAfterDownload = true,
  }) {
    return _downloadViaCore(
      appid: appid,
      appName: appName,
      version: version,
      url: url,
      fileName: fileName,
      saveFileName: saveFileName,
      installAfterDownload: installAfterDownload,
      forceDownload: forceDownload,
    );
  }

  @override
  Future<DownloadTask> downloadWithContext(
    DownloadRequest request,
    String appid,
    String appName,
    String version,
    String fileName, {
    bool breakPoint = true,
    String? saveFileName,
    bool installAfterDownload = true,
  }) {
    // 惰性 URL 解析：取一次当前有效地址（签名 URL 过期由上层重新构造请求）
    final url = request.urlProvider?.call() ?? request.url;
    return _downloadViaCore(
      appid: appid,
      appName: appName,
      version: version,
      url: url,
      fileName: fileName,
      // savePath 声明为可空：为空时回落到与 download() 相同的目录约定
      saveFileName: request.savePath ?? saveFileName,
      installAfterDownload: installAfterDownload,
      headers: request.headers ?? const <String, String>{},
    );
  }

  /// Starts the core-owned download.
  ///
  /// The legacy import resolves before any core read/start. It is memoized and
  /// non-fatal, so a broken legacy DB can never block a new download.
  Future<DownloadTask> _downloadViaCore({
    required String appid,
    required String appName,
    required String version,
    required String url,
    required String fileName,
    String? saveFileName,
    bool installAfterDownload = false,
    bool forceDownload = false,
    Map<String, String> headers = const <String, String>{},
  }) async {
    await _ensureCoreReady();

    // An absolute save path short-circuits directory resolution; otherwise the
    // builder falls back to the app documents dir exactly like DownloadPaths.
    final docsDir = saveFileName != null && saveFileName.startsWith('/')
        ? ''
        : (await getApplicationDocumentsDirectory()).path;
    final core = await CoreDownloadBuilder.build(
      appId: appid,
      appName: appName,
      version: version,
      fileName: fileName,
      url: url,
      saveFileName: saveFileName,
      docsDir: docsDir,
      installAfterDownload: installAfterDownload,
      headers: headers,
    );

    // `forceDownload` must re-download an existing file at the same path. The
    // core start keeps an existing task (`ConflictPolicy::Keep`), so a corrupt
    // completed file would be returned forever. Restart the newest task at
    // that path instead (clears segments/progress, re-downloads from zero).
    if (forceDownload) {
      final restarted = await _restartForDest(core.destPath);
      if (restarted != null) return restarted;
    }

    final id = await DownloadFacade.instance.start(
      rust.DownloadStartRequest(
        appId: core.appId,
        appName: core.appName,
        version: core.version,
        fileName: core.fileName,
        url: core.url,
        destPath: core.destPath,
        kind: core.kind,
        resourceId: core.resourceId,
        resourceVersion: core.resourceVersion,
        dedupKey: core.dedupKey,
        expectedSha256: core.expectedSha256,
        installAfterDownload: core.installAfterDownload,
        headers: core.headers,
      ),
    );
    final dto = await DownloadFacade.instance.get(id.toString());
    if (dto == null) {
      throw StateError(
          'RustDownloadService: core task $id not found after start');
    }
    return toDownloadTask(dto);
  }

  /// Returns the restarted task when a core row already occupies [destPath].
  Future<DownloadTask?> _restartForDest(String destPath) async {
    final matches = (await DownloadFacade.instance.list())
        .where((dto) => dto.destPath == destPath)
        .toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (matches.isEmpty) return null;

    final newest = matches.last;
    final key = newest.moduleTaskId ?? newest.id.toString();
    await DownloadFacade.instance.restart(key);
    final refreshed = await DownloadFacade.instance.get(key);
    if (refreshed == null) {
      throw StateError(
          'RustDownloadService: core task $key not found after restart');
    }
    return toDownloadTask(refreshed);
  }

  @override
  Future<void> pause(int id) async {
    await _ensureCoreReady();
    await DownloadFacade.instance.pause(id.toString());
  }

  @override
  Future<void> resume(int id) async {
    await _ensureCoreReady();
    await DownloadFacade.instance.resume(id.toString());
  }

  @override
  Future<void> cancel(int id) async {
    await _ensureCoreReady();
    await DownloadFacade.instance.cancel(id.toString());
  }

  @override
  Future<void> retry(int id) async {
    await _ensureCoreReady();
    await DownloadFacade.instance.retry(id.toString());
  }

  @override
  Future<void> restart(int id) async {
    await _ensureCoreReady();
    await DownloadFacade.instance.restart(id.toString());
  }

  /// 删除任务（含落盘文件）。
  @override
  Future<void> remove(int id) async {
    await _ensureCoreReady();
    await DownloadFacade.instance.remove(id.toString());
  }

  @override
  Future<DownloadTask?> getTask(int id) async {
    await _ensureCoreReady();
    final dto = await DownloadFacade.instance.get(id.toString());
    return dto == null ? null : toDownloadTask(dto);
  }

  /// 列出任务（可选按状态索引过滤）。面板展示列表时用。
  @override
  Future<List<DownloadTask>> listTasks(
      {List<DownloadStatusEnum>? statuses}) async {
    await _ensureCoreReady();
    final tasks = (await DownloadFacade.instance.list())
        .map(toDownloadTask)
        .toList(growable: false);
    if (statuses == null) return tasks;
    return tasks
        .where((t) => statuses.contains(t.status))
        .toList(growable: false);
  }

  /// 全局任务流：**不过滤 id**，供通知栏 / 自动安装统一消费。
  ///
  /// 唯一事件源是 [DownloadFacade.watchAll]（核心广播流）；不再合并 Dart /
  /// 模块事件总线，因此不会出现双份进度或旧模块残留事件。
  @override
  Stream<DownloadTask> watchAll() async* {
    // Import resolves before the core stream is created, so reconnecting to
    // an in-progress legacy task does not emit an empty first snapshot.
    await _ensureCoreReady();
    yield* DownloadFacade.instance.watchAll().map(toDownloadTask);
  }

  @override
  Stream<DownloadTask> watch(int id) async* {
    await _ensureCoreReady();
    // 与 watchAll 共用同一个核心事件源，按 id 过滤；单次调用只订阅一次。
    await for (final dto in DownloadFacade.instance.watchAll()) {
      final task = toDownloadTask(dto);
      if (task.id == id) yield task;
    }
  }
}

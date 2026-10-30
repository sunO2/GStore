import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/core_download_builder.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/download_module_unavailable_exception.dart';
import 'package:gstore/core/download/download_task_watcher.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/download_push_stream.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/module/module_manager.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/download/DownloadEventSource.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;
import 'package:gstore/core/rust/generated/event_bridge.dart' show ModuleEvent;

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
  /// `CORE_E_DOWNLOAD_MODULE_UNAVAILABLE` when it was never mounted.
  ///
  /// Here we only **mount** the module ([ModuleBootstrap.ensureMounted]) because
  /// the host (`HostDownloadPort::with_port`) creates the single instance with the
  /// core-owned directories (`files/gstore_core/data/gstore_mods/download`).
  /// Acquiring a Dart-side instance would duplicate it: two data dirs → two DBs,
  /// each running its own restart recovery, with tasks invisible across the two
  /// lanes. `ensureMounted` (rather than bare `ensureOnly`) still publishes the
  /// terminal `ready` so the app-wide `ModuleInstallBanner` clears.
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
  /// A genuinely failed mount (ensure reports `false` or throws
  /// [ModuleInstallFailedException]) surfaces [DownloadModuleUnavailableException]
  /// (`CORE_E_DOWNLOAD_MODULE_UNAVAILABLE`); there is **no** Dart fallback.
  Future<void> _ensureDownloadModule() async {
    try {
      final mounted = await ModuleBootstrap.instance.ensureMounted(moduleName);
      if (!mounted) {
        throw DownloadModuleUnavailableException();
      }
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
    // directory MUST live inside the FileProvider `<files-path>` root, because
    // the system install intent is built with FileProvider.getUriForFile and a
    // path outside that root throws, so no installer UI ever appears. App
    // support (/data/user/0/<pkg>/files) is covered; app documents
    // (app_flutter) is NOT.
    final docsDir = saveFileName != null && saveFileName.startsWith('/')
        ? ''
        : (await getApplicationSupportDirectory()).path;
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

    // 首次真实入队即绑定全局 watcher（通知 + 自动安装）；同一实现重复调用为空操作。
    // 冷启动不再于模块注册时启动它，这里就是「真的有下载了」的第一个触发点。
    // 仅在下载服务已由模块注册表绑定时启动：未注册模块的裸服务（测试/工具）不需要
    // 通知与自动安装，避免平白多出一条全局 watchAll 订阅。
    if (ModuleManager.instance.get<IDownloadService>() != null) {
      DownloadTaskWatcher.instance.start(this);
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

  /// 全局任务流：**由下载模块推送事件驱动**，不再 500ms 轮询。
  ///
  /// 唯一实时事件源是下载模块经 `emit_event` 上广播总线的事件
  /// （`download.progress` / `download.done`，载荷带 `taskId`），Dart 侧按
  /// `taskId` 解复用；订阅时先做一次权威核心行快照当种子，另有慢速安全网
  /// （仅在有活跃任务时）兜底漏事件。**不合并** [DownloadFacade.watchAll] 的
  /// 500ms 轮询流，因此同一 tick 不会出现双份进度。
  @override
  Stream<DownloadTask> watchAll() async* {
    await _ensureCoreReady();
    yield* DownloadPushStream(
      lane: downloadEventLane(),
      loadAll: listTasks,
      fetchOne: getTask,
      safetyInterval: downloadSafetyNetInterval,
    ).tasks();
  }

  @override
  Stream<DownloadTask> watch(int id) async* {
    await _ensureCoreReady();
    // 与 watchAll 共用同一个推送事件源，按 id 过滤；单次调用只订阅一次。
    yield* watchAll().where((task) => task.id == id);
  }

  /// 推送事件源接缝：生产读下载模块在宿主事件总线上的 lane；测试可替换。
  @visibleForTesting
  static Stream<ModuleEvent> Function()? downloadEventLaneOverride;

  /// 慢速安全网间隔（仅在有活跃任务时触发一次全量对账）。
  @visibleForTesting
  static Duration downloadSafetyNetInterval = const Duration(seconds: 4);

  /// 下载模块事件 lane（默认经 [DownloadEventSource] 读宿主总线）。
  static Stream<ModuleEvent> downloadEventLane() =>
      (downloadEventLaneOverride ?? () => DownloadEventSource.events)();

  /// 测试专用：清空推送接缝覆盖。
  @visibleForTesting
  static void debugResetPushSeams() {
    downloadEventLaneOverride = null;
    downloadSafetyNetInterval = const Duration(seconds: 4);
  }
}

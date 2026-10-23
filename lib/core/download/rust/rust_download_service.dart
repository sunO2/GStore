import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:gstore/core/core_flags.dart';
import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/core_download_builder.dart';
import 'package:gstore/core/download/download_module_unavailable_exception.dart';
import 'package:gstore/core/download/download_facade.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_mapper.dart';
import '../download_paths.dart';
import 'package:gstore/core/config/config_manager.dart';
import 'package:gstore/core/config/providers/download_config_provider.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/rust/ModuleBootstrap.dart';
import 'package:gstore/core/rust/ModuleManager.dart';
import 'package:gstore/core/rust/generated/bridge.dart' as rust;

/// [IDownloadService] 的 **Rust 内核实现**：把任务管理与传输交给
/// `gstore_mod_download` 模块，Dart 侧只做参数整形、结果映射与事件解复用。
///
/// 边界（明确不做的事，避免出现"看起来能用"的静默空实现）：
/// - **不负责 APK 安装**：`installAfterDownload` 由 Dart 侧既有安装流程处理，
///   本实现只在请求时记录并告警，不假装已支持。
/// - **不负责通知/前台保活**：模块是按需加载的 `.so`，无法拥有前台服务。
///
/// 事件回路：内核自带调度器，任务不由宿主 `start_task` 拉起，因此进度经
/// **广播总线**（`moduleEvents`）上报、载荷带 `taskId`，这里按 id 解复用成每任务流。
/// 即 `rust-flutter-async.md` §七 的「形态 B」，未新造机制。
class RustDownloadService implements IDownloadService {
  RustDownloadService._();

  static final RustDownloadService instance = RustDownloadService._();

  /// 模块名（对应 `libgstore_mod_download.so`）
  static const String moduleName = 'download';

  /// 进度/终态事件类型（内核 emit_event 的 type）
  static const String _evProgress = 'download.progress';
  static const String _evDone = 'download.done';

  /// 确保模块经门自举并取得实例（幂等；缓存/单飞由 [ModuleBootstrap] 门持有）。
  ///
  /// [isAvailable] 与所有 `_invoke` 共用此路径：首次真实使用即触发一次门的
  /// 安装确保（on-use install），并发调用由门的两级单飞去重；失败抛出
  /// [DownloadModuleUnavailableException]（`CORE_E_DOWNLOAD_MODULE_UNAVAILABLE`）。
  ///
  /// **不显式传 `factory`**：门在未显式指定工厂时，默认即用
  /// `RustModuleInstance.createWithContext(module, handle)`（与 download 所需完全
  /// 一致），因此这里再传一个等价闭包纯属冗余——反而会以更高优先级遮蔽
  /// `ModuleBootstrap.debugConfigure(factoryOverride:)` 这一测试接缝，使 download
  /// 成为唯一无法在无 FFI 下注入假实例的门消费方。交给门默认值即可：生产行为
  /// 字节不变，测试接缝恢复可用。
  Future<RustModuleInstance> _ensureInstance() async {
    try {
      return await ModuleBootstrap.instance.acquire(moduleName);
    } on ModuleInstallFailedException catch (error) {
      // 下载内核只有 Rust 一个实现：模块不可用是**类型化失败**，不是静默回落。
      throw DownloadModuleUnavailableException(error);
    }
  }

  /// 模块是否可用（面板可据此决定是否启用新内核；不可用时不抛错）。
  ///
  /// 同时是**首次真实使用**的安装触发器：内部经门获取实例，首次调用会触发
  /// 一次安装确保（并发调用由门单飞去重）。
  Future<bool> get isAvailable async {
    try {
      await _ensureInstance();
      return true;
    } catch (e) {
      appLog.warning('RustDownloadService: 内核不可用 - $e');
      return false;
    }
  }

  /// Memoized one-shot legacy import gate.
  ///
  /// Every flag-on entry point (start, read, watch, pause/resume/...) must wait
  /// for this before touching the core database, otherwise a fresh core DB
  /// looks empty until the first download is started.
  Future<void>? _coreReady;

  Future<void> _ensureCoreReady() =>
      _coreReady ??= _importLegacyBeforeCoreRead();

  /// Reads [CoreFlags.download], refreshing a disabled mirror first.
  ///
  /// The mirror can be stale when another component armed the flag after the
  /// last read; a flag-backend failure keeps the last mirror and degrades to
  /// the legacy path (a download never fails because flags are unavailable).
  Future<bool> _downloadEnabled() async {
    if (!CoreFlags.download) {
      try {
        await CoreFlags.refresh();
      } catch (error) {
        debugPrint('RustDownloadService: 刷新 download 开关失败（保持镜像原值）: $error');
      }
    }
    return CoreFlags.download;
  }

  Future<void> _importLegacyBeforeCoreRead() async {
    try {
      await DownloadFacade.instance.importLegacyOnce();
    } catch (error) {
      // The import is best-effort by contract: it must never block a download.
      debugPrint(
          'RustDownloadService: legacy import failed (non-fatal) - $error');
    }
  }

  /// Test seam: forces the next flag-on path to run the import gate again.
  @visibleForTesting
  void resetCoreReadyForTest() {
    _coreReady = null;
  }

  /// 统一调用：JSON 入参 → JSON 出参
  Future<Object?> _invoke(String method, Map<String, Object?> payload) async {
    final inst = await _ensureInstance();
    final resp = await inst.callModule(
      method,
      Uint8List.fromList(utf8.encode(jsonEncode(payload))),
    );
    if (resp.isEmpty) return null;
    return jsonDecode(utf8.decode(resp));
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
  }) async {
    if (await _downloadEnabled()) {
      return _downloadViaCore(
        appid: appid,
        appName: appName,
        version: version,
        url: url,
        fileName: fileName,
        saveFileName: saveFileName,
        installAfterDownload: installAfterDownload,
      );
    }
    // 落盘路径必须与 Dart 实现共用同一份规则，否则换内核后文件会落到别处
    final dest = await DownloadPaths.resolveSavePath(
      saveFileName: saveFileName,
      fileName: fileName,
    );

    if (installAfterDownload) {
      // 明确不假装支持：安装仍由 Dart 侧流程负责
      appLog.info(
          'RustDownloadService: installAfterDownload 由 Dart 侧处理（内核不负责安装）');
    }

    return _start(
      kind: 'app',
      resourceId: appid,
      resourceVersion: version,
      appId: appid,
      appName: appName,
      version: version,
      fileName: fileName,
      url: url,
      dest: dest,
      // forceDownload → replace；否则交给内核判重（keep）
      installAfterDownload: installAfterDownload,
      conflict: forceDownload ? 'replace' : 'keep',
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
  }) async {
    // 惰性 URL 解析：取一次当前有效地址（签名 URL 过期由上层重新构造请求）
    final url = request.urlProvider?.call() ?? request.url;
    if (await _downloadEnabled()) {
      return _downloadViaCore(
        appid: appid,
        appName: appName,
        version: version,
        url: url,
        fileName: fileName,
        saveFileName: request.savePath ?? saveFileName,
        installAfterDownload: installAfterDownload,
      );
    }
    // savePath 声明为可空：为空时回落到与 download() 相同的目录约定
    final dest = request.savePath ??
        await DownloadPaths.resolveSavePath(
          saveFileName: saveFileName,
          fileName: fileName,
        );

    if (installAfterDownload) {
      appLog.info(
          'RustDownloadService: installAfterDownload 由 Dart 侧处理（内核不负责安装）');
    }

    return _start(
      kind: 'app',
      resourceId: appid,
      resourceVersion: version,
      appId: appid,
      appName: appName,
      version: version,
      fileName: fileName,
      url: url,
      dest: dest,
      headers: request.headers,
      installAfterDownload: installAfterDownload,
      conflict: 'keep',
    );
  }

  /// Starts the core-owned download.
  ///
  /// The host-created core instance uses the default scheduler config; the Dart
  /// settings push (`_pushConfig`) is intentionally skipped here. That prevents
  /// mixing the legacy module instance with the core-owned one (known Wave-3
  /// limitation, not a claim that settings are applied).
  Future<DownloadTask> _downloadViaCore({
    required String appid,
    required String appName,
    required String version,
    required String url,
    required String fileName,
    String? saveFileName,
    bool installAfterDownload = false,
  }) async {
    // Legacy import must resolve before any core read/start. The gate is
    // memoized and non-fatal; flag-off paths never reach this method.
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
    );
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
      ),
    );
    final dto = await DownloadFacade.instance.get(id.toString());
    if (dto == null) {
      throw StateError(
          'RustDownloadService: core task $id not found after start');
    }
    return toDownloadTask(dto);
  }

  /// 把 Dart 设置页里的下载配置下发给模块。
  ///
  /// 模块实例创建时用的是它自己的**默认值**（并发 3 / 连接 4），必须显式下发一次，
  /// 否则设置页改了并发也不会生效。放在每次建任务前调用，顺带支持热更新。
  Future<void> _pushConfig() async {
    try {
      final provider = ConfigManager.instance.providers['download_config'];
      if (provider is! DownloadConfigProvider) return;
      final multi = await provider.isMultiSegmentEnabled();
      final concurrent = await provider.getMaxConcurrentDownloads();
      await _invoke('download.config', {
        'maxConcurrent': concurrent,
        // 关闭"分段下载" → 每文件连接数压到 1，等价整文件单连接
        if (!multi) 'connections': 1,
      });
      debugPrint(
          'RustDownloadService: 配置下发 maxConcurrent=$concurrent multiSegment=$multi');
    } catch (e) {
      debugPrint('RustDownloadService: 下发下载配置失败 - $e');
    }
  }

  Future<DownloadTask> _start({
    required String kind,
    required String resourceId,
    required String resourceVersion,
    required String appId,
    required String appName,
    required String version,
    required String fileName,
    required String url,
    required String dest,
    required String conflict,
    Map<String, String>? headers,
    bool installAfterDownload = false,
  }) async {
    await _pushConfig();
    final raw = await _invoke('download.start', {
      'kind': kind,
      'resourceId': resourceId,
      'resourceVersion': resourceVersion,
      'appId': appId,
      'appName': appName,
      'version': version,
      'fileName': fileName,
      'url': url,
      'filePath': dest,
      // Rust 侧 headers 是 map：显式 null 会被 serde 判为类型错误，这里给空表
      'headers': headers ?? const <String, String>{},
      'conflict': conflict,
      // 严格判重：单源渠道（平安这类，同版本可能有多个**同名**构建）开启——
      // 撞上"同名不同源"报冲突而不是静默覆盖；镜像类源关闭，否则换镜像会被误判。
      // TODO 改为由各下载策略显式声明身份语义（当前按 URL 判定，够用但不够优雅）
      'strictDedup': !url.toLowerCase().contains('fdroid'),
      'installAfterDownload': installAfterDownload,
    });

    if (raw is! Map<String, dynamic>) {
      throw StateError('RustDownloadService: download.start 返回异常 - $raw');
    }
    return RustDownloadMapper.fromDto(raw);
  }

  @override
  Future<void> pause(int id) async => _coreOp(
        isEnabled: await _downloadEnabled(),
        core: () => DownloadFacade.instance.pause(id.toString()),
        legacy: () => _op('download.pause', id),
      );

  @override
  Future<void> resume(int id) async => _coreOp(
        isEnabled: await _downloadEnabled(),
        core: () => DownloadFacade.instance.resume(id.toString()),
        legacy: () => _op('download.resume', id),
      );

  @override
  Future<void> cancel(int id) async => _coreOp(
        isEnabled: await _downloadEnabled(),
        core: () => DownloadFacade.instance.cancel(id.toString()),
        legacy: () => _op('download.cancel', id),
      );

  @override
  Future<void> retry(int id) async => _coreOp(
        isEnabled: await _downloadEnabled(),
        core: () => DownloadFacade.instance.retry(id.toString()),
        legacy: () => _op('download.retry', id),
      );

  @override
  Future<void> restart(int id) async => _coreOp(
        isEnabled: await _downloadEnabled(),
        core: () => DownloadFacade.instance.restart(id.toString()),
        legacy: () => _op('download.restart', id),
      );

  Future<void> _coreOp({
    required bool isEnabled,
    required Future<void> Function() core,
    required Future<void> Function() legacy,
  }) async {
    if (!isEnabled) {
      await legacy();
      return;
    }
    await _ensureCoreReady();
    await core();
  }

  Future<void> _op(String method, int id) async {
    // 诊断：确认按钮实际走到了哪个模块方法
    // （resume 不该刷新"最后开始时间"，若这里打的是 retry/restart 就说明分发错了）
    debugPrint('RustDownloadService.op: $method id=$id');
    await _invoke(method, {'id': id});
  }

  @override
  Future<DownloadTask?> getTask(int id) async {
    if (await _downloadEnabled()) {
      await _ensureCoreReady();
      final dto = await DownloadFacade.instance.get(id.toString());
      return dto == null ? null : toDownloadTask(dto);
    }
    final raw = await _invoke('download.get', {'id': id});
    if (raw is! Map<String, dynamic>) return null;
    return RustDownloadMapper.fromDto(raw);
  }

  /// 列出任务（可选按状态索引过滤）。面板展示列表时用。
  Future<List<DownloadTask>> listTasks(
      {List<DownloadStatusEnum>? statuses}) async {
    if (await _downloadEnabled()) {
      await _ensureCoreReady();
      final tasks = (await DownloadFacade.instance.list())
          .map(toDownloadTask)
          .toList(growable: false);
      if (statuses == null) return tasks;
      return tasks
          .where((t) => statuses.contains(t.status))
          .toList(growable: false);
    }
    final raw = await _invoke('download.list', {
      if (statuses != null) 'statuses': [for (final s in statuses) s.index],
    });
    return RustDownloadMapper.fromDtoList(raw);
  }

  /// 删除任务（含落盘文件），模块侧 `download.remove`
  @override
  Future<void> remove(int id) async => _coreOp(
        isEnabled: await _downloadEnabled(),
        core: () => DownloadFacade.instance.remove(id.toString()),
        legacy: () => _op('download.remove', id),
      );

  /// 全局任务流：**不过滤 id**，供通知栏 / 自动安装统一消费。
  ///
  /// 进度事件只带变化字段，所以要按 taskId 维护一份"全量基底"再合并，
  /// 否则消费方拿到的任务会缺 url / 路径 / 应用名。
  @override
  Stream<DownloadTask> watchAll() async* {
    if (await _downloadEnabled()) {
      // Import resolves before the core stream is created, so reconnecting to
      // an in-progress legacy task does not emit an empty first snapshot.
      await _ensureCoreReady();
      yield* DownloadFacade.instance.watchAll().map(toDownloadTask);
      return;
    }
    final bases = <int, DownloadTask>{};
    yield* RustModuleManager.instance.moduleEvents
        .where((e) => e.eventType == _evProgress || e.eventType == _evDone)
        .map(_decodeEvent)
        .where((m) => m != null)
        .map((m) => m!)
        .asyncMap((m) async {
          final id = _taskIdOf(m);
          if (id == null) return null;
          var base = bases[id];
          if (base == null) {
            base = await getTask(id);
            if (base == null) return null;
            bases[id] = base;
          }
          final merged = RustDownloadMapper.mergeProgress(base, m);
          bases[id] = merged;
          return merged;
        })
        .where((t) => t != null)
        .cast<DownloadTask>();
  }

  @override
  Stream<DownloadTask> watch(int id) async* {
    if (await _downloadEnabled()) {
      await _ensureCoreReady();
      final dto = await DownloadFacade.instance.get(id.toString());
      if (dto != null) yield toDownloadTask(dto);
      await for (final next in DownloadFacade.instance.watchAll()) {
        final task = toDownloadTask(next);
        if (task.id == id) yield task;
      }
      return;
    }
    // 先取一次全量任务作基底：进度事件不含 url / 保存路径 / 应用名，
    // 直接拿它构造会把面板里这些字段清空（信息弹框看不到地址就是这么来的）。
    var base = await getTask(id);
    if (base != null) {
      yield base;
    }

    await for (final m in RustModuleManager.instance.moduleEvents
        .where((e) => e.eventType == _evProgress || e.eventType == _evDone)
        .map(_decodeEvent)
        .where((m) => m != null)
        .map((m) => m!)
        .where((m) => _taskIdOf(m) == id)) {
      final merged = RustDownloadMapper.mergeProgress(base, m);
      base = merged;
      yield merged;
    }
  }

  /// 解码模块事件载荷（JSON）；结构不符返回 null 而不是抛错——
  /// 广播总线上还有其它模块的事件，不能因为一条脏数据打断整条流。
  Map<String, dynamic>? _decodeEvent(dynamic event) {
    try {
      final text = utf8.decode(event.data as Uint8List);
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 进度事件用 `taskId`，终态事件是完整 DTO（用 `id`）
  int? _taskIdOf(Map<String, dynamic> m) {
    final v = m['taskId'] ?? m['id'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return null;
  }

  DownloadTask _toTask(Map<String, dynamic> m) {
    // 终态事件带完整 DTO 字段，进度事件只有传输态字段
    return m.containsKey('filePath')
        ? RustDownloadMapper.fromDto(m)
        : RustDownloadMapper.fromProgressEvent(m);
  }
}

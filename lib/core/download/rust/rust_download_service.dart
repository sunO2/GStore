import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'dart:typed_data';

import 'package:gstore/core/download/core/download_request.dart';
import 'package:gstore/core/download/model/download_task.dart';
import 'package:gstore/core/download/rust/rust_download_mapper.dart';
import '../download_paths.dart';
import 'package:gstore/core/config/config_manager.dart';
import 'package:gstore/core/config/providers/download_config_provider.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/rust/ModuleLoader.dart';
import 'package:gstore/core/rust/ModuleManager.dart';

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

  RustModuleInstance? _inst;

  /// 进度/终态事件类型（内核 emit_event 的 type）
  static const String _evProgress = 'download.progress';
  static const String _evDone = 'download.done';

  /// 确保模块挂载 + 实例化（幂等，缓存在本类）
  Future<RustModuleInstance> _ensureInstance() async {
    final cached = _inst;
    if (cached != null) return cached;

    final ok = await RustModuleLoader.instance.ensureModule(moduleName);
    if (!ok) {
      throw StateError('RustDownloadService: download 模块不可用');
    }
    final handle = await RustModuleManager.instance.loadModule(moduleName);
    // 不传 dbPath：内核经 ModuleContext 从宿主拿到 data_dir/db_path
    final inst = await RustModuleInstance.createWithContext(moduleName, handle);
    _inst = inst;
    appLog.info('RustDownloadService: download 内核实例就绪');
    return inst;
  }

  /// 模块是否可用（面板可据此决定是否启用新内核；不可用时不抛错）
  Future<bool> get isAvailable async {
    try {
      await _ensureInstance();
      return true;
    } catch (e) {
      appLog.warning('RustDownloadService: 内核不可用 - $e');
      return false;
    }
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
    // 落盘路径必须与 Dart 实现共用同一份规则，否则换内核后文件会落到别处
    final dest = await DownloadPaths.resolveSavePath(
      saveFileName: saveFileName,
      fileName: fileName,
    );

    if (installAfterDownload) {
      // 明确不假装支持：安装仍由 Dart 侧流程负责
      appLog.info('RustDownloadService: installAfterDownload 由 Dart 侧处理（内核不负责安装）');
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
    // savePath 声明为可空：为空时回落到与 download() 相同的目录约定
    final dest = request.savePath ??
        await DownloadPaths.resolveSavePath(
          saveFileName: saveFileName,
          fileName: fileName,
        );

    if (installAfterDownload) {
      appLog.info('RustDownloadService: installAfterDownload 由 Dart 侧处理（内核不负责安装）');
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
      debugPrint('RustDownloadService: 配置下发 maxConcurrent=$concurrent multiSegment=$multi');
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
  Future<void> pause(int id) => _op('download.pause', id);

  @override
  Future<void> resume(int id) => _op('download.resume', id);

  @override
  Future<void> cancel(int id) => _op('download.cancel', id);

  @override
  Future<void> retry(int id) => _op('download.retry', id);

  @override
  Future<void> restart(int id) => _op('download.restart', id);

  Future<void> _op(String method, int id) async {
    // 诊断：确认按钮实际走到了哪个模块方法
    // （resume 不该刷新"最后开始时间"，若这里打的是 retry/restart 就说明分发错了）
    debugPrint('RustDownloadService.op: $method id=$id');
    await _invoke(method, {'id': id});
  }

  @override
  Future<DownloadTask?> getTask(int id) async {
    final raw = await _invoke('download.get', {'id': id});
    if (raw is! Map<String, dynamic>) return null;
    return RustDownloadMapper.fromDto(raw);
  }

  /// 列出任务（可选按状态索引过滤）。面板展示列表时用。
  Future<List<DownloadTask>> listTasks({List<DownloadStatusEnum>? statuses}) async {
    final raw = await _invoke('download.list', {
      if (statuses != null) 'statuses': [for (final s in statuses) s.index],
    });
    return RustDownloadMapper.fromDtoList(raw);
  }

  /// 删除任务（含落盘文件），模块侧 `download.remove`
  @override
  Future<void> remove(int id) => _op('download.remove', id);

  /// 全局任务流：**不过滤 id**，供通知栏 / 自动安装统一消费。
  ///
  /// 进度事件只带变化字段，所以要按 taskId 维护一份"全量基底"再合并，
  /// 否则消费方拿到的任务会缺 url / 路径 / 应用名。
  @override
  Stream<DownloadTask> watchAll() {
    final bases = <int, DownloadTask>{};
    return RustModuleManager.instance.moduleEvents
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

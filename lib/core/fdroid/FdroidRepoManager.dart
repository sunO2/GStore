import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:gstore/core/progress/task_progress.dart';
import 'package:gstore/core/rust/FdroidRustRepoManager.dart' as rust;
import 'package:gstore/core/rust/RustTask.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// F-Droid 仓库管理器
/// 使用 Rust 实现提供更快的下载和解析速度
///
/// 响应式状态承载：以 [ChangeNotifier] 暴露源列表/当前源/加载进度等字段，
/// 任何字段变更均调用 [notifyListeners]（页面 Notifier 订阅同步展示）。
class FdroidRepoManager extends ChangeNotifier implements IFdroidRepoService {
  static FdroidRepoManager? _instance;

  static FdroidRepoManager get instance {
    _instance ??= FdroidRepoManager();
    return _instance!;
  }

  /// 测试可自由构造自建实例；生产统一走 [instance]
  FdroidRepoManager();

  FdroidSource? _currentSource;

  /// 当前激活的源
  FdroidSource? get currentSource => _currentSource;

  final List<FdroidSource> _sources = [];

  /// 已配置的源列表
  /// 仓库身份键（委托 Rust 管理器的唯一实现，避免规则漂移）
  ///
  /// **存储身份 = 源 id**（[rust.FdroidRustRepoManager.storageIdentity]）：指纹是
  /// 下载后才学到的，不能参与库槽位/单飞键的判定，否则首次加载会中途翻槽
  /// （首跑两遍下载、列表空到下拉刷新）。
  @override
  String identityKeyFor(FdroidSource source) =>
      rust.FdroidRustRepoManager.storageIdentity(source);

  List<FdroidSource> get sources => _sources;

  bool _isLoading = false;

  /// 是否正在加载数据
  bool get isLoading => _isLoading;

  double _loadingProgress = 0.0;

  /// 加载进度 (0-1)
  double get loadingProgress => _loadingProgress;

  String? _errorMessage;

  /// 最后的错误信息
  String? get errorMessage => _errorMessage;

  /// 进行中的加载次数（可并发：搜索补齐 + 页面手动同步可能同时发生）。
  int _loadingCount = 0;

  /// 全局同步进度卡片的稳定标识。
  ///
  /// 整个同步只发**一张**卡片：本类的 [_loadingProgress] 是**全局**值，并不存在
  /// 逐源进度状态，因此逐源卡片在本类内无法实现（需要更大的改造）。用固定的
  /// `id` + `groupKey`，多源并发时 Hub 按 `id` 覆盖为同一张卡片，不会卡片风暴。
  static const String _syncTaskId = 'fdroid-sync';
  static const String _syncCardKey = 'module:repo';
  static const String _syncLabel = 'F-Droid 仓库';

  /// 当前同步周期对应的全局进度票据（无进行中周期时为 null）。
  ///
  /// 这是给顶部横幅的**附加通道**：不替代 [_loadingProgress]（F-Droid 页面仍照旧
  /// 消费它）。票据可能因「解析入库」阶段的不确定进度而经一次同 id `begin` 取代，
  /// 故始终保存**最新**票据，结算时以它为准。
  TaskTicket? _syncTicket;

  /// 本周期首个加载失败（成功则保持 null）——由 [_finishLoading] 决定终态是
  /// `failed` 还是 `ready`，避免失败后仍被标记为就绪。
  Object? _syncFailure;

  /// 进入一次加载：驱动 UI 的 loading 状态。
  ///
  /// 计数 0 → 1 时开启全局同步进度卡片；后续并发进入（1 → 2…）复用同一票据，
  /// 保证多源并发只有**一张**卡片。
  void _beginLoading() {
    _loadingCount++;
    _isLoading = true;
    if (_loadingCount == 1) {
      _syncFailure = null;
      _syncTicket = TaskProgressHub.instance.begin(
        id: _syncTaskId,
        groupKey: _syncCardKey,
        label: _syncLabel,
        stage: '正在连接',
      );
    }
    notifyListeners();
  }

  /// 结束一次加载；**最后一个**结束者才把 loading 置回并令进度到 1。
  ///
  /// WHY：用计数而非布尔值，避免"搜索触发的补齐"与"页面手动同步"互相覆盖，
  /// 导致进度条/按钮状态提前熄灭或永久卡住。
  ///
  /// 计数归零即结算全局同步卡片：本周期有失败 → `failed`；否则 → `ready`。
  void _finishLoading() {
    if (_loadingCount > 0) _loadingCount--;
    if (_loadingCount == 0) {
      _isLoading = false;
      _loadingProgress = 1.0;
      final ticket = _syncTicket;
      final failure = _syncFailure;
      _syncTicket = null;
      _syncFailure = null;
      if (ticket != null) {
        if (failure != null) {
          ticket.fail(failure);
        } else {
          ticket.ready();
        }
      }
      notifyListeners();
    }
  }

  /// 记录一次同步失败，并立即把聚合卡片置为 `failed`（终态停留期由 Hub 管理）。
  ///
  /// 保留原有失败记账（`_errorMessage` 等）不变，这里只是**追加**进度通道。
  void _failSyncTask(Object error) {
    _syncFailure = error;
    _syncTicket?.fail(error);
  }

  /// 源身份键 → 该源**最近一次同步**的真实结果。
  ///
  /// 按源记录：多源下不存在"整体上次同步"（那只会是"最后一个完成的源"），
  /// 界面按源展示才如实。本次会话内有效（冷启动后由 [getStatistics] 给出 null）。
  final Map<String, FdroidSyncInfo> _syncInfo = {};

  /// 某源最近一次同步结果（未同步过返回 null）
  FdroidSyncInfo? syncInfoFor(FdroidSource source) => _syncInfo[identityKeyFor(source)];

  /// 源身份键 → 该源**实际生效**的资源基址（模块 `resolved_url`）。
  ///
  /// 资源地址的唯一产出方：由下载结果回填，冷启动/换源时用 [ensureBaseFor] 从该源
  /// 自己的库补读。宿主侧不再用"第一个启用镜像"另算一套。
  final Map<String, String> _resolvedBases = {};

  @override
  String? cachedBaseFor(FdroidSource source) => _resolvedBases[identityKeyFor(source)];

  @override
  Future<void> ensureBaseFor(FdroidSource source) async {
    final key = identityKeyFor(source);
    final cached = _resolvedBases[key];
    if (cached != null && cached.isNotEmpty) return;
    final meta = await rust.FdroidRustRepoManager.getRepoMetaIn(source);
    final url = meta?['resolved_url'] as String?;
    if (url == null || url.isEmpty) return;
    _resolvedBases[key] = url;
    appLog.info('FdroidRepoManager: 「${source.name}」资源基址 = $url');
    notifyListeners();
  }

  /// 在列表中查找首个满足条件的元素（无则返回 null）。
  static FdroidSource? _firstWhereOrNull(
    List<FdroidSource> list,
    bool Function(FdroidSource) test,
  ) {
    for (final s in list) {
      if (test(s)) return s;
    }
    return null;
  }

  /// 幂等初始化：并发复用同一 Future；失败后清除缓存以便重试。
  ///
  /// 启动路径不 await（避免首帧黑屏），需要就绪状态的调用方按需 await。
  Future<void> ensureInitialized() {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = initialize();
    _initFuture = future;
    return future.catchError((Object e) {
      _initFuture = null;
      throw e;
    });
  }

  Future<void>? _initFuture;

  /// 初始化管理器
  Future<void> initialize() async {
    try {
      appLog.info('FdroidRepoManager: 开始初始化...');

      // 初始化 Rust 后端
      final dbPath = path.join(
        (await _getApplicationDocumentsDirectory()).path,
        'fdroid_rust.db',
      );
      debugPrint('FdroidRepoManager: 初始化 Rust 后端，数据库路径: $dbPath');
      await rust.FdroidRustRepoManager.initialize(dbPath: dbPath);
      appLog.info('FdroidRepoManager: Rust 后端初始化成功');

      // 加载保存的源配置
      await _loadSources();
      await _migrateEmptyMirrors();
      appLog.info('FdroidRepoManager: 已加载 ${sources.length} 个源');

      // 默认只有一个"官方源"；**国内镜像作为它的从属镜像**（默认启用并优先），
      // 不再把镜像注册成独立源（旧行为会造成"源就是镜像"的混乱）
      if (sources.isEmpty) {
        debugPrint('FdroidRepoManager: 没有保存的源，初始化官方源（含国内镜像）');
        _sources.clear();
        _sources.add(FdroidSource.official);
        notifyListeners();
        await _saveSources();
      }

      // 历史槽位（fp:/url:）库文件清理：源配置已就绪，且此时**尚未创建任何
      // repo 实例/打开任何库句柄**（initialize 仅 _loadSources + 默认源设置），
      // 删除旧文件不会与在用的 SQLite 连接竞争。best-effort，绝不影响启动。
      await _cleanupLegacyDbFiles();

      // 设置当前源
      final enabledSource = _firstWhereOrNull(_sources, (s) => s.enabled);
      debugPrint('FdroidRepoManager: 找到启用源: $enabledSource');

      // 尝试加载上次选中的源
      final lastSourceId =
          await ConfigService.instance.getT<String>(ConfigKeys.lastSourceId);
      if (lastSourceId != null && lastSourceId.isNotEmpty) {
        final lastSource = _firstWhereOrNull(_sources, (s) => s.id == lastSourceId);
        if (lastSource != null) {
          _currentSource = lastSource;
          notifyListeners();
          appLog.info('FdroidRepoManager: 恢复上次选中的源: $lastSource');
        } else {
          _currentSource = enabledSource;
          notifyListeners();
        }
      } else {
        _currentSource = enabledSource;
        notifyListeners();
      }
      // **始终**把当前源同步给 Rust 侧。旧实现在"无 lastSourceId"分支漏调，
      // 导致 `_activeSource` 为空、后续 `_ensureInstance` 落到幽灵键 `url:default`
      // ——下载写 A 库、搜索读 B 库，正是"加载成功却搜不到且重启依旧"的根因。
      // 此处只切身份，**不触发任何下载**（启动路径禁止下载）。
      rust.FdroidRustRepoManager.setActiveSource(_currentSource);

      appLog.info('FdroidRepoManager: 初始化完成，当前源: $currentSource');
    } catch (e) {
      appLog.error('FdroidRepoManager: 初始化失败 - $e');
      _errorMessage = '初始化失败: $e';
      notifyListeners();
      rethrow;
    }
  }

  /// 加载保存的源配置
  /// 迁移：老数据里官方源的 `mirrors` 是空的（旧版本把镜像建成了**独立源**）
  ///
  /// 真机后果：候选里没有镜像 → 只能直连 f-droid.org → 国内一直加载不出来。
  Future<void> _migrateEmptyMirrors() async {
    // 内联默认镜像（避免跨文件依赖；与 defaultSources 的官方源一致）
    final defaults = <FdroidMirror>[
      const FdroidMirror(url: 'https://mirrors.tuna.tsinghua.edu.cn/fdroid/repo'),
      const FdroidMirror(url: 'https://mirrors.niyawe.de/fdroid/repo'),
      const FdroidMirror(url: 'https://ftp.fau.de/fdroid/repo'),
    ];
    var changed = false;
    for (var i = 0; i < _sources.length; i++) {
      final s = _sources[i];
      if (s.repoUrl.contains('f-droid.org') && s.mirrors.isEmpty) {
        _sources[i] = s.copyWith(mirrors: defaults, useMirrors: true);
        changed = true;
        appLog.info(
            'FdroidRepoManager: 为「${s.name}」补默认镜像 ${defaults.length} 个（老数据迁移）');
      }
    }
    if (changed) await _saveSources();
  }

  /// 启动时清理**历史（未被当前槽位使用）**的 F-Droid 库文件。
  ///
  /// 挂钩点：`initialize()` 中 `_loadSources()` 之后、`setActiveSource` 之前——
  /// 此时源配置已就绪，且尚未创建任何 repo 实例/打开任何库句柄，删除旧文件
  /// 不会与在用的 SQLite 连接竞争。仅清理**已配置源**的两个历史逻辑槽位，
  /// 不做全盘扫描（孤儿清理是未来的独立事项）。
  ///
  /// best-effort：任何异常都被吞掉并记日志，绝不抛出、绝不阻断启动。
  Future<void> _cleanupLegacyDbFiles() async {
    try {
      final docs = await _getApplicationDocumentsDirectory();
      final result =
          await cleanLegacyDbSlots(sources: _sources, docsPath: docs.path);
      if (result.files > 0) {
        appLog.info('FdroidRepoManager: 已清理 ${result.files} 个历史库文件，'
            '回收 ${result.bytes} 字节（当前槽位未受影响）');
      }
      // 无文件可清（含二次冷启动）时保持静默。
    } catch (e) {
      // best-effort：绝不影响启动。
      appLog.warning('FdroidRepoManager: 历史库文件清理失败（忽略） - $e');
    }
  }

  /// 历史库文件名形态：`fdroid_<16 位小写 hex>.db` 及其 `-wal`/`-shm` 边车。
  static final RegExp _legacyDbNameRe =
      RegExp(r'^fdroid_[0-9a-f]{16}\.db(-wal|-shm)?$');

  /// 去掉 `-wal`/`-shm` 边车后缀，得到对应的主库文件路径。
  static String _baseDbPath(String dbPath) {
    if (dbPath.endsWith('-wal') || dbPath.endsWith('-shm')) {
      return dbPath.substring(0, dbPath.length - 4);
    }
    return dbPath;
  }

  /// 候选路径是否允许删除（三重护栏，缺一不可）：
  /// 1. **绝不删当前槽位**：[currentSlotPaths] 是全部已配置源的
  ///    `storageIdentity` 对应库文件；候选（含其 `-wal`/`-shm`）命中任一当前
  ///    槽位即拒删。`url:`/`fp:` 候选理论上不可能等于 `id:` 槽位，这里仍然
  ///    显式强制，作为整个清理的安全总闸。
  /// 2. **文件名白名单**：`fdroid_` + 16 位小写 hex 十六进制 + `.db`（可带
  ///    `-wal`/`-shm`），杜绝误伤 `fdroid_rust.db` 等其它文件。
  /// 3. **目录护栏**：必须直接位于 docs 目录之下，不下钻子目录、不 glob。
  @visibleForTesting
  static bool isDeletableLegacySlotPath({
    required String candidatePath,
    required String docsPath,
    required Set<String> currentSlotPaths,
  }) {
    if (currentSlotPaths.contains(candidatePath)) return false;
    if (currentSlotPaths.contains(_baseDbPath(candidatePath))) return false;
    if (!path.equals(path.dirname(candidatePath), docsPath)) return false;
    return _legacyDbNameRe.hasMatch(path.basename(candidatePath));
  }

  /// 清理**已配置源**的两个历史逻辑槽位（`fp:<HEX>` 与 `url:<归一化地址>`）
  /// 对应的库文件及其 `-wal`/`-shm` 边车。
  ///
  /// 返回 `(files: 删除文件数, bytes: 回收字节数, skipped: 被护栏跳过的候选数)`。
  /// 纯 best-effort：所有异常都被吞掉并记日志，绝不抛出。
  @visibleForTesting
  static Future<({int files, int bytes, int skipped})> cleanLegacyDbSlots({
    required Iterable<FdroidSource> sources,
    required String docsPath,
  }) async {
    var files = 0;
    var bytes = 0;
    var skipped = 0;
    try {
      // 当前槽位：任何候选命中它都绝不删除（安全总闸）。
      final currentSlots = <String>{
        for (final s in sources)
          rust.FdroidRustRepoManager.legacyDbPathFor(
              identity: s.id, docsPath: docsPath),
      };
      // 每个源的两个历史身份（`fp:<HEX>` / `url:<归一化地址>`）→ 各自的主库 + 边车候选。
      final candidates = <String>{};
      for (final s in sources) {
        for (final base in {
          rust.FdroidRustRepoManager.legacyDbPathFor(
              fingerprint: s.fingerprint,
              repoUrl: s.repoUrl,
              docsPath: docsPath),
          rust.FdroidRustRepoManager.legacyDbPathFor(
              repoUrl: s.repoUrl, docsPath: docsPath),
        }) {
          for (final suffix in const ['', '-wal', '-shm']) {
            candidates.add('$base$suffix');
          }
        }
      }

      for (final candidate in candidates) {
        try {
          if (!isDeletableLegacySlotPath(
            candidatePath: candidate,
            docsPath: docsPath,
            currentSlotPaths: currentSlots,
          )) {
            skipped++;
            continue;
          }
          final f = File(candidate);
          if (!f.existsSync()) continue;
          final size = f.lengthSync();
          f.deleteSync();
          files++;
          bytes += size;
        } catch (e) {
          appLog.warning('FdroidRepoManager: 清理旧库文件「$candidate」失败 - $e');
        }
      }
    } catch (e) {
      appLog.warning('FdroidRepoManager: 旧库文件清理跳过 - $e');
    }
    return (files: files, bytes: bytes, skipped: skipped);
  }

  Future<void> _loadSources() async {
    try {
      // fdroidSources 为 json 类型：存储层读回 List（Map/List 已由存储层解码）。
      final raw = await ConfigService.instance.getRaw(ConfigKeys.fdroidSources);
      final sourcesList = _asSourceList(raw);

      if (sourcesList != null && sourcesList.isNotEmpty) {
        final loadedSources = sourcesList
            .whereType<Map>()
            .map((json) => FdroidSource.fromJson(Map<String, dynamic>.from(json)))
            .toList();
        _sources
          ..clear()
          ..addAll(loadedSources);
        // id 唯一是「id 作为存储槽位键」的前置不变量：历史配置可能有两个
        // `official`，必须改派重复项，否则两个源会共用一个库。
        if (_dedupeSourceIds()) await _saveSources();
        notifyListeners();
        appLog.info('FdroidRepoManager: 已加载 ${sources.length} 个保存的源');
      } else {
        _sources.clear();
        notifyListeners();
        debugPrint('FdroidRepoManager: 没有保存的源配置');
      }
    } catch (e) {
      appLog.error('FdroidRepoManager: 加载源配置失败 - $e');
      _sources.clear();
      notifyListeners();
    }
  }

  /// 归一化存储读回值：
  /// - List：正常（json 类型已解码）
  /// - JSON 字符串：兼容旧格式，尝试 jsonDecode
  /// - 其他（旧版曾以 Dart `toString()` 落成非法 JSON）：丢弃（返回 null → 回退默认源）
  static List<dynamic>? _asSourceList(Object? raw) {
    if (raw is List) return raw;
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded;
      } catch (_) {
        // 非法 JSON（旧脏数据）→ 丢弃，由调用方回退默认源并重写
      }
    }
    return null;
  }

  /// 保存源配置
  Future<void> _saveSources() async {
    try {
      // fdroidSources 注册为 ConfigValueType.json：写入 List<Map>，
      // 由存储层 jsonEncode 落盘（读取侧还原为 List）。不可自行 jsonEncode 成字符串，
      // 否则会被 ConfigService 解码后再由存储层 toString() 落成非法 JSON。
      await ConfigService.instance.set(
        ConfigKeys.fdroidSources,
        sources.map((s) => s.toJson()).toList(),
        source: ConfigChangeSource.internal,
      );
      appLog.info('FdroidRepoManager: 已保存 ${sources.length} 个源配置');
    } catch (e) {
      appLog.error('FdroidRepoManager: 保存源配置失败 - $e');
    }
  }

  /// 保证 `id` 唯一：重复的 id 改派为 `custom_<ts>_<n>`（返回是否有改动）。
  ///
  /// 这是「id 作为存储槽位键」的前置不变量守卫：默认官方源的 id 固定为
  /// `official`，历史配置里可能出现重复（例如误导入两次），若不改派两个源会
  /// 共用同一个库文件。
  bool _dedupeSourceIds() {
    final seen = <String>{};
    var changed = false;
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < _sources.length; i++) {
      final id = _sources[i].id;
      if (seen.add(id)) continue;
      var n = 1;
      var candidate = 'custom_${ts}_$n';
      while (seen.contains(candidate)) {
        n++;
        candidate = 'custom_${ts}_$n';
      }
      _sources[i] = _sources[i].copyWith(id: candidate);
      seen.add(candidate);
      changed = true;
      appLog.warning('FdroidRepoManager: 源 id 重复「$id」→ 已改派为「$candidate」');
    }
    return changed;
  }

  /// 切换源
  Future<void> switchSource(String sourceId) async {
    final source = _firstWhereOrNull(_sources, (s) => s.id == sourceId);
    if (source == null) {
      throw Exception('未找到源: $sourceId');
    }

    if (!sources.contains(source)) {
      _sources.add(source);
      notifyListeners();
      await _saveSources();
    }

    _currentSource = source;
    rust.FdroidRustRepoManager.setActiveSource(source);
    notifyListeners();

    // 保存当前选中的源
    await ConfigService.instance.set(
      ConfigKeys.lastSourceId,
      sourceId,
      source: ConfigChangeSource.user,
    );
    appLog.info('FdroidRepoManager: 已保存当前源: $sourceId');

    // 重新加载数据
    await loadRepository();
  }

  /// 获取源列表
  List<FdroidSource> getSources() {
    return List<FdroidSource>.from(_sources);
  }

  /// 获取当前源
  FdroidSource? getCurrentSource() {
    return _currentSource;
  }

  /// 身份键 → 进行中的"加载该源"Future（单飞：并发/重复触发共享同一个下载）。
  ///
  /// key 用 [identityKeyFor]（存储身份 = 源 id，**与指纹发现无关**），与
  /// [rust.FdroidRustRepoManager.searchAppsIn]/[rust.FdroidRustRepoManager.appCountIn]
  /// 读取时的身份键**完全一致**，避免"下载写 A 库、搜索读 B 库"。
  ///
  /// 值携带 `(count, ok)`：`ok` 区分"加载成功（即便索引为 0）"与"加载失败"，
  /// 避免把合法空仓库误判为故障。
  final Map<String, Future<({int count, bool ok})>> _loadInFlight = {};

  /// 单飞加载一个源：同一身份键的并发请求**等待同一个 Future**（不是早退丢弃）。
  ///
  /// WHY：旧实现在 `_isLoading` 时直接 `return`，第二个调用者拿到"空成功"，
  /// 而写入的库又是幽灵键 `url:default` → 搜索永远空。这里等待完成、
  /// 完成的 Future 从 map 移除以便下次重新触发（如清库后）。
  Future<({int count, bool ok})> _ensureSourceLoaded(FdroidSource s) {
    final k = identityKeyFor(s);
    return _loadInFlight.putIfAbsent(
        k, () => _loadOneSource(s).whenComplete(() {
              // 必须丢弃 `Map.remove` 的返回值：它正是本 whenComplete 的 future，
              // 返回它会让 whenComplete 等待自身 → 永久挂起（所有空库读路径卡死）。
              _loadInFlight.remove(k);
            }));
  }

  /// 下载/解析**一个源**到它自己的库。
  ///
  /// 返回 `(count, ok)`：
  /// - `ok: true` → 下载/解析成功（`count` 是**真实**应用数，**允许为 0**，
  ///   即"合法空仓库"）；
  /// - `ok: false` → 任一下载失败/取消/超时/异常分支（`count` 恒为 0）。
  ///
  /// WHY：旧实现用 `0` 同时表示"成功但 0 应用"与"失败"，读路径据此把合法空
  /// 仓库误报成「F-Droid 仓库不可用」。用 `ok` 把两者分开。
  ///
  /// WHY 必须用 `downloadRepositoryTaskFor(source)`（带源身份）：只有这样
  /// 写入的库才与后续 `searchAppsIn(source)` 读取的库是同一个。
  Future<({int count, bool ok})> _loadOneSource(FdroidSource source) async {
    try {
      appLog.info('FdroidRepoManager: 加载源 - ${source.name}');
      final task = await rust.FdroidRustRepoManager.downloadRepositoryTaskFor(source);
      final sub = task.progress.listen((p) {
        final json = p.json;
        final phase = json?['phase'] as String?;
        final pct = (json?['percent'] as num?)?.toInt() ?? 0;
        final double next;
        if (phase == 'index') {
          // 索引下载是耗时主体：用真实字节百分比在 0.3→0.9 之间推进
          next = (0.3 + 0.6 * pct / 100).clamp(0.0, 1.0);
        } else {
          next = switch (phase) {
            'downloading' => 0.3,
            'stored' => 0.9,
            _ => _loadingProgress,
          };
        }
        if (next != _loadingProgress) {
          _loadingProgress = next;
          notifyListeners();
        }
        // 附加通道：把真实事件阶段映射到全局进度卡片（不替代上面的页面进度）。
        switch (phase) {
          case 'downloading':
            // 事件载荷只有 phase、无字节信息 → 只能给不确定进度。
            _syncTicket?.update(stage: '同步中');
          case 'index':
            _syncTicket?.update(stage: '下载索引 $pct%', progress: next);
          case 'stored':
            _syncTicket?.update(stage: '索引已下载', progress: next);
            // Rust 侧**不**为随后的解析/入库工作发任何事件（`stored` 已由模块在
            // call 返回前发出），且 Hub 的 update 是「非空覆盖」语义（无法把
            // progress 显式清回 null）。因此这里用一次**同 id / 同 groupKey** 的
            // begin 取代为不确定进度：既是同一张卡片，又能让用户在「解析入库」
            // 阶段看到活动条，而不是停在 90% 的假死进度。
            _syncTicket = TaskProgressHub.instance.begin(
              id: _syncTaskId,
              groupKey: _syncCardKey,
              label: _syncLabel,
              stage: '解析入库…',
            );
          default:
            break; // 未知阶段：页面进度已在上面按 `_ => _loadingProgress` 保持不变。
        }
      });
      RustTaskResult result;
      try {
        // 3 分钟兜底：completion 正常在流关闭时解析，这里只防"流悬挂"
        result = await task.completion.timeout(const Duration(minutes: 3));
      } on TimeoutException {
        await task.cancel();
        rethrow;
      } finally {
        await sub.cancel();
      }
      if (result.outcome == RustTaskOutcome.error) {
        _errorMessage = '「${source.name}」加载失败: ${result.error}';
        appLog.error('FdroidRepoManager: 「${source.name}」加载失败 - ${result.error}');
        _failSyncTask(StateError(_errorMessage!));
        notifyListeners();
        return (count: 0, ok: false);
      }
      if (result.outcome == RustTaskOutcome.cancelled) {
        _errorMessage = '「${source.name}」加载已取消';
        _failSyncTask(StateError(_errorMessage!));
        notifyListeners();
        return (count: 0, ok: false);
      }
      // 用签名里提取的真实指纹做事后校验：自动回填 + 同源判定（保留原语义）
      await _syncSignerFingerprint(source, result.payload);
      final count = await rust.FdroidRustRepoManager.appCountIn(source);
      // 解析/入库完成 → 就绪；终态 ready 由 _finishLoading 统一发布。
      _syncTicket?.update(stage: '已就绪', progress: 1.0);
      appLog.info('FdroidRepoManager: 「${source.name}」加载完成，共 $count 个应用');
      return (count: count, ok: true);
    } on TimeoutException catch (e) {
      _errorMessage = '「${source.name}」加载超时: $e';
      appLog.error('FdroidRepoManager: 「${source.name}」加载超时 - $e');
      _failSyncTask(e);
      notifyListeners();
      return (count: 0, ok: false);
    } catch (e) {
      _errorMessage = '「${source.name}」加载失败: $e';
      appLog.error('FdroidRepoManager: 「${source.name}」加载失败 - $e');
      _failSyncTask(e);
      notifyListeners();
      return (count: 0, ok: false);
    }
  }

  /// 读路径前置：**逐源**判断是否需要下载（仅空库才下载），返回就绪概况。
  ///
  /// WHY：旧读路径没有这一步（或走错身份键），干净安装后库永远为空 → 搜索恒空。
  /// 以每个源各自的 `appCountIn` 为准：已就绪的源不重复下载，空源也不会
  /// 掩盖另一个已就绪的源（多源并存）。
  Future<_RepoReadiness> _ensureDataFor(Iterable<FdroidSource> targets) async {
    final list = targets.toList(growable: false);
    if (list.isEmpty) {
      return const _RepoReadiness(hasData: false, failures: 0);
    }
    _errorMessage = '';
    _beginLoading();
    _loadingProgress = 0.0;
    notifyListeners();
    var hasData = false;
    var failures = 0;
    var empties = 0;
    try {
      for (final source in list) {
        try {
          var count = await rust.FdroidRustRepoManager.appCountIn(source);
          if (count == 0) {
            final result = await _ensureSourceLoaded(source);
            count = result.count;
            if (!result.ok) {
              // 加载失败：`_loadOneSource` 已设置 `_errorMessage` 并发布失败卡片。
              failures++;
              continue;
            }
          }
          if (count > 0) {
            hasData = true;
          } else {
            // 加载成功但索引为 0：合法空仓库，**不是**故障。
            empties++;
          }
        } catch (e) {
          failures++;
          appLog.error('FdroidRepoManager: 源「${source.name}」就绪失败 - $e');
          _errorMessage = '源「${source.name}」不可用: $e';
          _failSyncTask(e);
          notifyListeners();
        }
      }
      return _RepoReadiness(
        hasData: hasData,
        failures: failures,
        empties: empties,
      );
    } finally {
      _finishLoading();
    }
  }

  /// 加载仓库数据
  Future<void> loadRepository({bool forceRefresh = false}) async {
    debugPrint('FdroidRepoManager: loadRepository 被调用');

    final source = _currentSource;
    if (source == null) {
      appLog.error('FdroidRepoManager: 源为 null，返回错误');
      _errorMessage = '请先选择一个源';
      notifyListeners();
      return;
    }

    appLog.info('FdroidRepoManager: 开始加载源: ${source.name} (${source.repoUrl})');

    _errorMessage = '';
    _beginLoading();
    _loadingProgress = 0.0;
    notifyListeners();

    try {
      debugPrint('FdroidRepoManager: 使用 Rust 后端下载（身份键单飞）...');
      // 并发控制交给身份键单飞（_loadInFlight）：重复请求**等待同一个 Future**
      // 而不是 `_isLoading → return`。旧早退还写幽灵键 `url:default`，
      // 正是"下载成功但搜索永远空、重启依旧"的根因。
      // 注：forceRefresh 不参与判定——搜索路径每次击键都会传 true，
      // 读路径统一以"空库才下载"为准，避免把重下挂在 forceRefresh 上。
      final result = await _ensureSourceLoaded(source);
      final count = result.count;
      if (count == 0 && (_errorMessage?.isNotEmpty ?? false)) {
        throw Exception(_errorMessage);
      }
      _loadingProgress = 1.0;
      notifyListeners();
      appLog.info('FdroidRepoManager: 仓库加载完成（$count 个应用）');
    } catch (e) {
      appLog.error('FdroidRepoManager: 加载仓库失败 - $e');
      _errorMessage = '加载失败: $e';
      notifyListeners();
      rethrow;
    } finally {
      _finishLoading();
    }
  }

  /// 搜索应用
  Future<List<Map<String, dynamic>>> searchApps(String keyword, {int limit = 50}) =>
      searchAppsAcross(keyword, limit: limit);

  /// 精确查询应用（通过 packageName）
  ///
  /// **多源正解**：应用可能属于任一源，不能靠"当前选中源"定位。
  /// - 传 [sourceId] → 只查该源（语义正确、一次查询）
  /// - 不传 → **跨全部已启用源**逐个精确匹配，命中后在结果里回带 `sourceId`/`sourceName`
  Future<Map<String, dynamic>?> getAppByPackageName(
    String packageName, {
    String? sourceId,
  }) async {
    final candidates = <FdroidSource>[];
    if (sourceId != null && sourceId.isNotEmpty) {
      for (final s in _sources) {
        // 接受三种标识：记录 id / 指纹 / 旧逻辑身份键（`fp:` / `url:`，历史记录）
        if (rust.FdroidRustRepoManager.identityMatches(s, sourceId)) {
          candidates.add(s);
        }
      }
    }
    if (candidates.isEmpty) candidates.addAll(enabledSources);
    if (candidates.isEmpty) throw Exception('请先启用一个源');

    // ★ 定向源优先，**未命中则跨源兜底**：记录里的源标识可能写错/过期（写入侧取的是
    //   "当前选中源"），不能让一个错误的标识直接导致详情拿不到数据。
    final scopedCount = (sourceId != null && sourceId.isNotEmpty) ? candidates.length : 0;
    if (scopedCount > 0) {
      for (final s in enabledSources) {
        // 按**存储身份（源 id，唯一）**判重；identityMatches 兼容历史标识。
        final dup = candidates.any(
            (c) => rust.FdroidRustRepoManager.identityMatches(c, s.id));
        if (!dup) candidates.add(s);
      }
    }

    try {
      appLog.info('开始精确查询应用（跨源）', data: {
        'packageName': packageName,
        'sourceId': sourceId ?? '(全部已启用源)',
        'candidates': candidates.length,
      });

      // 候选源各自独立库：**逐源**检查空库并按需加载（某个空源不会掩盖另一个
      // 已就绪的源，也不会让已就绪的源被重复下载）。
      final readiness = await _ensureDataFor(candidates);
      if (!readiness.hasData && readiness.failures > 0) {
        appLog.warning('候选源均无数据且加载失败', data: {'packageName': packageName});
      }

      for (var ci = 0; ci < candidates.length; ci++) {
        final src = candidates[ci];
        if (ci == scopedCount) {
          appLog.warning('定向源未命中 → 跨源兜底查询', data: {
            'packageName': packageName,
            'wrongOrStaleSourceId': sourceId,
          });
        }
        final results =
            await rust.FdroidRustRepoManager.searchAppsIn(src, packageName, limit: 100);
        for (final app in results) {
          final appMap = rust.FdroidRustRepoManager.appInfoToMap(app);
          if (appMap['packageName'] == packageName) {
            // ★ 回带来源源：调用方据此按源定位，不再依赖"当前选中源"
            appMap['sourceId'] = src.id;
            appMap['sourceName'] = src.name;
            appLog.info('精确查询成功', data: {
              'packageName': packageName,
              'name': appMap['name'],
              'matchedSource': src.name,
              'currentSource': _currentSource?.name,
            });
            return appMap;
          }
        }
      }
      appLog.warning('未找到应用（已遍历全部候选源）', data: {'packageName': packageName});
      return null;
    } catch (e) {
      appLog.error('精确查询失败', data: {'packageName': packageName, 'error': e.toString()});
      rethrow;
    }
  }

  /// 获取所有应用（当前源）
  ///
  /// WHY：与搜索共用**身份键**路径——先按当前源身份补齐数据（仅空库才下载），
  /// 再从该源自己的库全量读取；不再经幽灵键 `url:default` 写/读。
  Future<List<Map<String, dynamic>>> getAllApps() async {
    final source = _currentSource;
    if (source == null) {
      throw Exception('请先选择一个源');
    }

    try {
      appLog.info('开始获取所有 F-Droid 应用', data: {
        'source': source.name,
      });

      // 确保数据已加载（按当前源身份；空库才下载）
      final readiness = await _ensureDataFor([source]);
      if (!readiness.hasData && readiness.failures > 0) {
        throw StateError(_errorMessage ?? 'F-Droid 仓库不可用');
      }

      // 从该源自己的库全量读取（空字符串 = 全部）
      final results = await rust.FdroidRustRepoManager.searchAppsIn(source, '', limit: 100000);

      appLog.info('获取应用完成', data: {
        'totalApps': results.length,
      });

      // 输出前100个应用的详细信息（避免日志过多）
      final displayLimit = results.length > 100 ? 100 : results.length;
      for (var i = 0; i < displayLimit; i++) {
        final app = results[i];
        final appMap = rust.FdroidRustRepoManager.appInfoToMap(app);

        appLog.info('应用 #${i + 1}/$results.length', data: {
          'packageName': appMap['packageName'],
          'name': appMap['name'],
          'summary': appMap['summary'],
          'icon': appMap['icon'],
          'license': appMap['license'],
          'authorName': appMap['authorName'],
          'sourceCode': appMap['sourceCode'],
          'webSite': appMap['webSite'],
          'categories': appMap['categories'],
          'added': appMap['added'],
          'lastUpdated': appMap['lastUpdated'],
          'hasMetadata': appMap['metadata'] != null,
          'hasVersions': appMap['versions'] != null,
          'metadataLength': appMap['metadata']?.toString().length ?? 0,
          'versionsLength': appMap['versions']?.toString().length ?? 0,
        });
      }

      if (results.length > 100) {
        appLog.info('剩余应用已省略，仅显示前100个', data: {
          'total': results.length,
          'displayed': 100,
          'skipped': results.length - 100,
        });
      }

      return results.map((app) => rust.FdroidRustRepoManager.appInfoToMap(app)).toList();
    } catch (e) {
      appLog.error('获取所有应用失败', data: {
        'error': e.toString(),
      });
      appLog.error('FdroidRepoManager: 获取所有应用失败 - $e');
      rethrow;
    }
  }

  /// 获取应用数量
  Future<int> getAppCount() async {
    try {
      return await rust.FdroidRustRepoManager.getAppCount();
    } catch (e) {
      appLog.error('FdroidRepoManager: 获取应用数量失败 - $e');
      return 0;
    }
  }

  /// 获取数据库统计信息
  ///
  /// **按源**给出（每个源一个独立的库）：多源下把各源加在一起会掩盖
  /// "哪个源没同步 / 哪个源一条数据都没有"，这正是排查多源问题时最需要的信息。
  Future<List<FdroidSourceStat>> getStatistics() async {
    final out = <FdroidSourceStat>[];
    for (final s in _sources) {
      var count = 0;
      try {
        count = await rust.FdroidRustRepoManager.appCountIn(s);
      } catch (e) {
        appLog.error('FdroidRepoManager: 源 ${s.name} 统计失败 - $e');
      }
      out.add(FdroidSourceStat(
        source: s,
        appCount: count,
        lastSync: _syncInfo[identityKeyFor(s)],
      ));
    }
    return out;
  }

  /// 添加自定义源
  Future<void> addSource(FdroidSource source) async {
    var toAdd = source;
    if (_sources.any((s) => s.id == toAdd.id)) {
      toAdd = toAdd.copyWith(
        id: 'custom_${DateTime.now().millisecondsSinceEpoch}_${_sources.length}',
      );
      appLog.warning(
          'FdroidRepoManager: 源 id「${source.id}」已存在 → 已改派为「${toAdd.id}」');
    }
    _sources.add(toAdd);
    notifyListeners();
    await _saveSources();
  }

  /// 移除源
  /// 从下载结果里取模块提取的签名指纹（只解析证书 DER 后 SHA-256，不验签）
  static String _fingerprintOf(List<int> payload) {
    try {
      final json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      return json['signer_fingerprint'] as String? ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 用真实指纹做事后处理：
  /// 1) 源没记指纹 → **自动回填**（供同源判定/TOFU 使用；**不改变存储槽位**，
  ///    槽位恒为 `storageIdentity(source)` = 源 id，避免首次加载中途翻槽）
  /// 2) 与已有源指纹相同 → 判定**同源重复**并提示
  /// 3) 与已记指纹不一致 → 可疑（可能换了签名密钥），明确告警
  /// 下载结果摘要：**增量是否生效一眼可见**（日志导出即可核对省了多少）
  void _logDownloadSummary(FdroidSource source, List<int> payload) {
    try {
      final m = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      final incremental = m['incremental'] == true;
      final resolved = m['resolved_url'] as String?;
      appLog.info('FdroidRepoManager: 「${source.name}」加载完成 → '
          '${incremental ? '增量更新（entry.json + diff）' : '全量下载'}'
          '，应用 ${m['total_apps']}，耗时 ${m['download_time_ms']}ms'
          '${m['verified'] == true ? '，SHA-256 已校验' : ''}'
          '，地址 $resolved');
      // 按源记同步结果（含本次实际生效的基址）——供界面逐源如实展示
      _syncInfo[identityKeyFor(source)] = FdroidSyncInfo(
        at: DateTime.now(),
        incremental: incremental,
        totalApps: (m['total_apps'] as num?)?.toInt(),
        elapsedMs: (m['download_time_ms'] as num?)?.toInt(),
        verified: m['verified'] == true,
        resolvedUrl: resolved,
      );
      if (resolved != null && resolved.isNotEmpty) {
        _resolvedBases[identityKeyFor(source)] = resolved;
      }
      notifyListeners();
    } catch (_) {
      // 摘要仅用于诊断，解析失败不影響主流程
    }
  }

  Future<void> _syncSignerFingerprint(FdroidSource source, List<int> payload) async {
    _logDownloadSummary(source, payload);
    final fp = _fingerprintOf(payload);
    if (fp.isEmpty) return;
    final i = _sources.indexWhere((s) => s.id == source.id);
    if (i < 0) return;
    final recorded = (_sources[i].fingerprint ?? '').replaceAll(':', '').toUpperCase();
    final actual = fp.replaceAll(':', '').toUpperCase();

    for (final other in _sources) {
      if (other.id == source.id) continue;
      final o = (other.fingerprint ?? '').replaceAll(':', '').toUpperCase();
      if (o.isNotEmpty && o == actual) {
        appLog.warning('FdroidRepoManager: 「${source.name}」与「${other.name}」**同源**'
            '（签名指纹一致）——按 F-Droid 层级应只保留一个源，其余作为它的镜像');
      }
    }

    if (recorded.isEmpty) {
      _sources[i] = _sources[i].copyWith(fingerprint: fp);
      await _saveSources();
      // 回填后 `_sources[i]` 已带上指纹：若它就是当前源，同步刷新引用并重挂 Rust
      // 活动源（`_currentSource` 陈旧会让读路径继续拿旧对象）。
      if (_currentSource?.id == _sources[i].id) {
        _currentSource = _sources[i];
        rust.FdroidRustRepoManager.setActiveSource(_currentSource!);
      }
      appLog.info('FdroidRepoManager: 已从签名回填「${source.name}」指纹 $fp');
    } else if (recorded != actual) {
      appLog.warning('FdroidRepoManager: 「${source.name}」指纹与记录不一致'
          '（记录=$recorded，实际=$actual）——仓库可能更换了签名密钥');
    }
  }

  /// **已启用**的源（多源同时生效；F-Droid 本身就是多源并存的设计）
  List<FdroidSource> get enabledSources =>
      _sources.where((s) => s.enabled).toList(growable: false);

  /// 启用/禁用某个源（多选，不是单选）
  Future<void> setSourceEnabled(String sourceId, bool enabled) async {
    final i = _sources.indexWhere((s) => s.id == sourceId);
    if (i < 0) return;
    _sources[i] = _sources[i].copyWith(enabled: enabled);
    notifyListeners();
    await _saveSources();
    appLog.info('FdroidRepoManager: ${enabled ? "启用" : "禁用"}源 ${_sources[i].name}');
  }

  /// 逐个加载全部已启用源：每个源用自己的镜像配置下载到自己的库；
  /// 单个源失败只记错误，不影响其它源（多源的可用性靠这一条保证）。
  ///
  /// 每个源走**身份键单飞**（[Future.wait] 并发）：与搜索读取同槽，
  /// 不再有"已加载中直接跳过"导致某源永远空库。
  Future<int> loadAllEnabled() async {
    final targets = enabledSources;
    if (targets.isEmpty) {
      _errorMessage = '没有已启用的源';
      notifyListeners();
      return 0;
    }
    _errorMessage = '';
    _beginLoading();
    _loadingProgress = 0.0;
    notifyListeners();

    try {
      // 单源失败在 `_loadOneSource` 内部隔离（ok=false、count=0），不会中断其它源。
      // 求和只取 count：与旧实现（失败返回 0）逐字节等价。
      final results = await Future.wait(targets.map(_ensureSourceLoaded));
      final total = results.fold<int>(0, (sum, r) => sum + r.count);
      _loadingProgress = 1.0;
      appLog.info('FdroidRepoManager: 多源加载完成，共 $total 个应用（${targets.length} 个源）');
      return total;
    } finally {
      _finishLoading();
    }
  }

  /// 跨源搜索：合并各已启用源的结果，按包名去重（**优先级高者胜**）
  Future<List<Map<String, dynamic>>> searchAppsAcross(String keyword, {int limit = 50}) async {
    final targets = enabledSources.isEmpty ? [_currentSource].whereType<FdroidSource>().toList() : enabledSources;
    final sorted = [...targets]..sort((a, b) => a.priority.compareTo(b.priority));
    // 读路径先确保各源就绪（仅空库才下载；已就绪不重复下载）——这是修复
    // "插件加载成功但搜索恒空"的关键一步。
    // 故意**不**处理 forceRefresh：发现页每次击键都传 true（discovery/logic.dart
    // 的搜索调用），若据此重下会打爆网络；是否需要下载一律以"空库"为准。
    final readiness = await _ensureDataFor(sorted);
    if (!readiness.hasData && readiness.failures > 0) {
      throw StateError(_errorMessage?.isNotEmpty == true ? _errorMessage! : 'F-Droid 仓库不可用');
    }
    if (!readiness.hasData && readiness.empties > 0) {
      // 所有源都**加载成功**但索引为空：合法空仓库 → 返回空列表而非报错。
      appLog.warning('FdroidRepoManager: 所有源加载成功但没有任何应用'
          '（${readiness.empties} 个源索引为空）');
    }
    final merged = <String, Map<String, dynamic>>{};
    for (final source in sorted) {
      try {
        final apps = await rust.FdroidRustRepoManager.searchAppsIn(source, keyword, limit: limit);
        for (final a in apps) {
          merged.putIfAbsent(
            a.packageName,
            () => {
              'packageName': a.packageName,
              'name': a.name,
              'summary': a.summary,
              'icon': a.icon,
              'license': a.license,
              'authorName': a.authorName,
              'sourceCode': a.sourceCode,
              'webSite': a.webSite,
              'categories': a.categories,
              'added': a.added,
              'lastUpdated': a.lastUpdated,
              // 来源源 ID：详情/安装需要路由回正确的库
              'sourceId': source.id,
              // 版本级元数据（原始 JSON；由 Dart 侧宽松解析）
              'metadata': a.metadata,
              'versions': a.versions,
            },
          );
        }
      } catch (e) {
        appLog.error('FdroidRepoManager: 源 ${source.name} 搜索失败 - $e');
      }
    }
    return merged.values.take(limit).toList();
  }

  /// 更新一个源的配置（如镜像启用/增删、是否启用镜像回退）并持久化
  Future<void> updateSource(FdroidSource source) async {
    final i = _sources.indexWhere((s) => s.id == source.id);
    if (i < 0) return;
    final old = _sources[i];
    _sources[i] = source;
    if (_currentSource?.id == source.id) {
      _currentSource = source;
      rust.FdroidRustRepoManager.setActiveSource(source);
    }

    // **逻辑身份**（指纹优先 / 归一化地址）变了 → 旧库数据已不再属于这个源，
    // 清空该库槽，避免编辑后长期展示陈旧索引。存储槽位本身由 `storageIdentity`
    // （稳定 id）决定，因此"同一身份内的改动"（如镜像/启用镜像回退）不会误清。
    final logicalChanged = !rust.FdroidRustRepoManager.sameLogicalIdentity(
      oldFingerprint: old.fingerprint,
      oldRepoUrl: old.repoUrl,
      newFingerprint: source.fingerprint,
      newRepoUrl: source.repoUrl,
    );
    if (logicalChanged) {
      try {
        final inst = await rust.FdroidRustRepoManager.instanceForSource(source);
        await inst.callModule('clear_apps');
        appLog.info('FdroidRepoManager: 源「${source.name}」逻辑身份已变，已清空其库槽');
      } catch (e) {
        appLog.error('FdroidRepoManager: 清空源「${source.name}」库槽失败 - $e');
      }
    }

    notifyListeners();
    await _saveSources();
  }

  Future<void> removeSource(String sourceId) async {
    _sources.removeWhere((s) => s.id == sourceId);
    notifyListeners();
    await _saveSources();

    // 如果删除的是当前源，切换到第一个可用源
    if (_currentSource?.id == sourceId) {
      final nextSource = _firstWhereOrNull(_sources, (s) => s.enabled);
      if (nextSource != null) {
        _currentSource = nextSource;
        rust.FdroidRustRepoManager.setActiveSource(nextSource);
        notifyListeners();
      }
    }
  }

  /// 清空当前数据
  Future<void> clearData() async {
    appLog.info('FdroidRepoManager: 开始清空数据...');

    try {
      // 调用 Rust 清空数据库
      final count = await rust.FdroidRustRepoManager.clearApps();
      appLog.info('FdroidRepoManager: 已清空 $count 个应用');
    } catch (e) {
      appLog.error('FdroidRepoManager: 清空数据失败 - $e');
      rethrow;
    }
  }

  /// 获取一个应用（用于调试）
  Future<Map<String, dynamic>?> getOneApp() async {
    try {
      final app = await rust.FdroidRustRepoManager.getOneApp();
      if (app != null) {
        return rust.FdroidRustRepoManager.appInfoToMap(app);
      }
      return null;
    } catch (e) {
      appLog.error('FdroidRepoManager: 获取应用失败 - $e');
      return null;
    }
  }

  /// 获取应用文档目录
  Future<Directory> _getApplicationDocumentsDirectory() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      return directory;
    } catch (e) {
      appLog.error('FdroidRepoManager: 获取文档目录失败，使用默认路径: $e');
    }

    // 回退到简单实现
    final home = Platform.environment['HOME'];
    if (home != null) {
      return Directory(path.join(home, '.gstore'));
    }
    return Directory.current;
  }
}

/// 一次读路径的"源就绪"结果。
///
/// - [hasData]：至少有一个源在补齐后拥有 > 0 个应用（可直接读）。
/// - [failures]：**加载失败**（ok=false，含异常/取消/超时）的源数量。
/// - [empties]：加载**成功**但索引为 0 个应用的源数量（诊断用；不参与报错判定）。
///
/// 调用方据此判定"全空且确有失败"才报错，避免把"合法空结果"误报为故障。
class _RepoReadiness {
  const _RepoReadiness({
    required this.hasData,
    required this.failures,
    this.empties = 0,
  });

  final bool hasData;
  final int failures;
  final int empties;
}
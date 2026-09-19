import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:gstore/core/config/config_registry.dart';
import 'package:gstore/core/config/config_service.dart';
import 'package:gstore/core/fdroid/FdroidRepoModels.dart';
import 'package:gstore/core/logger/LogManager.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
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
  @override
  String identityKeyFor(FdroidSource source) =>
      rust.FdroidRustRepoManager.sourceIdentity(
        fingerprint: source.fingerprint,
        repoUrl: source.repoUrl,
      );

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
          rust.FdroidRustRepoManager.setActiveSource(lastSource);
          notifyListeners();
          appLog.info('FdroidRepoManager: 恢复上次选中的源: $lastSource');
        } else {
          _currentSource = enabledSource;
        rust.FdroidRustRepoManager.setActiveSource(enabledSource);
          rust.FdroidRustRepoManager.setActiveSource(enabledSource);
          notifyListeners();
        }
      } else {
        _currentSource = enabledSource;
        notifyListeners();
      }

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

  /// 加载仓库数据
  Future<void> loadRepository({bool forceRefresh = false}) async {
    debugPrint('FdroidRepoManager: loadRepository 被调用');

    // 防止重复加载
    if (_isLoading) {
      debugPrint('FdroidRepoManager: 已在加载中，跳过重复请求');
      return;
    }

    final source = _currentSource;
    if (source == null) {
      appLog.error('FdroidRepoManager: 源为 null，返回错误');
      _errorMessage = '请先选择一个源';
      notifyListeners();
      return;
    }

    appLog.info('FdroidRepoManager: 开始加载源: ${source.name} (${source.repoUrl})');

    _isLoading = true;
    notifyListeners();
    _errorMessage = '';
    _loadingProgress = 0.0;
    notifyListeners();

    try {
      debugPrint('FdroidRepoManager: 使用 Rust 后端下载（Task 模式）...');
      // Task 模式：宿主自有线程执行，阶段进度真实上报（不再硬编码 0.5）
      // 该源**已启用**的镜像：useMirrors 关闭时不传（等价于不用镜像）；
      // 开启时优先走镜像（国内网络避免先卡在官方站超时）
      final enabledMirrors = [
        for (final m in source.mirrors)
          if (m.enabled) m.url,
      ];
      final task = await rust.FdroidRustRepoManager.downloadRepositoryTask(
        repoUrl: source.repoUrl,
        mirrors: source.useMirrors ? enabledMirrors : const [],
        mirrorFirst: source.useMirrors && enabledMirrors.isNotEmpty,
      );
      final sub = task.progress.listen((p) {
        final phase = p.json?['phase'] as String?;
        final next = switch (phase) {
          'downloading' => 0.3,
          'stored' => 0.9,
          _ => _loadingProgress,
        };
        if (next != _loadingProgress) {
          _loadingProgress = next;
          notifyListeners();
        }
      });
      final result = await task.completion;
      await sub.cancel();
      if (result.outcome == RustTaskOutcome.error) {
        throw Exception('仓库下载失败: ${result.error}');
      }
      if (result.outcome == RustTaskOutcome.cancelled) {
        throw Exception('仓库下载已取消');
      }

      _loadingProgress = 1.0;
      notifyListeners();
      appLog.info('FdroidRepoManager: Rust 后端下载完成');
      // 记录本次同步摘要（增量/全量、实际地址、应用数）——供界面如实展示
      _logDownloadSummary(source, result.payload);
      appLog.info('FdroidRepoManager: 仓库加载完成');
    } catch (e) {
      appLog.error('FdroidRepoManager: 加载仓库失败 - $e');
      _errorMessage = '加载失败: $e';
      notifyListeners();
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 搜索应用
  Future<List<Map<String, dynamic>>> searchApps(String keyword, {int limit = 50}) =>
      searchAppsAcross(keyword, limit: limit);

  Future<List<Map<String, dynamic>>> searchAppsLegacy(String keyword, {int limit = 50}) async {
    final source = _currentSource;
    if (source == null) {
      throw Exception('请先选择一个源');
    }

    try {
      appLog.info('开始搜索 F-Droid 应用', data: {
        'keyword': keyword,
        'limit': limit,
        'source': source.name,
      });

      // 确保数据已加载
      final appCount = await rust.FdroidRustRepoManager.getAppCount();
      if (appCount == 0) {
        appLog.warning('数据库中没有应用，开始加载仓库');
        await loadRepository();
      }

      final results = await rust.FdroidRustRepoManager.searchApps(keyword, limit: limit);

      // 输出每个应用的详细信息到日志
      for (var i = 0; i < results.length; i++) {
        final app = results[i];
        final appMap = rust.FdroidRustRepoManager.appInfoToMap(app);

        appLog.info('应用 #${i + 1}/${results.length}', data: {
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

      appLog.info('搜索完成', data: {
        'keyword': keyword,
        'resultCount': results.length,
      });

      return results.map((app) => rust.FdroidRustRepoManager.appInfoToMap(app)).toList();
    } catch (e) {
      appLog.error('搜索失败', data: {
        'keyword': keyword,
        'error': e.toString(),
      });
      appLog.error('FdroidRepoManager: 搜索失败 - $e');
      rethrow;
    }
  }

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
        // 接受三种标识：记录 id / 指纹 / **仓库身份键**（渠道记录里存的是身份键）
        if (s.id == sourceId ||
            s.fingerprint == sourceId ||
            rust.FdroidRustRepoManager.sourceIdentity(
                    fingerprint: s.fingerprint, repoUrl: s.repoUrl) ==
                sourceId) {
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
        // ★ 按**仓库身份键**判重：多个来源的 `id` 可能相同（默认源 id 是固定的 'official'），
        //   按 id 判重会把第三方源当成重复跳过（真机：candidates 只剩 1 个 → 查不到）
        final k = rust.FdroidRustRepoManager.sourceIdentity(
            fingerprint: s.fingerprint, repoUrl: s.repoUrl);
        final dup = candidates.any((c) =>
            c.id == s.id ||
            rust.FdroidRustRepoManager.sourceIdentity(
                    fingerprint: c.fingerprint, repoUrl: c.repoUrl) ==
                k);
        if (!dup) candidates.add(s);
      }
    }

    try {
      appLog.info('开始精确查询应用（跨源）', data: {
        'packageName': packageName,
        'sourceId': sourceId ?? '(全部已启用源)',
        'candidates': candidates.length,
      });

      // 候选源都为空 → 先加载一次（每源各自独立的库）
      var hasData = false;
      for (final s in candidates) {
        if (await rust.FdroidRustRepoManager.appCountIn(s) > 0) {
          hasData = true;
          break;
        }
      }
      if (!hasData) {
        appLog.warning('候选源均无数据，开始加载已启用源');
        await loadAllEnabled();
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

  /// 获取所有应用
  Future<List<Map<String, dynamic>>> getAllApps() async {
    final source = _currentSource;
    if (source == null) {
      throw Exception('请先选择一个源');
    }

    try {
      appLog.info('开始获取所有 F-Droid 应用', data: {
        'source': source.name,
      });

      // 确保数据已加载
      final appCount = await rust.FdroidRustRepoManager.getAppCount();
      appLog.info('数据库应用数量', data: {
        'count': appCount,
      });

      if (appCount == 0) {
        appLog.warning('数据库中没有应用，开始加载仓库');
        await loadRepository();
      }

      // 搜索空字符串获取所有应用
      final results = await rust.FdroidRustRepoManager.searchApps('', limit: 100000);

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
    _sources.add(source);
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
  /// 1) 源没记指纹 → **自动回填**（身份从此由密钥决定，换域名/换镜像都不影响）
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
  Future<int> loadAllEnabled() async {
    final targets = enabledSources;
    if (targets.isEmpty) {
      _errorMessage = '没有已启用的源';
      notifyListeners();
      return 0;
    }
    _isLoading = true;
    _errorMessage = '';
    _loadingProgress = 0.0;
    notifyListeners();

    var total = 0;
    final failures = <String>[];
    try {
      for (var i = 0; i < targets.length; i++) {
        final source = targets[i];
        try {
          appLog.info(
              'FdroidRepoManager: 加载源 ${i + 1}/${targets.length} - ${source.name}');
          final task = await rust.FdroidRustRepoManager.downloadRepositoryTaskFor(source);
          final sub = task.progress.listen((p) {
            final phase = p.json?['phase'] as String?;
            final base = i / targets.length;
            final span = 1 / targets.length;
            if (phase == 'index') {
              // 索引下载是耗时主体：用**真实字节百分比**在 0.3→0.9 之间推进
              final pct = (p.json?['percent'] as num?)?.toInt() ?? 0;
              _loadingProgress =
                  (base + span * (0.3 + 0.6 * pct / 100)).clamp(0.0, 1.0);
            } else {
              final inner = switch (phase) { 'downloading' => 0.3, 'stored' => 0.9, _ => 0.0 };
              _loadingProgress = (base + span * inner).clamp(0.0, 1.0);
            }
            notifyListeners();
          });
          final result = await task.completion;
          await sub.cancel();
          if (result.outcome == RustTaskOutcome.error) {
            failures.add('${source.name}: ${result.error}');
            continue;
          }
          // 用**签名里提取的真实指纹**做事后校验：自动回填 + 同源判定
          await _syncSignerFingerprint(source, result.payload);
          total += await rust.FdroidRustRepoManager.appCountIn(source);
        } catch (e) {
          failures.add('${source.name}: $e');
        }
      }
      _loadingProgress = 1.0;
      if (failures.isNotEmpty) {
        _errorMessage = '部分源加载失败: ${failures.join("; ")}';
      }
      appLog.info('FdroidRepoManager: 多源加载完成，共 $total 个应用（失败 ${failures.length} 个源）');
      return total;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 跨源搜索：合并各已启用源的结果，按包名去重（**优先级高者胜**）
  Future<List<Map<String, dynamic>>> searchAppsAcross(String keyword, {int limit = 50}) async {
    final targets = enabledSources.isEmpty ? [_currentSource].whereType<FdroidSource>().toList() : enabledSources;
    final sorted = [...targets]..sort((a, b) => a.priority.compareTo(b.priority));
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
    _sources[i] = source;
    if (_currentSource?.id == source.id) {
      _currentSource = source;
      rust.FdroidRustRepoManager.setActiveSource(source);
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
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug_models.dart';
import 'debug_secrets.dart';

/// 目录提供者接缝：生产用应用文档目录，测试注入临时目录。
typedef DebugStoreDirectoryProvider = Future<Directory> Function();

/// 「请求调试」JSON 文件存储。
///
/// 设计要点（见 `.omo/plans/proxy-http-capture.md` todo 25）：
/// - **单文件**：应用文档目录下 `request_debug_store.json`；
/// - **原子写**：先写 `<file>.tmp` 再 `rename` 覆盖，避免半截文件；
///   写失败返回 `false` 且不抛（页面据此 `showError`）；
/// - **损坏降级**：读取失败 / 根类型错误 → 空 store + 警告，绝不抛；
///   单条脏数据逐条跳过（好的条目保留）；
/// - **可注入**：构造函数接受 [directoryProvider]，测试用临时目录；
/// - **有界**：历史超过 [historyLimit] 时淘汰最旧（加载时也再裁剪一次）。
///
/// 本类**不含** UI / 网络；CRUD 均为内存操作，持久化由调用方显式 [save]。
class RequestDebugStore {
  RequestDebugStore({
    DebugStoreDirectoryProvider? directoryProvider,
    DebugSecureStorage? secureStorage,
    this.historyLimit = defaultHistoryLimit,
    this.collectionLimit = defaultCollectionLimit,
    this.requestLimit = defaultRequestLimit,
    this.environmentLimit = defaultEnvironmentLimit,
    this.ruleLimit = defaultRuleLimit,
    this.maxFileBytes = defaultMaxFileBytes,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationDocumentsDirectory,
        _codec = secureStorage == null
            ? null
            : DebugSecretCodec(secureStorage),
        assert(historyLimit >= 0, 'historyLimit 不能为负'),
        assert(collectionLimit >= 0, 'collectionLimit 不能为负'),
        assert(requestLimit >= 0, 'requestLimit 不能为负'),
        assert(environmentLimit >= 0, 'environmentLimit 不能为负'),
        assert(ruleLimit >= 0, 'ruleLimit 不能为负'),
        assert(maxFileBytes >= 0, 'maxFileBytes 不能为负');

  /// 存储文件名（测试据此定位文件）。
  static const String fileName = 'request_debug_store.json';

  /// 默认历史上限。
  static const int defaultHistoryLimit = 200;

  /// 当前 schema 版本。
  ///
  /// v2 相对 v1 引入了历史响应快照 / 每请求网络选项 / 环境密钥标记与密钥引用
  /// （todos 3/4/6/9）；这些字段在 v2 由模型**容忍解码**处理，v1→v2 迁移只需
  /// 规范化根节点结构并保留全部原始数据（见 [_migrateV1ToV2]）。
  static const int schemaVersion = 2;

  /// 无 `version` 字段（或非法值）时假定的旧版本。
  static const int legacySchemaVersion = 1;

  /// 默认集合数上限。
  static const int defaultCollectionLimit = 1000;

  /// 默认请求总数上限（跨全部集合）。
  static const int defaultRequestLimit = 5000;

  /// 默认环境数上限。
  static const int defaultEnvironmentLimit = 100;

  /// 默认改写规则数上限。
  static const int defaultRuleLimit = 1000;

  /// 默认单文件序列化体积上限（字节）。
  static const int defaultMaxFileBytes = 16 * 1024 * 1024;

  final DebugStoreDirectoryProvider _directoryProvider;

  /// 密钥编解码接缝：`null` 表示未配置安全存储（旧行为：密钥明文随文件存）。
  ///
  /// 生产装配（[DefaultRequestDebugFacade.production]）注入
  /// [FlutterDebugSecureStorage]；测试可注入内存假实现。未注入时保持向后
  /// 兼容（既有测试 / 无密钥用户不受影响）。
  final DebugSecretCodec? _codec;

  /// 历史条数上限（`0` 表示不留历史）。
  final int historyLimit;

  /// 集合数上限（加载时超出部分跳过）。
  final int collectionLimit;

  /// 请求总数上限（跨全部集合；加载时超出部分跳过）。
  final int requestLimit;

  /// 环境数上限（加载时超出部分跳过）。
  final int environmentLimit;

  /// 改写规则数上限（加载时超出部分跳过）。
  final int ruleLimit;

  /// 单文件序列化体积上限（字节）；超出时保存失败（可见），不写半成品。
  final int maxFileBytes;

  /// 磁盘上读到的 schema 版本（用于检测「未来版本」并拒绝降级写入）。
  int? _loadedDiskVersion;

  /// 未完成的保存（单飞）：并发 [save] 合并到同一个最终落盘。
  Future<bool>? _activeSave;

  /// 保存进行中是否又有新的保存请求（合并语义：最终以最新状态落盘）。
  bool _resaveRequested = false;

  /// 集合（含嵌套请求）。
  final List<DebugCollection> collections = [];

  /// 环境。
  final List<DebugEnvironment> environments = [];

  /// 历史（最新在前）。
  final List<DebugHistoryEntry> history = [];

  /// 改写规则。
  final List<DebugRewriteRule> rules = [];

  /// 当前激活环境 id。
  String? activeEnvironmentId;

  /// 是否已尝试加载。
  bool loaded = false;

  /// 当前激活环境（未设置 / 不存在时返回 `null`）。
  DebugEnvironment? get activeEnvironment => activeEnvironmentId == null
      ? null
      : environmentById(activeEnvironmentId!);

  // ==================== 持久化 ====================

  Future<File> _file() async {
    final dir = await _directoryProvider();
    return File(p.join(dir.path, fileName));
  }

  void _warn(String message) =>
      debugPrint('[RequestDebugStore] $message');

  void _reset() {
    collections.clear();
    environments.clear();
    history.clear();
    rules.clear();
    activeEnvironmentId = null;
    _loadedDiskVersion = null;
  }

  /// 磁盘版本高于当前 schema（未知未来版本）：只读降级加载，且拒绝降级写入。
  bool get hasUnsupportedVersion =>
      _loadedDiskVersion != null && _loadedDiskVersion! > schemaVersion;

  /// 迁移前原始文件备份路径（测试据此定位备份）。
  static String migrationBackupPath(String storeFilePath, int fromVersion) =>
      '$storeFilePath.v$fromVersion.bak';

  /// 迁移表：`源版本 → 迁移函数`。新增版本时在此登记一步。
  ///
  /// 采用**逐步**迁移（`v1→v2→…`），每步只负责相邻版本间的结构变化；任何
  /// 未知步骤都会停止迁移但仍保留全部数据（不丢用户内容）。
  static final Map<int, Map<String, dynamic> Function(Map<String, dynamic>)>
      _migrations =
      <int, Map<String, dynamic> Function(Map<String, dynamic>)>{
    1: _migrateV1ToV2,
  };

  /// v1 → v2 结构迁移。
  ///
  /// v2 新增的字段（历史响应快照 / 每请求网络选项 / `secretVars` / 密钥引用）
  /// 都由模型**容忍解码**处理，因此本步只规范化根节点数组结构；所有原始数据
  /// 原样保留（包括本步不认识的字段），绝不因迁移丢弃用户内容。
  static Map<String, dynamic> _migrateV1ToV2(Map<String, dynamic> root) {
    final out = Map<String, dynamic>.of(root);
    for (final key
        in const <String>['collections', 'environments', 'history', 'rules']) {
      if (out[key] is! List) out[key] = <dynamic>[];
    }
    return out;
  }

  /// 读取并校验磁盘 `version` 字段。
  ///
  /// 缺失 / 非数字 / 小于 1 → 视为旧版 [legacySchemaVersion]（旧格式兼容）。
  static int _readVersion(Map<String, dynamic> root) {
    final raw = root['version'];
    int? version;
    if (raw is int) {
      version = raw;
    } else if (raw is num) {
      version = raw.toInt();
    } else if (raw is String) {
      version = int.tryParse(raw);
    }
    if (version == null || version < 1) return legacySchemaVersion;
    return version;
  }

  /// 执行 [fromVersion] → 当前版本的逐步迁移，并把结果标记为当前版本。
  Map<String, dynamic> _migrate(Map<String, dynamic> root, int fromVersion) {
    var current = root;
    var version = fromVersion;
    while (version < schemaVersion) {
      final step = _migrations[version];
      if (step == null) {
        _warn('缺少 v$version → v${version + 1} 迁移步骤，停止结构迁移（数据保留）');
        break;
      }
      current = step(current);
      version++;
    }
    current['version'] = schemaVersion;
    return current;
  }

  /// 迁移前备份原始文件（写一次，保留最早的原始内容）。
  Future<void> _backupBeforeMigration(
    File file,
    String raw,
    int fromVersion,
  ) async {
    try {
      final backup = File(migrationBackupPath(file.path, fromVersion));
      if (!await backup.exists()) {
        await backup.writeAsString(raw, flush: true);
      }
    } catch (e) {
      // 备份失败不阻断加载（内存数据仍在）；但会留下警告便于排查。
      _warn('迁移前备份失败: $e');
    }
  }

  /// 从磁盘加载。
  ///
  /// 文件不存在 / 为空 → 空 store；JSON 损坏 / 根类型错误 → 空 store + 警告；
  /// 单条脏数据被跳过。**任何情况下都不抛异常**。
  ///
  /// 版本处理（todo 10）：
  /// - `version < schemaVersion`：先备份原始文件，再逐步迁移并立即落盘；
  /// - `version == schemaVersion`：正常加载；
  /// - `version > schemaVersion`（未知未来版本）：只读降级加载，不迁移、不重写、
  ///   之后拒绝 [save]（避免用旧 schema 覆盖并抹除用户数据）。
  Future<void> load() async {
    _reset();
    try {
      final file = await _file();
      if (!await file.exists()) {
        loaded = true;
        return;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        loaded = true;
        return;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('store 根节点不是 JSON 对象');
      }
      var map = decoded.cast<String, dynamic>();
      final diskVersion = _readVersion(map);
      _loadedDiskVersion = diskVersion;

      var migratedStructure = false;
      if (diskVersion > schemaVersion) {
        _warn('检测到未知的未来版本 v$diskVersion（当前 v$schemaVersion）：'
            '只读降级加载，不迁移、不重写、拒绝降级保存');
      } else if (diskVersion < schemaVersion) {
        await _backupBeforeMigration(file, raw, diskVersion);
        map = _migrate(map, diskVersion);
        migratedStructure = true;
      }

      var migratedSecrets = false;
      final codec = _codec;
      if (codec != null) {
        try {
          final opened = await codec.open(map);
          map = opened.root;
          migratedSecrets = opened.migrated;
        } catch (e) {
          // 安全存储解析失败不阻断加载：按原始 JSON（明文 / 引用）继续。
          _warn('密钥解析失败，按原始内容加载: $e');
        }
      }
      collections.addAll(_parseList(map['collections'], DebugCollection.fromJson));
      environments.addAll(
          _parseList(map['environments'], DebugEnvironment.fromJson));
      history.addAll(_parseList(map['history'], DebugHistoryEntry.fromJson));
      rules.addAll(_parseList(map['rules'], DebugRewriteRule.fromJson));
      final active = map['activeEnvironmentId'];
      activeEnvironmentId =
          active is String && active.isNotEmpty ? active : null;
      _applyCaps();
      _enforceHistoryCap();
      _backfillCollectionIds();
      loaded = true;
      // 结构迁移 / 旧明文密钥迁移：一次性改写文件（未知未来版本除外）。
      if (!hasUnsupportedVersion && (migratedStructure || migratedSecrets)) {
        await save();
      }
    } catch (e) {
      _warn('读取失败，使用空存储: $e');
      _reset();
      loaded = true;
    }
  }

  /// 原子写入磁盘（唯一临时文件 + rename）。
  ///
  /// **单飞（single-flight）**：并发调用被合并——若已有保存在进行，则标记需
  /// 重写并复用同一 Future；进行中的保存在完成后若发现期间又有修改，会再写一次，
  /// **保证最终以最新内存状态落盘**。成功返回 `true`，失败返回 `false` 且不抛。
  ///
  /// 配置了安全存储时，明文密钥在序列化前被替换为引用（[DebugSecretCodec.seal]）；
  /// 序列化超过 [maxFileBytes] 时**跳过写入**并返回失败（不写半成品）。
  /// 磁盘为未知未来版本时拒绝降级写入（不抹除用户数据）。
  Future<bool> save() {
    final active = _activeSave;
    if (active != null) {
      _resaveRequested = true;
      return active;
    }
    final future = _runSaveLoop();
    _activeSave = future;
    return future;
  }

  Future<bool> _runSaveLoop() async {
    var ok = true;
    try {
      do {
        _resaveRequested = false;
        ok = await _writeOnce();
      } while (ok && _resaveRequested);
      return ok;
    } finally {
      _activeSave = null;
    }
  }

  Future<bool> _writeOnce() async {
    File? tmp;
    try {
      if (hasUnsupportedVersion) {
        _warn('磁盘版本 v$_loadedDiskVersion 高于当前 v$schemaVersion，'
            '拒绝降级写入以免抹除用户数据');
        return false;
      }
      var root = _toJson();
      final codec = _codec;
      if (codec != null) {
        root = await codec.seal(root);
      }
      final data = jsonEncode(root);
      final bytes = utf8.encode(data).length;
      if (bytes > maxFileBytes) {
        _warn('序列化 $bytes 字节超过体积上限 $maxFileBytes，跳过写入');
        return false;
      }
      final file = await _file();
      tmp = await _createTemp(file);
      await tmp.writeAsString(data, flush: true);
      await tmp.rename(file.path);
      return true;
    } catch (e) {
      _warn('保存失败: $e');
      return false;
    } finally {
      final t = tmp;
      if (t != null) {
        try {
          if (await t.exists()) await t.delete();
        } catch (_) {
          // 清理失败（如 tmp 路径被目录占用）不影响结果。
        }
      }
    }
  }

  /// 创建**唯一（独占）**的临时文件：O_EXCL 保证两个写入者绝不会共享同一临时
  /// 文件；若该路径被目录 / 链接占用则创建失败 → 保存可见失败而非写坏数据。
  ///
  /// 先回收上次崩溃可能残留的**普通文件**临时（单飞保证本实例无并发写）。
  Future<File> _createTemp(File target) async {
    final path = '${target.path}.tmp';
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      try {
        await File(path).delete();
      } catch (_) {
        // 回收失败则交由随后的独占创建报错。
      }
    }
    final tmp = File(path);
    await tmp.create(exclusive: true);
    return tmp;
  }

  Map<String, dynamic> _toJson() => {
        'version': schemaVersion,
        'activeEnvironmentId': activeEnvironmentId,
        'collections': collections.map((e) => e.toJson()).toList(),
        'environments': environments.map((e) => e.toJson()).toList(),
        'history': history.map((e) => e.toJson()).toList(),
        'rules': rules.map((e) => e.toJson()).toList(),
      };

  /// 逐条解析：非对象 / 脏条目跳过，不牵连整份数据。
  ///
  /// 集合内的损坏请求由模型层的逐项容错隔离（见 `debug_models.dart`），
  /// 因此单个坏请求不会导致整个集合被丢弃。
  List<T> _parseList<T>(
    Object? raw,
    T Function(Map<String, dynamic>) parse,
  ) {
    if (raw is! List) return [];
    final out = <T>[];
    for (final item in raw) {
      if (item is! Map) {
        _warn('跳过非对象条目: $item');
        continue;
      }
      try {
        out.add(parse(item.cast<String, dynamic>()));
      } catch (e) {
        _warn('跳过脏条目: $e');
      }
    }
    return out;
  }

  /// 加载后裁剪到各上限：保留前 N、跳过其余（集合 / 请求总数 / 环境 / 规则）。
  void _applyCaps() {
    if (collections.length > collectionLimit) {
      _warn('集合数 ${collections.length} 超过上限 $collectionLimit，跳过其余');
      collections.removeRange(collectionLimit, collections.length);
    }
    var totalRequests = 0;
    for (final c in collections) {
      if (totalRequests >= requestLimit) {
        c.requests.clear();
        continue;
      }
      final allowed = requestLimit - totalRequests;
      if (c.requests.length > allowed) {
        _warn('请求总数超过上限 $requestLimit，跳过其余');
        c.requests.removeRange(allowed, c.requests.length);
      }
      totalRequests += c.requests.length;
    }
    if (environments.length > environmentLimit) {
      _warn('环境数 ${environments.length} 超过上限 $environmentLimit，跳过其余');
      environments.removeRange(environmentLimit, environments.length);
    }
    if (rules.length > ruleLimit) {
      _warn('规则数 ${rules.length} 超过上限 $ruleLimit，跳过其余');
      rules.removeRange(ruleLimit, rules.length);
    }
  }

  /// 嵌套请求回填 collectionId（磁盘缺省时补齐）。
  void _backfillCollectionIds() {
    for (final c in collections) {
      for (var i = 0; i < c.requests.length; i++) {
        if (c.requests[i].collectionId != c.id) {
          c.requests[i] = c.requests[i].copyWith(collectionId: c.id);
        }
      }
    }
  }

  /// 历史有界：超过 [historyLimit] 时从尾部淘汰最旧。
  void _enforceHistoryCap() {
    if (historyLimit <= 0) {
      history.clear();
      return;
    }
    if (history.length > historyLimit) {
      history.removeRange(historyLimit, history.length);
    }
  }

  // ==================== 集合 / 请求 CRUD ====================

  /// 新建集合 / 文件夹。
  DebugCollection addCollection({
    String? id,
    required String name,
    String? parentId,
  }) {
    final c = DebugCollection(
      id: id ?? generateDebugId('col'),
      name: name,
      parentId: parentId,
    );
    collections.add(c);
    return c;
  }

  /// 更新集合（按 id 替换）。
  bool updateCollection(DebugCollection collection) {
    final i = collections.indexWhere((e) => e.id == collection.id);
    if (i < 0) return false;
    collections[i] = collection;
    return true;
  }

  /// 删除集合及其所有后代（连带其下请求）。
  bool removeCollection(String id) {
    final doomed = <String>{};
    void collect(String cid) {
      if (!doomed.add(cid)) return;
      for (final c in collections) {
        if (c.parentId == cid) collect(c.id);
      }
    }

    collect(id);
    final before = collections.length;
    collections.removeWhere((c) => doomed.contains(c.id));
    return collections.length != before;
  }

  /// 按 id 查集合。
  DebugCollection? collectionById(String id) {
    for (final c in collections) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 向集合添加请求（自动回填 [DebugRequest.collectionId]）。
  ///
  /// **未知集合返回 `null`（失败），绝不静默成功**（todo 10）；调用方应据此
  /// 显式失败，而不是让请求无声消失。
  DebugRequest? addRequest(String collectionId, DebugRequest request) {
    final collection = collectionById(collectionId);
    if (collection == null) {
      _warn('未知集合 "$collectionId"，addRequest 返回失败');
      return null;
    }
    final linked = request.collectionId == collectionId
        ? request
        : request.copyWith(collectionId: collectionId);
    collection.requests.add(linked);
    return linked;
  }

  /// 更新请求（跨所有集合按 id 查找替换）。
  bool updateRequest(DebugRequest request) {
    for (final c in collections) {
      final i = c.requests.indexWhere((e) => e.id == request.id);
      if (i >= 0) {
        c.requests[i] = request;
        return true;
      }
    }
    return false;
  }

  /// 删除请求（跨所有集合）。
  bool removeRequest(String id) {
    var removed = false;
    for (final c in collections) {
      final before = c.requests.length;
      c.requests.removeWhere((e) => e.id == id);
      if (c.requests.length != before) removed = true;
    }
    return removed;
  }

  /// 按 id 查请求。
  DebugRequest? requestById(String id) {
    for (final c in collections) {
      for (final r in c.requests) {
        if (r.id == id) return r;
      }
    }
    return null;
  }

  // ==================== 排序 / 移动 / 复制 ====================

  /// 在集合内重排请求。
  ///
  /// 采用 Flutter `ReorderableListView.onReorderItem` 语义：`newIndex` 已按
  /// 「移除 `oldIndex`」调整，因此直接 `removeAt(oldIndex)` 后 `insert(newIndex)`。
  /// `oldIndex` / 未知集合越界返回 `false`（不修改）。
  bool reorderRequest(String collectionId, int oldIndex, int newIndex) {
    final collection = collectionById(collectionId);
    if (collection == null) return false;
    final requests = collection.requests;
    if (oldIndex < 0 || oldIndex >= requests.length) return false;
    final target = newIndex.clamp(0, requests.length - 1);
    final request = requests.removeAt(oldIndex);
    requests.insert(target, request);
    return true;
  }

  /// 把请求移动到 [toCollectionId]（可指定插入位置 [index]，`null` = 追加）。
  ///
  /// - 同集合 = 重排（[index] 以**移除前**的列表为准）；
  /// - 跨集合 = 从原集合移除、插入目标集合并回填 `collectionId`。
  ///
  /// 未知请求 / 未知目标集合返回 `false`（绝不静默成功）。
  bool moveRequest(String requestId, String toCollectionId, {int? index}) {
    final target = collectionById(toCollectionId);
    if (target == null) return false;
    final request = requestById(requestId);
    if (request == null) return false;
    DebugCollection? source;
    var sourceIndex = -1;
    for (final c in collections) {
      final i = c.requests.indexWhere((e) => e.id == requestId);
      if (i >= 0) {
        source = c;
        sourceIndex = i;
        c.requests.removeAt(i);
        break;
      }
    }
    final linked = request.collectionId == toCollectionId
        ? request
        : request.copyWith(collectionId: toCollectionId);
    var at = index ?? target.requests.length;
    // 同集合内移动：index 以移除前列表为准，移除后需回退一位。
    if (identical(source, target) && sourceIndex >= 0 && at > sourceIndex) {
      at -= 1;
    }
    at = at.clamp(0, target.requests.length);
    target.requests.insert(at, linked);
    return true;
  }

  /// 在同一 [parentId] 的兄弟集合间重排（`parentId == null` = 顶层）。
  ///
  /// `newIndex` 语义同 [reorderRequest]（已按移除调整）。`oldIndex` 越界返回
  /// `false`。
  bool reorderCollection(String? parentId, int oldIndex, int newIndex) {
    final siblings = <DebugCollection>[];
    final slots = <int>[];
    for (var i = 0; i < collections.length; i++) {
      if (collections[i].parentId == parentId) {
        siblings.add(collections[i]);
        slots.add(i);
      }
    }
    if (oldIndex < 0 || oldIndex >= siblings.length) return false;
    final target = newIndex.clamp(0, siblings.length - 1);
    final moved = siblings.removeAt(oldIndex);
    siblings.insert(target, moved);
    for (var k = 0; k < slots.length; k++) {
      collections[slots[k]] = siblings[k];
    }
    return true;
  }

  /// 把集合移动到新的父级（`null` = 顶层），可指定同级插入位置 [index]。
  ///
  /// 拒绝把集合移入**自身或其任一后代**（防止环）；未知集合返回 `false`。
  bool moveCollection(String collectionId, String? newParentId, {int? index}) {
    final collection = collectionById(collectionId);
    if (collection == null) return false;
    if (newParentId != null) {
      if (newParentId == collectionId) return false;
      // 沿新父级的祖先链上溯：遇到自身即为「移入后代」，拒绝。
      var cursor = collectionById(newParentId);
      while (cursor != null) {
        if (cursor.id == collectionId) return false;
        cursor = cursor.parentId == null
            ? null
            : collectionById(cursor.parentId!);
      }
    }
    final at = collections.indexOf(collection);
    collections[at] = DebugCollection(
      id: collection.id,
      name: collection.name,
      parentId: newParentId,
      requests: collection.requests,
    );
    if (index != null) {
      // 在新父级的兄弟序列中重新落位。
      final siblings = <DebugCollection>[];
      final slots = <int>[];
      for (var k = 0; k < collections.length; k++) {
        if (collections[k].parentId == newParentId) {
          siblings.add(collections[k]);
          slots.add(k);
        }
      }
      final from = siblings.indexWhere((e) => e.id == collectionId);
      if (from >= 0) {
        final to = index.clamp(0, siblings.length - 1);
        final moved = siblings.removeAt(from);
        siblings.insert(to, moved);
        for (var k = 0; k < slots.length; k++) {
          collections[slots[k]] = siblings[k];
        }
      }
    }
    return true;
  }

  /// 深拷贝请求：列表逐项复制（headers / query / multipart / cookies），
  /// 避免副本与原请求共享可变列表；可空字段保持哨兵语义。
  DebugRequest _cloneRequest(
    DebugRequest src, {
    required String id,
    required String? collectionId,
    String? name,
  }) =>
      DebugRequest(
        id: id,
        name: name ?? src.name,
        method: src.method,
        url: src.url,
        headers: src.headers.map((e) => e.copyWith()).toList(),
        query: src.query.map((e) => e.copyWith()).toList(),
        body: src.body,
        bodyKind: src.bodyKind,
        binarySource: src.binarySource,
        binaryFilePath: src.binaryFilePath,
        multipartFields: src.multipartFields.map((e) => e.copyWith()).toList(),
        auth: src.auth?.copyWith(),
        cookies: src.cookies.map((e) => e.copyWith()).toList(),
        collectionId: collectionId,
        overrides: src.overrides,
        timeoutMs: src.timeoutMs,
        followRedirects: src.followRedirects,
        useCookieJar: src.useCookieJar,
        skipTlsVerify: src.skipTlsVerify,
      );

  /// 复制请求：新 id、默认名称加 [suffix] 后缀，插入原请求之后（同一集合）。
  DebugRequest? duplicateRequest(String requestId, {String suffix = ' 副本'}) {
    for (final c in collections) {
      final i = c.requests.indexWhere((e) => e.id == requestId);
      if (i < 0) continue;
      final src = c.requests[i];
      final copy = _cloneRequest(
        src,
        id: generateDebugId('req'),
        collectionId: c.id,
        name: src.name.isEmpty ? src.name : '${src.name}$suffix',
      );
      c.requests.insert(i + 1, copy);
      return copy;
    }
    return null;
  }

  /// 复制集合：连同全部后代集合与请求生成新 id（`parentId` 重映射），插入原
  /// 集合之后。仅顶层副本名称加 [suffix]（后代保持原名）。
  DebugCollection? duplicateCollection(String collectionId,
      {String suffix = ' 副本'}) {
    final src = collectionById(collectionId);
    if (src == null) return null;
    final insertAt = collections.indexOf(src) + 1;
    final clones = <DebugCollection>[];
    final rootId = _cloneCollectionTree(
      src,
      src.parentId,
      clones,
      rootName: '${src.name}$suffix',
    );
    collections.insertAll(insertAt, clones);
    return collectionById(rootId);
  }

  /// 递归克隆集合树，返回新根 id；按 DFS 顺序把克隆追加到 [out]。
  String _cloneCollectionTree(
    DebugCollection src,
    String? parentId,
    List<DebugCollection> out, {
    String? rootName,
  }) {
    final newId = generateDebugId('col');
    final requests = src.requests
        .map((r) => _cloneRequest(
              r,
              id: generateDebugId('req'),
              collectionId: newId,
            ))
        .toList();
    out.add(DebugCollection(
      id: newId,
      name: rootName ?? src.name,
      parentId: parentId,
      requests: requests,
    ));
    for (final child in collections.where((e) => e.parentId == src.id)) {
      _cloneCollectionTree(child, newId, out);
    }
    return newId;
  }

  // ==================== 环境 CRUD ====================

  DebugEnvironment addEnvironment({
    String? id,
    required String name,
    Map<String, String>? vars,
    Set<String>? secretVars,
  }) {
    final e = DebugEnvironment(
      id: id ?? generateDebugId('env'),
      name: name,
      vars: vars,
      secretVars: secretVars,
    );
    environments.add(e);
    return e;
  }

  bool updateEnvironment(DebugEnvironment environment) {
    final i = environments.indexWhere((e) => e.id == environment.id);
    if (i < 0) return false;
    environments[i] = environment;
    return true;
  }

  bool removeEnvironment(String id) {
    final before = environments.length;
    environments.removeWhere((e) => e.id == id);
    if (activeEnvironmentId == id) activeEnvironmentId = null;
    return environments.length != before;
  }

  DebugEnvironment? environmentById(String id) {
    for (final e in environments) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 设置当前激活环境（不存在的 id 归零为 `null`）。
  void setActiveEnvironment(String? id) {
    activeEnvironmentId =
        (id != null && environmentById(id) != null) ? id : null;
  }

  // ==================== 历史 CRUD ====================

  /// 追加历史（最新在前），超出上限自动淘汰最旧。
  DebugHistoryEntry addHistory(DebugHistoryEntry entry) {
    history.insert(0, entry);
    _enforceHistoryCap();
    return entry;
  }

  bool removeHistory(String id) {
    final before = history.length;
    history.removeWhere((e) => e.id == id);
    return history.length != before;
  }

  void clearHistory() => history.clear();

  // ==================== 改写规则 CRUD ====================

  DebugRewriteRule addRule(DebugRewriteRule rule) {
    rules.add(rule);
    return rule;
  }

  bool updateRule(DebugRewriteRule rule) {
    final i = rules.indexWhere((e) => e.id == rule.id);
    if (i < 0) return false;
    rules[i] = rule;
    return true;
  }

  bool removeRule(String id) {
    final before = rules.length;
    rules.removeWhere((e) => e.id == id);
    return rules.length != before;
  }

  DebugRewriteRule? ruleById(String id) {
    for (final r in rules) {
      if (r.id == id) return r;
    }
    return null;
  }
}

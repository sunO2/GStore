import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'debug_models.dart';

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
    this.historyLimit = defaultHistoryLimit,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationDocumentsDirectory,
        assert(historyLimit >= 0, 'historyLimit 不能为负');

  /// 存储文件名（测试据此定位文件）。
  static const String fileName = 'request_debug_store.json';

  /// 默认历史上限。
  static const int defaultHistoryLimit = 200;

  /// 当前 schema 版本（为后续迁移预留）。
  static const int schemaVersion = 1;

  final DebugStoreDirectoryProvider _directoryProvider;

  /// 历史条数上限（`0` 表示不留历史）。
  final int historyLimit;

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
  }

  /// 从磁盘加载。
  ///
  /// 文件不存在 / 为空 → 空 store；JSON 损坏 / 根类型错误 → 空 store + 警告；
  /// 单条脏数据被跳过。**任何情况下都不抛异常**。
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
      final map = decoded.cast<String, dynamic>();
      collections.addAll(_parseList(map['collections'], DebugCollection.fromJson));
      environments.addAll(
          _parseList(map['environments'], DebugEnvironment.fromJson));
      history.addAll(_parseList(map['history'], DebugHistoryEntry.fromJson));
      rules.addAll(_parseList(map['rules'], DebugRewriteRule.fromJson));
      final active = map['activeEnvironmentId'];
      activeEnvironmentId =
          active is String && active.isNotEmpty ? active : null;
      _enforceHistoryCap();
      _backfillCollectionIds();
      loaded = true;
    } catch (e) {
      _warn('读取失败，使用空存储: $e');
      _reset();
      loaded = true;
    }
  }

  /// 原子写入磁盘（tmp + rename）。成功返回 `true`，失败返回 `false` 且不抛。
  Future<bool> save() async {
    File? tmp;
    try {
      final file = await _file();
      final data = jsonEncode(_toJson());
      tmp = File('${file.path}.tmp');
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

  Map<String, dynamic> _toJson() => {
        'version': schemaVersion,
        'activeEnvironmentId': activeEnvironmentId,
        'collections': collections.map((e) => e.toJson()).toList(),
        'environments': environments.map((e) => e.toJson()).toList(),
        'history': history.map((e) => e.toJson()).toList(),
        'rules': rules.map((e) => e.toJson()).toList(),
      };

  /// 逐条解析：非对象 / 脏条目跳过，不牵连整份数据。
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
  DebugRequest addRequest(String collectionId, DebugRequest request) {
    final linked = request.collectionId == collectionId
        ? request
        : request.copyWith(collectionId: collectionId);
    collectionById(collectionId)?.requests.add(linked);
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

  // ==================== 环境 CRUD ====================

  DebugEnvironment addEnvironment({
    String? id,
    required String name,
    Map<String, String>? vars,
  }) {
    final e = DebugEnvironment(
      id: id ?? generateDebugId('env'),
      name: name,
      vars: vars,
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

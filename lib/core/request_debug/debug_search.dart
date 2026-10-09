/// 「请求调试」各分区的搜索 / 过滤 / 排序纯逻辑（plan todo 15）。
///
/// 全部为无副作用纯函数：接收列表 + 查询串 / 排序参数，返回**新列表**，绝不
/// 修改输入，也不触碰 store 或 UI。UI 分区（集合树 / 历史 / 环境 / 改写规则）
/// 只负责收集查询串并把返回值渲染出来，从而使过滤逻辑可单测、与 CRUD 解耦。
library;

import 'debug_models.dart';

/// 通用排序顺序。
///
/// - [original]：保留原顺序（集合 = 层级原序；历史 = 最新在前；环境 / 规则 =
///   store 原序）；
/// - [nameAsc] / [nameDesc]：按「名称」排序（集合 / 环境用名称，
///   历史 / 规则用 URL）。
enum DebugSortOrder {
  original('original', '默认顺序'),
  nameAsc('name_asc', '名称升序'),
  nameDesc('name_desc', '名称降序');

  const DebugSortOrder(this.wire, this.label);

  /// 持久化 / 线缆值。
  final String wire;

  /// UI 展示名。
  final String label;
}

// ==================== 通用匹配 ====================

/// 查询串是否命中任一字段（大小写不敏感、子串包含）。
///
/// 空查询串（仅空白）视为「不过滤」，恒为 `true`。`null` 字段被跳过，
/// 绝不抛异常（无匹配不崩）。
bool debugQueryMatches(String query, Iterable<String?> fields) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  for (final field in fields) {
    if (field == null) continue;
    if (field.toLowerCase().contains(q)) return true;
  }
  return false;
}

/// 请求是否命中查询（名称 / URL / 方法）。
bool debugRequestMatches(DebugRequest request, String query) =>
    debugQueryMatches(query, [request.name, request.url, request.method]);

/// 名称比较：大小写不敏感；相等时调用方以 id / 时间等稳定兜底。
int _compareText(String a, String b) =>
    a.toLowerCase().compareTo(b.toLowerCase());

// ==================== 集合树 ====================

/// 过滤集合树（保留层级）。
///
/// 规则：
/// - 集合名称命中 → 保留该集合及**全部**子文件夹 / 请求（便于按文件夹名定位）；
/// - 请求命中 → 保留其所属集合（仅展示命中的请求）；
/// - 子文件夹命中 → 保留祖先链（祖先仅展示命中的后代）；
/// - 不命中任何项 → 返回空列表。
///
/// 返回**新**列表，输入不被修改；空查询返回输入副本（原顺序）。
List<DebugCollection> filterDebugCollections(
  List<DebugCollection> collections,
  String query,
) {
  final q = query.trim();
  if (q.isEmpty) return List<DebugCollection>.of(collections);

  final byParent = <String?, List<DebugCollection>>{};
  for (final c in collections) {
    (byParent[c.parentId] ??= <DebugCollection>[]).add(c);
  }

  // 命中集合 id；`keepAll` = 名称命中的集合及其后代 → 请求全量保留。
  final keep = <String>{};
  final keepAll = <String>{};

  void keepAllDescendants(DebugCollection c) {
    keep.add(c.id);
    keepAll.add(c.id);
    for (final child in byParent[c.id] ?? const <DebugCollection>[]) {
      keepAllDescendants(child);
    }
  }

  bool mark(DebugCollection c) {
    if (debugQueryMatches(q, [c.name])) {
      keepAllDescendants(c);
      return true;
    }
    var childMatched = false;
    for (final child in byParent[c.id] ?? const <DebugCollection>[]) {
      if (mark(child)) childMatched = true;
    }
    final requestMatched = c.requests.any((r) => debugRequestMatches(r, q));
    if (childMatched || requestMatched) {
      keep.add(c.id);
      return true;
    }
    return false;
  }

  for (final c in collections) {
    if (c.parentId == null) mark(c);
  }
  // 兜底：父 id 悬空的条目也要参与匹配，避免静默丢失。
  for (final c in collections) {
    if (!keep.contains(c.id)) mark(c);
  }
  if (keep.isEmpty) return <DebugCollection>[];

  final out = <DebugCollection>[];
  for (final c in collections) {
    if (!keep.contains(c.id)) continue;
    final requests = keepAll.contains(c.id)
        ? c.requests
        : c.requests.where((r) => debugRequestMatches(r, q)).toList();
    out.add(c.copyWith(requests: requests));
  }
  return out;
}

/// 按 [order] 对集合树做**同级**排序（保持父子层级）。
///
/// [DebugSortOrder.original] 返回输入副本。
List<DebugCollection> sortDebugCollections(
  List<DebugCollection> collections,
  DebugSortOrder order,
) {
  if (order == DebugSortOrder.original || collections.isEmpty) {
    return List<DebugCollection>.of(collections);
  }

  final byParent = <String?, List<DebugCollection>>{};
  for (final c in collections) {
    (byParent[c.parentId] ??= <DebugCollection>[]).add(c);
  }

  int compare(DebugCollection a, DebugCollection b) {
    final r = _compareText(a.name, b.name);
    final signed = order == DebugSortOrder.nameAsc ? r : -r;
    if (signed != 0) return signed;
    return a.id.compareTo(b.id);
  }

  final out = <DebugCollection>[];
  void emit(String? parentId) {
    final siblings = byParent[parentId] ?? const <DebugCollection>[];
    final sorted = List<DebugCollection>.of(siblings)..sort(compare);
    for (final c in sorted) {
      out.add(c);
      emit(c.id);
    }
  }

  emit(null);
  // 父 id 悬空的孤儿：原序追加，避免丢失。
  for (final c in collections) {
    if (!out.contains(c)) out.add(c);
  }
  return out;
}

// ==================== 历史 ====================

/// 过滤历史（名称 / URL / 方法）。空查询返回输入副本。
List<DebugHistoryEntry> filterDebugHistory(
  List<DebugHistoryEntry> entries,
  String query,
) {
  final q = query.trim();
  if (q.isEmpty) return List<DebugHistoryEntry>.of(entries);
  return <DebugHistoryEntry>[
    for (final e in entries)
      if (debugQueryMatches(
        q,
        [e.request.name, e.request.url, e.request.method],
      ))
        e,
  ];
}

/// 排序历史（按 URL；[DebugSortOrder.original] = 最新在前，即原顺序）。
List<DebugHistoryEntry> sortDebugHistory(
  List<DebugHistoryEntry> entries,
  DebugSortOrder order,
) {
  final out = List<DebugHistoryEntry>.of(entries);
  if (order == DebugSortOrder.original) return out;
  final asc = order == DebugSortOrder.nameAsc;
  out.sort((a, b) {
    final r = _compareText(a.request.url, b.request.url);
    final signed = asc ? r : -r;
    if (signed != 0) return signed;
    // 同 URL 时最新在前，保证稳定。
    return b.tsMs.compareTo(a.tsMs);
  });
  return out;
}

// ==================== 环境 ====================

/// 过滤环境（名称 / 变量键 / 变量值）。空查询返回输入副本。
List<DebugEnvironment> filterDebugEnvironments(
  List<DebugEnvironment> environments,
  String query,
) {
  final q = query.trim();
  if (q.isEmpty) return List<DebugEnvironment>.of(environments);
  return <DebugEnvironment>[
    for (final e in environments)
      if (debugQueryMatches(q, <String?>[
        e.name,
        ...e.vars.keys,
        ...e.vars.values,
      ]))
        e,
  ];
}

/// 排序环境（按名称）。
List<DebugEnvironment> sortDebugEnvironments(
  List<DebugEnvironment> environments,
  DebugSortOrder order,
) {
  final out = List<DebugEnvironment>.of(environments);
  if (order == DebugSortOrder.original) return out;
  final asc = order == DebugSortOrder.nameAsc;
  out.sort((a, b) {
    final r = _compareText(a.name, b.name);
    final signed = asc ? r : -r;
    if (signed != 0) return signed;
    return a.id.compareTo(b.id);
  });
  return out;
}

// ==================== 改写规则 ====================

/// 过滤改写规则（URL / 方法 / 备注 / id / 类型线缆值）。空查询返回输入副本。
List<DebugRewriteRule> filterDebugRules(
  List<DebugRewriteRule> rules,
  String query,
) {
  final q = query.trim();
  if (q.isEmpty) return List<DebugRewriteRule>.of(rules);
  return <DebugRewriteRule>[
    for (final r in rules)
      if (debugQueryMatches(q, <String?>[
        r.url,
        r.method,
        r.remark,
        r.id,
        r.kind.wire,
      ]))
        r,
  ];
}

/// 排序改写规则（按 URL）。
List<DebugRewriteRule> sortDebugRules(
  List<DebugRewriteRule> rules,
  DebugSortOrder order,
) {
  final out = List<DebugRewriteRule>.of(rules);
  if (order == DebugSortOrder.original) return out;
  final asc = order == DebugSortOrder.nameAsc;
  out.sort((a, b) {
    final r = _compareText(a.url, b.url);
    final signed = asc ? r : -r;
    if (signed != 0) return signed;
    return a.id.compareTo(b.id);
  });
  return out;
}

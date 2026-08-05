import '../../../core/workflow/models/workflow_model.dart';
import '../constants/step_option_keys.dart';

/// StepConfig.options 的类型安全扩展
/// 提供 getter 和 setter，避免到处使用字符串字面量
extension StepOptionsExtension on StepConfig {
  // ========== 输入输出 ==========

  String get inputFrom =>
      options[StepOptionKeys.inputFrom] as String? ?? '';

  set inputFrom(String value) =>
      options[StepOptionKeys.inputFrom] = value;

  String get inputPath =>
      options[StepOptionKeys.inputPath] as String? ?? '';

  set inputPath(String value) =>
      options[StepOptionKeys.inputPath] = value;

  String get outputVar =>
      options[StepOptionKeys.outputVar] as String? ?? '';

  set outputVar(String value) =>
      options[StepOptionKeys.outputVar] = value;

  // ========== HTTP 请求 ==========

  String get url => options[StepOptionKeys.url] as String? ?? '';

  set url(String value) => options[StepOptionKeys.url] = value;

  String get method =>
      options[StepOptionKeys.method] as String? ?? 'GET';

  set method(String value) => options[StepOptionKeys.method] = value;

  String get bodyType =>
      options[StepOptionKeys.bodyType] as String? ?? 'none';

  set bodyType(String value) => options[StepOptionKeys.bodyType] = value;

  String get body => options[StepOptionKeys.body] as String? ?? '';

  set body(String value) => options[StepOptionKeys.body] = value;

  String get headers =>
      options[StepOptionKeys.headers] as String? ?? '{}';

  set headers(String value) => options[StepOptionKeys.headers] = value;

  int get timeout =>
      options[StepOptionKeys.timeout] as int? ?? 30;

  set timeout(int value) => options[StepOptionKeys.timeout] = value;

  String get responsePath =>
      options[StepOptionKeys.responsePath] as String? ?? '';

  set responsePath(String value) =>
      options[StepOptionKeys.responsePath] = value;

  // ========== 数据提取 ==========

  List<Map<String, dynamic>> get fields {
    final f = options[StepOptionKeys.fields];
    if (f == null) return [];
    return (f as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  set fields(List<Map<String, dynamic>> value) =>
      options[StepOptionKeys.fields] = value;

  String get regexPattern =>
      options[StepOptionKeys.regexPattern] as String? ?? '';

  set regexPattern(String value) =>
      options[StepOptionKeys.regexPattern] = value;

  int? get arrayIndex =>
      options[StepOptionKeys.arrayIndex] as int?;

  set arrayIndex(int? value) =>
      options[StepOptionKeys.arrayIndex] = value;

  // ========== 过滤 ==========

  String get filterField =>
      options[StepOptionKeys.field] as String? ?? '';

  set filterField(String value) =>
      options[StepOptionKeys.field] = value;

  String get filterOperator =>
      options[StepOptionKeys.operator] as String? ?? 'eq';

  set filterOperator(String value) =>
      options[StepOptionKeys.operator] = value;

  String get filterValue =>
      options[StepOptionKeys.value] as String? ?? '';

  set filterValue(String value) =>
      options[StepOptionKeys.value] = value;

  bool get caseSensitive =>
      options[StepOptionKeys.caseSensitive] as bool? ?? false;

  set caseSensitive(bool value) =>
      options[StepOptionKeys.caseSensitive] = value;

  // ========== 参数配置 ==========

  String get parameterName =>
      options[StepOptionKeys.parameterName] as String? ?? '';

  set parameterName(String value) =>
      options[StepOptionKeys.parameterName] = value;

  String get defaultValue =>
      options[StepOptionKeys.defaultValue] as String? ?? '';

  set defaultValue(String value) =>
      options[StepOptionKeys.defaultValue] = value;

  String get dataPath =>
      options[StepOptionKeys.dataPath] as String? ?? '';

  set dataPath(String value) =>
      options[StepOptionKeys.dataPath] = value;

  // ========== 数据库 ==========

  String get tableName =>
      options[StepOptionKeys.tableName] as String? ?? '';

  set tableName(String value) =>
      options[StepOptionKeys.tableName] = value;

  String get condition =>
      options[StepOptionKeys.condition] as String? ?? '';

  set condition(String value) =>
      options[StepOptionKeys.condition] = value;

  String get orderBy =>
      options[StepOptionKeys.orderBy] as String? ?? '';

  set orderBy(String value) =>
      options[StepOptionKeys.orderBy] = value;

  String get orderDirection =>
      options[StepOptionKeys.orderDirection] as String? ?? 'asc';

  set orderDirection(String value) =>
      options[StepOptionKeys.orderDirection] = value;

  // ========== 去重 ==========

  String get dedupField =>
      options[StepOptionKeys.dedupField] as String? ?? '';

  set dedupField(String value) =>
      options[StepOptionKeys.dedupField] = value;

  // ========== 排序 ==========

  String get sortField =>
      options[StepOptionKeys.sortField] as String? ?? '';

  set sortField(String value) =>
      options[StepOptionKeys.sortField] = value;

  String get sortDirection =>
      options[StepOptionKeys.sortDirection] as String? ?? 'asc';

  set sortDirection(String value) =>
      options[StepOptionKeys.sortDirection] = value;

  // ========== 映射 ==========

  List<Map<String, dynamic>> get mappings {
    final m = options[StepOptionKeys.mappings];
    if (m == null) return [];
    return (m as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  set mappings(List<Map<String, dynamic>> value) =>
      options[StepOptionKeys.mappings] = value;

  // ========== 缓存 ==========

  String get cacheKey =>
      options[StepOptionKeys.cacheKey] as String? ?? '';

  set cacheKey(String value) =>
      options[StepOptionKeys.cacheKey] = value;

  int get cacheTtl =>
      options[StepOptionKeys.cacheTtl] as int? ?? 300;

  set cacheTtl(int value) =>
      options[StepOptionKeys.cacheTtl] = value;

  // ========== 验证 ==========

  List<Map<String, dynamic>> get rules {
    final r = options[StepOptionKeys.rules];
    if (r == null) return [];
    return (r as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  set rules(List<Map<String, dynamic>> value) =>
      options[StepOptionKeys.rules] = value;
}

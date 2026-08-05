/// 步骤配置字段名常量
/// 集中定义所有步骤类型的配置字段名，避免魔法字符串
class StepOptionKeys {
  StepOptionKeys._();

  // ========== 输入输出配置 ==========
  /// 输入来源: '__PREV__', 'stepId', 'var:contextVarName'
  static const String inputFrom = 'inputFrom';

  /// 输入数据路径: 'data.result.items[0].name'
  static const String inputPath = 'inputPath';

  /// 输出变量名: 'result', 'httpData'
  static const String outputVar = 'outputVar';

  // ========== HTTP 请求配置 ==========
  /// 请求 URL
  static const String url = 'url';

  /// 请求方法: GET, POST, PUT, DELETE, PATCH
  static const String method = 'method';

  /// Body 类型: none, json, form, urlencoded, text
  static const String bodyType = 'bodyType';

  /// 请求体内容
  static const String body = 'body';

  /// 请求头 JSON 字符串
  static const String headers = 'headers';

  /// 超时秒数
  static const String timeout = 'timeout';

  /// 响应数据路径
  static const String responsePath = 'responsePath';

  // ========== 数据提取配置 ==========
  /// 提取字段列表: [{name, path, description}]
  static const String fields = 'fields';

  /// 正则提取模式
  static const String regexPattern = 'regexPattern';

  /// 数组索引
  static const String arrayIndex = 'arrayIndex';

  // ========== 过滤配置 ==========
  /// 过滤字段名
  static const String field = 'field';

  /// 操作符: eq, ne, gt, lt, gte, lte, contains, startsWith, endsWith
  static const String operator = 'operator';

  /// 过滤值
  static const String value = 'value';

  /// 区分大小写
  static const String caseSensitive = 'caseSensitive';

  // ========== 参数配置 ==========
  /// 参数名称
  static const String parameterName = 'parameterName';

  /// 默认值
  static const String defaultValue = 'defaultValue';

  /// 数据路径
  static const String dataPath = 'dataPath';

  // ========== 数据库配置 ==========
  /// 表名
  static const String tableName = 'tableName';

  /// 查询条件
  static const String condition = 'condition';

  /// 排序字段
  static const String orderBy = 'orderBy';

  /// 排序方向: asc, desc
  static const String orderDirection = 'orderDirection';

  // ========== 去重配置 ==========
  /// 去重字段
  static const String dedupField = 'dedupField';

  // ========== 排序配置 ==========
  /// 排序字段
  static const String sortField = 'sortField';

  /// 排序方向
  static const String sortDirection = 'sortDirection';

  // ========== 映射配置 ==========
  /// 映射规则: [{from, to}]
  static const String mappings = 'mappings';

  // ========== 缓存配置 ==========
  /// 缓存键
  static const String cacheKey = 'cacheKey';

  /// 缓存 TTL (秒)
  static const String cacheTtl = 'cacheTtl';

  // ========== 验证配置 ==========
  /// 验证规则: [{field, rule, message}]
  static const String rules = 'rules';
}

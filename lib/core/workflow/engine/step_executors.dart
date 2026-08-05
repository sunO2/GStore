import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/step_model.dart';
import '../models/workflow_model.dart';
import 'database_executors.dart';

/// 步骤执行器基类
abstract class StepExecutor {
  String get type;

  Future<StepOutput> execute(StepContext context);

  bool validate(StepConfig config) => true;
}

/// 步骤执行上下文
class StepContext {
  final StepConfig config;
  final Map<String, dynamic> variables;
  final Map<String, StepOutput> results;
  dynamic inputData;

  StepContext({
    required this.config,
    required this.variables,
    required this.results,
    this.inputData,
  });

  /// 获取输入数据
  dynamic getInput() {
    return inputData;
  }

  /// 设置输出
  void setOutput(String name, dynamic data) {
    variables[name] = data;
  }

  /// 解析值（支持变量引用）
  dynamic resolveValue(dynamic value) {
    if (value is String && value.startsWith(r'${') && value.endsWith('}')) {
      final varName = value.substring(2, value.length - 1);
      return variables[varName] ?? value;
    }
    return value;
  }

  /// 从数据中提取路径
  dynamic extractPath(dynamic data, String path) {
    if (path.isEmpty) return data;
    if (data == null) return null;

    String cleanPath = path;
    if (path.startsWith(r'$.')) {
      cleanPath = path.substring(2);
    } else if (path.startsWith('.')) {
      cleanPath = path.substring(1);
    }

    if (cleanPath.isEmpty) return data;

    final parts = cleanPath.split('.');
    dynamic current = data;

    for (final part in parts) {
      if (current == null) return null;

      final arrayMatch = RegExp(r'^(\w*)\[(\d+)\]$').firstMatch(part);
      if (arrayMatch != null) {
        final field = arrayMatch.group(1);
        final index = int.parse(arrayMatch.group(2)!);

        if (field != null && field.isNotEmpty) {
          if (current is Map) {
            current = current[field];
          } else {
            return null;
          }
        }

        if (current is List && index < current.length) {
          current = current[index];
        } else {
          return null;
        }
      } else {
        if (current is Map) {
          current = current[part];
        } else {
          return null;
        }
      }
    }

    return current;
  }
}

/// 执行器注册表
class StepExecutorRegistry {
  static final StepExecutorRegistry _instance = StepExecutorRegistry._internal();
  factory StepExecutorRegistry() => _instance;
  StepExecutorRegistry._internal();

  final Map<String, StepExecutor> _executors = {};

  void register(StepExecutor executor) {
    _executors[executor.type] = executor;
  }

  StepExecutor? get(String type) {
    return _executors[type];
  }

  bool contains(String type) {
    return _executors.containsKey(type);
  }
}

/// HTTP 请求执行器
class HttpExecutor extends StepExecutor {
  final Dio _dio;

  HttpExecutor({Dio? dio}) : _dio = dio ?? Dio();

  @override
  String get type => 'http_request';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final config = context.config;
    final httpOpts = config.httpOptions;

    try {
      // 解析 headers
      final headers = <String, dynamic>{...httpOpts.headers};

      // 处理认证
      if (httpOpts.authType != null && httpOpts.authType!.isNotEmpty) {
        switch (httpOpts.authType) {
          case 'basic':
            final username = httpOpts.authConfig['username'] ?? '';
            final password = httpOpts.authConfig['password'] ?? '';
            final encoded = base64Encode(utf8.encode('$username:$password'));
            headers['Authorization'] = 'Basic $encoded';
            break;
          case 'bearer':
            final token = httpOpts.authConfig['token'] ?? '';
            headers['Authorization'] = 'Bearer $token';
            break;
          case 'apiKey':
            final keyName = httpOpts.authConfig['keyName'] ?? 'X-API-Key';
            final keyValue = httpOpts.authConfig['keyValue'] ?? '';
            headers[keyName] = keyValue;
            break;
        }
      }

      // 构建 URL（添加查询参数）
      var url = httpOpts.url;
      if (httpOpts.queryParams.isNotEmpty) {
        final uri = Uri.parse(url);
        final updatedUri = uri.replace(
          queryParameters: {
            ...uri.queryParameters,
            ...httpOpts.queryParams,
          },
        );
        url = updatedUri.toString();
      }

      // 处理 Body
      dynamic requestData;
      if (httpOpts.bodyType != 'none' && httpOpts.body.isNotEmpty) {
        switch (httpOpts.bodyType) {
          case 'json':
            headers['Content-Type'] = 'application/json';
            try {
              requestData = jsonDecode(httpOpts.body);
            } catch (e) {
              requestData = httpOpts.body;
            }
            break;
          case 'form':
            final formData = FormData();
            final lines = httpOpts.body.split('\n');
            for (final line in lines) {
              final parts = line.split('=');
              if (parts.length == 2) {
                formData.fields.add(MapEntry(parts[0].trim(), parts[1].trim()));
              }
            }
            requestData = formData;
            break;
          case 'urlencoded':
            headers['Content-Type'] = 'application/x-www-form-urlencoded';
            requestData = httpOpts.body;
            break;
          case 'text':
            headers['Content-Type'] = 'text/plain';
            requestData = httpOpts.body;
            break;
          case 'xml':
            headers['Content-Type'] = 'application/xml';
            requestData = httpOpts.body;
            break;
        }
      }

      // 发送请求
      final response = await _dio.request(
        url,
        options: Options(
          method: httpOpts.method,
          headers: headers,
          sendTimeout: Duration(seconds: httpOpts.writeTimeout),
          receiveTimeout: Duration(seconds: httpOpts.readTimeout),
          followRedirects: httpOpts.followRedirects,
          validateStatus: (status) => true, // 不验证状态码
        ),
        data: requestData,
      );

      var data = response.data;

      // 提取响应路径
      if (httpOpts.responsePath != null && httpOpts.responsePath!.isNotEmpty) {
        data = context.extractPath(data, httpOpts.responsePath!);
      }

      // 检查状态码处理
      final statusCode = response.statusCode ?? 0;
      if (httpOpts.statusCodeHandlers != null &&
          httpOpts.statusCodeHandlers!.containsKey(statusCode)) {
        // 状态码有专门的处理器
        context.setOutput('_statusCode', statusCode);
        context.setOutput('_statusHandler', httpOpts.statusCodeHandlers![statusCode]);
      }

      // 检查是否错误
      if (httpOpts.throwOnError && (statusCode < 200 || statusCode >= 300)) {
        return StepOutput.failure(
          config.id,
          'HTTP 请求失败: $statusCode ${response.statusMessage}',
        );
      }

      return StepOutput.success(
        config.id,
        data,
        metadata: {'statusCode': statusCode},
      );
    } on DioException catch (e) {
      return StepOutput.failure(
        config.id,
        'HTTP 请求失败: ${e.message}',
      );
    }
  }
}

/// 数据提取执行器
class DataExtractExecutor extends StepExecutor {
  @override
  String get type => 'data_extract';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final data = context.getInput();
    if (data == null) {
      return StepOutput.failure(context.config.id, '输入数据为空');
    }

    final options = context.config.options;
    final fields = options['fields'] as List<dynamic>?;
    final inputPath = options['inputPath'] as String?;

    // 如果有输入路径，先提取输入数据
    dynamic sourceData = data;
    if (inputPath != null && inputPath.isNotEmpty) {
      sourceData = context.extractPath(data, inputPath);
      if (sourceData == null) {
        return StepOutput.failure(context.config.id, '输入路径提取失败: $inputPath');
      }
    }

    // 如果没有配置字段，直接返回原数据
    if (fields == null || fields.isEmpty) {
      return StepOutput.success(context.config.id, sourceData);
    }

    // 提取多个字段
    final extracted = <String, dynamic>{};
    final errors = <String>[];

    for (final field in fields) {
      if (field is! Map) continue;

      final fieldName = field['name'] as String? ?? 'field';
      final fieldPath = field['path'] as String? ?? '';
      final fieldEnabled = field['enabled'] as bool? ?? true;
      final fieldRegex = field['regex'] as String?;
      final fieldDefault = field['defaultValue'] as String?;

      // 如果字段被禁用，跳过
      if (!fieldEnabled) continue;

      dynamic value;

      // 使用正则表达式提取
      if (fieldRegex != null && fieldRegex.isNotEmpty) {
        value = _extractByRegex(sourceData.toString(), fieldRegex);
        if (value == null && fieldDefault != null) {
          value = _parseDefaultValue(fieldDefault);
        }
      }
      // 使用路径提取
      else if (fieldPath.isNotEmpty) {
        value = context.extractPath(sourceData, fieldPath);
        if (value == null && fieldDefault != null) {
          value = _parseDefaultValue(fieldDefault);
        }
      }
      // 无路径，使用原数据
      else {
        value = sourceData;
        if (fieldDefault != null && value == null) {
          value = _parseDefaultValue(fieldDefault);
        }
      }

      if (value != null) {
        extracted[fieldName] = value;
      } else {
        errors.add(fieldName);
      }
    }

    if (extracted.isEmpty && errors.isNotEmpty) {
      return StepOutput.failure(
        context.config.id,
        '字段提取失败: ${errors.join(', ')}',
      );
    }

    return StepOutput.success(context.config.id, extracted);
  }

  dynamic _extractByRegex(String data, String pattern) {
    try {
      final regex = RegExp(pattern);
      final match = regex.firstMatch(data);
      if (match == null) return null;

      // 如果有捕获组，返回第一个捕获组
      if (match.groupCount > 0) {
        return match.group(1);
      }
      return match.group(0);
    } catch (_) {
      return null;
    }
  }

  dynamic _parseDefaultValue(String defaultValue) {
    // 尝试解析为不同类型
    if (defaultValue == 'null' || defaultValue.isEmpty) return null;
    if (defaultValue == 'true') return true;
    if (defaultValue == 'false') return false;

    // 尝试解析为数字
    final parsed = num.tryParse(defaultValue);
    if (parsed != null) return parsed;

    // 返回字符串
    return defaultValue;
  }
}

/// 数据转换执行器
class DataTransformExecutor extends StepExecutor {
  @override
  String get type => 'data_transform';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final data = context.getInput();
    if (data == null) {
      return StepOutput.failure(context.config.id, '输入数据为空');
    }

    final options = context.config.options;
    final mappings = options['mappings'] as List<dynamic>? ?? [];

    if (mappings.isEmpty) {
      return StepOutput.success(context.config.id, data);
    }

    // 如果是列表，转换每个元素
    if (data is List) {
      final mapped = data.map((item) {
        if (item is! Map) return item;
        return _transformMap(item as Map, mappings);
      }).toList();
      return StepOutput.success(context.config.id, mapped);
    } else if (data is Map) {
      return StepOutput.success(context.config.id, _transformMap(data, mappings));
    }

    return StepOutput.success(context.config.id, data);
  }

  Map<String, dynamic> _transformMap(
    Map item,
    List<dynamic> mappings,
  ) {
    final result = Map<String, dynamic>.from(item);

    for (final mapping in mappings) {
      if (mapping is! Map) continue;

      final sourceField = mapping['sourceField'] as String?;
      final targetField = mapping['targetField'] as String?;
      final transform = mapping['transform'] as String?;

      if (sourceField == null || targetField == null) continue;

      var value = item[sourceField];

      if (transform != null && value != null) {
        value = _applyTransform(value, transform);
      }

      result[targetField] = value;
    }

    return result;
  }

  dynamic _applyTransform(dynamic value, String transform) {
    switch (transform) {
      case 'uppercase':
        return value.toString().toUpperCase();
      case 'lowercase':
        return value.toString().toLowerCase();
      case 'trim':
        return value.toString().trim();
      case 'capitalize':
        return value.toString().split(' ').map((w) =>
          w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : w
        ).join(' ');
      case 'toString':
        return value.toString();
      case 'toInt':
        return int.tryParse(value.toString()) ?? value;
      case 'toDouble':
        return double.tryParse(value.toString()) ?? value;
      case 'toBool':
        if (value.toString().toLowerCase() == 'true') return true;
        if (value.toString().toLowerCase() == 'false') return false;
        return value;
      case 'toJson':
        return jsonEncode(value);
      case 'fromJson':
        return jsonDecode(value.toString());
      default:
        return value;
    }
  }
}

/// 数据过滤执行器
class DataFilterExecutor extends StepExecutor {
  @override
  String get type => 'data_filter';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final data = context.getInput();
    if (data is! List) {
      return StepOutput.failure(context.config.id, '过滤步骤需要列表数据');
    }

    final options = context.config.options;
    final field = options['field'] as String? ?? '';
    final operator = options['operator'] as String? ?? 'eq';
    final value = options['value'];
    final caseSensitive = options['caseSensitive'] as bool? ?? false;

    // 支持多个条件
    final conditions = options['conditions'] as List<dynamic>?;

    List<dynamic> result = data;

    if (conditions != null && conditions.isNotEmpty) {
      // 多条件过滤
      for (final cond in conditions) {
        if (cond is! Map) continue;
        final condField = cond['field'] as String? ?? '';
        final condOperator = cond['operator'] as String? ?? 'eq';
        final condValue = cond['value'];
        final condCaseSensitive = cond['caseSensitive'] as bool? ?? false;

        result = result.where((item) {
          if (item is! Map) return true;
          final itemValue = item[condField];
          return _compareValues(itemValue, condOperator, condValue, condCaseSensitive);
        }).toList();
      }
    } else if (field.isNotEmpty) {
      // 单条件过滤
      result = data.where((item) {
        if (item is! Map) return true;
        final itemValue = item[field];
        return _compareValues(itemValue, operator, value, caseSensitive);
      }).toList();
    }

    return StepOutput.success(
      context.config.id,
      result,
      metadata: {'filteredCount': result.length},
    );
  }

  bool _compareValues(dynamic a, String operator, dynamic b, bool caseSensitive) {
    if (a == null) return false;

    String? aStr = a.toString();
    String? bStr = b?.toString();

    if (!caseSensitive) {
      aStr = aStr?.toLowerCase();
      bStr = bStr?.toLowerCase();
    }

    switch (operator) {
      case 'eq':
        return aStr == bStr;
      case 'ne':
        return aStr != bStr;
      case 'gt':
        if (a is num && b is num) return a > b;
        return aStr!.compareTo(bStr!) > 0;
      case 'lt':
        if (a is num && b is num) return a < b;
        return aStr!.compareTo(bStr!) < 0;
      case 'gte':
        if (a is num && b is num) return a >= b;
        return aStr!.compareTo(bStr!) >= 0;
      case 'lte':
        if (a is num && b is num) return a <= b;
        return aStr!.compareTo(bStr!) <= 0;
      case 'contains':
        return aStr!.contains(bStr!);
      case 'notContains':
        return !aStr!.contains(bStr!);
      case 'startsWith':
        return aStr!.startsWith(bStr!);
      case 'endsWith':
        return aStr!.endsWith(bStr!);
      case 'isNull':
        return a == null;
      case 'isNotNull':
        return a != null;
      case 'isEmpty':
        return aStr == null || aStr.isEmpty;
      case 'isNotEmpty':
        return aStr != null && aStr.isNotEmpty;
      case 'in':
        if (b is List) return b.contains(a);
        return false;
      case 'notIn':
        if (b is List) return !b.contains(a);
        return true;
      default:
        return false;
    }
  }
}

/// 数据排序执行器
class DataSortExecutor extends StepExecutor {
  @override
  String get type => 'data_sort';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final data = context.getInput();
    if (data is! List) {
      return StepOutput.failure(context.config.id, '排序步骤需要列表数据');
    }

    final options = context.config.options;
    final sortFields = options['fields'] as List<dynamic>? ?? [];

    if (sortFields.isEmpty) {
      return StepOutput.success(context.config.id, data);
    }

    final sorted = List.from(data);
    sorted.sort((a, b) {
      for (final sortField in sortFields) {
        final fieldName = sortField['field'] as String? ?? '';
        final ascending = sortField['ascending'] as bool? ?? true;

        dynamic valueA, valueB;
        if (a is Map) valueA = a[fieldName];
        if (b is Map) valueB = b[fieldName];

        int comparison = 0;
        if (valueA is Comparable && valueB is Comparable) {
          comparison = valueA.compareTo(valueB);
        }

        if (comparison != 0) {
          return ascending ? comparison : -comparison;
        }
      }
      return 0;
    });

    return StepOutput.success(context.config.id, sorted);
  }
}

/// 数据去重执行器
class DataDedupExecutor extends StepExecutor {
  @override
  String get type => 'data_dedup';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final data = context.getInput();
    if (data is! List) {
      return StepOutput.failure(context.config.id, '去重步骤需要列表数据');
    }

    final options = context.config.options;
    final fields = options['fields'] as List<dynamic>? ?? [];
    final caseSensitive = options['caseSensitive'] as bool? ?? true;
    final keepFirst = options['keepFirst'] as bool? ?? true;

    final seen = <String, int>{};
    final result = <dynamic>[];

    for (var i = 0; i < data.length; i++) {
      final item = data[i];
      String key;

      if (fields.isEmpty) {
        key = item.toString();
      } else {
        final values = fields.map((f) {
          final v = (item is Map) ? item[f] : null;
          return v?.toString() ?? '';
        }).toList();
        key = values.join('|');
      }

      if (!caseSensitive) {
        key = key.toLowerCase();
      }

      if (!seen.containsKey(key)) {
        seen[key] = result.length;
        if (keepFirst) {
          result.add(item);
        }
      } else if (!keepFirst) {
        result[seen[key]!] = item;
      }
    }

    return StepOutput.success(
      context.config.id,
      result,
      metadata: {'dedupedCount': data.length - result.length},
    );
  }
}

/// 条件分支执行器
class ConditionExecutor extends StepExecutor {
  @override
  String get type => 'condition';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final data = context.getInput();
    final options = context.config.options;

    final conditions = options['conditions'] as List<dynamic>? ?? [];
    final logicOperator = options['logicOperator'] as String? ?? 'and'; // and / or

    bool result = true;

    for (final cond in conditions) {
      if (cond is! Map) continue;

      final field = cond['field'] as String? ?? '';
      final operator = cond['operator'] as String? ?? 'eq';
      final value = cond['value'];
      final caseSensitive = cond['caseSensitive'] as bool? ?? false;

      dynamic itemValue;
      if (field.isNotEmpty && data is Map) {
        itemValue = data[field];
      } else {
        itemValue = data;
      }

      final condResult = _compareValues(itemValue, operator, value, caseSensitive);

      if (logicOperator == 'and') {
        result = result && condResult;
        if (!result) break;
      } else {
        result = result || condResult;
        if (result) break;
      }
    }

    // 也支持简单的 singleCondition
    if (conditions.isEmpty) {
      final singleCondition = options['singleCondition'] as bool? ?? false;
      if (singleCondition) {
        final field = options['field'] as String? ?? '';
        final operator = options['operator'] as String? ?? 'eq';
        final value = options['value'];

        dynamic itemValue;
        if (field.isNotEmpty && data is Map) {
          itemValue = data[field];
        } else {
          itemValue = data;
        }

        result = _compareValues(itemValue, operator, value, false);
      }
    }

    return StepOutput.success(
      context.config.id,
      result,
      metadata: {'conditionResult': result},
    );
  }

  bool _compareValues(dynamic a, String operator, dynamic b, bool caseSensitive) {
    if (a == null) return false;

    String? aStr = a.toString();
    String? bStr = b?.toString();

    if (!caseSensitive) {
      aStr = aStr?.toLowerCase();
      bStr = bStr?.toLowerCase();
    }

    switch (operator) {
      case 'eq':
        return aStr == bStr;
      case 'ne':
        return aStr != bStr;
      case 'gt':
        if (a is num && b is num) return a > b;
        return aStr!.compareTo(bStr!) > 0;
      case 'lt':
        if (a is num && b is num) return a < b;
        return aStr!.compareTo(bStr!) < 0;
      case 'gte':
        if (a is num && b is num) return a >= b;
        return aStr!.compareTo(bStr!) >= 0;
      case 'lte':
        if (a is num && b is num) return a <= b;
        return aStr!.compareTo(bStr!) <= 0;
      case 'contains':
        return aStr!.contains(bStr!);
      case 'startsWith':
        return aStr!.startsWith(bStr!);
      case 'endsWith':
        return aStr!.endsWith(bStr!);
      case 'isNull':
        return a == null;
      case 'isNotNull':
        return a != null;
      case 'isEmpty':
        return aStr == null || aStr.isEmpty;
      case 'isNotEmpty':
        return aStr != null && aStr.isNotEmpty;
      default:
        return false;
    }
  }
}

/// 变量获取执行器
class VarGetExecutor extends StepExecutor {
  @override
  String get type => 'var_get';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final varName = options['varName'] as String? ?? '';
    final defaultValue = options['defaultValue'];

    if (varName.isEmpty) {
      return StepOutput.failure(context.config.id, '变量名不能为空');
    }

    final value = context.variables[varName] ?? defaultValue;

    return StepOutput.success(
      context.config.id,
      value,
      metadata: {'varName': varName},
    );
  }
}

/// 变量设置执行器
class VarSetExecutor extends StepExecutor {
  @override
  String get type => 'var_set';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final varName = options['varName'] as String? ?? '';
    final value = options['value'] ?? context.getInput();
    final isSecret = options['isSecret'] as bool? ?? false;

    if (varName.isEmpty) {
      return StepOutput.failure(context.config.id, '变量名不能为空');
    }

    context.setOutput(varName, value);

    return StepOutput.success(
      context.config.id,
      value,
      metadata: {'varName': varName, 'isSecret': isSecret},
    );
  }
}

/// 变量删除执行器
class VarDeleteExecutor extends StepExecutor {
  @override
  String get type => 'var_delete';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final varName = options['varName'] as String? ?? '';

    if (varName.isEmpty) {
      return StepOutput.failure(context.config.id, '变量名不能为空');
    }

    final existed = context.variables.containsKey(varName);
    context.variables.remove(varName);

    return StepOutput.success(
      context.config.id,
      existed,
      metadata: {'varName': varName, 'existed': existed},
    );
  }
}

/// 日志执行器
class LogExecutor extends StepExecutor {
  @override
  String get type => 'log';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final level = options['level'] as String? ?? 'info';
    final message = options['message'] as String? ?? '';
    final dataPath = options['dataPath'] as String?;

    dynamic data = context.getInput();
    if (dataPath != null && dataPath.isNotEmpty) {
      data = context.extractPath(data, dataPath);
    }

    // 这里应该使用真实的日志框架，打印到控制台或日志文件
    // 暂时收集到 metadata 中
    final logEntry = {
      'level': level,
      'message': message,
      'data': data,
      'timestamp': DateTime.now().toIso8601String(),
    };

    return StepOutput.success(
      context.config.id,
      data,
      metadata: {'log': logEntry},
    );
  }
}

/// 断言执行器
class AssertExecutor extends StepExecutor {
  @override
  String get type => 'assert';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final condition = options['condition'] as String?;
    final message = options['message'] as String? ?? '断言失败';

    bool result = false;

    // 解析条件表达式
    if (condition != null && condition.isNotEmpty) {
      result = _evaluateCondition(condition, context);
    }

    if (!result) {
      return StepOutput.failure(context.config.id, message);
    }

    return StepOutput.success(context.config.id, true);
  }

  bool _evaluateCondition(String condition, StepContext context) {
    final data = context.getInput();

    // 简单的条件解析
    // 格式: field operator value
    // 例如: status eq 200, count gt 0

    final parts = condition.split(' ');
    if (parts.length < 3) {
      // 假设是布尔值或简单表达式
      if (condition == 'true') return true;
      if (condition == 'false') return false;
      return data == condition;
    }

    final field = parts[0];
    final operator = parts[1];
    final value = parts.sublist(2).join(' ');

    dynamic fieldValue;
    if (field == 'this' || field.isEmpty) {
      fieldValue = data;
    } else if (data is Map) {
      fieldValue = data[field];
    }

    return _compareSimple(fieldValue, operator, value);
  }

  bool _compareSimple(dynamic a, String operator, String b) {
    switch (operator) {
      case 'eq':
        return a.toString() == b;
      case 'ne':
        return a.toString() != b;
      case 'gt':
        if (a is num) return a > (num.tryParse(b) ?? 0);
        return a.toString().compareTo(b) > 0;
      case 'lt':
        if (a is num) return a < (num.tryParse(b) ?? 0);
        return a.toString().compareTo(b) < 0;
      case 'gte':
        if (a is num) return a >= (num.tryParse(b) ?? 0);
        return a.toString().compareTo(b) >= 0;
      case 'lte':
        if (a is num) return a <= (num.tryParse(b) ?? 0);
        return a.toString().compareTo(b) <= 0;
      case 'contains':
        return a.toString().contains(b);
      default:
        return false;
    }
  }
}

/// 延迟执行器
class DelayExecutor extends StepExecutor {
  @override
  String get type => 'delay';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final seconds = options['seconds'] as int? ?? 1;

    await Future.delayed(Duration(seconds: seconds));

    return StepOutput.success(
      context.config.id,
      {'delayed': seconds},
      metadata: {'seconds': seconds},
    );
  }
}

/// 注释执行器（不执行任何操作）
class CommentExecutor extends StepExecutor {
  @override
  String get type => 'comment';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final text = options['text'] as String? ?? '';

    return StepOutput.success(
      context.config.id,
      null,
      metadata: {'comment': text},
    );
  }
}

/// 数据库查询执行器（占位实现）
class DatabaseQueryExecutor extends StepExecutor {
  @override
  String get type => 'database_query';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final connectionId = options['connectionId'] as String? ?? '';
    final query = options['query'] as String? ?? '';
    final params = options['params'] as Map<String, dynamic>? ?? {};

    // TODO: 实现实际的数据库查询
    return StepOutput.success(
      context.config.id,
      [],
      metadata: {
        'connectionId': connectionId,
        'query': query,
        'params': params,
        'note': 'Database query - implementation pending',
      },
    );
  }
}

/// 缓存操作执行器（占位实现）
class CacheOpsExecutor extends StepExecutor {
  @override
  String get type => 'cache_ops';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final key = options['key'] as String? ?? '';
    final operation = options['operation'] as String? ?? 'get'; // get, set, delete
    final value = options['value'];
    final ttl = options['ttl'] as int? ?? 3600;

    // TODO: 实现实际的缓存操作
    dynamic result;
    switch (operation) {
      case 'get':
        result = null; // 缓存中获取
        break;
      case 'set':
        result = value;
        break;
      case 'delete':
        result = true;
        break;
    }

    return StepOutput.success(
      context.config.id,
      result,
      metadata: {
        'key': key,
        'operation': operation,
        'ttl': ttl,
        'note': 'Cache operations - implementation pending',
      },
    );
  }
}

/// 通知执行器（占位实现）
class NotificationExecutor extends StepExecutor {
  @override
  String get type => 'notification';

  @override
  Future<StepOutput> execute(StepContext context) async {
    final options = context.config.options;
    final channel = options['channel'] as String? ?? 'default';
    final recipient = options['recipient'] as String? ?? '';
    final message = options['message'] as String? ?? '';

    // TODO: 实现实际的通知发送
    return StepOutput.success(
      context.config.id,
      {'sent': true},
      metadata: {
        'channel': channel,
        'recipient': recipient,
        'message': message,
        'note': 'Notification - implementation pending',
      },
    );
  }
}

/// 初始化执行器注册表
void registerExecutors() {
  final registry = StepExecutorRegistry();

  registry.register(HttpExecutor());
  registry.register(DataExtractExecutor());
  registry.register(DataTransformExecutor());
  registry.register(DataFilterExecutor());
  registry.register(DataSortExecutor());
  registry.register(DataDedupExecutor());
  registry.register(ConditionExecutor());
  registry.register(VarGetExecutor());
  registry.register(VarSetExecutor());
  registry.register(VarDeleteExecutor());
  registry.register(LogExecutor());
  registry.register(AssertExecutor());
  registry.register(DelayExecutor());
  registry.register(CommentExecutor());
  registry.register(DatabaseReadExecutor());
  registry.register(DatabaseWriteExecutor());
  registry.register(DatabaseCreateExecutor());
  registry.register(DatabaseQueryExecutor());
  registry.register(CacheOpsExecutor());
  registry.register(NotificationExecutor());
}

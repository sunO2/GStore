import 'dart:convert';
import 'package:dio/dio.dart';
import '../models/step_model.dart';
import '../models/workflow_model.dart';
import 'step_executors.dart';

/// 工作流执行引擎
class WorkflowEngine {
  final Dio _dio;
  bool _executorsRegistered = false;

  WorkflowEngine({Dio? dio}) : _dio = dio ?? Dio();

  /// 确保执行器已注册
  void _ensureExecutorsRegistered() {
    if (!_executorsRegistered) {
      registerExecutors();
      _executorsRegistered = true;
    }
  }

  /// 执行工作流
  Future<WorkflowResult> execute(
    WorkflowModel workflow, {
    Map<String, dynamic>? inputParameters,
    Function(String stepId, StepOutput output)? onStepComplete,
  }) async {
    final startTime = DateTime.now();
    final stepOutputs = <StepOutput>[];
    var contextVars = Map<String, dynamic>.from(inputParameters ?? {});

    // 初始化工作流变量
    for (final entry in workflow.variables.entries) {
      contextVars[entry.key] = entry.value.defaultValue;
    }

    try {
      // 验证工作流
      if (workflow.steps.isEmpty) {
        return WorkflowResult.failure('工作流没有步骤', DateTime.now().difference(startTime));
      }

      // 按顺序执行每个步骤
      for (final step in workflow.steps) {
        if (!step.enabled) continue;

        // 获取输入数据
        dynamic inputData = _resolveInput(step, stepOutputs, contextVars);

        // 构建执行上下文
        final stepContext = StepContext(
          config: step,
          variables: contextVars,
          results: {for (var o in stepOutputs) o.stepId: o},
          inputData: inputData,
        );

        // 执行步骤
        StepOutput output;
        final errorHandling = step.errorHandling;

        if (errorHandling != null && errorHandling.retryCount > 0) {
          // 带重试的执行
          output = await _executeWithRetry(stepContext, errorHandling);
        } else {
          // 普通执行
          output = await _executeStep(step, stepContext);
        }

        // 在 metadata 中记录输入数据用于调试
        final outputWithInput = StepOutput(
          stepId: output.stepId,
          success: output.success,
          data: output.data,
          error: output.error,
          metadata: {
            ...?output.metadata,
            '_inputData': inputData,
            '_inputFrom': step.inputFrom ?? step.input?.sourceStepId ?? '__PREV__',
            '_inputPath': step.inputPath ?? step.input?.dataPath ?? '',
            '_outputVar': step.outputVar ?? step.output?.sourceStepId ?? '',
          },
        );

        stepOutputs.add(outputWithInput);

        if (onStepComplete != null) {
          onStepComplete(step.id, outputWithInput);
        }

        // 如果步骤失败，根据配置决定是否继续
        if (!output.success) {
          if (errorHandling?.continueOnError == true) {
            // 继续执行，但记录错误
            contextVars[errorHandling!.errorVar ?? '_error'] = output.error;
            continue;
          }
          return WorkflowResult(
            success: false,
            output: null,
            stepOutputs: stepOutputs,
            error: '步骤 "${step.name}" 执行失败: ${output.error}',
            duration: DateTime.now().difference(startTime),
          );
        }

        // 如果步骤配置了 outputVar，保存到上下文
        final outputVarName = step.outputVar ?? step.output?.sourceStepId;
        if (outputVarName != null && outputVarName.isNotEmpty && output.success) {
          contextVars[outputVarName] = output.data;
        }

        // 如果步骤有输出参数，更新上下文（兼容旧逻辑）
        if (output.metadata != null && output.metadata!.containsKey('output')) {
          final outputMap = output.metadata!['output'] as Map<String, dynamic>;
          contextVars.addAll(outputMap);
        }
      }

      final finalOutput = stepOutputs.isEmpty ? null : stepOutputs.last.data;

      return WorkflowResult(
        success: true,
        output: finalOutput,
        stepOutputs: stepOutputs,
        duration: DateTime.now().difference(startTime),
      );
    } catch (e) {
      return WorkflowResult.failure(
        '工作流执行异常: $e',
        DateTime.now().difference(startTime),
      );
    }
  }

  /// 带重试的执行
  Future<StepOutput> _executeWithRetry(
    StepContext context,
    ErrorHandlingConfig errorHandling,
  ) async {
    StepOutput? lastError;
    final maxRetries = errorHandling.retryCount;
    final retryDelay = errorHandling.retryDelay;

    for (var i = 0; i <= maxRetries; i++) {
      if (i > 0) {
        // 等待后重试
        await Future.delayed(Duration(seconds: retryDelay));
      }

      final output = await _executeStep(context.config, context);

      if (output.success) {
        return output;
      }

      lastError = output;

      // 如果是最后一次尝试，直接返回
      if (i == maxRetries) break;
    }

    return lastError ?? StepOutput.failure(context.config.id, '执行失败');
  }

  /// 解析步骤输入数据
  dynamic _resolveInput(
    StepConfig step,
    List<StepOutput> stepOutputs,
    Map<String, dynamic> contextVars,
  ) {
    dynamic inputData = null;

    // 首先检查新版 input 配置
    final input = step.input;
    final inputFrom = step.inputFrom;
    final inputPath = step.inputPath;

    // 确定输入来源
    String? sourceId;
    if (input?.sourceStepId != null && input!.sourceStepId!.isNotEmpty) {
      sourceId = input.sourceStepId;
    } else if (inputFrom != null && inputFrom.isNotEmpty) {
      sourceId = inputFrom;
    }

    if (sourceId != null) {
      if (sourceId == '__PREV__') {
        // 从上一步获取
        if (stepOutputs.isNotEmpty) {
          inputData = stepOutputs.last.data;
        }
      } else if (sourceId.startsWith('var:')) {
        // 从上下文变量获取
        final varName = sourceId.substring(4);
        inputData = contextVars[varName];
      } else {
        // 从指定步骤获取
        try {
          final sourceStep = stepOutputs.firstWhere((o) => o.stepId == sourceId);
          inputData = sourceStep.data;
        } catch (_) {
          // 指定步骤未找到，尝试从上一步获取
          if (stepOutputs.isNotEmpty) {
            inputData = stepOutputs.last.data;
          }
        }
      }

      // 如果配置了 inputPath，提取数据路径
      final path = input?.dataPath ?? inputPath;
      if (path != null && path.isNotEmpty && inputData != null) {
        inputData = _extractByPath(inputData, path);
      }
    } else if (stepOutputs.isNotEmpty) {
      // 默认从上一步获取
      inputData = stepOutputs.last.data;
    }

    // 如果没有获取到数据，使用默认值
    if (inputData == null && input?.defaultValue != null) {
      inputData = input!.defaultValue;
    }

    return inputData;
  }

  /// 执行单个步骤
  Future<StepOutput> _executeStep(StepConfig step, StepContext context) async {
    _ensureExecutorsRegistered();

    try {
      // 尝试从注册表获取执行器
      final registry = StepExecutorRegistry();
      final executor = registry.get(step.type.name);

      if (executor != null) {
        return await executor.execute(context);
      }

      // 如果没有注册的执行器，使用内置实现
      switch (step.type) {
        case StepType.http_request:
          return await _executeHttpStep(step, context);
        case StepType.data_extract:
          return _executeDataExtractStep(step, context);
        case StepType.data_transform:
          return _executeDataTransformStep(step, context);
        case StepType.data_filter:
          return _executeFilterStep(step, context);
        case StepType.data_sort:
          return _executeSortStep(step, context);
        case StepType.data_dedup:
          return _executeDedupStep(step, context);
        case StepType.condition:
          return _executeConditionStep(step, context);
        case StepType.var_get:
          return _executeVarGetStep(step, context);
        case StepType.var_set:
          return _executeVarSetStep(step, context);
        case StepType.var_delete:
          return _executeVarDeleteStep(step, context);
        case StepType.log:
          return _executeLogStep(step, context);
        case StepType.assertion:
          return _executeAssertStep(step, context);
        case StepType.delay:
          return _executeDelayStep(step, context);
        case StepType.comment:
          return _executeCommentStep(step, context);
        case StepType.database_query:
          return _executeDatabaseQueryStep(step, context);
        case StepType.cache_ops:
          return _executeCacheOpsStep(step, context);
        case StepType.notification:
          return _executeNotificationStep(step, context);
        default:
          return StepOutput.failure(step.id, '不支持的步骤类型: ${step.type}');
      }
    } catch (e) {
      return StepOutput.failure(step.id, e.toString());
    }
  }

  /// 执行 HTTP 请求步骤
  Future<StepOutput> _executeHttpStep(StepConfig step, StepContext context) async {
    final httpOpts = step.httpOptions;

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
          validateStatus: (status) => true,
        ),
        data: requestData,
      );

      var data = response.data;

      // 提取响应路径
      if (httpOpts.responsePath != null && httpOpts.responsePath!.isNotEmpty) {
        data = context.extractPath(data, httpOpts.responsePath!);
      }

      // 检查状态码
      final statusCode = response.statusCode ?? 0;
      if (httpOpts.throwOnError && (statusCode < 200 || statusCode >= 300)) {
        return StepOutput.failure(
          step.id,
          'HTTP 请求失败: $statusCode ${response.statusMessage}',
        );
      }

      return StepOutput.success(
        step.id,
        data,
        metadata: {'statusCode': statusCode},
      );
    } on DioException catch (e) {
      return StepOutput.failure(
        step.id,
        'HTTP 请求失败: ${e.message}',
      );
    }
  }

  /// 执行数据提取步骤
  StepOutput _executeDataExtractStep(StepConfig step, StepContext context) {
    final data = context.getInput();
    if (data == null) {
      return StepOutput.failure(step.id, '输入数据为空');
    }

    final options = step.options;
    final fields = options['fields'] as List<dynamic>?;
    final regexPattern = options['regexPattern'] as String?;
    final arrayIndex = options['arrayIndex'] as String?;

    dynamic result;

    if (fields != null && fields.isNotEmpty) {
      final extracted = <String, dynamic>{};
      for (final field in fields) {
        if (field is Map) {
          final name = field['name'] as String? ?? 'field';
          final path = field['path'] as String?;
          if (path != null && path.isNotEmpty) {
            extracted[name] = context.extractPath(data, path);
          } else {
            extracted[name] = data;
          }
        }
      }
      result = extracted;
    } else if (regexPattern != null && regexPattern.isNotEmpty) {
      result = _extractByRegex(data.toString(), regexPattern);
    } else if (arrayIndex != null && arrayIndex.isNotEmpty) {
      final index = int.tryParse(arrayIndex);
      if (data is List && index != null && index < data.length) {
        result = data[index];
      } else {
        return StepOutput.failure(step.id, '数组索引无效或数据不是数组: index=$arrayIndex');
      }
    } else {
      result = data;
    }

    return StepOutput.success(step.id, result);
  }

  /// 执行数据转换步骤
  StepOutput _executeDataTransformStep(StepConfig step, StepContext context) {
    final data = context.getInput();
    if (data == null) {
      return StepOutput.failure(step.id, '输入数据为空');
    }

    final options = step.options;
    final mappings = options['mappings'] as List<dynamic>? ?? [];

    if (mappings.isEmpty) {
      return StepOutput.success(step.id, data);
    }

    if (data is List) {
      final mapped = data.map((item) {
        if (item is! Map) return item;
        return _transformMap(item as Map, mappings);
      }).toList();
      return StepOutput.success(step.id, mapped);
    } else if (data is Map) {
      return StepOutput.success(step.id, _transformMap(data, mappings));
    }

    return StepOutput.success(step.id, data);
  }

  Map<String, dynamic> _transformMap(Map item, List<dynamic> mappings) {
    final result = Map<String, dynamic>.from(item);

    for (final mapping in mappings) {
      if (mapping is! Map) continue;

      final sourceField = mapping['sourceField'] as String?;
      final targetField = mapping['targetField'] as String?;
      final transform = mapping['transform'] as String?;

      if (sourceField == null || targetField == null) continue;

      var value = item[sourceField];

      if (transform != null && value != null) {
        switch (transform) {
          case 'uppercase':
            value = value.toString().toUpperCase();
            break;
          case 'lowercase':
            value = value.toString().toLowerCase();
            break;
          case 'trim':
            value = value.toString().trim();
            break;
          case 'capitalize':
            value = value.toString().split(' ').map((w) =>
              w.isNotEmpty ? '${w[0].toUpperCase()}${w.substring(1)}' : w
            ).join(' ');
            break;
        }
      }

      result[targetField] = value;
    }

    return result;
  }

  /// 执行过滤步骤
  StepOutput _executeFilterStep(StepConfig step, StepContext context) {
    final data = context.getInput();
    if (data is! List) {
      return StepOutput.failure(step.id, '过滤步骤需要列表数据');
    }

    final options = step.options;
    final field = options['field'] as String? ?? '';
    final operator = options['operator'] as String? ?? 'eq';
    final value = options['value'];
    final caseSensitive = options['caseSensitive'] as bool? ?? false;

    final filtered = data.where((item) {
      if (item is! Map) return true;

      final itemValue = item[field];
      return _compareValues(itemValue, operator, value, caseSensitive);
    }).toList();

    return StepOutput.success(step.id, filtered, metadata: {'filteredCount': filtered.length});
  }

  /// 执行排序步骤
  StepOutput _executeSortStep(StepConfig step, StepContext context) {
    final data = context.getInput();
    if (data is! List) {
      return StepOutput.failure(step.id, '排序步骤需要列表数据');
    }

    final options = step.options;
    final sortFields = options['fields'] as List<dynamic>? ?? [];

    if (sortFields.isEmpty) {
      return StepOutput.success(step.id, data);
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

    return StepOutput.success(step.id, sorted);
  }

  /// 执行去重步骤
  StepOutput _executeDedupStep(StepConfig step, StepContext context) {
    final data = context.getInput();
    if (data is! List) {
      return StepOutput.failure(step.id, '去重步骤需要列表数据');
    }

    final options = step.options;
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

    return StepOutput.success(step.id, result, metadata: {'dedupedCount': data.length - result.length});
  }

  /// 执行条件步骤
  StepOutput _executeConditionStep(StepConfig step, StepContext context) {
    final data = context.getInput();
    final options = step.options;

    final conditions = options['conditions'] as List<dynamic>? ?? [];
    final logicOperator = options['logicOperator'] as String? ?? 'and';

    bool result = true;

    for (final cond in conditions) {
      if (cond is! Map) continue;

      final field = cond['field'] as String? ?? '';
      final operator = cond['operator'] as String? ?? 'eq';
      final value = cond['value'];
      final condCaseSensitive = cond['caseSensitive'] as bool? ?? false;

      dynamic itemValue;
      if (field.isNotEmpty && data is Map) {
        itemValue = data[field];
      } else {
        itemValue = data;
      }

      final condResult = _compareValues(itemValue, operator, value, condCaseSensitive);

      if (logicOperator == 'and') {
        result = result && condResult;
        if (!result) break;
      } else {
        result = result || condResult;
        if (result) break;
      }
    }

    return StepOutput.success(
      step.id,
      result,
      metadata: {'conditionResult': result},
    );
  }

  /// 执行变量获取步骤
  StepOutput _executeVarGetStep(StepConfig step, StepContext context) {
    final options = step.options;
    final varName = options['varName'] as String? ?? '';
    final defaultValue = options['defaultValue'];

    if (varName.isEmpty) {
      return StepOutput.failure(step.id, '变量名不能为空');
    }

    final value = context.variables[varName] ?? defaultValue;

    return StepOutput.success(
      step.id,
      value,
      metadata: {'varName': varName},
    );
  }

  /// 执行变量设置步骤
  StepOutput _executeVarSetStep(StepConfig step, StepContext context) {
    final options = step.options;
    final varName = options['varName'] as String? ?? '';
    final value = options['value'] ?? context.getInput();
    final isSecret = options['isSecret'] as bool? ?? false;

    if (varName.isEmpty) {
      return StepOutput.failure(step.id, '变量名不能为空');
    }

    context.setOutput(varName, value);

    return StepOutput.success(
      step.id,
      value,
      metadata: {'varName': varName, 'isSecret': isSecret},
    );
  }

  /// 执行变量删除步骤
  StepOutput _executeVarDeleteStep(StepConfig step, StepContext context) {
    final options = step.options;
    final varName = options['varName'] as String? ?? '';

    if (varName.isEmpty) {
      return StepOutput.failure(step.id, '变量名不能为空');
    }

    final existed = context.variables.containsKey(varName);
    context.variables.remove(varName);

    return StepOutput.success(
      step.id,
      existed,
      metadata: {'varName': varName, 'existed': existed},
    );
  }

  /// 执行日志步骤
  StepOutput _executeLogStep(StepConfig step, StepContext context) {
    final options = step.options;
    final level = options['level'] as String? ?? 'info';
    final message = options['message'] as String? ?? '';
    final dataPath = options['dataPath'] as String?;

    dynamic data = context.getInput();
    if (dataPath != null && dataPath.isNotEmpty) {
      data = context.extractPath(data, dataPath);
    }

    final logEntry = {
      'level': level,
      'message': message,
      'data': data,
      'timestamp': DateTime.now().toIso8601String(),
    };

    return StepOutput.success(
      step.id,
      data,
      metadata: {'log': logEntry},
    );
  }

  /// 执行断言步骤
  StepOutput _executeAssertStep(StepConfig step, StepContext context) {
    final options = step.options;
    final condition = options['condition'] as String?;
    final message = options['message'] as String? ?? '断言失败';

    bool result = false;

    if (condition != null && condition.isNotEmpty) {
      result = _evaluateCondition(condition, context);
    }

    if (!result) {
      return StepOutput.failure(step.id, message);
    }

    return StepOutput.success(step.id, true);
  }

  /// 执行延迟步骤
  Future<StepOutput> _executeDelayStep(StepConfig step, StepContext context) async {
    final options = step.options;
    final seconds = options['seconds'] as int? ?? 1;

    await Future.delayed(Duration(seconds: seconds));

    return StepOutput.success(
      step.id,
      {'delayed': seconds},
      metadata: {'seconds': seconds},
    );
  }

  /// 执行注释步骤
  StepOutput _executeCommentStep(StepConfig step, StepContext context) {
    final options = step.options;
    final text = options['text'] as String? ?? '';

    return StepOutput.success(
      step.id,
      null,
      metadata: {'comment': text},
    );
  }

  /// 执行数据库查询步骤（占位实现）
  StepOutput _executeDatabaseQueryStep(StepConfig step, StepContext context) {
    final options = step.options;
    final tableName = options['tableName'] as String? ?? '';
    final columns = options['columns'] as List<dynamic>?;
    final whereClause = options['whereClause'] as String?;
    final limit = options['limit'] as int?;

    return StepOutput.success(
      step.id,
      [],
      metadata: {
        'tableName': tableName,
        'columns': columns,
        'whereClause': whereClause,
        'limit': limit,
        'note': 'Database query - implementation pending',
      },
    );
  }

  /// 执行缓存操作步骤（占位实现）
  StepOutput _executeCacheOpsStep(StepConfig step, StepContext context) {
    final options = step.options;
    final cacheKey = options['cacheKey'] as String? ?? '';
    final operation = options['operation'] as String? ?? 'get';
    final ttlSeconds = options['ttlSeconds'] as int? ?? 3600;

    return StepOutput.success(
      step.id,
      operation == 'get' ? null : context.getInput(),
      metadata: {
        'cacheKey': cacheKey,
        'operation': operation,
        'ttlSeconds': ttlSeconds,
        'note': 'Cache operations - implementation pending',
      },
    );
  }

  /// 执行通知步骤（占位实现）
  StepOutput _executeNotificationStep(StepConfig step, StepContext context) {
    final options = step.options;
    final channel = options['channel'] as String? ?? 'default';
    final recipient = options['recipient'] as String? ?? '';
    final message = options['message'] as String? ?? '';

    return StepOutput.success(
      step.id,
      {'sent': true},
      metadata: {
        'channel': channel,
        'recipient': recipient,
        'message': message,
        'note': 'Notification - implementation pending',
      },
    );
  }

  /// 根据路径提取数据
  dynamic _extractByPath(dynamic data, String path) {
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

  /// 根据正则表达式提取数据
  String? _extractByRegex(String data, String pattern) {
    try {
      final regex = RegExp(pattern);
      final match = regex.firstMatch(data);
      return match?.group(0);
    } catch (e) {
      return null;
    }
  }

  /// 比较值
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
      default:
        return false;
    }
  }

  /// 评估条件
  bool _evaluateCondition(String condition, StepContext context) {
    final data = context.getInput();

    final parts = condition.split(' ');
    if (parts.length < 3) {
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

    return _compareValues(fieldValue, operator, value, false);
  }
}

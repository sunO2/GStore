import 'dart:convert';

/// 工作流步骤类型枚举
enum StepType {
  // 网络类 (HTTP)
  http_request('HTTP 请求', '发送网络请求', StepCategory.network),

  // 数据处理类 (Data Processing)
  data_extract('数据提取', '提取数据字段', StepCategory.dataProcessing),
  data_transform('数据转换', '转换/映射字段', StepCategory.dataProcessing),
  data_filter('数据过滤', '按条件过滤数据', StepCategory.dataProcessing),
  data_sort('数据排序', '排序数据', StepCategory.dataProcessing),
  data_dedup('数据去重', '去除重复数据', StepCategory.dataProcessing),
  data_batch('批量处理', '批量处理数据', StepCategory.dataProcessing),

  // 逻辑控制类 (Control Flow)
  condition('条件分支', '条件判断分支', StepCategory.controlFlow),
  switch_case('多值分支', '多值条件分支', StepCategory.controlFlow),
  loop('循环', '循环执行', StepCategory.controlFlow),
  parallel('并行执行', '并行执行多个分支', StepCategory.controlFlow),
  merge('合并', '合并多个分支', StepCategory.controlFlow),
  delay('延迟等待', '延迟等待', StepCategory.controlFlow),

  // 变量类 (Variables)
  var_get('获取变量', '获取变量值', StepCategory.variables),
  var_set('设置变量', '设置变量值', StepCategory.variables),
  var_delete('删除变量', '删除变量', StepCategory.variables),

  // 外部集成类 (Integrations)
  database_read('数据库读取', '从数据库读取数据', StepCategory.integrations),
  database_write('数据库写入', '写入数据到数据库', StepCategory.integrations),
  database_create('数据库建表', '创建数据库表', StepCategory.integrations),
  database_query('数据库查询', '执行SQL查询', StepCategory.integrations),
  cache_ops('缓存操作', '缓存数据操作', StepCategory.integrations),
  notification('发送通知', '发送通知', StepCategory.integrations),

  // 工具类 (Utilities)
  log('日志记录', '记录日志', StepCategory.utilities),
  assertion('断言验证', '断言验证', StepCategory.utilities),
  comment('注释说明', '添加注释', StepCategory.utilities);

  final String label;
  final String description;
  final StepCategory category;

  const StepType(this.label, this.description, this.category);

  /// 获取步骤图标
  String get iconName {
    switch (this) {
      case StepType.http_request:
        return 'http';
      case StepType.data_extract:
        return 'data_usage';
      case StepType.data_transform:
        return 'transform';
      case StepType.data_filter:
        return 'filter_list';
      case StepType.data_sort:
        return 'sort';
      case StepType.data_dedup:
        return 'unique';
      case StepType.data_batch:
        return 'batch';
      case StepType.condition:
        return 'alt_route';
      case StepType.switch_case:
        return 'switch_video';
      case StepType.loop:
        return 'loop';
      case StepType.parallel:
        return 'account_tree';
      case StepType.merge:
        return 'merge';
      case StepType.delay:
        return 'timer';
      case StepType.var_get:
        return 'download';
      case StepType.var_set:
        return 'upload';
      case StepType.var_delete:
        return 'delete';
      case StepType.database_read:
        return 'table_rows';
      case StepType.database_write:
        return 'table_chart';
      case StepType.database_create:
        return 'add_circle';
      case StepType.database_query:
        return 'storage';
      case StepType.cache_ops:
        return 'cached';
      case StepType.notification:
        return 'notifications';
      case StepType.log:
        return 'note_add';
      case StepType.assertion:
        return 'verified';
      case StepType.comment:
        return 'comment';
    }
  }
}

/// 步骤类别
enum StepCategory {
  network('网络', 'network'),
  dataProcessing('数据处理', 'data_processing'),
  controlFlow('逻辑控制', 'control_flow'),
  variables('变量', 'variables'),
  integrations('外部集成', 'integrations'),
  utilities('工具', 'utilities');

  final String label;
  final String value;

  const StepCategory(this.label, this.value);
}

/// 步骤输入输出配置
class StepIOConfig {
  /// 来源步骤ID
  final String? sourceStepId;

  /// 数据路径 (如: data.items[0].name)
  final String? dataPath;

  /// 默认值
  final dynamic defaultValue;

  /// 是否必需
  final bool required;

  /// 数据转换器表达式
  final String? transform;

  StepIOConfig({
    this.sourceStepId,
    this.dataPath,
    this.defaultValue,
    this.required = false,
    this.transform,
  });

  StepIOConfig copyWith({
    String? sourceStepId,
    String? dataPath,
    dynamic defaultValue,
    bool? required,
    String? transform,
    bool clearSourceStepId = false,
    bool clearDataPath = false,
    bool clearTransform = false,
  }) {
    return StepIOConfig(
      sourceStepId: clearSourceStepId ? null : (sourceStepId ?? this.sourceStepId),
      dataPath: clearDataPath ? null : (dataPath ?? this.dataPath),
      defaultValue: defaultValue ?? this.defaultValue,
      required: required ?? this.required,
      transform: clearTransform ? null : (transform ?? this.transform),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (sourceStepId != null) 'sourceStepId': sourceStepId,
      if (dataPath != null) 'dataPath': dataPath,
      if (defaultValue != null) 'defaultValue': defaultValue,
      'required': required,
      if (transform != null) 'transform': transform,
    };
  }

  factory StepIOConfig.fromJson(Map<String, dynamic> json) {
    return StepIOConfig(
      sourceStepId: json['sourceStepId'] as String?,
      dataPath: json['dataPath'] as String?,
      defaultValue: json['defaultValue'],
      required: json['required'] as bool? ?? false,
      transform: json['transform'] as String?,
    );
  }

  /// 判断是否为空配置
  bool get isEmpty =>
      sourceStepId == null &&
      dataPath == null &&
      defaultValue == null &&
      transform == null;

  /// 获取输入来源描述
  String get sourceDescription {
    if (sourceStepId == null || sourceStepId!.isEmpty) {
      return '上一步';
    }
    if (sourceStepId == '__PREV__') {
      return '上一步';
    }
    if (sourceStepId!.startsWith('var:')) {
      return '变量: ${sourceStepId!.substring(4)}';
    }
    return '步骤: $sourceStepId';
  }
}

/// 错误处理配置
class ErrorHandlingConfig {
  /// 重试次数
  final int retryCount;

  /// 重试延迟秒数
  final int retryDelay;

  /// 出错继续执行
  final bool continueOnError;

  /// 错误输出变量名
  final String? errorVar;

  ErrorHandlingConfig({
    this.retryCount = 0,
    this.retryDelay = 1,
    this.continueOnError = false,
    this.errorVar,
  });

  ErrorHandlingConfig copyWith({
    int? retryCount,
    int? retryDelay,
    bool? continueOnError,
    String? errorVar,
    bool clearErrorVar = false,
  }) {
    return ErrorHandlingConfig(
      retryCount: retryCount ?? this.retryCount,
      retryDelay: retryDelay ?? this.retryDelay,
      continueOnError: continueOnError ?? this.continueOnError,
      errorVar: clearErrorVar ? null : (errorVar ?? this.errorVar),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'retryCount': retryCount,
      'retryDelay': retryDelay,
      'continueOnError': continueOnError,
      if (errorVar != null) 'errorVar': errorVar,
    };
  }

  factory ErrorHandlingConfig.fromJson(Map<String, dynamic> json) {
    return ErrorHandlingConfig(
      retryCount: json['retryCount'] as int? ?? 0,
      retryDelay: json['retryDelay'] as int? ?? 1,
      continueOnError: json['continueOnError'] as bool? ?? false,
      errorVar: json['errorVar'] as String?,
    );
  }
}

/// 数据提取字段配置
class ExtractField {
  /// 字段名称（输出变量名）
  final String name;

  /// 数据路径（JSONPath 或属性路径）
  final String path;

  /// 字段描述
  final String? description;

  /// 是否启用
  final bool enabled;

  /// 正则表达式（可选，用于复杂提取）
  final String? regex;

  /// 默认值（提取失败时使用）
  final String? defaultValue;

  ExtractField({
    required this.name,
    this.path = '',
    this.description,
    this.enabled = true,
    this.regex,
    this.defaultValue,
  });

  ExtractField copyWith({
    String? name,
    String? path,
    String? description,
    bool? enabled,
    String? regex,
    String? defaultValue,
  }) {
    return ExtractField(
      name: name ?? this.name,
      path: path ?? this.path,
      description: description ?? this.description,
      enabled: enabled ?? this.enabled,
      regex: regex ?? this.regex,
      defaultValue: defaultValue ?? this.defaultValue,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'path': path,
      if (description != null) 'description': description,
      'enabled': enabled,
      if (regex != null) 'regex': regex,
      if (defaultValue != null) 'defaultValue': defaultValue,
    };
  }

  factory ExtractField.fromJson(Map<String, dynamic> json) {
    return ExtractField(
      name: json['name'] as String,
      path: json['path'] as String? ?? '',
      description: json['description'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      regex: json['regex'] as String?,
      defaultValue: json['defaultValue'] as String?,
    );
  }
}

/// HTTP 请求配置
class HttpRequestOptions {
  // 请求基础
  final String method;
  final String url;

  // 请求头
  final Map<String, String> headers;
  final Map<String, String> queryParams;

  // 认证
  final String? authType;
  final Map<String, String> authConfig;

  // Body
  final String bodyType;
  final String body;
  final String? bodyFilePath;

  // SSL
  final bool verifySsl;
  final String? caCert;

  // 重定向
  final bool followRedirects;
  final int maxRedirects;

  // 超时
  final int connectTimeout;
  final int readTimeout;
  final int writeTimeout;

  // 响应处理
  final String? responsePath;
  final Map<int, String>? statusCodeHandlers;
  final bool throwOnError;

  HttpRequestOptions({
    this.method = 'GET',
    this.url = '',
    this.headers = const {},
    this.queryParams = const {},
    this.authType,
    this.authConfig = const {},
    this.bodyType = 'none',
    this.body = '',
    this.bodyFilePath,
    this.verifySsl = true,
    this.caCert,
    this.followRedirects = true,
    this.maxRedirects = 5,
    this.connectTimeout = 30,
    this.readTimeout = 30,
    this.writeTimeout = 30,
    this.responsePath,
    this.statusCodeHandlers,
    this.throwOnError = true,
  });

  HttpRequestOptions copyWith({
    String? method,
    String? url,
    Map<String, String>? headers,
    Map<String, String>? queryParams,
    String? authType,
    Map<String, String>? authConfig,
    String? bodyType,
    String? body,
    String? bodyFilePath,
    bool? verifySsl,
    String? caCert,
    bool? followRedirects,
    int? maxRedirects,
    int? connectTimeout,
    int? readTimeout,
    int? writeTimeout,
    String? responsePath,
    Map<int, String>? statusCodeHandlers,
    bool? throwOnError,
    bool clearAuthType = false,
    bool clearCaCert = false,
    bool clearResponsePath = false,
  }) {
    return HttpRequestOptions(
      method: method ?? this.method,
      url: url ?? this.url,
      headers: headers ?? this.headers,
      queryParams: queryParams ?? this.queryParams,
      authType: clearAuthType ? null : (authType ?? this.authType),
      authConfig: authConfig ?? this.authConfig,
      bodyType: bodyType ?? this.bodyType,
      body: body ?? this.body,
      bodyFilePath: bodyFilePath ?? this.bodyFilePath,
      verifySsl: verifySsl ?? this.verifySsl,
      caCert: clearCaCert ? null : (caCert ?? this.caCert),
      followRedirects: followRedirects ?? this.followRedirects,
      maxRedirects: maxRedirects ?? this.maxRedirects,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      readTimeout: readTimeout ?? this.readTimeout,
      writeTimeout: writeTimeout ?? this.writeTimeout,
      responsePath: clearResponsePath ? null : (responsePath ?? this.responsePath),
      statusCodeHandlers: statusCodeHandlers ?? this.statusCodeHandlers,
      throwOnError: throwOnError ?? this.throwOnError,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'method': method,
      'url': url,
      'headers': headers,
      'queryParams': queryParams,
      if (authType != null) 'authType': authType,
      'authConfig': authConfig,
      'bodyType': bodyType,
      'body': body,
      if (bodyFilePath != null) 'bodyFilePath': bodyFilePath,
      'verifySsl': verifySsl,
      if (caCert != null) 'caCert': caCert,
      'followRedirects': followRedirects,
      'maxRedirects': maxRedirects,
      'connectTimeout': connectTimeout,
      'readTimeout': readTimeout,
      'writeTimeout': writeTimeout,
      if (responsePath != null) 'responsePath': responsePath,
      if (statusCodeHandlers != null)
        'statusCodeHandlers': statusCodeHandlers!.map((k, v) => MapEntry(k.toString(), v)),
      'throwOnError': throwOnError,
    };
  }

  factory HttpRequestOptions.fromJson(Map<String, dynamic> json) {
    return HttpRequestOptions(
      method: json['method'] as String? ?? 'GET',
      url: json['url'] as String? ?? '',
      headers: Map<String, String>.from(json['headers'] as Map? ?? {}),
      queryParams: Map<String, String>.from(json['queryParams'] as Map? ?? {}),
      authType: json['authType'] as String?,
      authConfig: Map<String, String>.from(json['authConfig'] as Map? ?? {}),
      bodyType: json['bodyType'] as String? ?? 'none',
      body: json['body'] as String? ?? '',
      bodyFilePath: json['bodyFilePath'] as String?,
      verifySsl: json['verifySsl'] as bool? ?? true,
      caCert: json['caCert'] as String?,
      followRedirects: json['followRedirects'] as bool? ?? true,
      maxRedirects: json['maxRedirects'] as int? ?? 5,
      connectTimeout: json['connectTimeout'] as int? ?? 30,
      readTimeout: json['readTimeout'] as int? ?? 30,
      writeTimeout: json['writeTimeout'] as int? ?? 30,
      responsePath: json['responsePath'] as String?,
      statusCodeHandlers: (json['statusCodeHandlers'] as Map<String, dynamic>?)?.map(
        (k, v) => MapEntry(int.parse(k), v as String),
      ),
      throwOnError: json['throwOnError'] as bool? ?? true,
    );
  }

  /// 转换为旧版 options 格式（用于兼容）
  Map<String, dynamic> toLegacyOptions() {
    return {
      'method': method,
      'url': url,
      'headers': jsonEncode(headers),
      'queryParams': queryParams,
      'bodyType': bodyType,
      'body': body,
      'connectTimeout': connectTimeout,
      'readTimeout': readTimeout,
      'writeTimeout': writeTimeout,
      'responsePath': responsePath,
      'verifySsl': verifySsl,
      'followRedirects': followRedirects,
      'maxRedirects': maxRedirects,
      'throwOnError': throwOnError,
      if (authType != null) 'authType': authType,
      ...authConfig.map((k, v) => MapEntry('auth_$k', v)),
    };
  }

  /// 从旧版 options 创建
  factory HttpRequestOptions.fromLegacyOptions(Map<String, dynamic> options) {
    String? authType;
    Map<String, String> authConfig = {};
    if (options.containsKey('authType')) {
      authType = options['authType'] as String?;
      authConfig = options.map((k, v) {
        if (k.startsWith('auth_')) {
          return MapEntry(k.substring(5), v.toString());
        }
        return MapEntry(k, v);
      }).cast<String, String>();
    }

    Map<String, String> headers = {};
    if (options['headers'] is String) {
      try {
        headers = Map<String, String>.from(jsonDecode(options['headers'] as String) as Map);
      } catch (_) {}
    }

    return HttpRequestOptions(
      method: options['method'] as String? ?? 'GET',
      url: options['url'] as String? ?? '',
      headers: headers,
      queryParams: Map<String, String>.from(options['queryParams'] as Map? ?? {}),
      authType: authType,
      authConfig: authConfig,
      bodyType: options['bodyType'] as String? ?? 'none',
      body: options['body'] as String? ?? '',
      connectTimeout: options['connectTimeout'] as int? ?? 30,
      readTimeout: options['readTimeout'] as int? ?? 30,
      writeTimeout: options['writeTimeout'] as int? ?? 30,
      responsePath: options['responsePath'] as String?,
      verifySsl: options['verifySsl'] as bool? ?? true,
      followRedirects: options['followRedirects'] as bool? ?? true,
      maxRedirects: options['maxRedirects'] as int? ?? 5,
      throwOnError: options['throwOnError'] as bool? ?? true,
    );
  }
}

/// 条件配置
class ConditionConfig {
  final String field;
  final String operator;
  final dynamic value;
  final bool caseSensitive;

  ConditionConfig({
    this.field = '',
    this.operator = 'eq',
    this.value,
    this.caseSensitive = false,
  });

  ConditionConfig copyWith({
    String? field,
    String? operator,
    dynamic value,
    bool? caseSensitive,
  }) {
    return ConditionConfig(
      field: field ?? this.field,
      operator: operator ?? this.operator,
      value: value ?? this.value,
      caseSensitive: caseSensitive ?? this.caseSensitive,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'field': field,
      'operator': operator,
      'value': value,
      'caseSensitive': caseSensitive,
    };
  }

  factory ConditionConfig.fromJson(Map<String, dynamic> json) {
    return ConditionConfig(
      field: json['field'] as String? ?? '',
      operator: json['operator'] as String? ?? 'eq',
      value: json['value'],
      caseSensitive: json['caseSensitive'] as bool? ?? false,
    );
  }
}

/// 步骤输入
class StepInput {
  final String stepId;
  final dynamic data;
  final Map<String, dynamic>? context;

  StepInput({
    required this.stepId,
    required this.data,
    this.context,
  });
}

/// 步骤输出
class StepOutput {
  final String stepId;
  final bool success;
  final dynamic data;
  final String? error;
  final Map<String, dynamic>? metadata;

  StepOutput({
    required this.stepId,
    required this.success,
    required this.data,
    this.error,
    this.metadata,
  });

  factory StepOutput.success(String stepId, dynamic data, {Map<String, dynamic>? metadata}) {
    return StepOutput(
      stepId: stepId,
      success: true,
      data: data,
      metadata: metadata,
    );
  }

  factory StepOutput.failure(String stepId, String error) {
    return StepOutput(
      stepId: stepId,
      success: false,
      data: null,
      error: error,
    );
  }
}

import 'dart:convert';
import '../../channel/channel.dart';
import 'step_model.dart';
import 'step_position.dart';
import 'variable.dart';

/// 工作流步骤配置
class StepConfig {
  final String id;
  final StepType type;
  final String name;
  final String? description;
  final bool enabled;
  final Map<String, dynamic> options;
  final String? branchId;  // 分支ID，用于并行步骤
  final List<String> nextStepIds;  // 下一个步骤ID列表（支持多输出，用于分支）
  // 新增：输入输出配置
  final StepIOConfig? input;
  final StepIOConfig? output;
  // 新增：错误处理配置
  final ErrorHandlingConfig? errorHandling;

  StepConfig({
    required this.id,
    required this.type,
    required this.name,
    this.description,
    this.enabled = true,
    Map<String, dynamic>? options,
    this.branchId,
    List<String>? nextStepIds,
    this.input,
    this.output,
    this.errorHandling,
  }) : options = options ?? {},
       nextStepIds = nextStepIds ?? [];

  StepConfig copyWith({
    String? id,
    StepType? type,
    String? name,
    String? description,
    bool? enabled,
    Map<String, dynamic>? options,
    String? branchId,
    bool clearBranchId = false,
    List<String>? nextStepIds,
    StepIOConfig? input,
    bool clearInput = false,
    StepIOConfig? output,
    bool clearOutput = false,
    ErrorHandlingConfig? errorHandling,
    bool clearErrorHandling = false,
  }) {
    return StepConfig(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      description: description ?? this.description,
      enabled: enabled ?? this.enabled,
      options: options ?? Map.from(this.options),
      branchId: clearBranchId ? null : (branchId ?? this.branchId),
      nextStepIds: nextStepIds ?? List.from(this.nextStepIds),
      input: clearInput ? null : (input ?? this.input),
      output: clearOutput ? null : (output ?? this.output),
      errorHandling: clearErrorHandling ? null : (errorHandling ?? this.errorHandling),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'name': name,
      'description': description,
      'enabled': enabled,
      'options': options,
      'branchId': branchId,
      'nextStepIds': nextStepIds,
      if (input != null) 'input': input!.toJson(),
      if (output != null) 'output': output!.toJson(),
      if (errorHandling != null) 'errorHandling': errorHandling!.toJson(),
    };
  }

  factory StepConfig.fromJson(Map<String, dynamic> json) {
    return StepConfig(
      id: json['id'] as String,
      type: StepType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => StepType.http_request,
      ),
      name: json['name'] as String,
      description: json['description'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      options: Map<String, dynamic>.from(json['options'] ?? {}),
      branchId: json['branchId'] as String?,
      nextStepIds: (json['nextStepIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ?? [],
      input: json['input'] != null
          ? StepIOConfig.fromJson(json['input'] as Map<String, dynamic>)
          : null,
      output: json['output'] != null
          ? StepIOConfig.fromJson(json['output'] as Map<String, dynamic>)
          : null,
      errorHandling: json['errorHandling'] != null
          ? ErrorHandlingConfig.fromJson(json['errorHandling'] as Map<String, dynamic>)
          : null,
    );
  }

  // ========== 兼容旧版 options 的便捷访问 ==========

  /// 获取输入来源（旧版兼容）
  String? get inputFrom => options['inputFrom'] as String?;

  /// 获取输入路径（旧版兼容）
  String? get inputPath => options['inputPath'] as String?;

  /// 获取输出变量名（旧版兼容）
  String? get outputVar => options['outputVar'] as String?;

  /// 获取 HTTP 请求配置（新版）
  HttpRequestOptions get httpOptions {
    if (options.containsKey('httpOptions')) {
      return HttpRequestOptions.fromJson(options['httpOptions'] as Map<String, dynamic>);
    }
    // 兼容旧版
    return HttpRequestOptions.fromLegacyOptions(options);
  }

  /// 复制并设置 HTTP 请求配置
  StepConfig withHttpOptions(HttpRequestOptions httpOptions) {
    return copyWith(options: {
      ...options,
      'httpOptions': httpOptions.toJson(),
      // 同时保留旧版字段用于兼容
      ...httpOptions.toLegacyOptions(),
    });
  }
}

/// 工作流设置
class WorkflowSettings {
  /// 超时时间（秒）
  final int timeout;

  /// 最大迭代次数
  final int maxIterations;

  /// 是否启用调试模式
  final bool debugMode;

  WorkflowSettings({
    this.timeout = 300,
    this.maxIterations = 1000,
    this.debugMode = false,
  });

  WorkflowSettings copyWith({
    int? timeout,
    int? maxIterations,
    bool? debugMode,
  }) {
    return WorkflowSettings(
      timeout: timeout ?? this.timeout,
      maxIterations: maxIterations ?? this.maxIterations,
      debugMode: debugMode ?? this.debugMode,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'timeout': timeout,
      'maxIterations': maxIterations,
      'debugMode': debugMode,
    };
  }

  factory WorkflowSettings.fromJson(Map<String, dynamic> json) {
    return WorkflowSettings(
      timeout: json['timeout'] as int? ?? 300,
      maxIterations: json['maxIterations'] as int? ?? 1000,
      debugMode: json['debugMode'] as bool? ?? false,
    );
  }
}

/// 工作流元数据
class WorkflowMetadata {
  final String? createdBy;
  final String? version;
  final List<String> tags;
  final Map<String, dynamic>? customData;

  WorkflowMetadata({
    this.createdBy,
    this.version,
    this.tags = const [],
    this.customData,
  });

  WorkflowMetadata copyWith({
    String? createdBy,
    String? version,
    List<String>? tags,
    Map<String, dynamic>? customData,
  }) {
    return WorkflowMetadata(
      createdBy: createdBy ?? this.createdBy,
      version: version ?? this.version,
      tags: tags ?? this.tags,
      customData: customData ?? this.customData,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (createdBy != null) 'createdBy': createdBy,
      if (version != null) 'version': version,
      'tags': tags,
      if (customData != null) 'customData': customData,
    };
  }

  factory WorkflowMetadata.fromJson(Map<String, dynamic> json) {
    return WorkflowMetadata(
      createdBy: json['createdBy'] as String?,
      version: json['version'] as String?,
      tags: (json['tags'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [],
      customData: json['customData'] as Map<String, dynamic>?,
    );
  }
}

/// 工作流模型
class WorkflowModel {
  final String id;
  final String name;
  final String? description;
  final ChannelType? channelType;      // 绑定的渠道类型
  final String? functionName;          // 绑定的函数名 (getAllApps, searchApps 等)
  final List<StepConfig> steps;
  final Map<String, dynamic>? parameters;
  /// 步骤在画布上的位置 {stepId: StepPosition}
  final Map<String, StepPosition> stepPositions;
  /// 视口缩放比例
  final double viewportScale;
  /// 视口偏移量
  final double viewportOffsetX;
  final double viewportOffsetY;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isEnabled;

  // 新增：工作流变量
  final Map<String, WorkflowVariable> variables;

  // 新增：工作流设置
  final WorkflowSettings settings;

  // 新增：工作流元数据
  final WorkflowMetadata metadata;

  WorkflowModel({
    required this.id,
    required this.name,
    this.description,
    this.channelType,
    this.functionName,
    required this.steps,
    this.parameters,
    this.stepPositions = const {},
    this.viewportScale = 1.0,
    this.viewportOffsetX = 0.0,
    this.viewportOffsetY = 0.0,
    required this.createdAt,
    required this.updatedAt,
    this.isEnabled = true,
    this.variables = const {},
    WorkflowSettings? settings,
    WorkflowMetadata? metadata,
  }) : settings = settings ?? WorkflowSettings(),
       metadata = metadata ?? WorkflowMetadata();

  /// 是否已绑定到渠道函数
  bool get isBound => channelType != null && functionName != null;

  /// 获取拓扑排序后的步骤列表
  List<StepConfig> get topologicalSteps {
    if (steps.isEmpty) return [];

    final result = <StepConfig>[];
    final visited = <String>{};
    final stepMap = {for (var s in steps) s.id: s};

    void visit(StepConfig step) {
      if (visited.contains(step.id)) return;
      visited.add(step.id);
      result.add(step);

      for (final nextId in step.nextStepIds) {
        final nextStep = stepMap[nextId];
        if (nextStep != null) {
          visit(nextStep);
        }
      }
    }

    // 从第一个步骤开始
    if (steps.isNotEmpty) {
      visit(steps.first);
    }

    return result;
  }

  WorkflowModel copyWith({
    String? id,
    String? name,
    String? description,
    ChannelType? channelType,
    String? functionName,
    List<StepConfig>? steps,
    Map<String, dynamic>? parameters,
    Map<String, StepPosition>? stepPositions,
    double? viewportScale,
    double? viewportOffsetX,
    double? viewportOffsetY,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isEnabled,
    Map<String, WorkflowVariable>? variables,
    WorkflowSettings? settings,
    WorkflowMetadata? metadata,
    bool clearChannelBinding = false,
  }) {
    return WorkflowModel(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      channelType: clearChannelBinding ? null : (channelType ?? this.channelType),
      functionName: clearChannelBinding ? null : (functionName ?? this.functionName),
      steps: steps ?? List.from(this.steps),
      parameters: parameters ?? Map.from(this.parameters ?? {}),
      stepPositions: stepPositions ?? Map.from(this.stepPositions),
      viewportScale: viewportScale ?? this.viewportScale,
      viewportOffsetX: viewportOffsetX ?? this.viewportOffsetX,
      viewportOffsetY: viewportOffsetY ?? this.viewportOffsetY,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isEnabled: isEnabled ?? this.isEnabled,
      variables: variables ?? Map.from(this.variables),
      settings: settings ?? this.settings,
      metadata: metadata ?? this.metadata,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'channelType': channelType?.name,
      'functionName': functionName,
      'steps': steps.map((s) => s.toJson()).toList(),
      'parameters': parameters,
      'stepPositions': stepPositions.map((k, v) => MapEntry(k, v.toJson())),
      'viewportScale': viewportScale,
      'viewportOffsetX': viewportOffsetX,
      'viewportOffsetY': viewportOffsetY,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'isEnabled': isEnabled,
      'variables': variables.map((k, v) => MapEntry(k, v.toJson())),
      'settings': settings.toJson(),
      'metadata': metadata.toJson(),
    };
  }

  factory WorkflowModel.fromJson(Map<String, dynamic> json) {
    // 解析 stepPositions
    Map<String, StepPosition> positions = {};
    final positionsJson = json['stepPositions'] as Map<String, dynamic>?;
    if (positionsJson != null) {
      positions = positionsJson.map(
        (k, v) => MapEntry(k, StepPosition.fromJson(v as Map<String, dynamic>)),
      );
    }

    // 解析 variables
    Map<String, WorkflowVariable> variables = {};
    final variablesJson = json['variables'] as Map<String, dynamic>?;
    if (variablesJson != null) {
      variables = variablesJson.map(
        (k, v) => MapEntry(k, WorkflowVariable.fromJson(v as Map<String, dynamic>)),
      );
    }

    return WorkflowModel(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      channelType: json['channelType'] != null
          ? ChannelType.values.firstWhere(
              (e) => e.name == json['channelType'],
              orElse: () => ChannelType.github,
            )
          : null,
      functionName: json['functionName'] as String?,
      steps: (json['steps'] as List<dynamic>?)
              ?.map((s) => StepConfig.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
      parameters: json['parameters'] as Map<String, dynamic>?,
      stepPositions: positions,
      viewportScale: (json['viewportScale'] as num?)?.toDouble() ?? 1.0,
      viewportOffsetX: (json['viewportOffsetX'] as num?)?.toDouble() ?? 0.0,
      viewportOffsetY: (json['viewportOffsetY'] as num?)?.toDouble() ?? 0.0,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      isEnabled: json['isEnabled'] as bool? ?? true,
      variables: variables,
      settings: json['settings'] != null
          ? WorkflowSettings.fromJson(json['settings'] as Map<String, dynamic>)
          : null,
      metadata: json['metadata'] != null
          ? WorkflowMetadata.fromJson(json['metadata'] as Map<String, dynamic>)
          : null,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory WorkflowModel.fromJsonString(String jsonStr) {
    return WorkflowModel.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
  }
}

/// 工作流执行结果
class WorkflowResult {
  final bool success;
  final dynamic output;
  final List<StepOutput> stepOutputs;
  final String? error;
  final Duration duration;

  WorkflowResult({
    required this.success,
    required this.output,
    required this.stepOutputs,
    this.error,
    required this.duration,
  });

  factory WorkflowResult.failure(String error, Duration duration) {
    return WorkflowResult(
      success: false,
      output: null,
      stepOutputs: [],
      error: error,
      duration: duration,
    );
  }

  /// 获取中间输出结果（用于步骤间传递数据）
  dynamic getOutput(String stepId) {
    try {
      return stepOutputs.firstWhere((o) => o.stepId == stepId).data;
    } catch (e) {
      return null;
    }
  }

  /// 获取所有输出作为 Map
  Map<String, dynamic> getAllOutputs() {
    final result = <String, dynamic>{};
    for (final output in stepOutputs) {
      if (output.metadata != null && output.metadata!.containsKey('output')) {
        result.addAll(output.metadata!['output'] as Map<String, dynamic>);
      }
    }
    return result;
  }
}

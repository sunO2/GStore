import 'dart:convert';

/// 变量类型
enum VariableType {
  string('字符串'),
  number('数字'),
  boolean('布尔值'),
  object('对象'),
  array('数组');

  final String label;
  const VariableType(this.label);
}

/// 工作流变量定义
class WorkflowVariable {
  final String name;
  final VariableType type;
  final dynamic defaultValue;
  final String? description;
  final bool isSecret;

  WorkflowVariable({
    required this.name,
    required this.type,
    this.defaultValue,
    this.description,
    this.isSecret = false,
  });

  WorkflowVariable copyWith({
    String? name,
    VariableType? type,
    dynamic defaultValue,
    String? description,
    bool? isSecret,
  }) {
    return WorkflowVariable(
      name: name ?? this.name,
      type: type ?? this.type,
      defaultValue: defaultValue ?? this.defaultValue,
      description: description ?? this.description,
      isSecret: isSecret ?? this.isSecret,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type.name,
      'defaultValue': defaultValue,
      'description': description,
      'isSecret': isSecret,
    };
  }

  factory WorkflowVariable.fromJson(Map<String, dynamic> json) {
    return WorkflowVariable(
      name: json['name'] as String,
      type: VariableType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => VariableType.string,
      ),
      defaultValue: json['defaultValue'],
      description: json['description'] as String?,
      isSecret: json['isSecret'] as bool? ?? false,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory WorkflowVariable.fromJsonString(String jsonStr) {
    return WorkflowVariable.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
  }
}

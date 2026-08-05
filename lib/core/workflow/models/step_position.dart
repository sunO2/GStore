/// 步骤在画布上的位置
class StepPosition {
  final double x;
  final double y;

  const StepPosition({required this.x, required this.y});

  StepPosition copyWith({double? x, double? y}) {
    return StepPosition(
      x: x ?? this.x,
      y: y ?? this.y,
    );
  }

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  factory StepPosition.fromJson(Map<String, dynamic> json) {
    return StepPosition(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StepPosition &&
          runtimeType == other.runtimeType &&
          x == other.x &&
          y == other.y;

  @override
  int get hashCode => x.hashCode ^ y.hashCode;

  @override
  String toString() => 'StepPosition($x, $y)';
}

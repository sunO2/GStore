/// FPS 会话录制模型（纯 Dart，无 Flutter / 引擎 / I/O 依赖）。
///
/// 一次「FPS 会话录制」= 起止时间 + 逐拍帧率样本 + 汇总统计（平均 / 最小 /
/// 最大 / 末值）。本文件只承载**数据 + 纯函数**（序列化 / CSV / 时长格式化），
/// 采样与落盘分别由 [FpsSessionRecorder] 与 `fps_session_store.dart` 负责。
///
/// 设计要点：
/// * **确定性**：[FpsSession] 不取 `DateTime.now()`，起止时间由调用方注入；
/// * **宽容反序列化**：缺失 / 非法字段一律降级（空串 / `0` / 空样本），统计量
///   缺失时由样本重算，绝不抛出；
/// * **有界语义**：[frameCount] 即样本条数，与 [samples] 长度恒等。
library;

/// 一次 FPS 会话的汇总统计（`0` 样本时为全 `0`）。
///
/// 纯函数：对样本先过滤非有限 / 负值，再计算；`null` / 越界样本被忽略。
class FpsStats {
  const FpsStats({
    required this.fps,
    required this.avg,
    required this.min,
    required this.max,
    required this.count,
  });

  /// 末值（最后一个有效样本；无样本为 `0`）。
  final double fps;

  /// 平均值（无样本为 `0`）。
  final double avg;

  /// 最小值（无样本为 `0`）。
  final double min;

  /// 最大值（无样本为 `0`）。
  final double max;

  /// 有效样本数。
  final int count;

  /// 由样本序列计算统计（过滤 `NaN` / `±Infinity` / 负值）。
  factory FpsStats.fromSamples(Iterable<double> samples) {
    final valid = <double>[];
    for (final value in samples) {
      if (value.isFinite && value >= 0) valid.add(value);
    }
    if (valid.isEmpty) {
      return const FpsStats(fps: 0, avg: 0, min: 0, max: 0, count: 0);
    }
    var min = valid.first;
    var max = valid.first;
    var sum = 0.0;
    for (final value in valid) {
      if (value < min) min = value;
      if (value > max) max = value;
      sum += value;
    }
    return FpsStats(
      fps: valid.last,
      avg: sum / valid.length,
      min: min,
      max: max,
      count: valid.length,
    );
  }

  @override
  String toString() => 'FpsStats(fps: $fps, avg: $avg, min: $min, max: $max, '
      'count: $count)';
}

/// 一次 FPS 会话录制结果。
class FpsSession {
  const FpsSession({
    required this.id,
    this.package,
    required this.label,
    required this.startMs,
    required this.endMs,
    required this.samples,
    required this.fps,
    required this.avg,
    required this.min,
    required this.max,
    this.source,
    this.avgPower = 0,
    this.viewSize = '',
    this.mode = '',
    this.temperatures = const <double>[],
  });

  /// 由起止时间 + 样本构造（统计量自动计算）。
  ///
  /// Scene-parity 字段 [avgPower] / [viewSize] / [mode] / [temperatures]
  /// 由调用方注入（见 `fps_session_recorder.dart`），缺省安全降级。
  factory FpsSession.fromRecording({
    required String id,
    String? package,
    required String label,
    required int startMs,
    required int endMs,
    required Iterable<double> samples,
    String? source,
    double avgPower = 0,
    String viewSize = '',
    String mode = '',
    Iterable<double> temperatures = const <double>[],
  }) {
    final list = <double>[];
    for (final value in samples) {
      if (value.isFinite && value >= 0) list.add(value);
    }
    final stats = FpsStats.fromSamples(list);
    return FpsSession(
      id: id,
      package: package,
      label: label,
      startMs: startMs,
      endMs: endMs,
      samples: List<double>.unmodifiable(list),
      fps: stats.fps,
      avg: stats.avg,
      min: stats.min,
      max: stats.max,
      source: source,
      avgPower: avgPower.isFinite ? avgPower : 0,
      viewSize: viewSize,
      mode: mode,
      temperatures: List<double>.unmodifiable(_finiteValues(temperatures)),
    );
  }

  /// 唯一标识（默认 `<startMs>` 派生，见 `fps_session_recorder.dart`）。
  final String id;

  /// Scene 的 `sessionId` **是 [id] 的别名**（同一标识，不是新字段）。
  ///
  /// Scene `PerfWatchStore` 的 `session` 表主键即会话标识；GStore 沿用既有
  /// [id]，对外暴露 [sessionId] 以对齐 Scene 命名。JSON 仍只写 `id`。
  String get sessionId => id;

  /// 目标包名（本会话固定为系统屏幕口径时通常为 `null`）。
  final String? package;

  /// 展示名（会话标签）。
  final String label;

  /// 开始时刻（Unix ms）。
  final int startMs;

  /// 结束时刻（Unix ms）。
  final int endMs;

  /// 逐拍帧率样本（全部为有限非负值）。
  final List<double> samples;

  /// 末值帧率（最后一个有效样本；无样本为 `0`）。
  final double fps;

  /// 平均帧率（无样本为 `0`）。
  final double avg;

  /// 最小帧率（无样本为 `0`）。
  final double min;

  /// 最大帧率（无样本为 `0`）。
  final double max;

  /// 数据源（如 `'latency'` / `'timestats'`）；未知为 `null`。
  final String? source;

  /// 平均功耗（**GStore 等价定义**：`voltage_v × current_ma / 1000` 的均值，W；
  /// 无数据为 `0`）。Scene 侧物理单位 `unverified`（见 task-33 证据）。
  final double avgPower;

  /// 视图尺寸字符串（Scene `session.surface_view_size` 等价；
  /// **GStore 定义**：`MediaQuery.size` 逻辑像素，如 `'1080.0x2340.0'`；
  /// 未知为空串）。
  final String viewSize;

  /// 生效模式标签（**自由字符串**，如 `'均衡'`；**不依赖 `PerfMode` 枚举**，
  /// 未知为空串）。Scene 对应 `mode` / `power_mode`。
  final String mode;

  /// 逐拍电池温度样本（**GStore-only，非 Scene 字段**；单位 ℃）。
  ///
  /// Scene 仅在 `fps_history` 中记录单一 `temperature`；GStore 额外保留逐拍
  /// 温度序列以便计算高温占比（≥46℃）。允许负值（寒冷环境），仅过滤非有限值。
  final List<double> temperatures;

  /// 样本条数（= [samples] 长度）。
  int get frameCount => samples.length;

  /// 样本条数（与 [frameCount] 同义，便于 UI 语义化命名）。
  int get sampleCount => samples.length;

  /// 会话时长（ms）；[endMs] 早于 [startMs] 时为 `0`。
  int get durationMs => endMs > startMs ? endMs - startMs : 0;

  /// 序列化为 JSON 友好映射（键顺序固定）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'package': package,
        'label': label,
        'start_ms': startMs,
        'end_ms': endMs,
        'samples': samples,
        'fps': fps,
        'avg': avg,
        'min': min,
        'max': max,
        'source': source,
        'avg_power': avgPower,
        'view_size': viewSize,
        'mode': mode,
        'temperatures': temperatures,
      };

  /// 宽容反序列化：缺失 / 非法字段降级；统计量缺失时由样本重算。
  ///
  /// **向后兼容**：旧 JSON（无 `avg_power` / `view_size` / `mode` /
  /// `temperatures`）解码为安全默认（`0` / `''` / `''` / 空列表），绝不抛出。
  factory FpsSession.fromJson(Map<String, dynamic> json) {
    final samples = _doubleList(json['samples']);
    final stats = FpsStats.fromSamples(samples);
    return FpsSession(
      id: _string(json['id']) ?? _string(json['session_id']) ?? '',
      package: _string(json['package']),
      label: _string(json['label']) ?? '',
      startMs: _int(json['start_ms']) ?? 0,
      endMs: _int(json['end_ms']) ?? 0,
      samples: List<double>.unmodifiable(samples),
      fps: _finiteDouble(json['fps']) ?? stats.fps,
      avg: _finiteDouble(json['avg']) ?? stats.avg,
      min: _finiteDouble(json['min']) ?? stats.min,
      max: _finiteDouble(json['max']) ?? stats.max,
      source: _string(json['source']),
      avgPower: _finiteDouble(json['avg_power']) ?? 0,
      viewSize: _string(json['view_size']) ?? '',
      mode: _string(json['mode']) ?? '',
      temperatures: List<double>.unmodifiable(
        _finiteValues(json['temperatures']),
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FpsSession &&
      other.id == id &&
      other.package == package &&
      other.label == label &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.samples.length == samples.length &&
      other.fps == fps &&
      other.avg == avg &&
      other.min == min &&
      other.max == max &&
      other.source == source &&
      other.avgPower == avgPower &&
      other.viewSize == viewSize &&
      other.mode == mode &&
      other.temperatures.length == temperatures.length;

  @override
  int get hashCode => Object.hash(
        id,
        package,
        label,
        startMs,
        endMs,
        samples.length,
        fps,
        avg,
        min,
        max,
        source,
        avgPower,
        viewSize,
        mode,
        temperatures.length,
      );

  @override
  String toString() => 'FpsSession(id: $id, label: $label, '
      'startMs: $startMs, endMs: $endMs, samples: ${samples.length}, '
      'avg: $avg, min: $min, max: $max)';
}

// ==================== 纯函数：CSV / 时长 ====================

/// 把一次会话渲染为可分享的 CSV 文本（元信息块 + 样本块）。
///
/// 结构：先 `key,value` 元信息行（含汇总统计），空行分隔，再 `index,fps`
/// 逐样本行。纯函数，同一输入恒产出同一文本。
String buildFpsSessionCsv(FpsSession session) {
  final buffer = StringBuffer();
  void meta(String key, String value) =>
      buffer.writeln('${_csvField(key)},${_csvField(value)}');

  meta('key', 'value');
  meta('id', session.id);
  meta('package', session.package ?? '');
  meta('label', session.label);
  meta('start_ms', '${session.startMs}');
  meta('end_ms', '${session.endMs}');
  meta('duration_ms', '${session.durationMs}');
  meta('source', session.source ?? '');
  meta('sample_count', '${session.sampleCount}');
  meta('fps', _number(session.fps));
  meta('avg', _number(session.avg));
  meta('min', _number(session.min));
  meta('max', _number(session.max));
  buffer.writeln();
  buffer.writeln('${_csvField('index')},${_csvField('fps')}');
  for (var i = 0; i < session.samples.length; i++) {
    buffer.writeln('$i,${_number(session.samples[i])}');
  }
  return buffer.toString();
}

/// 时长（ms）→ 人类可读中文串（`0秒` / `45秒` / `1分23秒`）。
String formatFpsSessionDuration(int ms) {
  final totalSeconds = ms <= 0 ? 0 : (ms / 1000).round();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  if (minutes > 0) return '$minutes分$seconds秒';
  return '$seconds秒';
}

// ==================== 宽容解析辅助 ====================

String _number(double value) => value.isFinite ? value.toString() : '';

String? _string(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? _finiteDouble(Object? value) {
  final parsed = _double(value);
  if (parsed == null || !parsed.isFinite) return null;
  return parsed;
}

double? _double(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

/// 过滤掉非有限值（`NaN` / `±Infinity`），保留其余（含负温度）。
List<double> _finiteValues(Object? value) {
  if (value is! Iterable) return <double>[];
  final out = <double>[];
  for (final item in value) {
    final parsed = _double(item);
    if (parsed != null && parsed.isFinite) out.add(parsed);
  }
  return out;
}

List<double> _doubleList(Object? value) {
  if (value is! List) return <double>[];
  final out = <double>[];
  for (final item in value) {
    final parsed = _double(item);
    if (parsed != null && parsed.isFinite && parsed >= 0) out.add(parsed);
  }
  return out;
}

String _csvField(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

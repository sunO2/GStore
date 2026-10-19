/// FPS 会话录制器（纯 Dart，注入式 sampler / 时钟 / 存储）。
///
/// 职责：`start` 起开始按固定节拍（默认 1s）采样系统帧率并累积；`stop` 计算
/// 平均 / 最小 / 最大 / 末值并生成 [FpsSession] 落盘；`cancel` 丢弃当前会话。
///
/// ## 设计
/// * **可注入**：[FpsSampler]（返回 `null` 表示本拍无数据）、[FpsSessionStore]、
///   [RecorderClock]、采样间隔、最大时长**全部可注入**，故单元测试无需真机 /
///   Shizuku / 计时等待。
/// * **软失败**：sampler 抛异常 / 返回非有限值 / 负值一律**跳过**该拍（不中断），
///   落盘失败静默（仅日志）；绝不向调用方抛出。
/// * **幂等**：重复 `start` 不重置当前会话；未录制时 `stop` 返回 `null`、
///   `cancel` 无副作用。
/// * **自动停止**：达到 [maxDuration]（默认 30 分钟）时自动 `stop` 并落盘；传
///   `null` 关闭自动停止。
/// * **可观测**：[FpsSessionRecorder] 是 [ChangeNotifier]，`start` / `stop` /
///   每拍采样后通知监听者，UI 据此实时刷新时长 / 当前 FPS / 样本数。
library;

import 'dart:async';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, visibleForTesting;

import 'package:gstore/core/perf/fps_session.dart';
import 'package:gstore/core/perf/fps_session_store.dart';
import 'package:gstore/core/perf/system_fps_service.dart';

/// 采样器：返回本拍帧率；无数据返回 `null`。
typedef FpsSampler = Future<double?> Function();

/// 时钟（Unix 时间源）；测试注入以便起止时间 / 时长可复现。
typedef RecorderClock = DateTime Function();

/// 会话 id 工厂（默认由 [FpsSession.startMs] 派生）。
typedef FpsSessionIdFactory = String Function(int startMs);

/// 默认会话标签。
const String kFpsSessionDefaultLabel = '系统 FPS 会话';

/// 默认采样间隔（1 秒）。
const Duration kFpsSessionDefaultInterval = Duration(seconds: 1);

/// 默认最大录制时长（30 分钟，达到即自动停止并落盘）。
const Duration kFpsSessionDefaultMaxDuration = Duration(minutes: 30);

/// FPS 会话录制器。
class FpsSessionRecorder extends ChangeNotifier {
  FpsSessionRecorder({
    FpsSampler? sampler,
    required FpsSessionStore store,
    RecorderClock? clock,
    this.interval = kFpsSessionDefaultInterval,
    this.maxDuration = kFpsSessionDefaultMaxDuration,
    FpsSessionIdFactory? idFactory,
  })  : _sampler = sampler ?? _defaultSampler,
        _store = store,
        _clock = clock ?? DateTime.now,
        _idFactory = idFactory ?? _defaultIdFactory;

  /// 采样间隔（每拍触发一次 sampler）。
  final Duration interval;

  /// 最大录制时长；`null` 表示不自动停止。
  final Duration? maxDuration;

  final FpsSampler _sampler;
  final FpsSessionStore _store;
  final RecorderClock _clock;
  final FpsSessionIdFactory _idFactory;

  /// 默认采样器（生产）：`SystemFpsService().sample()?.fps`。
  static final SystemFpsService _service = SystemFpsService();

  static Future<double?> _defaultSampler() async {
    try {
      final sample = await _service.sample();
      return sample?.fps;
    } catch (error) {
      debugPrint('[FpsSessionRecorder] 默认采样失败（跳过）: $error');
      return null;
    }
  }

  static String _defaultIdFactory(int startMs) => 'fps_$startMs';

  bool _disposed = false;
  bool _recording = false;
  Timer? _timer;
  int _startMs = 0;
  String? _package;
  String _label = kFpsSessionDefaultLabel;
  String? _source;
  List<double> _samples = <double>[];
  double? _currentFps;

  /// 是否正在录制。
  bool get isRecording => _recording;

  /// 是否已释放（释放后所有操作 no-op）。
  bool get isDisposed => _disposed;

  /// 当前会话已录制时长；未录制时为 [Duration.zero]。
  Duration get elapsed {
    if (!_recording) return Duration.zero;
    final delta = _clock().millisecondsSinceEpoch - _startMs;
    return delta <= 0 ? Duration.zero : Duration(milliseconds: delta);
  }

  /// 最近一拍帧率；尚无有效样本时为 `null`。
  double? get currentFps => _currentFps;

  /// 已累积的有效样本数。
  int get sampleCount => _samples.length;

  /// 当前会话样本的只读副本。
  List<double> get samples => List<double>.unmodifiable(_samples);

  /// 当前会话标签。
  String get label => _label;

  /// 当前会话目标包名（未设置时为 `null`）。
  String? get package => _package;

  /// 开始录制（幂等：录制中调用为 no-op）。
  void start({
    String? package,
    String label = kFpsSessionDefaultLabel,
    String? source,
  }) {
    if (_disposed || _recording) return;
    _recording = true;
    _startMs = _clock().millisecondsSinceEpoch;
    _package = package;
    _label = label.isEmpty ? kFpsSessionDefaultLabel : label;
    _source = source;
    _samples = <double>[];
    _currentFps = null;
    _timer = Timer.periodic(interval, (_) => _onTick());
    notifyListeners();
  }

  /// 停止录制：计算统计、生成 [FpsSession] 并落盘，返回该会话。
  ///
  /// 未在录制时为 no-op，返回 `null`。
  Future<FpsSession?> stop() async {
    if (_disposed || !_recording) return null;
    _recording = false;
    _timer?.cancel();
    _timer = null;
    final endMs = _clock().millisecondsSinceEpoch;
    final session = FpsSession.fromRecording(
      id: _idFactory(_startMs),
      package: _package,
      label: _label,
      startMs: _startMs,
      endMs: endMs,
      samples: _samples,
      source: _source,
    );
    _samples = <double>[];
    _currentFps = null;
    try {
      await _store.append(session);
    } catch (error) {
      debugPrint('[FpsSessionRecorder] 落盘失败（忽略）: $error');
    }
    // 落盘后再通知：监听者刷新列表时新会话已可见，避免读写竞态。
    notifyListeners();
    return session;
  }

  /// 丢弃当前会话（不落盘）；未在录制时为 no-op。
  void cancel() {
    if (_disposed || !_recording) return;
    _recording = false;
    _timer?.cancel();
    _timer = null;
    _samples = <double>[];
    _currentFps = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  // ==================== 内部 ====================

  Future<void> _onTick() async {
    if (_disposed || !_recording) return;
    double? value;
    try {
      value = await _sampler();
    } catch (error) {
      debugPrint('[FpsSessionRecorder] 采样异常（跳过本拍）: $error');
      value = null;
    }
    if (_disposed || !_recording) return;
    if (value != null && value.isFinite && value >= 0) {
      _samples.add(value);
      _currentFps = value;
      notifyListeners();
    }
    _maybeAutoStop();
  }

  void _maybeAutoStop() {
    final max = maxDuration;
    if (max == null || _disposed || !_recording) return;
    if (elapsed >= max) {
      // 忽略返回值：auto-stop 与手动 stop 同路径（落盘 + 通知）。
      unawaited(stop());
    }
  }

  /// 仅测试用：暴露内部样本列表判空（避免外部误改）。
  @visibleForTesting
  bool get hasSamples => _samples.isNotEmpty;
}

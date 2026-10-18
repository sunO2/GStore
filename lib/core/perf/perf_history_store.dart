/// 性能滚动历史的跨会话持久化（`<appDocs>/perf_history.json`）。
///
/// 把性能页各指标的滚动序列（FPS / CPU% / 内存% / 温度 / 第三方 CPU / 内存 /
/// jank）写入单个 JSON 文件，下次打开页面时恢复，使图表显示跨会话数据。
///
/// 设计要点：
/// * **有界**：[kPerfHistoryStoreCapacity] 为各序列上限，保存与读取时都会裁剪最旧；
/// * **静默**：任何 I/O / 解析失败都只记日志并降级为空快照，绝不抛出；
/// * **可注入目录**：测试传入临时目录，无需平台通道。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

/// 各滚动序列的最大样本数（与页面 `kPerfHistoryCapacity` 保持一致）。
const int kPerfHistoryStoreCapacity = 90;

/// 目录提供者（默认 `getApplicationDocumentsDirectory`；测试注入临时目录）。
typedef PerfHistoryDirectoryProvider = Future<Directory> Function();

/// 一份可序列化的历史快照（全部列表有界、非负）。
class PerfHistorySnapshot {
  const PerfHistorySnapshot({
    this.fps = const <double>[],
    this.cpu = const <double>[],
    this.memory = const <double>[],
    this.thermal = const <double>[],
    this.thirdPartyCpu = const <double>[],
    this.thirdPartyMem = const <double>[],
    this.thirdPartyJank = const <double>[],
  });

  /// FPS 历史。
  final List<double> fps;

  /// CPU 总占用（%）历史。
  final List<double> cpu;

  /// 内存占用率（%）历史。
  final List<double> memory;

  /// 最高温度（°C）历史。
  final List<double> thermal;

  /// 第三方应用 CPU（%）历史。
  final List<double> thirdPartyCpu;

  /// 第三方应用内存（MB）历史。
  final List<double> thirdPartyMem;

  /// 第三方应用 jank（%）历史。
  final List<double> thirdPartyJank;

  /// 是否无任何数据。
  bool get isEmpty =>
      fps.isEmpty &&
      cpu.isEmpty &&
      memory.isEmpty &&
      thermal.isEmpty &&
      thirdPartyCpu.isEmpty &&
      thirdPartyMem.isEmpty &&
      thirdPartyJank.isEmpty;

  /// 序列化（全部为数值数组）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'fps': fps,
        'cpu': cpu,
        'memory': memory,
        'thermal': thermal,
        'third_party_cpu': thirdPartyCpu,
        'third_party_mem': thirdPartyMem,
        'third_party_jank': thirdPartyJank,
      };

  /// 宽容反序列化：缺失 / 非法字段一律降级为空列表。
  factory PerfHistorySnapshot.fromJson(Map<String, dynamic> json) =>
      PerfHistorySnapshot(
        fps: _doubleList(json['fps']),
        cpu: _doubleList(json['cpu']),
        memory: _doubleList(json['memory']),
        thermal: _doubleList(json['thermal']),
        thirdPartyCpu: _doubleList(json['third_party_cpu']),
        thirdPartyMem: _doubleList(json['third_party_mem']),
        thirdPartyJank: _doubleList(json['third_party_jank']),
      );
}

/// 滚动历史持久化存储。
class PerfHistoryStore {
  PerfHistoryStore({
    PerfHistoryDirectoryProvider? directoryProvider,
    int capacity = kPerfHistoryStoreCapacity,
  })  : _directoryProvider =
            directoryProvider ?? getApplicationDocumentsDirectory,
        _capacity = capacity;

  /// 历史文件名（位于 app documents 下）。
  static const String fileName = 'perf_history.json';

  final PerfHistoryDirectoryProvider _directoryProvider;
  final int _capacity;

  Future<File> _file() async {
    final base = await _directoryProvider();
    return File('${base.path}${Platform.pathSeparator}$fileName');
  }

  /// 保存快照（各序列裁剪到容量上限）；失败静默。
  Future<void> save(PerfHistorySnapshot snapshot) async {
    try {
      final file = await _file();
      final trimmed = PerfHistorySnapshot(
        fps: _trim(snapshot.fps),
        cpu: _trim(snapshot.cpu),
        memory: _trim(snapshot.memory),
        thermal: _trim(snapshot.thermal),
        thirdPartyCpu: _trim(snapshot.thirdPartyCpu),
        thirdPartyMem: _trim(snapshot.thirdPartyMem),
        thirdPartyJank: _trim(snapshot.thirdPartyJank),
      );
      await file.writeAsString(jsonEncode(trimmed.toJson()));
    } catch (error) {
      debugPrint('[PerfHistoryStore] 保存历史失败（忽略）: $error');
    }
  }

  /// 读取快照；文件缺失 / 损坏 / 读取失败返回空快照（绝不抛出）。
  Future<PerfHistorySnapshot> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const PerfHistorySnapshot();
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return const PerfHistorySnapshot();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const PerfHistorySnapshot();
      final snapshot = PerfHistorySnapshot.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
      return PerfHistorySnapshot(
        fps: _trim(snapshot.fps),
        cpu: _trim(snapshot.cpu),
        memory: _trim(snapshot.memory),
        thermal: _trim(snapshot.thermal),
        thirdPartyCpu: _trim(snapshot.thirdPartyCpu),
        thirdPartyMem: _trim(snapshot.thirdPartyMem),
        thirdPartyJank: _trim(snapshot.thirdPartyJank),
      );
    } catch (error) {
      debugPrint('[PerfHistoryStore] 读取历史失败（降级为空）: $error');
      return const PerfHistorySnapshot();
    }
  }

  List<double> _trim(List<double> values) {
    final clean = values.where((v) => v.isFinite).toList(growable: false);
    if (clean.length <= _capacity) return clean;
    return clean.sublist(clean.length - _capacity);
  }
}

List<double> _doubleList(Object? value) {
  if (value is! List) return const <double>[];
  final out = <double>[];
  for (final item in value) {
    if (item is num && item.isFinite) {
      out.add(item.toDouble());
    } else if (item is String) {
      final parsed = double.tryParse(item);
      if (parsed != null && parsed.isFinite) out.add(parsed);
    }
  }
  return out;
}

/// FPS 会话的**派生分析纯函数**（无 I/O / 无 Flutter / 无状态）。
///
/// 职责：由 [FpsSession] 的原始采样序列（帧率 / 温度 / 电压电流）派生 Scene
/// 对齐的**统计比率**与**平均功耗**，供 UI（`reports_page.dart` 列表 / 详情）
/// 与 CSV 导出复用。
///
/// 设计要点：
/// * **阈值来自共享常量**：流畅度口径与高温口径**不在此硬编码**，引用
///   `scene_thresholds.dart`（plan todo 23）的 [sceneFluencyFpsThreshold] 与
///   [sceneHighTempCThreshold]，避免与展示层色档各写一份而漂移。
/// * **纯函数**：同一输入恒产出同一结果；不读时钟、不落盘、不抛异常。
/// * **宽容 / 有界**：非有限值（`NaN` / `±Infinity`）一律**忽略**（既不计入
///   分子也不计入分母）；无有效样本时返回 `0`，**绝不产出 `NaN` / `Infinity`**。
library;

import 'package:gstore/core/perf/scene_thresholds.dart';

/// 流畅度占比：帧率 **≥ [sceneFluencyFpsThreshold]**（Scene `scripts.js:152`）
/// 的样本数占**有效样本数**的比例，取值 `[0, 1]`。
///
/// * [samples] 为逐拍帧率序列；非有限值被忽略（不计入分母）。
/// * 无有效样本 → `0`。负值（理论上非法）保留在分母中，因其 `< 阈值` 自然
///   不计入分子，无需额外过滤。
///
/// 例：`fpsFluencyRatio([60, 60, 30])` → `2/3`。
double fpsFluencyRatio(Iterable<double> samples) {
  var valid = 0;
  var fluent = 0;
  for (final fps in samples) {
    if (!fps.isFinite) continue;
    valid++;
    if (fps >= sceneFluencyFpsThreshold) fluent++;
  }
  return valid == 0 ? 0 : fluent / valid;
}

/// 高温占比：温度 **≥ [sceneHighTempCThreshold]**（Scene `scripts.js:163`）
/// 的样本数占**有效样本数**的比例，取值 `[0, 1]`。
///
/// * [temperatures] 为逐拍电池温度（℃）；非有限值被忽略（不计入分母）。
/// * 允许负值（寒冷环境），其为 `< 阈值` 自然不计入分子。
/// * 无有效样本 → `0`。
///
/// 例：`highTempRatio([41.5, 47.0, 47.2])` → `2/3`。
double highTempRatio(Iterable<double> temperatures) {
  var valid = 0;
  var hot = 0;
  for (final tempC in temperatures) {
    if (!tempC.isFinite) continue;
    valid++;
    if (tempC >= sceneHighTempCThreshold) hot++;
  }
  return valid == 0 ? 0 : hot / valid;
}

/// 平均功耗（W）：逐拍 `voltage_v × current_ma / 1000` 的**均值**。
///
/// **GStore 等价定义**（见 `FpsSession.avgPower` 文档 / task-33）：
/// 每拍功耗 `P[W] = V[V] × I[mA] / 1000`，会话功耗为其均值。Scene 侧物理单位
/// `unverified`（`fps_history` 用 `battery_io * voltage / 1000`）。
///
/// * [voltageV] / [currentMa] 为**逐拍对齐**的电压（V）与电流（mA）序列；
///   按**较短者**逐位配对（长度不等时忽略多余尾部）。
/// * 任一维为非有限值的**配对整对被忽略**（不计入均值）。
/// * 无有效配对 → `0`。电流负值（充电/放电符号）**保留**，因其为有效物理量。
///
/// 例：`avgPower([3.8, 4.0], [500, -500])` → `(3.8*500 + 4.0*-500)/1000/2`
/// = `(1900 - 2000)/1000/2` = `-0.05`。
double avgPower(Iterable<double> voltageV, Iterable<double> currentMa) {
  final voltages = voltageV.toList(growable: false);
  final currents = currentMa.toList(growable: false);
  final count = voltages.length < currents.length
      ? voltages.length
      : currents.length;
  var valid = 0;
  var sum = 0.0;
  for (var i = 0; i < count; i++) {
    final v = voltages[i];
    final iMa = currents[i];
    if (!v.isFinite || !iMa.isFinite) continue;
    sum += v * iMa / 1000;
    valid++;
  }
  return valid == 0 ? 0 : sum / valid;
}

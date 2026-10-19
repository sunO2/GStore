/// Scene 展示**色档 / 统计阈值**的集中常量（plan todo 23）。
///
/// 出处：`.omo/evidence/task-2-scene-reference.md` §4（每条阈值均有 Scene 4.7.3
/// `file:line` 引用）。本文件只承载 **Scene 颜色档位 / 统计口径** 语义，供性能
/// 仪表盘（`lib/page/home/tab/dashboard/view.dart`）等展示层复用。
///
/// ## 与告警阈值的区分（task-2 §4.5，**勿混**）
///
/// GStore 既有的 `lib/core/perf/perf_alert_settings.dart`
/// （cpu80 / temp45 / jank5 / minFps50）是「**越界告警**」语义（可配置、可关闭），
/// 与 Scene 这里的「**颜色档位**」语义**不同**。两者独立：本文件**不**引用、也
/// **不**替换告警默认值；告警阈值改动不得影响色档，反之亦然。
///
/// ## 颜色
///
/// Scene 色令牌（`colors.xml:21-25`：`color_load_none/low/mid/hight/veryhight` +
/// 内联 `#FF0F00`）**不在此硬编码**——GStore 遵守 AGENTS.md，展示层只把本文件的
/// *档位* 映射到主题角色（`ColorScheme.error` / `tertiary` / `primary`）。本文件
/// 为**纯 Dart**，不 import Flutter。
library;

// ==================== 统计比率阈值（task-2 §4.1） ====================

/// 流畅度口径：帧率** ≥ 该值** 视为流畅样本（Scene `scripts.js:152`，值 `45`）。
///
/// 注：Scene 脚本注释写「≥40」但代码取 45——以代码为准。
const double sceneFluencyFpsThreshold = 45;

/// 高温口径：温度** ≥ 该值** 视为高温样本（Scene `scripts.js:163`，值 `46`）。
const double sceneHighTempCThreshold = 46;

// ==================== CPU 负载色档阈值（task-2 §4.2） ====================

/// CPU 负载「很高」阈值：**严格大于** 该值 → 最高色档
/// （Scene `CpuChartView.kt:172` / `CpuChartBarView.kt:72`，值 `85`）。
const double sceneCpuVeryHighPercent = 85;

/// CPU 负载「高」阈值：**严格大于** 该值 → 次高色档
/// （Scene `CpuChartView.kt:174` / `CpuChartBarView.kt:74`，值 `65`）。
const double sceneCpuHighPercent = 65;

// ==================== RAM 使用率色档阈值（task-2 §4.2） ====================

/// RAM 使用率「很高」阈值：**严格大于** 该值 → 最高色档
/// （Scene `RamChartView.kt:158` / `ZRamStateView.kt:154`，值 `89`）。
const double sceneRamVeryHighPercent = 89;

/// RAM 使用率「高」阈值：**严格大于** 该值 → 次高色档
/// （Scene `RamChartView.kt:160` / `ZRamStateView.kt:156`，值 `80`）。
const double sceneRamHighPercent = 80;

// ==================== 电池温度色档阈值（task-2 §4.2） ====================

/// 电池温度「最高」阈值：**≥ 该值** → 最高色档
/// （Scene `BatteryView.kt:176` / `FloatMonitorBatteryView.kt:176`，值 `48`）。
const double sceneTempVeryHighC = 48;

/// 电池温度「很高」阈值：**严格大于** 该值 → 高色档
/// （Scene `BatteryView.kt:178` / `FloatMonitorBatteryView.kt:178`，值 `44`）。
const double sceneTempHighC = 44;

/// 电池温度「高」阈值：**严格大于** 该值 → 中间色档
/// （Scene `BatteryView.kt:180` / `FloatMonitorBatteryView.kt:180`，值 `41`）。
const double sceneTempMidC = 41;

// ==================== 档位解析（集中比较语义，展示层只做档位→主题色映射） ====================

/// CPU / RAM 负载色档（正常 / 高 / 很高）。
enum SceneLoadTier {
  /// 未越过任何阈值。
  normal,

  /// 越过「高」阈值（`> high`）。
  high,

  /// 越过「很高」阈值（`> veryHigh`）。
  veryHigh,
}

/// 电池温度色档（正常 / 中 / 高 / 最高）。
///
/// Scene 中「高」与「最高」映射到两个更强的颜色令牌；GStore 展示层将两者都映射到
/// [ColorScheme.error]（保留 Scene 的档位边界，颜色取主题语义角色）。
enum SceneTempTier {
  /// 未越过任何阈值（`≤ 41`）。
  normal,

  /// `> 41` 且 `≤ 44`。
  mid,

  /// `> 44` 且 `< 48`。
  high,

  /// `≥ 48`。
  veryHigh,
}

/// CPU 负载 → 色档：`> [sceneCpuVeryHighPercent]` → [SceneLoadTier.veryHigh]；
/// `> [sceneCpuHighPercent]` → [SceneLoadTier.high]；否则 [SceneLoadTier.normal]。
SceneLoadTier sceneCpuLoadTier(double percent) {
  if (percent > sceneCpuVeryHighPercent) return SceneLoadTier.veryHigh;
  if (percent > sceneCpuHighPercent) return SceneLoadTier.high;
  return SceneLoadTier.normal;
}

/// RAM 使用率 → 色档：`> [sceneRamVeryHighPercent]` → [SceneLoadTier.veryHigh]；
/// `> [sceneRamHighPercent]` → [SceneLoadTier.high]；否则 [SceneLoadTier.normal]。
SceneLoadTier sceneRamLoadTier(double percent) {
  if (percent > sceneRamVeryHighPercent) return SceneLoadTier.veryHigh;
  if (percent > sceneRamHighPercent) return SceneLoadTier.high;
  return SceneLoadTier.normal;
}

/// 电池温度 → 色档：`≥ [sceneTempVeryHighC]` → [SceneTempTier.veryHigh]；
/// `> [sceneTempHighC]` → [SceneTempTier.high]；`> [sceneTempMidC]` →
/// [SceneTempTier.mid]；否则 [SceneTempTier.normal]（保留 Scene 的 `≥` / `>` 边界）。
SceneTempTier sceneTempTier(double tempC) {
  if (tempC >= sceneTempVeryHighC) return SceneTempTier.veryHigh;
  if (tempC > sceneTempHighC) return SceneTempTier.high;
  if (tempC > sceneTempMidC) return SceneTempTier.mid;
  return SceneTempTier.normal;
}

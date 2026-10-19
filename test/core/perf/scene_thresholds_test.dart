import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/perf_alert_settings.dart';
import 'package:gstore/core/perf/scene_thresholds.dart';

/// Scene 展示色档 / 统计阈值集中常量的单元测试（plan todo 23）。
///
/// 覆盖：① 每个采用阈值的确切数值（对齐 task-2 §4）；② 档位比较语义与
/// `≥` / `>` 边界；③ 与 `PerfAlertSettings`（告警语义）**相互独立**。
void main() {
  group('Scene 统计比率阈值', () {
    test('FPS 流畅 45 / 高温 46', () {
      expect(sceneFluencyFpsThreshold, 45);
      expect(sceneHighTempCThreshold, 46);
    });
  });

  group('Scene CPU 负载色档', () {
    test('阈值 85 / 65', () {
      expect(sceneCpuVeryHighPercent, 85);
      expect(sceneCpuHighPercent, 65);
    });

    test('边界：> 85 veryHigh；> 65 high；否则 normal', () {
      expect(sceneCpuLoadTier(0), SceneLoadTier.normal);
      expect(sceneCpuLoadTier(65), SceneLoadTier.normal);
      expect(sceneCpuLoadTier(65.1), SceneLoadTier.high);
      expect(sceneCpuLoadTier(85), SceneLoadTier.high);
      expect(sceneCpuLoadTier(85.1), SceneLoadTier.veryHigh);
      expect(sceneCpuLoadTier(100), SceneLoadTier.veryHigh);
    });
  });

  group('Scene RAM 使用率色档', () {
    test('阈值 89 / 80', () {
      expect(sceneRamVeryHighPercent, 89);
      expect(sceneRamHighPercent, 80);
    });

    test('边界：> 89 veryHigh；> 80 high；否则 normal', () {
      expect(sceneRamLoadTier(0), SceneLoadTier.normal);
      expect(sceneRamLoadTier(80), SceneLoadTier.normal);
      expect(sceneRamLoadTier(80.1), SceneLoadTier.high);
      expect(sceneRamLoadTier(89), SceneLoadTier.high);
      expect(sceneRamLoadTier(89.1), SceneLoadTier.veryHigh);
      expect(sceneRamLoadTier(100), SceneLoadTier.veryHigh);
    });
  });

  group('Scene 电池温度色档', () {
    test('阈值 48 / 44 / 41', () {
      expect(sceneTempVeryHighC, 48);
      expect(sceneTempHighC, 44);
      expect(sceneTempMidC, 41);
    });

    test('边界：≥ 48 veryHigh；> 44 high；> 41 mid；否则 normal', () {
      expect(sceneTempTier(0), SceneTempTier.normal);
      expect(sceneTempTier(41), SceneTempTier.normal);
      expect(sceneTempTier(41.1), SceneTempTier.mid);
      expect(sceneTempTier(44), SceneTempTier.mid);
      expect(sceneTempTier(44.1), SceneTempTier.high);
      expect(sceneTempTier(47.9), SceneTempTier.high);
      expect(sceneTempTier(48), SceneTempTier.veryHigh);
      expect(sceneTempTier(60), SceneTempTier.veryHigh);
    });
  });

  group('与告警阈值相互独立（task-2 §4.5）', () {
    test('Scene 色档常量不等于 PerfAlertSettings 告警默认', () {
      const alert = PerfAlertSettings.defaults;
      // 色档 CPU 85 ≠ 告警 CPU 80。
      expect(sceneCpuVeryHighPercent, isNot(alert.cpuPercent));
      // 色档温度 48/44/41 ≠ 告警温度 45。
      expect(sceneTempVeryHighC, isNot(alert.temperatureC));
      expect(sceneTempHighC, isNot(alert.temperatureC));
      expect(sceneTempMidC, isNot(alert.temperatureC));
      // 色档 FPS 45 ≠ 告警 minFps 50。
      expect(sceneFluencyFpsThreshold, isNot(alert.minFps));
    });
  });
}

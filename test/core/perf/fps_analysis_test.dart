import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/fps_analysis.dart';
import 'package:gstore/core/perf/scene_thresholds.dart';

void main() {
  group('fpsFluencyRatio', () {
    test('canned samples：≥45 的占比', () {
      // 3 个 ≥45（45/60/45.5）+ 2 个 <45（30/44.9）→ 3/5。
      expect(
        fpsFluencyRatio(<double>[60, 30, 45, 44.9, 45.5]),
        closeTo(3 / 5, 1e-12),
      );
    });

    test('边界：恰好等于阈值算流畅', () {
      expect(fpsFluencyRatio(<double>[sceneFluencyFpsThreshold]), 1.0);
      expect(
        fpsFluencyRatio(<double>[sceneFluencyFpsThreshold - 0.1]),
        0.0,
      );
    });

    test('全流畅 → 1；全不流畅 → 0', () {
      expect(fpsFluencyRatio(<double>[60, 90, 120]), 1.0);
      expect(fpsFluencyRatio(<double>[10, 20, 30]), 0.0);
    });

    test('空输入 → 0，无 NaN/Inf', () {
      final ratio = fpsFluencyRatio(const <double>[]);
      expect(ratio, 0);
      expect(ratio.isFinite, isTrue);
    });

    test('NaN / ±Infinity 被忽略（不计入分母）', () {
      // 有效样本 [60, 30]：1 个 ≥45 → 0.5（非有限值不参与）。
      expect(
        fpsFluencyRatio(<double>[
          60,
          double.nan,
          30,
          double.infinity,
          double.negativeInfinity,
        ]),
        0.5,
      );
      // 仅非有限值 → 无有效样本 → 0。
      expect(
        fpsFluencyRatio(<double>[double.nan, double.infinity]),
        0,
      );
    });
  });

  group('highTempRatio', () {
    test('canned samples：≥46 的占比', () {
      // 2 个 ≥46（46/47.2）+ 3 个 <46（41.5/45.9/44）→ 2/5。
      expect(
        highTempRatio(<double>[41.5, 46, 47.2, 45.9, 44]),
        closeTo(2 / 5, 1e-12),
      );
    });

    test('边界：恰好等于阈值算高温', () {
      expect(highTempRatio(<double>[sceneHighTempCThreshold]), 1.0);
      expect(highTempRatio(<double>[sceneHighTempCThreshold - 0.1]), 0.0);
    });

    test('允许负温度（寒冷环境）且不计入高温', () {
      expect(highTempRatio(<double>[-10, 0, 47]), closeTo(1 / 3, 1e-12));
    });

    test('空输入 → 0，无 NaN/Inf', () {
      final ratio = highTempRatio(const <double>[]);
      expect(ratio, 0);
      expect(ratio.isFinite, isTrue);
    });

    test('NaN / ±Infinity 被忽略（不计入分母）', () {
      // 有效样本 [46, 40]：1 个 ≥46 → 0.5。
      expect(
        highTempRatio(<double>[
          46,
          double.nan,
          40,
          double.infinity,
        ]),
        0.5,
      );
      expect(
        highTempRatio(<double>[double.nan, double.negativeInfinity]),
        0,
      );
    });
  });

  group('avgPower', () {
    test('canned samples：voltage × current / 1000 的均值', () {
      // (3.8*500 + 4.0*1000)/1000 / 2 = (1900 + 4000)/1000/2 = 2.95。
      expect(
        avgPower(<double>[3.8, 4.0], <double>[500, 1000]),
        closeTo(2.95, 1e-12),
      );
    });

    test('电流负值（放电符号）保留', () {
      // (3.8*500 + 4.0*-500)/1000 / 2 = (1900 - 2000)/1000/2 = -0.05。
      expect(
        avgPower(<double>[3.8, 4.0], <double>[500, -500]),
        closeTo(-0.05, 1e-12),
      );
    });

    test('空输入 → 0，无 NaN/Inf', () {
      expect(avgPower(const <double>[], const <double>[]), 0);
      final zero = avgPower(const <double>[], const <double>[]);
      expect(zero.isFinite, isTrue);
    });

    test('长度不等：按较短者逐位配对（忽略多余尾部）', () {
      // 只配对前 2 对：(3.8*500 + 4.0*1000)/1000/2 = 2.95。
      expect(
        avgPower(<double>[3.8, 4.0, 9.9], <double>[500, 1000]),
        closeTo(2.95, 1e-12),
      );
      expect(
        avgPower(<double>[3.8], <double>[500, 1000, 7]),
        closeTo(1.9, 1e-12),
      );
    });

    test('任一分量为非有限值 → 整对被忽略', () {
      // 有效配对仅 (4.0, 2000)/(4.0, 4000) → (8000+16000)/1000/2 = 12。
      expect(
        avgPower(
          <double>[double.nan, 4.0, 4.0],
          <double>[100, 2000, 4000],
        ),
        closeTo(12, 1e-12),
      );
      expect(
        avgPower(
          <double>[3.8, 4.0],
          <double>[double.infinity, 1000],
        ),
        closeTo(4.0, 1e-12),
      );
    });

    test('仅非有限值 → 0，无 NaN/Inf', () {
      final value = avgPower(
        <double>[double.nan, double.infinity],
        <double>[double.nan, 1000],
      );
      expect(value, 0);
      expect(value.isFinite, isTrue);
    });
  });

  test('阈值引自共享常量（非本地硬编码）', () {
    expect(sceneFluencyFpsThreshold, 45);
    expect(sceneHighTempCThreshold, 46);
    // 用常量本身作为样本 → 恒为流畅 / 高温，证明函数引用的是共享阈值。
    expect(fpsFluencyRatio(<double>[sceneFluencyFpsThreshold]), 1.0);
    expect(highTempRatio(<double>[sceneHighTempCThreshold]), 1.0);
  });
}

/// todo 27 · per-SoC 模式常量表查表测试。
///
/// 覆盖：已知 SoC（lahaina/kona）逐值命中；未知 / 空 SoC → 安全回退；
/// 变体默认 conservative；回退表与 todo 24 的 [PerfModePreset.forMode] 逐值一致；
/// 常量表**只**含 shizuku-writable 旋钮形状（不出现 root-only 目标）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/perf_mode_profiles.dart';
import 'package:gstore/core/perf/perf_profile.dart';

void main() {
  const clusters = <String>['policy0', 'policy4', 'policy7'];

  PerfCpuClusterProfile cluster(
    PerfModePreset preset,
    String policy,
  ) =>
      preset.cpuClusters[policy]!;

  group('PerfVariant', () {
    test('默认变体 = conservative（安全）', () {
      expect(PerfVariant.defaultVariant, PerfVariant.conservative);
    });

    test('fromWire 宽容解析；未知 → conservative', () {
      expect(PerfVariant.fromWire('active'), PerfVariant.active);
      expect(PerfVariant.fromWire('CONSERVATIVE'), PerfVariant.conservative);
      expect(PerfVariant.fromWire('nope'), PerfVariant.conservative);
      expect(PerfVariant.fromWire(null), PerfVariant.conservative);
      expect(PerfVariant.fromWire(42), PerfVariant.conservative);
    });
  });

  group('安全回退（未知 SoC）', () {
    test('回退表与 forMode 逐值一致（防漂移）', () {
      for (final mode in PerfMode.values) {
        expect(
          kFallbackModeProfiles[mode],
          PerfModePreset.forMode(mode),
          reason: 'fallback[$mode] 必须等于 PerfModePreset.forMode($mode)',
        );
      }
    });

    test('未知 / 空 / null SoC → 回退表（每个模式，无抛异常）', () {
      for (final platform in <String?>[
        'unknown-soc',
        'lahaina-prime',
        '',
        '   ',
        null,
      ]) {
        final table = modeProfilesForPlatform(platform);
        expect(table, kFallbackModeProfiles);
        for (final mode in PerfMode.values) {
          expect(
            modePresetForPlatform(platform, mode),
            kFallbackModeProfiles[mode],
          );
        }
      }
    });

    test('未知 SoC 不返回任何 SoC 专属 CPU 频率（回退无 cpuClusters 频率）', () {
      final preset = modePresetForPlatform('mystery', PerfMode.fast);
      // 回退 fast = cpuset top-app，无 SoC 专属 CPU/GPU。
      expect(preset, PerfModePreset.forMode(PerfMode.fast));
      expect(preset.gpuLevel, isNull);
      expect(preset.cpuClusters, isEmpty);
    });
  });

  group('已知 SoC · 参考表命中', () {
    test('lahaina + conservative balance 逐值', () {
      final preset = modePresetForPlatform('lahaina', PerfMode.balance);
      expect(preset.gpuLevel, 0);
      expect(preset.thermalEnabled, isTrue);
      expect(preset.cpuset, isNull); // GStore 默认 balance 不移动 cpuset
      expect(
        cluster(preset, 'policy0'),
        const PerfCpuClusterProfile(
          governor: 'schedutil',
          minFreqMhz: 300,
          maxFreqMhz: 1804.8,
        ),
      );
      expect(
        cluster(preset, 'policy4'),
        const PerfCpuClusterProfile(
          governor: 'schedutil',
          minFreqMhz: 710.4,
          maxFreqMhz: 1881.6,
        ),
      );
      expect(
        cluster(preset, 'policy7'),
        const PerfCpuClusterProfile(
          governor: 'schedutil',
          minFreqMhz: 844.8,
          maxFreqMhz: 2035.2,
        ),
      );
    });

    test('lahaina + active fast 逐值（含 gpu_pl_up 2 / top-app）', () {
      final preset = modePresetForPlatform(
        'lahaina',
        PerfMode.fast,
        variant: PerfVariant.active,
      );
      expect(preset.gpuLevel, 2);
      expect(preset.cpuset, 'top-app');
      expect(
        cluster(preset, 'policy4'),
        const PerfCpuClusterProfile(
          governor: 'schedutil',
          minFreqMhz: 1766.4,
          maxFreqMhz: 2600,
        ),
      );
      expect(
        cluster(preset, 'policy7'),
        const PerfCpuClusterProfile(
          governor: 'schedutil',
          minFreqMhz: 1670.4,
          maxFreqMhz: 3200,
        ),
      );
    });

    test('kona + conservative fast 逐值（低 min freq）', () {
      final preset = modePresetForPlatform('kona', PerfMode.fast);
      expect(
        cluster(preset, 'policy0'),
        const PerfCpuClusterProfile(
          governor: 'schedutil',
          minFreqMhz: 1248,
          maxFreqMhz: 1804.8,
        ),
      );
      expect(
        cluster(preset, 'policy4'),
        const PerfCpuClusterProfile(
          governor: 'schedutil',
          minFreqMhz: 1478.4,
          maxFreqMhz: 2600,
        ),
      );
    });

    test('kona + active performance gpu_pl_up=1（相对 conservative 0）', () {
      final active = modePresetForPlatform(
        'kona',
        PerfMode.performance,
        variant: PerfVariant.active,
      );
      final conservative =
          modePresetForPlatform('kona', PerfMode.performance);
      expect(active.gpuLevel, 1);
      expect(conservative.gpuLevel, 0);
    });

    test('默认变体 = conservative：lahaina balance 默认即 conservative 表', () {
      expect(
        modePresetForPlatform('lahaina', PerfMode.balance),
        kLahainaConservativeModeProfiles[PerfMode.balance],
      );
      expect(
        modePresetForPlatform('lahaina', PerfMode.balance),
        isNot(kLahainaActiveModeProfiles[PerfMode.balance]),
      );
    });

    test('active 与 conservative 的 balance 最大频率不同（变体确有差异）', () {
      final active = kLahainaActiveModeProfiles[PerfMode.balance]!;
      final conservative =
          kLahainaConservativeModeProfiles[PerfMode.balance]!;
      expect(
        cluster(active, 'policy4').maxFreqMhz,
        isNot(cluster(conservative, 'policy4').maxFreqMhz),
      );
    });

    test('kSceneSocPlatforms 仅含已编码平台', () {
      expect(kSceneSocPlatforms, containsAll(<String>['lahaina', 'kona']));
      expect(kSocModeProfiles.keys, kSceneSocPlatforms);
    });

    test('大小写 / 空白不命中参考表（ro.board.platform 原样小写）→ 回退', () {
      expect(
        modeProfilesForPlatform('LAHAINA'),
        kFallbackModeProfiles,
      );
      expect(
        modeProfilesForPlatform(' lahaina '),
        isNotNull, // trim 后命中
      );
      expect(
        modeProfilesForPlatform(' lahaina '),
        kLahainaConservativeModeProfiles,
      );
    });
  });

  group('常量表仅含 shizuku-writable 旋钮形状', () {
    test('每张参考表的每模式都只使用受支持的旋钮形状', () {
      for (final entry in kSocModeProfiles.entries) {
        for (final variantEntry in entry.value.entries) {
          for (final modeEntry in variantEntry.value.entries) {
            final preset = modeEntry.value;
            // CPU：仅在 policy0/4/7 上设置 schedutil + 正有限频率。
            preset.cpuClusters.forEach((policy, c) {
              expect(clusters, contains(policy));
              expect(c.governor, kSceneCpuGovernor);
              for (final f in <double?>[c.minFreqMhz, c.maxFreqMhz]) {
                expect(f, isNotNull);
                expect(f!.isFinite && f > 0, isTrue);
              }
              expect(
                c.minFreqMhz! <= c.maxFreqMhz!,
                isTrue,
                reason: '${entry.key}/${variantEntry.key}/${modeEntry.key}'
                    ' $policy min<=max',
              );
            });
            // GPU：Scene gpu_pl_up 偏移（0..2）。
            final g = preset.gpuLevel;
            expect(g == null || (g >= 0 && g <= 2), isTrue);
            // cpuset：仅允许通用 cpuset 名。
            final cs = preset.cpuset;
            expect(
              cs == null || const <String>['background', 'foreground', 'top-app']
                  .contains(cs),
              isTrue,
            );
            // thermal：常量表只编码安全方向（true），绝不编码 root-only 关温控。
            expect(preset.thermalEnabled, isTrue);
          }
        }
      }
    });

    test('无 root-only 目标字符串出现在任何预设值里（governor 仅 schedutil）', () {
      for (final entry in kSocModeProfiles.entries) {
        for (final variantEntry in entry.value.entries) {
          for (final preset in variantEntry.value.values) {
            for (final c in preset.cpuClusters.values) {
              // root-only governor 旋钮（conservative/schedutil sub-tree）不出现。
              expect(c.governor, 'schedutil');
            }
          }
        }
      }
    });
  });
}

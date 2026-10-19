import 'package:flutter_test/flutter_test.dart';

import 'package:gstore/core/perf/perf_profile.dart';

void main() {
  group('PerfCpuClusterProfile', () {
    test('toJson/fromJson 往返', () {
      const cluster = PerfCpuClusterProfile(
        governor: 'schedutil',
        minFreqMhz: 300,
        maxFreqMhz: 2000,
      );
      final json = cluster.toJson();
      expect(json, <String, dynamic>{
        'governor': 'schedutil',
        'min_freq_mhz': 300.0,
        'max_freq_mhz': 2000.0,
      });
      expect(PerfCpuClusterProfile.fromJson(json), cluster);
      expect(cluster.isEmpty, isFalse);
    });

    test('null 字段省略 + fromJson 缺字段 → null（不抛）', () {
      const cluster = PerfCpuClusterProfile();
      expect(cluster.toJson(), isEmpty);
      expect(cluster.isEmpty, isTrue);
      final decoded = PerfCpuClusterProfile.fromJson(<String, dynamic>{});
      expect(decoded.governor, isNull);
      expect(decoded.minFreqMhz, isNull);
      expect(decoded.maxFreqMhz, isNull);
    });

    test('类型不符 → 安全 null（不抛）', () {
      final decoded = PerfCpuClusterProfile.fromJson(<String, dynamic>{
        'governor': 42,
        'min_freq_mhz': 'abc',
        'max_freq_mhz': true,
      });
      expect(decoded, const PerfCpuClusterProfile());
    });

    test('非有限频率（NaN / Infinity）→ null', () {
      final decoded = PerfCpuClusterProfile.fromJson(<String, dynamic>{
        'min_freq_mhz': double.nan,
        'max_freq_mhz': 'Infinity',
      });
      expect(decoded.minFreqMhz, isNull);
      expect(decoded.maxFreqMhz, isNull);
    });
  });

  group('PerfProfile', () {
    test('完整档案 toJson/fromJson 往返且相等', () {
      const profile = PerfProfile(
        package: 'com.example.app',
        enabled: true,
        cpuClusters: <String, PerfCpuClusterProfile>{
          'policy0': PerfCpuClusterProfile(governor: 'schedutil'),
          'policy4': PerfCpuClusterProfile(minFreqMhz: 400, maxFreqMhz: 2400),
        },
        gpuLevel: 2,
        cpuset: 'top-app',
        thermalEnabled: false,
      );
      final json = profile.toJson();
      expect(json['package'], 'com.example.app');
      expect(json['enabled'], isTrue);
      expect(json['gpu_level'], 2);
      expect(json['cpuset'], 'top-app');
      expect(json['thermal_enabled'], isFalse);
      expect((json['cpu_clusters'] as Map).length, 2);
      expect(PerfProfile.fromJson(json), profile);
      expect(json, equals(profile.toJson()));
    });

    test('缺字段 → 安全默认（空包 / 未启用 / 空簇 / null）', () {
      final decoded =
          PerfProfile.fromJson(<String, dynamic>{'package': 'com.a'});
      expect(decoded.package, 'com.a');
      expect(decoded.enabled, isFalse);
      expect(decoded.cpuClusters, isEmpty);
      expect(decoded.gpuLevel, isNull);
      expect(decoded.cpuset, isNull);
      expect(decoded.thermalEnabled, isNull);
    });

    test('类型全错 → 安全默认（不抛）', () {
      final decoded = PerfProfile.fromJson(<String, dynamic>{
        'package': 123,
        'enabled': 'yes',
        'cpu_clusters': 'not-a-map',
        'gpu_level': 'high',
        'cpuset': <int>[1, 2],
        'thermal_enabled': 'maybe',
      });
      expect(decoded.package, '');
      expect(decoded.enabled, isFalse);
      expect(decoded.cpuClusters, isEmpty);
      expect(decoded.gpuLevel, isNull);
      expect(decoded.cpuset, isNull);
      expect(decoded.thermalEnabled, isNull);
    });

    test('部分损坏的簇被跳过，其余保留', () {
      final decoded = PerfProfile.fromJson(<String, dynamic>{
        'package': 'com.a',
        'cpu_clusters': <String, dynamic>{
          'policy0': <String, dynamic>{'governor': 'performance'},
          'bad': 'not-a-map',
        },
      });
      expect(decoded.cpuClusters.keys, <String>['policy0']);
      expect(decoded.cpuClusters['policy0']!.governor, 'performance');
    });

    test('字符串 "NaN" 频率 → null', () {
      final decoded = PerfProfile.fromJson(<String, dynamic>{
        'package': 'com.a',
        'cpu_clusters': <String, dynamic>{
          'policy0': <String, dynamic>{'min_freq_mhz': 'NaN'},
        },
      });
      expect(decoded.cpuClusters['policy0']!.minFreqMhz, isNull);
    });

    test('copyWith 覆盖与清空 cpuset', () {
      const base = PerfProfile(package: 'com.a', cpuset: 'top-app');
      expect(base.copyWith(enabled: true).enabled, isTrue);
      expect(base.copyWith(package: 'com.b').package, 'com.b');
      expect(base.copyWith(cpusetClear: true).cpuset, isNull);
      expect(base.copyWith(cpuset: 'bg').cpuset, 'bg');
    });

    test('相等与 hashCode', () {
      const a = PerfProfile(
        package: 'com.a',
        cpuClusters: <String, PerfCpuClusterProfile>{
          'policy0': PerfCpuClusterProfile(governor: 'schedutil'),
        },
      );
      const b = PerfProfile(
        package: 'com.a',
        cpuClusters: <String, PerfCpuClusterProfile>{
          'policy0': PerfCpuClusterProfile(governor: 'schedutil'),
        },
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const PerfProfile(package: 'com.a'), isFalse);
    });

    test('empty 常量语义', () {
      expect(PerfProfile.empty.isEmpty, isTrue);
      expect(PerfProfile.empty.package, '');
      expect(PerfProfile.empty.mode, PerfMode.balance);
    });
  });

  group('PerfMode', () {
    test('四档线格式名 + 中文标签', () {
      expect(PerfMode.powersave.wireName, 'powersave');
      expect(PerfMode.balance.wireName, 'balance');
      expect(PerfMode.performance.wireName, 'performance');
      expect(PerfMode.fast.wireName, 'fast');
      expect(PerfMode.powersave.label, '省电');
      expect(PerfMode.balance.label, '均衡');
      expect(PerfMode.performance.label, '性能');
      expect(PerfMode.fast.label, '极速');
      expect(PerfMode.defaultMode, PerfMode.balance);
    });

    test('fromWire：线格式名 / 大小写 / 中文标签 / 序号', () {
      expect(PerfMode.fromWire('performance'), PerfMode.performance);
      expect(PerfMode.fromWire(' FAST '), PerfMode.fast);
      expect(PerfMode.fromWire('极速'), PerfMode.fast);
      expect(PerfMode.fromWire('省电'), PerfMode.powersave);
      expect(PerfMode.fromWire(2), PerfMode.performance);
      expect(PerfMode.fromWire(0), PerfMode.powersave);
    });

    test('fromWire：未知 / 缺失 / 越界 → 默认 balance（不抛）', () {
      expect(PerfMode.fromWire(null), PerfMode.balance);
      expect(PerfMode.fromWire(''), PerfMode.balance);
      expect(PerfMode.fromWire('bogus'), PerfMode.balance);
      expect(PerfMode.fromWire(42), PerfMode.balance);
      expect(PerfMode.fromWire(-1), PerfMode.balance);
      expect(PerfMode.fromWire(<int>[1]), PerfMode.balance);
    });
  });

  group('PerfModePreset', () {
    test('forMode 映射到既有旋钮形状（无新增旋钮）', () {
      expect(PerfModePreset.forMode(PerfMode.balance).isEmpty, isTrue);
      expect(
        PerfModePreset.forMode(PerfMode.powersave).cpuset,
        'background',
      );
      expect(
        PerfModePreset.forMode(PerfMode.powersave).thermalEnabled,
        isTrue,
      );
      expect(
        PerfModePreset.forMode(PerfMode.performance).cpuset,
        'foreground',
      );
      expect(PerfModePreset.forMode(PerfMode.fast).cpuset, 'top-app');
      // 预设不携带身份 / 启用 / mode 字段（只描述旋钮）。
      expect(PerfModePreset.empty.isEmpty, isTrue);
    });

    test('完整预设 toJson/fromJson 往返且相等', () {
      const preset = PerfModePreset(
        cpuClusters: <String, PerfCpuClusterProfile>{
          'policy0': PerfCpuClusterProfile(
            governor: 'performance',
            minFreqMhz: 1000,
            maxFreqMhz: 2400,
          ),
        },
        gpuLevel: 1,
        cpuset: 'top-app',
        thermalEnabled: false,
      );
      final json = preset.toJson();
      expect((json['cpu_clusters'] as Map).length, 1);
      expect(json['gpu_level'], 1);
      expect(json['cpuset'], 'top-app');
      expect(json['thermal_enabled'], isFalse);
      expect(PerfModePreset.fromJson(json), preset);
    });

    test('类型全错 → 安全默认（不抛）', () {
      final decoded = PerfModePreset.fromJson(<String, dynamic>{
        'cpu_clusters': 'not-a-map',
        'gpu_level': 'high',
        'cpuset': <int>[1],
        'thermal_enabled': 'maybe',
      });
      expect(decoded.isEmpty, isTrue);
    });

    test('部分损坏的簇被跳过，其余保留', () {
      final decoded = PerfModePreset.fromJson(<String, dynamic>{
        'cpu_clusters': <String, dynamic>{
          'policy0': <String, dynamic>{'governor': 'schedutil'},
          'bad': 'not-a-map',
        },
      });
      expect(decoded.cpuClusters.keys, <String>['policy0']);
    });

    test('相等与 hashCode', () {
      const a = PerfModePreset(cpuset: 'top-app', gpuLevel: 2);
      const b = PerfModePreset(cpuset: 'top-app', gpuLevel: 2);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == const PerfModePreset(cpuset: 'top-app'), isFalse);
    });
  });

  group('PerfProfile.mode', () {
    test('默认 mode = balance，且 JSON 写出 mode', () {
      const profile = PerfProfile(package: 'com.a');
      expect(profile.mode, PerfMode.balance);
      expect(profile.toJson()['mode'], 'balance');
    });

    test('mode 往返（fast）', () {
      const profile = PerfProfile(
        package: 'com.a',
        enabled: true,
        mode: PerfMode.fast,
      );
      final json = profile.toJson();
      expect(json['mode'], 'fast');
      expect(PerfProfile.fromJson(json), profile);
      expect(PerfProfile.fromJson(json).mode, PerfMode.fast);
    });

    test('旧档案缺 mode → 默认 balance（不抛，向后兼容）', () {
      final decoded = PerfProfile.fromJson(<String, dynamic>{
        'package': 'com.legacy',
        'enabled': true,
        'cpuset': 'top-app',
      });
      expect(decoded.mode, PerfMode.balance);
      expect(decoded.cpuset, 'top-app');
      expect(decoded.enabled, isTrue);
    });

    test('非法 mode 值 → 默认 balance（不抛）', () {
      final decoded = PerfProfile.fromJson(<String, dynamic>{
        'package': 'com.a',
        'mode': 'turbo-ultra',
      });
      expect(decoded.mode, PerfMode.balance);
    });

    test('仅 mode 变化 → 视为已变更（!=，hashCode 变化）', () {
      const balance = PerfProfile(
        package: 'com.a',
        enabled: true,
        cpuset: 'top-app',
      );
      const fast = PerfProfile(
        package: 'com.a',
        enabled: true,
        cpuset: 'top-app',
        mode: PerfMode.fast,
      );
      expect(balance == fast, isFalse);
      expect(balance.hashCode == fast.hashCode, isFalse);
    });

    test('copyWith 覆盖 mode', () {
      const base = PerfProfile(package: 'com.a');
      expect(base.copyWith(mode: PerfMode.performance).mode,
          PerfMode.performance);
      expect(base.copyWith().mode, PerfMode.balance);
    });

    test('mode-only 档案非空（mode 参与 isEmpty 判定）', () {
      const modeOnly = PerfProfile(package: 'com.a', mode: PerfMode.fast);
      expect(modeOnly.isEmpty, isFalse);
    });
  });
}

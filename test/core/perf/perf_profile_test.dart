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
    });
  });
}

// Todo 13 单元测试：弱网模拟预设表 + Schema 校验 + 自定义构造器 + 门面接缝。
//
// 全部密闭式：预设表是纯数据/纯函数；门面测试用手的 fake gateway 注入
// [ProxyModule]，不触碰 FFI / 原生模块 / 平台通道。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';
import 'package:gstore/core/rust/proxy/ProxyModule.dart';
import 'package:gstore/page/proxy/proxy_settings_facade.dart';
import 'package:gstore/page/proxy/proxy_shaper_presets.dart';

// ==================== 假网关 ====================

/// 记录方法名与请求载荷的假网关；响应由构造时给定。
class _RecordingGateway implements ProxyModuleGateway {
  _RecordingGateway(this.responses);

  final Map<String, Uint8List> responses;
  final List<String> methods = <String>[];
  final List<Uint8List?> payloads = <Uint8List?>[];

  @override
  Future<Uint8List> call(String method, [Uint8List? payload]) async {
    methods.add(method);
    payloads.add(payload);
    final response = responses[method];
    if (response == null) {
      throw StateError('no stub for $method');
    }
    return response;
  }

  @override
  Stream<ProxyRawEvent> get events => const Stream<ProxyRawEvent>.empty();
}

Uint8List _okEnvelope(Map<String, dynamic> data) => Uint8List.fromList(
      utf8.encode(jsonEncode(<String, dynamic>{'ok': true, 'data': data})),
    );

/// `net.shaper.get` / `net.shaper.set` 共用的冻结快照 fixture（3G 档）。
const Map<String, dynamic> _directionFixture = <String, dynamic>{
  'rateBps': 400000,
  'burstBytes': 32768,
  'delayMs': 400,
  'jitterMs': 50,
  'jitterDistribution': 'normal',
  'lossPct': 0,
  'lossModel': 'none',
  'lossGoodToBadPct': 0,
  'lossBadToGoodPct': 0,
  'duplicatePct': 0,
  'reorderPct': 0,
  'reorderGap': 0,
  'order': 'preserve',
};

const Map<String, dynamic> _shaperSnapshotFixture = <String, dynamic>{
  'config': <String, dynamic>{
    'enabled': true,
    'seed': null,
    'uplink': _directionFixture,
    'downlink': _directionFixture,
  },
  'effective': <String, dynamic>{
    'enabled': true,
    'seed': null,
    'uplink': _directionFixture,
    'downlink': _directionFixture,
  },
  'applied': true,
  'engineRunning': true,
  'counters': <String, dynamic>{
    'upFramesShaped': 1,
    'downFramesShaped': 2,
    'upBytesShaped': 3,
    'downBytesShaped': 4,
    'lossDropped': 5,
    'bufferDropped': 6,
    'duplicated': 7,
    'reordered': 8,
    'bufferedFrames': 9,
    'bufferedBytes': 10,
    'maxBufferedFrames': 11,
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('预设表', () {
    test('shaper_presets_map_to_valid_config', () {
      // 顺序固定：2G → 3G → 4G → 5G → 弱网 → 自定义。
      expect(
        proxyShaperPresets.map((p) => p.id).toList(),
        <String>[
          ProxyShaperPresetIds.g2,
          ProxyShaperPresetIds.g3,
          ProxyShaperPresetIds.g4,
          ProxyShaperPresetIds.g5,
          ProxyShaperPresetIds.weak,
          ProxyShaperPresetIds.custom,
        ],
      );
      expect(proxyShaperPresets.last.isCustom, isTrue);

      for (final preset in proxyShaperPresets) {
        expect(
          isValidShaperConfig(preset.config),
          isTrue,
          reason: '${preset.id} 必须满足 Schema',
        );
        for (final d in <ProxyShaperDirection>[
          preset.config.uplink,
          preset.config.downlink,
        ]) {
          expect(
            d.rateBps == 0 ||
                (d.rateBps >= 1000 && d.rateBps <= 1000000000),
            isTrue,
            reason: '${preset.id} rateBps',
          );
          expect(d.burstBytes, inInclusiveRange(1500, 65535));
          expect(d.delayMs, inInclusiveRange(0, 60000));
          expect(d.jitterMs, inInclusiveRange(0, 30000));
          expect(d.reorderGap, inInclusiveRange(0, 255));
          for (final pct in <double>[
            d.lossPct,
            d.lossGoodToBadPct,
            d.lossBadToGoodPct,
            d.duplicatePct,
            d.reorderPct,
          ]) {
            expect(pct, inInclusiveRange(0, 100));
          }
          expect(
            !(d.order == 'reorder' && d.reorderPct > 0 && d.rateBps == 0),
            isTrue,
            reason: '${preset.id} 跨字段规则',
          );
        }
      }

      // 已知档位确实携带非默认限速。
      expect(presetById(ProxyShaperPresetIds.g3)!.config.uplink.rateBps, 400000);
      expect(
        presetOrCustomById(ProxyShaperPresetIds.weak).config.uplink.lossPct,
        greaterThan(0),
      );
    });

    test('unknown_preset_falls_back_without_throwing', () {
      expect(presetById('nope'), isNull);
      expect(() => presetById('nope'), returnsNormally);

      final fallback = presetOrCustomById('nope');
      expect(fallback.id, ProxyShaperPresetIds.custom);
      expect(fallback.config.enabled, isFalse);

      // 未知 / 部分匹配的已加载配置 → 自定义（不改写、不抛错）。
      expect(presetForConfig(const ProxyShaperConfig()).id,
          ProxyShaperPresetIds.custom);
      const partial = ProxyShaperConfig(
        enabled: true,
        uplink: ProxyShaperDirection(rateBps: 7777, delayMs: 33),
      );
      expect(presetForConfig(partial).id, ProxyShaperPresetIds.custom);

      // 匹配已知档位时返回其 id（忽略 enabled）。
      final g4 = presetById(ProxyShaperPresetIds.g4)!.config;
      expect(presetForConfig(g4.copyWith(enabled: false)).id,
          ProxyShaperPresetIds.g4);
    });
  });

  group('自定义构造器', () {
    test('invalid_custom_is_rejected_without_set', () async {
      final gateway = _RecordingGateway(<String, Uint8List>{
        ProxyMethods.netShaperSet: _okEnvelope(_shaperSnapshotFixture),
      });
      final facade = ProxyModuleSettingsFacade(
        module: ProxyModule(gateway: gateway),
      );

      // 每个越界输入都必须得到 null。
      final rejected = <ProxyShaperDirection?>[
        buildCustomShaperDirection(rateBps: 999),
        buildCustomShaperDirection(delayMs: 60001),
        buildCustomShaperDirection(jitterMs: 30001),
        buildCustomShaperDirection(lossPct: 101),
        buildCustomShaperDirection(burstBytes: 100),
        buildCustomShaperDirection(reorderGap: 256),
        buildCustomShaperDirection(
          order: 'reorder',
          reorderPct: 10,
          rateBps: 0,
        ),
        buildCustomShaperDirection(order: 'nope'),
        buildCustomShaperDirection(lossModel: 'bogus'),
      ];
      for (final d in rejected) {
        expect(d, isNull);
      }

      // 调用方约定：仅当构造器返回非空才下发。此处全部为空 → 零 RPC。
      for (final d in rejected) {
        if (d == null) continue;
        final config = buildCustomShaperConfig(uplink: d, downlink: d);
        if (config == null) continue;
        await facade.saveShaperConfig(config);
      }
      expect(gateway.methods, isNot(contains(ProxyMethods.netShaperSet)));
      expect(gateway.methods, isEmpty);

      // 合法输入可构造出有效配置。
      final ok = buildCustomShaperDirection(
        rateBps: 200000,
        delayMs: 100,
        jitterMs: 20,
        lossPct: 1,
        lossModel: 'random',
      );
      expect(ok, isNotNull);
      final cfg = buildCustomShaperConfig(uplink: ok!, downlink: ok);
      expect(cfg, isNotNull);
      expect(isValidShaperConfig(cfg!), isTrue);
    });
  });

  group('门面接缝', () {
    test('load decodes fixture snapshot and save issues net.shaper.set', () async {
      final gateway = _RecordingGateway(<String, Uint8List>{
        ProxyMethods.netShaperGet: _okEnvelope(_shaperSnapshotFixture),
        ProxyMethods.netShaperSet: _okEnvelope(_shaperSnapshotFixture),
      });
      final facade = ProxyModuleSettingsFacade(
        module: ProxyModule(gateway: gateway),
      );

      // load：解码 fixture → 类型化快照。
      final loaded = await facade.loadShaperConfig();
      expect(gateway.methods, <String>[ProxyMethods.netShaperGet]);
      expect(loaded.config.enabled, isTrue);
      expect(loaded.config.uplink.rateBps, 400000);
      expect(loaded.applied, isTrue);
      expect(loaded.counters.bufferedBytes, 10);

      // save：下发预设，校验请求体 == toRequestJson()。
      final preset = presetById(ProxyShaperPresetIds.g3)!;
      final saved = await facade.saveShaperConfig(preset.config);
      expect(gateway.methods, <String>[
        ProxyMethods.netShaperGet,
        ProxyMethods.netShaperSet,
      ]);
      expect(saved.config.uplink.rateBps, 400000);

      final sent =
          jsonDecode(utf8.decode(gateway.payloads.last!)) as Map<String, dynamic>;
      expect(sent, preset.config.toRequestJson());
    });
  });
}

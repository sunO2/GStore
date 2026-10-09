/// 弱网模拟（`net.shaper.*`）预设表 + Schema 校验 + 自定义构造器。
///
/// **纯数据 / 纯函数**：不含任何 UI、平台通道或模块调用；只把「人类可读的网络
/// 档位」翻译成冻结契约里的 [ProxyShaperConfig]。UI（Todo 14）负责选择与下发。
///
/// 数值来源：
/// * Chrome DevTools 节流预设（Slow 3G ≈ 400 kbps / 400 ms；Fast 3G ≈ 1.6 Mbps /
///   150 ms）；
/// * Android emulator 网络档位（GPRS/EDGE/UMTS/HSPA/LTE 量级）；
/// * 3GPP 类别（2G ≈ 数十–数百 kbps；3G ≈ 384 kbps–2 Mbps；4G ≈ 5–100 Mbps；
///   5G ≈ 100 Mbps–1 Gbps）。
///
/// 所有档位都必须满足 Rust `shaper.rs` 的 Schema（见 [isValidShaperDirection]）；
/// [buildCustomShaperDirection] / [buildCustomShaperConfig] 对调用方输入做同样
/// 校验，越界返回 `null`，调用方**必须**在非空时才下发 `net.shaper.set`。
library;

import 'package:flutter/foundation.dart';
import 'package:gstore/core/rust/proxy/ProxyContract.dart';

// ==================== Schema 约束常量 ====================

/// 非零限速下限（bps）。
const int kShaperMinRateBps = 1000;

/// 限速上限（bps）。
const int kShaperMaxRateBps = 1000000000;

/// 突发桶下限（字节）。
const int kShaperMinBurstBytes = 1500;

/// 突发桶上限（字节）。
const int kShaperMaxBurstBytes = 65535;

/// 延迟上限（毫秒）。
const int kShaperMaxDelayMs = 60000;

/// 抖动上限（毫秒）。
const int kShaperMaxJitterMs = 30000;

/// 重排间隙上限（帧）。
const int kShaperMaxReorderGap = 255;

/// 允许的抖动分布字面值（Rust `JitterDistribution`）。
const Set<String> kShaperJitterDistributions = <String>{
  'uniform',
  'normal',
  'pareto',
};

/// 允许的丢包模型字面值（Rust `LossModel`）。
const Set<String> kShaperLossModels = <String>{
  'none',
  'random',
  'gilbertElliot',
};

/// 允许的包序字面值（Rust `PacketOrder`）。
const Set<String> kShaperOrders = <String>{'preserve', 'reorder'};

// ==================== 预设标识 ====================

/// 预设稳定 id（与 UI 选择 / 持久化无关，仅用于查表）。
class ProxyShaperPresetIds {
  const ProxyShaperPresetIds._();

  static const String g2 = '2G';
  static const String g3 = '3G';
  static const String g4 = '4G';
  static const String g5 = '5G';
  static const String weak = 'weak';
  static const String custom = 'custom';
}

// ==================== 预设模型 ====================

/// 一个弱网档位：稳定 [id] + 展示 [label] + 显式 [config]。
@immutable
class ProxyShaperPreset {
  const ProxyShaperPreset({
    required this.id,
    required this.label,
    required this.config,
  });

  /// 稳定 id（[ProxyShaperPresetIds]）。
  final String id;

  /// 界面展示名。
  final String label;

  /// 该档位对应的完整配置（Ping 值单位为 bps，与契约一致）。
  final ProxyShaperConfig config;

  /// 是否为「自定义」兜底档。
  bool get isCustom => id == ProxyShaperPresetIds.custom;

  @override
  String toString() => 'ProxyShaperPreset($id, $label)';
}

// ==================== 档位参数（双向一致） ====================

const ProxyShaperDirection _dir2g = ProxyShaperDirection(
  rateBps: 100000, // 100 kbps
  burstBytes: 32768,
  delayMs: 500,
  jitterMs: 100,
  jitterDistribution: 'normal',
);

const ProxyShaperDirection _dir3g = ProxyShaperDirection(
  rateBps: 400000, // 400 kbps（Chrome DevTools Slow 3G）
  burstBytes: 32768,
  delayMs: 400,
  jitterMs: 50,
  jitterDistribution: 'normal',
);

const ProxyShaperDirection _dir4g = ProxyShaperDirection(
  rateBps: 10000000, // 10 Mbps
  burstBytes: 32768,
  delayMs: 50,
  jitterMs: 20,
  jitterDistribution: 'normal',
);

const ProxyShaperDirection _dir5g = ProxyShaperDirection(
  rateBps: 100000000, // 100 Mbps
  burstBytes: 32768,
  delayMs: 20,
  jitterMs: 5,
  jitterDistribution: 'normal',
);

const ProxyShaperDirection _dirWeak = ProxyShaperDirection(
  rateBps: 50000, // 50 kbps：明显低于 2G，用于快速暴露超时/重试缺陷
  burstBytes: 32768,
  delayMs: 1000,
  jitterMs: 300,
  jitterDistribution: 'normal',
  lossPct: 2,
  lossModel: 'random',
);

// ==================== 兜底「自定义」 ====================

/// 「自定义」兜底档：默认关闭、双向全零（不整形）。
///
/// 未知 id / 无法识别的已加载配置都回落到这里，**绝不抛错**。
const ProxyShaperPreset customShaperPreset = ProxyShaperPreset(
  id: ProxyShaperPresetIds.custom,
  label: '自定义',
  config: ProxyShaperConfig(),
);

// ==================== 预设表（顺序即 UI 顺序） ====================

/// 有序预设表：2G → 3G → 4G → 5G → 弱网 → 自定义。
const List<ProxyShaperPreset> proxyShaperPresets = <ProxyShaperPreset>[
  ProxyShaperPreset(
    id: ProxyShaperPresetIds.g2,
    label: '2G',
    config: ProxyShaperConfig(enabled: true, uplink: _dir2g, downlink: _dir2g),
  ),
  ProxyShaperPreset(
    id: ProxyShaperPresetIds.g3,
    label: '3G',
    config: ProxyShaperConfig(enabled: true, uplink: _dir3g, downlink: _dir3g),
  ),
  ProxyShaperPreset(
    id: ProxyShaperPresetIds.g4,
    label: '4G',
    config: ProxyShaperConfig(enabled: true, uplink: _dir4g, downlink: _dir4g),
  ),
  ProxyShaperPreset(
    id: ProxyShaperPresetIds.g5,
    label: '5G',
    config: ProxyShaperConfig(enabled: true, uplink: _dir5g, downlink: _dir5g),
  ),
  ProxyShaperPreset(
    id: ProxyShaperPresetIds.weak,
    label: '弱网',
    config: ProxyShaperConfig(enabled: true, uplink: _dirWeak, downlink: _dirWeak),
  ),
  customShaperPreset,
];

/// 按稳定 id 查档位；未知 id 返回 `null`（**不抛错**）。
ProxyShaperPreset? presetById(String id) {
  for (final preset in proxyShaperPresets) {
    if (preset.id == id) return preset;
  }
  return null;
}

/// 按 id 查档位，未知 id 回落到 [customShaperPreset]（UI 恢复的宽容入口）。
ProxyShaperPreset presetOrCustomById(String id) =>
    presetById(id) ?? customShaperPreset;

/// 判断一个已加载配置匹配哪个预设（忽略 `enabled` / `seed`，只比双向参数）。
///
/// 命中已知档位返回之；未知 / 部分匹配（含默认空配置）回落 [customShaperPreset]。
ProxyShaperPreset presetForConfig(ProxyShaperConfig config) {
  for (final preset in proxyShaperPresets) {
    if (preset.isCustom) continue;
    if (preset.config.uplink == config.uplink &&
        preset.config.downlink == config.downlink) {
      return preset;
    }
  }
  return customShaperPreset;
}

// ==================== Schema 校验 ====================

bool _pctInRange(double value) => value >= 0 && value <= 100;

/// 单个方向是否满足 Rust `shaper.rs::DirectionConfig::validate` 的 Schema。
///
/// 规则：
/// * `rateBps == 0 || 1000 <= rateBps <= 1_000_000_000`
/// * `1500 <= burstBytes <= 65535`
/// * `0 <= delayMs <= 60000`，`0 <= jitterMs <= 30000`
/// * 各百分比 ∈ `[0, 100]`，`0 <= reorderGap <= 255`
/// * `!(order == 'reorder' && reorderPct > 0 && rateBps == 0)`（跨字段规则）
/// * 枚举字面值合法
///
/// `NaN` 因比较恒为 `false` 而被拒。
bool isValidShaperDirection(ProxyShaperDirection direction) {
  final rate = direction.rateBps;
  if (rate < 0) return false;
  if (rate != 0 && (rate < kShaperMinRateBps || rate > kShaperMaxRateBps)) {
    return false;
  }
  if (direction.burstBytes < kShaperMinBurstBytes ||
      direction.burstBytes > kShaperMaxBurstBytes) {
    return false;
  }
  if (direction.delayMs < 0 || direction.delayMs > kShaperMaxDelayMs) {
    return false;
  }
  if (direction.jitterMs < 0 || direction.jitterMs > kShaperMaxJitterMs) {
    return false;
  }
  if (!kShaperJitterDistributions.contains(direction.jitterDistribution)) {
    return false;
  }
  if (!kShaperLossModels.contains(direction.lossModel)) return false;
  if (!kShaperOrders.contains(direction.order)) return false;
  for (final pct in <double>[
    direction.lossPct,
    direction.lossGoodToBadPct,
    direction.lossBadToGoodPct,
    direction.duplicatePct,
    direction.reorderPct,
  ]) {
    if (!_pctInRange(pct)) return false;
  }
  if (direction.reorderGap < 0 ||
      direction.reorderGap > kShaperMaxReorderGap) {
    return false;
  }
  if (direction.order == 'reorder' &&
      direction.reorderPct > 0 &&
      direction.rateBps == 0) {
    return false;
  }
  return true;
}

/// 完整配置（双向）是否满足 Schema。
bool isValidShaperConfig(ProxyShaperConfig config) =>
    isValidShaperDirection(config.uplink) &&
    isValidShaperDirection(config.downlink);

// ==================== 自定义构造器 ====================

/// 用调用方输入构造一个**已校验**的单方向参数。
///
/// 越界 / 非法枚举 / 违反跨字段规则时返回 `null`；调用方**不得**在 `null` 时
/// 下发 `net.shaper.set`。
ProxyShaperDirection? buildCustomShaperDirection({
  int rateBps = 0,
  int burstBytes = 32768,
  int delayMs = 0,
  int jitterMs = 0,
  String jitterDistribution = 'uniform',
  double lossPct = 0,
  String lossModel = 'none',
  double lossGoodToBadPct = 0,
  double lossBadToGoodPct = 0,
  double duplicatePct = 0,
  double reorderPct = 0,
  int reorderGap = 0,
  String order = 'preserve',
}) {
  final direction = ProxyShaperDirection(
    rateBps: rateBps,
    burstBytes: burstBytes,
    delayMs: delayMs,
    jitterMs: jitterMs,
    jitterDistribution: jitterDistribution,
    lossPct: lossPct,
    lossModel: lossModel,
    lossGoodToBadPct: lossGoodToBadPct,
    lossBadToGoodPct: lossBadToGoodPct,
    duplicatePct: duplicatePct,
    reorderPct: reorderPct,
    reorderGap: reorderGap,
    order: order,
  );
  return isValidShaperDirection(direction) ? direction : null;
}

/// 用**输入框字符串**构造一个已校验的单方向参数（Todo 29：完整参数面）。
///
/// 覆盖 `DirectionConfig` 的全部字段：限速（输入单位 kbps，换算为 bps）、burst、
/// 延迟、抖动、抖动分布、丢包模型（含 Gilbert-Elliot 双概率）、复制、重排
/// （order / pct / gap）。任一字段为空 / 非数字，或 [buildCustomShaperDirection]
/// 判定越界 / 非法枚举 / 违反跨字段规则时返回 `null`。
///
/// **lossModel 由调用方显式给出**（不再从 `lossPct > 0` 反推），因此编辑
/// Gilbert-Elliot 配置时不会被静默重置为 `random` / `none`。
ProxyShaperDirection? buildShaperDirectionFromStrings({
  required String rateKbps,
  required String delayMs,
  required String jitterMs,
  required String burstBytes,
  required String jitterDistribution,
  required String lossPct,
  required String lossModel,
  required String lossGoodToBadPct,
  required String lossBadToGoodPct,
  required String duplicatePct,
  required String reorderPct,
  required String reorderGap,
  required String order,
}) {
  final rate = int.tryParse(rateKbps.trim());
  final burst = int.tryParse(burstBytes.trim());
  final delay = int.tryParse(delayMs.trim());
  final jitter = int.tryParse(jitterMs.trim());
  final loss = double.tryParse(lossPct.trim());
  final goodToBad = double.tryParse(lossGoodToBadPct.trim());
  final badToGood = double.tryParse(lossBadToGoodPct.trim());
  final duplicate = double.tryParse(duplicatePct.trim());
  final reorder = double.tryParse(reorderPct.trim());
  final gap = int.tryParse(reorderGap.trim());
  if (rate == null ||
      burst == null ||
      delay == null ||
      jitter == null ||
      loss == null ||
      goodToBad == null ||
      badToGood == null ||
      duplicate == null ||
      reorder == null ||
      gap == null) {
    return null;
  }
  return buildCustomShaperDirection(
    // 输入框单位为 kbps，契约单位为 bps，此处换算。
    rateBps: rate * 1000,
    burstBytes: burst,
    delayMs: delay,
    jitterMs: jitter,
    jitterDistribution: jitterDistribution,
    lossPct: loss,
    lossModel: lossModel,
    lossGoodToBadPct: goodToBad,
    lossBadToGoodPct: badToGood,
    duplicatePct: duplicate,
    reorderPct: reorder,
    reorderGap: gap,
    order: order,
  );
}

/// 用调用方输入构造一个**已校验**的完整配置（双向独立）。
///
/// 任一方向越界返回 `null`；调用方**不得**在 `null` 时下发 `net.shaper.set`。
ProxyShaperConfig? buildCustomShaperConfig({
  bool enabled = true,
  int? seed,
  required ProxyShaperDirection uplink,
  required ProxyShaperDirection downlink,
}) {
  if (!isValidShaperDirection(uplink) || !isValidShaperDirection(downlink)) {
    return null;
  }
  return ProxyShaperConfig(
    enabled: enabled,
    seed: seed,
    uplink: uplink,
    downlink: downlink,
  );
}

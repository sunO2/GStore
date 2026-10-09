/// 统计看板的纯展示辅助（排序键映射 / CSV 导出）。
///
/// * [ProxyStatSort]：UI 列（枚举顺序即展示顺序）。
/// * [proxyStatsServerSortFor]：列 → `stats.domain.get.sort` 契约键的**唯一映射**。
/// * [buildStatsCsv]：把当前页 [DomainStat] 行渲染为 CSV（Dart 不聚合）。
///
/// 契约只支持 `bytes|connections|lastSeen|domain`（`API.md §2.9`），且
/// **不得改动**；没有原生键的列（上传 / 下载 / 策略）返回 `null`，由页面本地
/// 比较器决定顺序 —— 不再用 `bytes` 误导性复用（历史缺陷：这些列全部下发
/// `bytes`，即「排序列 wire 映射偏置」）。
library;

import 'package:gstore/core/rust/proxy/ProxyContract.dart';

/// 统计表列（枚举顺序 = UI 展示顺序；测试按索引断言防偏移回归）。
enum ProxyStatSort {
  bytes('流量'),
  connections('连接数'),
  upload('上传'),
  download('下载'),
  lastSeen('最近'),
  outbound('策略'),
  domain('域名');

  const ProxyStatSort(this.label);

  final String label;
}

/// `stats.domain.get.sort` 冻结契约允许的键（`API.md §2.9`）。
const Set<String> kStatsServerSortKeys = <String>{
  'bytes',
  'connections',
  'lastSeen',
  'domain',
};

/// 列 → 服务端 `sort` 键；无原生键返回 `null`（省略字段，后端取默认 `bytes`）。
String? proxyStatsServerSortFor(ProxyStatSort sort) {
  switch (sort) {
    case ProxyStatSort.bytes:
      return 'bytes';
    case ProxyStatSort.connections:
      return 'connections';
    case ProxyStatSort.lastSeen:
      return 'lastSeen';
    case ProxyStatSort.domain:
      return 'domain';
    case ProxyStatSort.upload:
    case ProxyStatSort.download:
    case ProxyStatSort.outbound:
      return null;
  }
}

/// 统计表 CSV（仅当前 `stats.domain.get` 返回的行；不聚合、不补齐）。
String buildStatsCsv(List<DomainStat> domains) {
  final buffer = StringBuffer()
    ..writeln(
      'domain,connections,upload_bytes,download_bytes,last_seen_ms,'
      'outbound,rule,rule_payload',
    );
  for (final domain in domains) {
    buffer.writeln(<String>[
      _csvField(domain.domain),
      '${domain.connections}',
      '${domain.uploadBytes}',
      '${domain.downloadBytes}',
      '${domain.lastSeenMs}',
      _csvField(domain.outbound),
      _csvField(domain.rule),
      _csvField(domain.rulePayload),
    ].join(','));
  }
  return buffer.toString();
}

/// RFC 4180 字段转义：含逗号 / 引号 / 换行时加引号并双写内部引号。
String _csvField(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

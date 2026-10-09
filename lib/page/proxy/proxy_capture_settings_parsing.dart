/// 抓包设置页的纯解析 / 校验逻辑（无 Flutter 依赖，便于表驱动单测）。
///
/// 与 `rust/gstore_mod_proxy/API.md` §2.16 `CaptureConfig` 的取值范围对齐：
/// * `tlsPorts` 每项 ∈ `[1, 65535]`，数组不得为空；
/// * `maxBodyBytes` ∈ `[1, 1048576]`。
library;

/// 落盘 Body 上限的合法上界（镜像 Rust `capture.rs` / `API.md` §2.16）。
const int kCaptureMaxBodyBytes = 1048576;

/// `tlsPorts` 单端口合法下界。
const int kCaptureMinPort = 1;

/// `tlsPorts` 单端口合法上界。
const int kCaptureMaxPort = 65535;

/// 域名批量解析结果。
class DomainBulkParseResult {
  const DomainBulkParseResult({
    required this.accepted,
    required this.duplicates,
    required this.rejected,
    required this.overLimit,
  });

  /// 新增且去重后的条目（保留原始大小写，按首次出现顺序）。
  final List<String> accepted;

  /// 与既有白名单 / 本次输入内部重复而被跳过的条数。
  final int duplicates;

  /// 超长（`> maxEntryBytes`）被拒的条目。
  final List<String> rejected;

  /// 因达到条数上限而被丢弃的条数。
  final int overLimit;
}

/// 解析「批量粘贴」的域名文本。
///
/// 切分符：空白 / 逗号 / 分号；自动 trim、丢空行；按小写去重（DNS 大小写不敏感）；
/// 与 [existing] 合并去重；遵守 [maxEntries] / [maxEntryBytes]（镜像 Rust 上限）。
DomainBulkParseResult parseDomainBulk(
  String raw, {
  required int maxEntries,
  required int maxEntryBytes,
  List<String> existing = const <String>[],
}) {
  final seen = <String>{for (final entry in existing) entry.toLowerCase()};
  final accepted = <String>[];
  final rejected = <String>[];
  final remaining = maxEntries - existing.length;
  var duplicates = 0;
  var overLimit = 0;
  for (final token in raw.split(RegExp(r'[\s,;]+'))) {
    final value = token.trim();
    if (value.isEmpty) continue;
    if (value.length > maxEntryBytes) {
      rejected.add(value);
      continue;
    }
    if (!seen.add(value.toLowerCase())) {
      duplicates++;
      continue;
    }
    if (accepted.length >= remaining) {
      overLimit++;
      continue;
    }
    accepted.add(value);
  }
  return DomainBulkParseResult(
    accepted: accepted,
    duplicates: duplicates,
    rejected: rejected,
    overLimit: overLimit,
  );
}

/// 解析 TLS 端口输入（逗号 / 空格 / 分号分隔）：去重并校验每项 ∈ `[1,65535]`。
///
/// 无有效端口或任一非法 → `null`（调用方据此拒绝提交）。
List<int>? parseTlsPorts(String raw) {
  final ports = <int>[];
  final seen = <int>{};
  for (final token in raw.split(RegExp(r'[\s,;]+'))) {
    final value = token.trim();
    if (value.isEmpty) continue;
    final port = int.tryParse(value);
    if (port == null || port < kCaptureMinPort || port > kCaptureMaxPort) {
      return null;
    }
    if (seen.add(port)) ports.add(port);
  }
  if (ports.isEmpty) return null;
  return ports;
}

/// 解析 `maxBodyBytes`：合法整数且 ∈ `[1, 1048576]`，否则 `null`。
int? parseMaxBodyBytes(String raw) {
  final value = int.tryParse(raw.trim());
  if (value == null || value < 1 || value > kCaptureMaxBodyBytes) return null;
  return value;
}

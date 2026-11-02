/// Typed core-update errors, core check reports and the JSON codecs shared by
/// the update facade and its backends.
library;

import 'dart:convert';

import 'package:gstore/core/update/app_update_info.dart';
import 'package:gstore/core/update/update_log.dart';

/// Typed failure raised by the core `update` lane.
///
/// The Rust core rejects a check with a stable message prefix; this type keeps
/// that code machine-readable all the way to the UI. It is never swallowed and
/// never downgraded into a silent legacy fallback.
class CoreUpdateException implements Exception {
  const CoreUpdateException(this.code, [this.message = '']);

  /// `CORE_E_FACTS_MISSING`: the frontend has not pushed platform facts.
  static const String factsMissing = 'CORE_E_FACTS_MISSING';

  /// `CORE_E_INVENTORY_STALE`: the inventory snapshot is older than the rule.
  static const String inventoryStale = 'CORE_E_INVENTORY_STALE';

  /// Dart-side ordering guard: `update` is flipped before `catalog` is
  /// authoritative (the durable cutover order is catalog -> update).
  static const String cutoverOrder = 'CORE_E_UPDATE_CUTOVER_ORDER';

  /// Any other core failure (bridge unavailable, serialization, ...).
  static const String generic = 'CORE_E_UPDATE';

  final String code;
  final String message;

  /// Maps a raw bridge/backend failure onto a typed core update error.
  factory CoreUpdateException.fromRaw(Object error) {
    final text = error.toString();
    if (text.contains(factsMissing)) {
      return CoreUpdateException(factsMissing, text);
    }
    if (text.contains(inventoryStale)) {
      return CoreUpdateException(inventoryStale, text);
    }
    return CoreUpdateException(generic, text);
  }

  @override
  String toString() => message.isEmpty
      ? code
      : (message.contains(code) ? message : '$code: $message');
}

/// One per-app skip recorded by the core report.
class UpdateSkip {
  const UpdateSkip({
    required this.channelId,
    required this.appId,
    required this.reason,
  });

  final String channelId;
  final String appId;
  final String reason;

  factory UpdateSkip.fromJson(Map<String, dynamic> json) => UpdateSkip(
        channelId: json['channelId']?.toString() ?? '',
        appId: json['appId']?.toString() ?? '',
        reason: json['reason']?.toString() ?? '',
      );
}

/// Everything one core check exposes over the FRB boundary.
class CoreCheckReport {
  const CoreCheckReport({
    required this.updates,
    required this.skipped,
    required this.checkedAt,
    required this.total,
    required this.usedCache,
  });

  final List<AppUpdateInfo> updates;
  final List<UpdateSkip> skipped;
  final DateTime checkedAt;
  final int total;
  final bool usedCache;
}

/// Derives the UI log lines carried by the shared state from a core report.
///
/// The Rust core persists its own authoritative log rows; the FRB report does
/// not expose them yet, so the facade renders the same start/progress/finish
/// lines the legacy manager emits for the equivalent outcome. Skipped lines are
/// only rendered where the reason maps to a stable text (`unknown_channel`);
/// the Rust-owned log rows remain the source of truth for the rest.
List<CheckLogEntry> deriveCoreCheckLogs(CoreCheckReport report) {
  final time = report.checkedAt;
  final logs = <CheckLogEntry>[];
  if (report.usedCache) {
    logs.add(CheckLogEntry(
      level: CheckLogLevel.info,
      text: '使用缓存结果：${report.updates.length} 个可更新应用',
      time: time,
    ));
    return List<CheckLogEntry>.unmodifiable(logs);
  }
  logs.add(CheckLogEntry(
    level: CheckLogLevel.info,
    text: '开始检测应用更新...',
    time: time,
  ));
  logs.add(CheckLogEntry(
    level: CheckLogLevel.info,
    text: '已添加应用共 ${report.total} 个',
    time: time,
  ));
  for (final skip in report.skipped) {
    if (skip.reason == 'unknown_channel') {
      logs.add(CheckLogEntry(
        level: CheckLogLevel.skip,
        text: '${skip.appId}：渠道不可用',
        time: time,
      ));
    }
  }
  for (final update in report.updates) {
    final platform = update.latestDownload.platform?.trim();
    final platformLabel =
        platform == null || platform.isEmpty ? '自动匹配' : platform;
    logs.add(CheckLogEntry(
      level: CheckLogLevel.info,
      text: '开始检测应用：${update.appId}',
      time: time,
    ));
    logs.add(CheckLogEntry(
      level: CheckLogLevel.installed,
      text: '应用 ${update.appName}：安装版本 ${update.installedVersion}',
      time: time,
    ));
    logs.add(CheckLogEntry(
      level: CheckLogLevel.update,
      text: '应用 ${update.appName} 发现新版本：${update.latestVersion}',
      time: time,
    ));
    logs.add(CheckLogEntry(
      level: CheckLogLevel.info,
      text: '应用 ${update.appName}：选择平台 $platformLabel',
      time: time,
    ));
  }
  logs.add(CheckLogEntry(
    level: CheckLogLevel.update,
    text: '检测完成：共 ${report.total} 个应用，更新 ${report.updates.length} 个，'
        '跳过 ${report.skipped.length} 个',
    time: time,
  ));
  if (report.updates.isEmpty && report.skipped.isEmpty) {
    logs.add(CheckLogEntry(
      level: CheckLogLevel.none,
      text: '所有已添加应用均已是最新版本',
      time: time,
    ));
  }
  return List<CheckLogEntry>.unmodifiable(logs);
}

/// Persisted update state used to paint the last known result on startup.
typedef CachedUpdateSnapshot = ({
  List<AppUpdateInfo> updates,
  List<CheckLogEntry> logs,
  DateTime? lastCheckedAt,
});

/// Decodes the serialized `CheckLogEntry` array.
List<CheckLogEntry> decodeCheckLogs(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const <CheckLogEntry>[];
  return decoded
      .whereType<Map>()
      .map((item) => CheckLogEntry.fromJson(Map<String, dynamic>.from(item)))
      .where((entry) => entry.text.isNotEmpty)
      .toList(growable: false);
}

/// Decodes the serialized `UpdateSkip` array.
List<UpdateSkip> decodeUpdateSkips(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const <UpdateSkip>[];
  return decoded
      .whereType<Map>()
      .map((item) => UpdateSkip.fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

/// gstore_mod_proxy 类型化 Dart 契约（Todo 18，手写，**无 code-gen**）。
///
/// 本文件是 `rust/gstore_mod_proxy/API.md` 的 Dart 镜像：
/// * [ProxyMethods.all] = 全部可派发方法名（与 Rust `DISPATCH_METHODS` 一致）；
/// * [ProxyEvents.all] = 全部 `emit_event` 事件名（`proxy.log` 走 ABI log 回调，不在此）；
/// * [proxyResponseDecoders] = 方法名 → 响应 `fromJson` 解码器（每个方法一项）；
/// * 每个请求/响应/事件都是显式模型，未知/`null` 字段按文档默认值宽容解码，绝不抛裸异常。
///
/// 纯 Dart，无网络/无 dio/无业务逻辑：Flutter 只展示，逻辑在 Rust（`API.md` 头部）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:gstore/core/rust/proxy/ProxyModule.dart';

// ==================== 方法 / 事件注册表 ====================

/// 全部可派发方法名（冻结契约，与 `API.md` §2 表逐项对应）。
class ProxyMethods {
  const ProxyMethods._();

  static const String ping = 'ping';
  static const String version = 'version';
  static const String tunSetFd = 'tun.set_fd';
  static const String coreStart = 'core.start';
  static const String coreStop = 'core.stop';
  static const String coreRestart = 'core.restart';
  static const String coreGetMode = 'core.get_mode';
  static const String coreSetMode = 'core.set_mode';
  static const String routingGetMode = 'routing.get_mode';
  static const String routingSetMode = 'routing.set_mode';
  static const String dnsGet = 'dns.get';
  static const String dnsSet = 'dns.set';
  static const String dnsClearCache = 'dns.clear_cache';
  static const String dnsFlushCache = 'dns.flush_cache';
  // 运行日志查看器页面与展示门面已移除，
  // 但 `log.*` 是**冻结契约能力**而非该 UI 专属：模块日志环经宿主 `log` 回调
  // 桥接到 LogManager，诊断 / 故障排查仍依赖它。删除 UI ≠ 删除能力。
  static const String logGet = 'log.get';
  static const String logSetLevel = 'log.set_level';
  static const String logClear = 'log.clear';
  static const String rulesGet = 'rules.get';
  static const String rulesReload = 'rules.reload';
  static const String configGenerate = 'config.generate';
  static const String configApply = 'config.apply';
  static const String profileExportClash = 'profile.export_clash';
  static const String profileImportUrl = 'profile.import_url';
  static const String profileImportText = 'profile.import_text';
  static const String profileImportLink = 'profile.import_link';
  static const String profileList = 'profile.list';
  static const String profileGet = 'profile.get';
  static const String profileCreate = 'profile.create';
  static const String profileUpdate = 'profile.update';
  static const String profileDelete = 'profile.delete';
  static const String profileRefresh = 'profile.refresh';
  static const String profileRefreshAll = 'profile.refresh_all';
  static const String profileSetSchedule = 'profile.set_schedule';
  static const String nodeSelect = 'node.select';
  static const String nodeDelayTest = 'node.delay_test';
  static const String nodeList = 'node.list';
  static const String connList = 'conn.list';
  static const String connClose = 'conn.close';
  static const String connCloseAll = 'conn.close_all';
  static const String statsDomainGet = 'stats.domain.get';
  static const String statsDomainReset = 'stats.domain.reset';
  static const String statsTrafficGet = 'stats.traffic.get';
  static const String statsGet = 'stats.get';
  static const String statsReset = 'stats.reset';
  static const String requestsGet = 'requests.get';
  static const String requestsReset = 'requests.reset';
  static const String requestsExport = 'requests.export';
  static const String clashApiStart = 'diagnostics.clash_api.start';
  static const String clashApiStop = 'diagnostics.clash_api.stop';
  static const String clashApiStatus = 'diagnostics.clash_api.status';

  // `lan.*`：可选 LAN 入站（API.md §2.12，默认关闭）。
  static const String lanGet = 'lan.get';
  static const String lanSet = 'lan.set';
  static const String lanStatus = 'lan.status';

  /// 全部方法名（顺序与 `API.md` §2 一致）。
  static const List<String> all = <String>[
    ping,
    version,
    tunSetFd,
    coreStart,
    coreStop,
    coreRestart,
    coreGetMode,
    coreSetMode,
    routingGetMode,
    routingSetMode,
    dnsGet,
    dnsSet,
    dnsClearCache,
    dnsFlushCache,
    logGet,
    logSetLevel,
    logClear,
    rulesGet,
    rulesReload,
    configGenerate,
    configApply,
    profileExportClash,
    profileImportUrl,
    profileImportText,
    profileImportLink,
    profileList,
    profileGet,
    profileCreate,
    profileUpdate,
    profileDelete,
    profileRefresh,
    profileRefreshAll,
    profileSetSchedule,
    nodeSelect,
    nodeDelayTest,
    nodeList,
    connList,
    connClose,
    connCloseAll,
    statsDomainGet,
    statsDomainReset,
    statsTrafficGet,
    statsGet,
    statsReset,
    requestsGet,
    requestsReset,
    requestsExport,
    clashApiStart,
    clashApiStop,
    clashApiStatus,
    lanGet,
    lanSet,
    lanStatus,
  ];
}

/// 全部模块 → 宿主事件名（冻结契约，与 `API.md` §3 表逐行对应）。
class ProxyEvents {
  const ProxyEvents._();

  static const String state = 'proxy.state';
  static const String mode = 'proxy.mode';
  static const String nodeDelay = 'proxy.node.delay';
  static const String stats = 'proxy.stats';
  static const String request = 'proxy.request';
  static const String subscriptionUpdated = 'proxy.subscription.updated';
  static const String subscriptionProgress = 'proxy.subscription.progress';
  static const String subscriptionFailed = 'proxy.subscription.failed';
  static const String subscriptionAdded = 'proxy.subscription.added';
  static const String subscriptionRemoved = 'proxy.subscription.removed';
  static const String conn = 'proxy.conn';
  static const String dns = 'proxy.dns';
  static const String tunReleased = 'proxy.tun.released';
  static const String configApplied = 'proxy.config.applied';

  static const List<String> all = <String>[
    state,
    mode,
    nodeDelay,
    stats,
    request,
    subscriptionUpdated,
    subscriptionProgress,
    subscriptionFailed,
    subscriptionAdded,
    subscriptionRemoved,
    conn,
    dns,
    tunReleased,
    configApplied,
  ];
}

/// 响应解码器类型。
typedef ProxyJsonDecoder<T> = T Function(Map<String, dynamic> json);

// ==================== JSON 工具 ====================

Map<String, dynamic> _map(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : const <String, dynamic>{};

List<Map<String, dynamic>> _mapList(Object? value) => value is List
    ? value.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
    : const <Map<String, dynamic>>[];

List<String> _strList(Object? value) =>
    value is List ? value.map((e) => e.toString()).toList() : const <String>[];

int _int(Object? value) => _intOrNull(value) ?? 0;

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value == null) return null;
  return int.tryParse(value.toString());
}

bool _bool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  return value?.toString() == 'true';
}

String _str(Object? value) => value?.toString() ?? '';

// ==================== core.* ====================

/// `tun.set_fd` 响应。
class TunSetFdResult {
  const TunSetFdResult({
    required this.fd,
    required this.nonblocking,
    required this.replacedRunning,
  });

  factory TunSetFdResult.fromJson(Map<String, dynamic> json) => TunSetFdResult(
        fd: _int(json['fd']),
        nonblocking: _bool(json['nonblocking']),
        replacedRunning: _bool(json['replacedRunning']),
      );

  final int fd;
  final bool nonblocking;
  final bool replacedRunning;
}

/// `core.start` / `core.restart` 响应（含生成配置摘要）。
class ProxyCoreStatus {
  const ProxyCoreStatus({
    required this.state,
    required this.mode,
    required this.instanceId,
    required this.spawned,
    this.profileId,
    this.profileName,
    this.hash,
    this.template,
    this.proxies = 0,
    this.groups = 0,
    this.rules = 0,
    this.overlays,
    this.warnings = const <ProxyConfigWarning>[],
  });

  factory ProxyCoreStatus.fromJson(Map<String, dynamic> json) => ProxyCoreStatus(
        state: ProxyConnState.fromWire(json['state']),
        mode: ProxyMode.fromWire(json['mode']),
        instanceId: _int(json['instanceId']),
        spawned: _bool(json['spawned']),
        profileId: json['profileId']?.toString(),
        profileName: json['profileName']?.toString(),
        hash: json['hash']?.toString(),
        template: json['template']?.toString(),
        proxies: _int(json['proxies']),
        groups: _int(json['groups']),
        rules: _int(json['rules']),
        overlays: ProxyConfigOverlay.fromJsonOrNull(json['overlays']),
        warnings: _mapList(json['warnings'])
            .map(ProxyConfigWarning.fromJson)
            .toList(),
      );

  final ProxyConnState state;
  final ProxyMode mode;
  final int instanceId;
  final bool spawned;
  final String? profileId;
  final String? profileName;
  final String? hash;
  final String? template;
  final int proxies;
  final int groups;
  final int rules;
  final ProxyConfigOverlay? overlays;
  final List<ProxyConfigWarning> warnings;
}

/// `core.stop` 响应。
class CoreStopResult {
  const CoreStopResult({required this.state});

  factory CoreStopResult.fromJson(Map<String, dynamic> json) =>
      CoreStopResult(state: ProxyConnState.fromWire(json['state']));

  final ProxyConnState state;
}

/// `core.get_mode` 响应。
class CoreModeResult {
  const CoreModeResult({
    required this.mode,
    required this.state,
    required this.sinceMs,
  });

  factory CoreModeResult.fromJson(Map<String, dynamic> json) => CoreModeResult(
        mode: ProxyMode.fromWire(json['mode']),
        state: ProxyConnState.fromWire(json['state']),
        sinceMs: _int(json['sinceMs']),
      );

  final ProxyMode mode;
  final ProxyConnState state;
  final int sinceMs;
}

/// `core.set_mode` 响应。
class CoreSetModeResult {
  const CoreSetModeResult({
    required this.ok,
    required this.mode,
    required this.previous,
  });

  factory CoreSetModeResult.fromJson(Map<String, dynamic> json) =>
      CoreSetModeResult(
        ok: _bool(json['ok']),
        mode: ProxyMode.fromWire(json['mode']),
        previous: ProxyMode.fromWire(json['previous']),
      );

  final bool ok;
  final ProxyMode mode;
  final ProxyMode previous;
}

// ==================== routing.* ====================

/// `routing.get_mode` 响应。
class RoutingModeResult {
  const RoutingModeResult({required this.mode, required this.engineRunning});

  factory RoutingModeResult.fromJson(Map<String, dynamic> json) =>
      RoutingModeResult(
        mode: ProxyRoutingMode.fromWire(json['mode']),
        engineRunning: _bool(json['engineRunning']),
      );

  final ProxyRoutingMode mode;
  final bool engineRunning;
}

/// `routing.set_mode` 响应（`applied:false` = 引擎未运行，仅记录意图）。
class RoutingModeSetResult {
  const RoutingModeSetResult({
    required this.mode,
    required this.applied,
    required this.engineRunning,
  });

  factory RoutingModeSetResult.fromJson(Map<String, dynamic> json) =>
      RoutingModeSetResult(
        mode: ProxyRoutingMode.fromWire(json['mode']),
        applied: _bool(json['applied']),
        engineRunning: _bool(json['engineRunning']),
      );

  final ProxyRoutingMode mode;
  final bool applied;
  final bool engineRunning;
}

// ==================== dns.* ====================

/// 有效 DNS 配置（`dns.get` / `dns.set` 的 `config`）。
class DnsConfig {
  const DnsConfig({
    this.mode = 'fake-ip',
    this.nameservers = const <String>[],
    this.fallback = const <String>[],
    this.doh = const <String>[],
    this.dot = const <String>[],
    this.defaultNameservers = const <String>[],
    this.fakeIpRange,
    this.fakeIpRangeV6,
    this.fakeIpTtlMs,
    this.fakeIpFilter = const <String>[],
    this.fakeIpFilterMode,
    this.useHosts = true,
    this.ipv6 = true,
    this.hijack = true,
    this.hosts = const <String, List<String>>{},
  });

  factory DnsConfig.fromJson(Map<String, dynamic> json) => DnsConfig(
        mode: _str(json['mode']),
        nameservers: _strList(json['nameservers']),
        fallback: _strList(json['fallback']),
        doh: _strList(json['doh']),
        dot: _strList(json['dot']),
        defaultNameservers: _strList(json['defaultNameservers']),
        fakeIpRange: json['fakeIpRange']?.toString(),
        fakeIpRangeV6: json['fakeIpRangeV6']?.toString(),
        fakeIpTtlMs: _intOrNull(json['fakeIpTtlMs']),
        fakeIpFilter: _strList(json['fakeIpFilter']),
        fakeIpFilterMode: json['fakeIpFilterMode']?.toString(),
        useHosts: json['useHosts'] == null ? true : _bool(json['useHosts']),
        ipv6: json['ipv6'] == null ? true : _bool(json['ipv6']),
        hijack: json['hijack'] == null ? true : _bool(json['hijack']),
        hosts: json['hosts'] is Map
            ? (json['hosts'] as Map).map((k, v) =>
                MapEntry(k.toString(), _strList(v)))
            : const <String, List<String>>{},
      );

  final String mode;
  final List<String> nameservers;
  final List<String> fallback;
  final List<String> doh;
  final List<String> dot;
  final List<String> defaultNameservers;
  final String? fakeIpRange;
  final String? fakeIpRangeV6;
  final int? fakeIpTtlMs;
  final List<String> fakeIpFilter;
  final String? fakeIpFilterMode;
  final bool useHosts;
  final bool ipv6;
  final bool hijack;
  final Map<String, List<String>> hosts;

  /// 部分配置编码（`dns.set` 请求体）；仅写入显式提供的字段。
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (mode.isNotEmpty) 'mode': mode,
        if (nameservers.isNotEmpty) 'nameservers': nameservers,
        if (fallback.isNotEmpty) 'fallback': fallback,
        if (doh.isNotEmpty) 'doh': doh,
        if (dot.isNotEmpty) 'dot': dot,
        if (defaultNameservers.isNotEmpty)
          'defaultNameservers': defaultNameservers,
        if (fakeIpRange != null) 'fakeIpRange': fakeIpRange,
        if (fakeIpRangeV6 != null) 'fakeIpRangeV6': fakeIpRangeV6,
        if (fakeIpTtlMs != null) 'fakeIpTtlMs': fakeIpTtlMs,
        if (fakeIpFilter.isNotEmpty) 'fakeIpFilter': fakeIpFilter,
        if (fakeIpFilterMode != null) 'fakeIpFilterMode': fakeIpFilterMode,
        if (useHosts != true) 'useHosts': useHosts,
        if (ipv6 != true) 'ipv6': ipv6,
        if (hijack != true) 'hijack': hijack,
        if (hosts.isNotEmpty) 'hosts': hosts,
      };
}

/// DNS 查询/缓存统计。
class DnsStats {
  const DnsStats({
    this.queries = 0,
    this.failures = 0,
    this.cacheEntries = 0,
    this.fakeIpActive = false,
    this.fakeIpRange,
  });

  factory DnsStats.fromJson(Map<String, dynamic> json) => DnsStats(
        queries: _int(json['queries']),
        failures: _int(json['failures']),
        cacheEntries: _int(json['cacheEntries']),
        fakeIpActive: _bool(json['fakeIpActive']),
        fakeIpRange: json['fakeIpRange']?.toString(),
      );

  final int queries;
  final int failures;
  final int cacheEntries;
  final bool fakeIpActive;
  final String? fakeIpRange;
}

/// 一条 DNS 查询记录（同 `proxy.dns` 事件载荷）。
class DnsQueryRecord {
  const DnsQueryRecord({
    required this.tsMs,
    required this.domain,
    required this.qtype,
    required this.rcode,
    this.answers = const <String>[],
    this.resolver = '',
    this.latencyMs = 0,
    this.ok = true,
    this.mode = '',
    this.note,
  });

  factory DnsQueryRecord.fromJson(Map<String, dynamic> json) => DnsQueryRecord(
        tsMs: _int(json['tsMs']),
        domain: _str(json['domain']),
        qtype: _str(json['qtype']),
        rcode: _str(json['rcode']),
        answers: _strList(json['answers']),
        resolver: _str(json['resolver']),
        latencyMs: _int(json['latencyMs']),
        ok: _bool(json['ok']),
        mode: _str(json['mode']),
        note: json['note']?.toString(),
      );

  final int tsMs;
  final String domain;
  final String qtype;
  final String rcode;
  final List<String> answers;
  final String resolver;
  final int latencyMs;
  final bool ok;
  final String mode;
  final String? note;
}

/// 一条 domain → IP 映射（fake-IP / DNS 反查）。
class DnsMapping {
  const DnsMapping({
    required this.domain,
    required this.ip,
    this.fake = false,
    this.tsMs = 0,
    this.domainKnown = true,
  });

  factory DnsMapping.fromJson(Map<String, dynamic> json) => DnsMapping(
        domain: _str(json['domain']),
        ip: _str(json['ip']),
        fake: _bool(json['fake']),
        tsMs: _int(json['tsMs']),
        domainKnown: json['domainKnown'] == null
            ? true
            : _bool(json['domainKnown']),
      );

  final String domain;
  final String ip;
  final bool fake;
  final int tsMs;
  final bool domainKnown;
}

/// `dns.get` 响应。
class DnsSnapshot {
  const DnsSnapshot({
    required this.mode,
    required this.config,
    required this.stats,
    this.mappings = const <DnsMapping>[],
    this.recentQueries = const <DnsQueryRecord>[],
  });

  factory DnsSnapshot.fromJson(Map<String, dynamic> json) => DnsSnapshot(
        mode: _str(json['mode']),
        config: DnsConfig.fromJson(_map(json['config'])),
        stats: DnsStats.fromJson(_map(json['stats'])),
        mappings: _mapList(json['mappings']).map(DnsMapping.fromJson).toList(),
        recentQueries: _mapList(json['recentQueries'])
            .map(DnsQueryRecord.fromJson)
            .toList(),
      );

  final String mode;
  final DnsConfig config;
  final DnsStats stats;
  final List<DnsMapping> mappings;
  final List<DnsQueryRecord> recentQueries;
}

/// `dns.set` 响应。
class DnsSetResult {
  const DnsSetResult({required this.ok, required this.config});

  factory DnsSetResult.fromJson(Map<String, dynamic> json) => DnsSetResult(
        ok: _bool(json['ok']),
        config: DnsConfig.fromJson(_map(json['config'])),
      );

  final bool ok;
  final DnsConfig config;
}

/// `dns.clear_cache` / `dns.flush_cache` 响应。
class DnsClearResult {
  const DnsClearResult({required this.ok, required this.flushed});

  factory DnsClearResult.fromJson(Map<String, dynamic> json) => DnsClearResult(
        ok: _bool(json['ok']),
        flushed: _int(json['flushed']),
      );

  final bool ok;
  final int flushed;
}

// ==================== log.* ====================

/// 日志级别。
enum ProxyLogLevel {
  debug('debug'),
  info('info'),
  warn('warn'),
  error('error'),
  unknown('unknown');

  const ProxyLogLevel(this.wire);

  final String wire;

  static ProxyLogLevel fromWire(Object? value) {
    final s = value?.toString();
    for (final level in values) {
      if (level.wire == s) return level;
    }
    return ProxyLogLevel.unknown;
  }
}

/// 日志记录类别。
enum ProxyLogKind {
  message('message'),
  connection('connection'),
  dns('dns'),
  unknown('unknown');

  const ProxyLogKind(this.wire);

  final String wire;

  static ProxyLogKind fromWire(Object? value) {
    final s = value?.toString();
    for (final kind in values) {
      if (kind.wire == s) return kind;
    }
    return ProxyLogKind.unknown;
  }
}

/// `kind:"connection"` 载荷（无密钥字段）。
class ConnectionLog {
  const ConnectionLog({
    required this.id,
    this.direction = 'in',
    this.domain = '',
    this.outbound = '',
    this.rule = '',
    this.rulePayload = '',
    this.network = '',
    this.src = '',
    this.dst = '',
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.bytes = 0,
    this.durationMs = 0,
    this.error,
  });

  factory ConnectionLog.fromJson(Map<String, dynamic> json) => ConnectionLog(
        id: _str(json['id']),
        direction: _str(json['direction']),
        domain: _str(json['domain']),
        outbound: _str(json['outbound']),
        rule: _str(json['rule']),
        rulePayload: _str(json['rulePayload']),
        network: _str(json['network']),
        src: _str(json['src']),
        dst: _str(json['dst']),
        uploadBytes: _int(json['uploadBytes']),
        downloadBytes: _int(json['downloadBytes']),
        bytes: _int(json['bytes']),
        durationMs: _int(json['durationMs']),
        error: json['error']?.toString(),
      );

  final String id;
  final String direction;
  final String domain;
  final String outbound;
  final String rule;
  final String rulePayload;
  final String network;
  final String src;
  final String dst;
  final int uploadBytes;
  final int downloadBytes;
  final int bytes;
  final int durationMs;
  final String? error;
}

/// 单条日志记录。
class LogRecord {
  const LogRecord({
    required this.cursor,
    required this.tsMs,
    required this.level,
    required this.kind,
    this.message = '',
    this.connection,
    this.dns,
  });

  factory LogRecord.fromJson(Map<String, dynamic> json) => LogRecord(
        cursor: _int(json['cursor']),
        tsMs: _int(json['tsMs']),
        level: ProxyLogLevel.fromWire(json['level']),
        kind: ProxyLogKind.fromWire(json['kind']),
        message: _str(json['message']),
        connection: json['connection'] == null
            ? null
            : ConnectionLog.fromJson(_map(json['connection'])),
        dns: json['dns'] == null
            ? null
            : DnsQueryRecord.fromJson(_map(json['dns'])),
      );

  final int cursor;
  final int tsMs;
  final ProxyLogLevel level;
  final ProxyLogKind kind;
  final String message;
  final ConnectionLog? connection;
  final DnsQueryRecord? dns;
}

/// `log.get` 响应。
class LogPage {
  const LogPage({
    this.records = const <LogRecord>[],
    this.cursor = 0,
    this.nextCursor = 0,
    this.firstCursor = 0,
    this.retained = 0,
    this.capacity = 1000,
    this.dropped = 0,
    this.sinkDropped = 0,
    this.level = ProxyLogLevel.info,
  });

  factory LogPage.fromJson(Map<String, dynamic> json) => LogPage(
        records: _mapList(json['records']).map(LogRecord.fromJson).toList(),
        cursor: _int(json['cursor']),
        nextCursor: _int(json['nextCursor']),
        firstCursor: _int(json['firstCursor']),
        retained: _int(json['retained']),
        capacity: _int(json['capacity']),
        dropped: _int(json['dropped']),
        sinkDropped: _int(json['sinkDropped']),
        level: ProxyLogLevel.fromWire(json['level']),
      );

  final List<LogRecord> records;
  final int cursor;
  final int nextCursor;
  final int firstCursor;
  final int retained;
  final int capacity;
  final int dropped;
  final int sinkDropped;
  final ProxyLogLevel level;
}

/// `log.set_level` 响应。
class LogSetLevelResult {
  const LogSetLevelResult({required this.ok, required this.level});

  factory LogSetLevelResult.fromJson(Map<String, dynamic> json) =>
      LogSetLevelResult(
        ok: _bool(json['ok']),
        level: ProxyLogLevel.fromWire(json['level']),
      );

  final bool ok;
  final ProxyLogLevel level;
}

/// 通用 `{ "ok": true }` 响应（如 `log.clear`）。
class OkResult {
  const OkResult({required this.ok});

  factory OkResult.fromJson(Map<String, dynamic> json) =>
      OkResult(ok: _bool(json['ok']));

  final bool ok;
}

// ==================== rules.* ====================

/// 一条已解析规则。
class RuleLine {
  const RuleLine({
    required this.index,
    required this.lineNumber,
    required this.line,
    required this.type,
    required this.value,
    required this.target,
    this.source = '',
  });

  factory RuleLine.fromJson(Map<String, dynamic> json) => RuleLine(
        index: _int(json['index']),
        lineNumber: _int(json['lineNumber']),
        line: _str(json['line']),
        type: _str(json['type']),
        value: _str(json['value']),
        target: _str(json['target']),
        source: _str(json['source']),
      );

  final int index;
  final int lineNumber;
  final String line;
  final String type;
  final String value;
  final String target;
  final String source;
}

/// rule-provider 状态。
class RuleProviderStatus {
  const RuleProviderStatus({
    required this.name,
    required this.type,
    this.behavior = '',
    this.url = '',
    this.status = 'pending',
    this.count = 0,
    this.updatedAtMs = 0,
  });

  factory RuleProviderStatus.fromJson(Map<String, dynamic> json) =>
      RuleProviderStatus(
        name: _str(json['name']),
        type: _str(json['type']),
        behavior: _str(json['behavior']),
        url: _str(json['url']),
        status: _str(json['status']),
        count: _int(json['count']),
        updatedAtMs: _int(json['updatedAtMs']),
      );

  final String name;
  final String type;
  final String behavior;
  final String url;
  final String status;
  final int count;
  final int updatedAtMs;
}

/// 单个 geo 资产状态。
class GeoAsset {
  const GeoAsset({
    required this.kind,
    required this.file,
    this.path = '',
    this.status = 'missing',
    this.verified = false,
    this.sha256 = '',
  });

  factory GeoAsset.fromJson(Map<String, dynamic> json) => GeoAsset(
        kind: _str(json['kind']),
        file: _str(json['file']),
        path: _str(json['path']),
        status: _str(json['status']),
        verified: _bool(json['verified']),
        sha256: _str(json['sha256']),
      );

  final String kind;
  final String file;
  final String path;
  final String status;
  final bool verified;
  final String sha256;
}

/// geo 汇总状态。
class GeoStatus {
  const GeoStatus({this.status = 'idle', this.assets = const <GeoAsset>[]});

  factory GeoStatus.fromJson(Map<String, dynamic> json) => GeoStatus(
        status: _str(json['status']),
        assets: _mapList(json['assets']).map(GeoAsset.fromJson).toList(),
      );

  final String status;
  final List<GeoAsset> assets;
}

/// 一条规则错误。
class RuleError {
  const RuleError({
    this.lineNumber = 0,
    this.line = '',
    required this.code,
    required this.message,
  });

  factory RuleError.fromJson(Map<String, dynamic> json) => RuleError(
        lineNumber: _int(json['lineNumber']),
        line: _str(json['line']),
        code: _str(json['code']),
        message: _str(json['message']),
      );

  final int lineNumber;
  final String line;
  final String code;
  final String message;
}

/// `rules.get` / `rules.reload` 响应。
class RulesSnapshot {
  const RulesSnapshot({
    this.rules = const <RuleLine>[],
    this.finalTarget = 'DIRECT',
    this.count = 0,
    this.revision = 0,
    this.groups = const <String>[],
    this.providers = const <RuleProviderStatus>[],
    this.geo = const GeoStatus(),
    this.errors = const <RuleError>[],
    this.warnings = const <String>[],
  });

  factory RulesSnapshot.fromJson(Map<String, dynamic> json) => RulesSnapshot(
        rules: _mapList(json['rules']).map(RuleLine.fromJson).toList(),
        finalTarget: _str(json['final'] ?? 'DIRECT'),
        count: _int(json['count']),
        revision: _int(json['revision']),
        groups: _strList(json['groups']),
        providers: _mapList(json['providers'])
            .map(RuleProviderStatus.fromJson)
            .toList(),
        geo: GeoStatus.fromJson(_map(json['geo'])),
        errors: _mapList(json['errors']).map(RuleError.fromJson).toList(),
        warnings: _strList(json['warnings']),
      );

  final List<RuleLine> rules;
  final String finalTarget;
  final int count;
  final int revision;
  final List<String> groups;
  final List<RuleProviderStatus> providers;
  final GeoStatus geo;
  final List<RuleError> errors;
  final List<String> warnings;
}

// ==================== config.* ====================

/// 生成配置计数。
class ProxyConfigCounts {
  const ProxyConfigCounts({this.proxies = 0, this.groups = 0, this.rules = 0});

  factory ProxyConfigCounts.fromJson(Map<String, dynamic> json) =>
      ProxyConfigCounts(
        proxies: _int(json['proxies']),
        groups: _int(json['groups']),
        rules: _int(json['rules']),
      );

  final int proxies;
  final int groups;
  final int rules;
}

/// tun 覆盖项。
class ProxyConfigOverlay {
  const ProxyConfigOverlay({this.stack = '', this.mtu = 0});

  static ProxyConfigOverlay? fromJsonOrNull(Object? value) {
    if (value is! Map) return null;
    return ProxyConfigOverlay(
      stack: _str(value['stack']),
      mtu: _int(value['mtu']),
    );
  }

  final String stack;
  final int mtu;
}

/// 生成配置警告。
class ProxyConfigWarning {
  const ProxyConfigWarning({
    required this.code,
    required this.message,
    this.node,
  });

  factory ProxyConfigWarning.fromJson(Map<String, dynamic> json) =>
      ProxyConfigWarning(
        code: _str(json['code']),
        message: _str(json['message']),
        node: json['node']?.toString(),
      );

  final String code;
  final String message;
  final String? node;
}

/// `config.generate` / `config.apply` / `profile.export_clash` 响应。
class GeneratedConfig {
  const GeneratedConfig({
    required this.config,
    this.format = 'clash',
    this.template = '',
    this.profileId,
    this.profileName,
    this.hash = '',
    this.generatedAtMs = 0,
    this.counts = const ProxyConfigCounts(),
    this.overlays,
    this.warnings = const <ProxyConfigWarning>[],
    this.applied,
    this.rulesCount,
  });

  factory GeneratedConfig.fromJson(Map<String, dynamic> json) =>
      GeneratedConfig(
        config: _str(json['config']),
        format: _str(json['format']),
        template: _str(json['template']),
        profileId: json['profileId']?.toString(),
        profileName: json['profileName']?.toString(),
        hash: _str(json['hash']),
        generatedAtMs: _int(json['generatedAtMs']),
        counts: ProxyConfigCounts.fromJson(_map(json['counts'])),
        overlays: ProxyConfigOverlay.fromJsonOrNull(json['overlays']),
        warnings: _mapList(json['warnings'])
            .map(ProxyConfigWarning.fromJson)
            .toList(),
        applied: json.containsKey('applied') ? _bool(json['applied']) : null,
        rulesCount: _intOrNull(json['rules']),
      );

  final String config;
  final String format;
  final String template;
  final String? profileId;
  final String? profileName;
  final String hash;
  final int generatedAtMs;
  final ProxyConfigCounts counts;
  final ProxyConfigOverlay? overlays;
  final List<ProxyConfigWarning> warnings;

  /// 仅 `config.apply` 出现。
  final bool? applied;

  /// 仅 `config.apply` 出现（应用后的规则条数）。
  final int? rulesCount;
}

// ==================== profile.* ====================

/// REALITY 参数。
class ProxyReality {
  const ProxyReality({this.publicKey, this.shortId, this.spiderX});

  factory ProxyReality.fromJson(Map<String, dynamic> json) => ProxyReality(
        publicKey: json['publicKey']?.toString(),
        shortId: json['shortId']?.toString(),
        spiderX: json['spiderX']?.toString(),
      );

  final String? publicKey;
  final String? shortId;
  final String? spiderX;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (publicKey != null) 'publicKey': publicKey,
        if (shortId != null) 'shortId': shortId,
        if (spiderX != null) 'spiderX': spiderX,
      };
}

/// WebSocket 参数。
class ProxyWs {
  const ProxyWs({this.path, this.host});

  factory ProxyWs.fromJson(Map<String, dynamic> json) => ProxyWs(
        path: json['path']?.toString(),
        host: json['host']?.toString(),
      );

  final String? path;
  final String? host;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (path != null) 'path': path,
        if (host != null) 'host': host,
      };
}

/// gRPC 参数。
class ProxyGrpc {
  const ProxyGrpc({this.serviceName});

  factory ProxyGrpc.fromJson(Map<String, dynamic> json) =>
      ProxyGrpc(serviceName: json['serviceName']?.toString());

  final String? serviceName;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (serviceName != null) 'serviceName': serviceName,
      };
}

/// 节点来源（格式/来源/index）。
class ProxyNodeSource {
  const ProxyNodeSource({this.format, this.origin, this.index = 0});

  factory ProxyNodeSource.fromJson(Map<String, dynamic> json) =>
      ProxyNodeSource(
        format: json['format']?.toString(),
        origin: json['origin']?.toString(),
        index: _int(json['index']),
      );

  final String? format;
  final String? origin;
  final int index;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (format != null) 'format': format,
        if (origin != null) 'origin': origin,
        'index': index,
      };
}

/// 规范节点模型（`ImportedProfile.nodes`）。
///
/// 含凭据字段（[password] / [uuid] / REALITY / obfs）；仅在 UI 必须展示时瞬态持有，
/// 绝不打日志。[raw] 保留原始键值以容忍未来新增字段。
class ProxyNode {
  const ProxyNode({
    required this.name,
    required this.type,
    this.server = '',
    this.port = 0,
    this.cipher,
    this.password,
    this.uuid,
    this.alterId,
    this.security,
    this.flow,
    this.network,
    this.tls,
    this.sni,
    this.skipCertVerify,
    this.alpn = const <String>[],
    this.fingerprint,
    this.reality,
    this.ws,
    this.grpc,
    this.obfs,
    this.obfsPassword,
    this.groups = const <String>[],
    this.source,
    this.raw = const <String, dynamic>{},
  });

  factory ProxyNode.fromJson(Map<String, dynamic> json) => ProxyNode(
        name: _str(json['name']),
        type: _str(json['type']),
        server: _str(json['server']),
        port: _int(json['port']),
        cipher: json['cipher']?.toString(),
        password: json['password']?.toString(),
        uuid: json['uuid']?.toString(),
        alterId: _intOrNull(json['alterId']),
        security: json['security']?.toString(),
        flow: json['flow']?.toString(),
        network: json['network']?.toString(),
        tls: json.containsKey('tls') ? _bool(json['tls']) : null,
        sni: json['sni']?.toString(),
        skipCertVerify: json.containsKey('skipCertVerify')
            ? _bool(json['skipCertVerify'])
            : null,
        alpn: _strList(json['alpn']),
        fingerprint: json['fingerprint']?.toString(),
        reality: json['reality'] == null
            ? null
            : ProxyReality.fromJson(_map(json['reality'])),
        ws: json['ws'] == null ? null : ProxyWs.fromJson(_map(json['ws'])),
        grpc: json['grpc'] == null
            ? null
            : ProxyGrpc.fromJson(_map(json['grpc'])),
        obfs: json['obfs']?.toString(),
        obfsPassword: json['obfsPassword']?.toString(),
        groups: _strList(json['groups']),
        source: json['source'] == null
            ? null
            : ProxyNodeSource.fromJson(_map(json['source'])),
        raw: json,
      );

  final String name;
  final String type;
  final String server;
  final int port;
  final String? cipher;
  final String? password;
  final String? uuid;
  final int? alterId;
  final String? security;
  final String? flow;
  final String? network;
  final bool? tls;
  final String? sni;
  final bool? skipCertVerify;
  final List<String> alpn;
  final String? fingerprint;
  final ProxyReality? reality;
  final ProxyWs? ws;
  final ProxyGrpc? grpc;
  final String? obfs;
  final String? obfsPassword;
  final List<String> groups;
  final ProxyNodeSource? source;
  final Map<String, dynamic> raw;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'type': type,
        'server': server,
        'port': port,
        if (cipher != null) 'cipher': cipher,
        if (password != null) 'password': password,
        if (uuid != null) 'uuid': uuid,
        if (alterId != null) 'alterId': alterId,
        if (security != null) 'security': security,
        if (flow != null) 'flow': flow,
        if (network != null) 'network': network,
        if (tls != null) 'tls': tls,
        if (sni != null) 'sni': sni,
        if (skipCertVerify != null) 'skipCertVerify': skipCertVerify,
        if (alpn.isNotEmpty) 'alpn': alpn,
        if (fingerprint != null) 'fingerprint': fingerprint,
        if (reality != null) 'reality': reality!.toJson(),
        if (ws != null) 'ws': ws!.toJson(),
        if (grpc != null) 'grpc': grpc!.toJson(),
        if (obfs != null) 'obfs': obfs,
        if (obfsPassword != null) 'obfsPassword': obfsPassword,
        if (groups.isNotEmpty) 'groups': groups,
        if (source != null) 'source': source!.toJson(),
      };
}

/// 代理组（`ImportedProfile.groups`）。
class ProxyGroup {
  const ProxyGroup({
    required this.name,
    required this.type,
    this.members = const <String>[],
  });

  factory ProxyGroup.fromJson(Map<String, dynamic> json) => ProxyGroup(
        name: _str(json['name']),
        type: _str(json['type']),
        members: _strList(json['members']),
      );

  final String name;
  final String type;
  final List<String> members;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'type': type,
        'members': members,
      };
}

/// 订阅 userinfo。
class SubscriptionUserinfo {
  const SubscriptionUserinfo({
    this.upload,
    this.download,
    this.total,
    this.expire,
  });

  factory SubscriptionUserinfo.fromJson(Map<String, dynamic> json) =>
      SubscriptionUserinfo(
        upload: _intOrNull(json['upload']),
        download: _intOrNull(json['download']),
        total: _intOrNull(json['total']),
        expire: _intOrNull(json['expire']),
      );

  final int? upload;
  final int? download;
  final int? total;
  final int? expire;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (upload != null) 'upload': upload,
        if (download != null) 'download': download,
        if (total != null) 'total': total,
        if (expire != null) 'expire': expire,
      };
}

/// 订阅来源元数据。
class ProfileSource {
  const ProfileSource({
    this.origin = '',
    this.url = '',
    this.finalUrl = '',
    this.filename = '',
    this.userAgent = '',
    this.fetchedAtMs = 0,
    this.bytes = 0,
    this.contentType = '',
  });

  factory ProfileSource.fromJson(Map<String, dynamic> json) => ProfileSource(
        origin: _str(json['origin']),
        url: _str(json['url']),
        finalUrl: _str(json['finalUrl']),
        filename: _str(json['filename']),
        userAgent: _str(json['userAgent']),
        fetchedAtMs: _int(json['fetchedAtMs']),
        bytes: _int(json['bytes']),
        contentType: _str(json['contentType']),
      );

  final String origin;
  final String url;
  final String finalUrl;
  final String filename;
  final String userAgent;
  final int fetchedAtMs;
  final int bytes;
  final String contentType;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'origin': origin,
        'url': url,
        'finalUrl': finalUrl,
        'filename': filename,
        'userAgent': userAgent,
        'fetchedAtMs': fetchedAtMs,
        'bytes': bytes,
        'contentType': contentType,
      };
}

/// 规范导入结果（`profile.import_*` 响应）。
class ImportedProfile {
  const ImportedProfile({
    required this.name,
    required this.format,
    this.nodeCount = 0,
    this.nodes = const <ProxyNode>[],
    this.groups = const <ProxyGroup>[],
    this.hasProxyGroups = true,
    this.userinfo,
    this.source,
    this.warnings = const <String>[],
  });

  factory ImportedProfile.fromJson(Map<String, dynamic> json) => ImportedProfile(
        name: _str(json['name']),
        format: _str(json['format']),
        nodeCount: _int(json['nodeCount']),
        nodes: _mapList(json['nodes']).map(ProxyNode.fromJson).toList(),
        groups: _mapList(json['groups']).map(ProxyGroup.fromJson).toList(),
        hasProxyGroups: json['hasProxyGroups'] == null
            ? true
            : _bool(json['hasProxyGroups']),
        userinfo: json['userinfo'] == null
            ? null
            : SubscriptionUserinfo.fromJson(_map(json['userinfo'])),
        source: json['source'] == null
            ? null
            : ProfileSource.fromJson(_map(json['source'])),
        warnings: _strList(json['warnings']),
      );

  final String name;
  final String format;
  final int nodeCount;
  final List<ProxyNode> nodes;
  final List<ProxyGroup> groups;
  final bool hasProxyGroups;
  final SubscriptionUserinfo? userinfo;
  final ProfileSource? source;
  final List<String> warnings;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'format': format,
        'nodeCount': nodeCount,
        'nodes': <Map<String, dynamic>>[for (final n in nodes) n.toJson()],
        'groups': <Map<String, dynamic>>[for (final g in groups) g.toJson()],
        'hasProxyGroups': hasProxyGroups,
        if (userinfo != null) 'userinfo': userinfo!.toJson(),
        if (source != null) 'source': source!.toJson(),
        if (warnings.isNotEmpty) 'warnings': warnings,
      };
}

/// 刷新状态。
enum ProxyRefreshState {
  idle('idle'),
  requested('requested'),
  done('done'),
  failed('failed'),
  unknown('unknown');

  const ProxyRefreshState(this.wire);

  final String wire;

  static ProxyRefreshState fromWire(Object? value) {
    final s = value?.toString();
    for (final state in values) {
      if (state.wire == s) return state;
    }
    return ProxyRefreshState.unknown;
  }
}

/// 单 profile 刷新调度元数据。
class ProfileRefreshState {
  const ProfileRefreshState({
    required this.state,
    this.requestedAtMs = 0,
    this.lastAttemptMs,
    this.attempts = 0,
    this.error,
    this.errorCode,
    this.lastUpdatedAtMs,
    this.intervalMs,
    this.consecutiveFailures = 0,
    this.nextRefreshAtMs,
  });

  factory ProfileRefreshState.fromJson(Map<String, dynamic> json) =>
      ProfileRefreshState(
        state: ProxyRefreshState.fromWire(json['state']),
        requestedAtMs: _int(json['requestedAtMs']),
        lastAttemptMs: _intOrNull(json['lastAttemptMs']),
        attempts: _int(json['attempts']),
        error: json['error']?.toString(),
        errorCode: json['errorCode']?.toString(),
        lastUpdatedAtMs: _intOrNull(json['lastUpdatedAtMs']),
        intervalMs: _intOrNull(json['intervalMs']),
        consecutiveFailures: _int(json['consecutiveFailures']),
        nextRefreshAtMs: _intOrNull(json['nextRefreshAtMs']),
      );

  final ProxyRefreshState state;
  final int requestedAtMs;
  final int? lastAttemptMs;
  final int attempts;
  final String? error;
  final String? errorCode;
  final int? lastUpdatedAtMs;
  final int? intervalMs;
  final int consecutiveFailures;
  final int? nextRefreshAtMs;
}

/// 存储摘要（`profile.list.profiles`）。
class ProfileSummary {
  const ProfileSummary({
    required this.id,
    required this.name,
    this.format = '',
    this.nodeCount = 0,
    this.groupCount = 0,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.revision = 0,
    this.sourceOrigin,
    this.sourceUrl,
    this.userinfo,
    this.refresh,
  });

  factory ProfileSummary.fromJson(Map<String, dynamic> json) => ProfileSummary(
        id: _str(json['id']),
        name: _str(json['name']),
        format: _str(json['format']),
        nodeCount: _int(json['nodeCount']),
        groupCount: _int(json['groupCount']),
        createdAtMs: _int(json['createdAtMs']),
        updatedAtMs: _int(json['updatedAtMs']),
        revision: _int(json['revision']),
        sourceOrigin: json['sourceOrigin']?.toString(),
        sourceUrl: json['sourceUrl']?.toString(),
        userinfo: json['userinfo'] == null
            ? null
            : SubscriptionUserinfo.fromJson(_map(json['userinfo'])),
        refresh: json['refresh'] == null
            ? null
            : ProfileRefreshState.fromJson(_map(json['refresh'])),
      );

  final String id;
  final String name;
  final String format;
  final int nodeCount;
  final int groupCount;
  final int createdAtMs;
  final int updatedAtMs;
  final int revision;
  final String? sourceOrigin;
  final String? sourceUrl;
  final SubscriptionUserinfo? userinfo;
  final ProfileRefreshState? refresh;
}

/// `profile.list` 警告。
class ProfileWarning {
  const ProfileWarning({
    required this.code,
    this.id,
    this.file,
    this.message = '',
  });

  factory ProfileWarning.fromJson(Map<String, dynamic> json) => ProfileWarning(
        code: _str(json['code']),
        id: json['id']?.toString(),
        file: json['file']?.toString(),
        message: _str(json['message']),
      );

  final String code;
  final String? id;
  final String? file;
  final String message;
}

/// `profile.list` 响应。
class ProfileList {
  const ProfileList({
    this.schemaVersion = 2,
    this.revision = 0,
    this.count = 0,
    this.profiles = const <ProfileSummary>[],
    this.warnings = const <ProfileWarning>[],
  });

  factory ProfileList.fromJson(Map<String, dynamic> json) => ProfileList(
        schemaVersion: _int(json['schemaVersion']),
        revision: _int(json['revision']),
        count: _int(json['count']),
        profiles: _mapList(json['profiles'])
            .map(ProfileSummary.fromJson)
            .toList(),
        warnings: _mapList(json['warnings'])
            .map(ProfileWarning.fromJson)
            .toList(),
      );

  final int schemaVersion;
  final int revision;
  final int count;
  final List<ProfileSummary> profiles;
  final List<ProfileWarning> warnings;
}

/// 存储 profile（`get`/`create`/`update`/`set_schedule` 响应）。
class StoredProfile {
  const StoredProfile({
    this.schemaVersion = 2,
    required this.id,
    this.revision = 1,
    this.createdAtMs = 0,
    this.updatedAtMs = 0,
    this.refresh,
    this.appBackup,
    required this.profile,
  });

  factory StoredProfile.fromJson(Map<String, dynamic> json) => StoredProfile(
        schemaVersion: _int(json['schemaVersion']),
        id: _str(json['id']),
        revision: _int(json['revision']),
        createdAtMs: _int(json['createdAtMs']),
        updatedAtMs: _int(json['updatedAtMs']),
        refresh: json['refresh'] == null
            ? null
            : ProfileRefreshState.fromJson(_map(json['refresh'])),
        appBackup: json['appBackup'],
        profile: ImportedProfile.fromJson(_map(json['profile'])),
      );

  final int schemaVersion;
  final String id;
  final int revision;
  final int createdAtMs;
  final int updatedAtMs;
  final ProfileRefreshState? refresh;
  final Object? appBackup;
  final ImportedProfile profile;
}

/// 刷新错误。
class RefreshError {
  const RefreshError({required this.code, required this.message});

  factory RefreshError.fromJson(Map<String, dynamic> json) => RefreshError(
        code: _str(json['code']),
        message: _str(json['message']),
      );

  final String code;
  final String message;
}

/// `profile.refresh` 响应。
class RefreshResult {
  const RefreshResult({
    required this.profileId,
    required this.state,
    this.attempts = 0,
    this.nodeCount = 0,
    this.userinfo,
    this.lastUpdatedAtMs,
    this.intervalMs,
    this.nextRefreshAtMs,
    this.retryAfterMs,
    this.error,
    this.profile,
  });

  factory RefreshResult.fromJson(Map<String, dynamic> json) => RefreshResult(
        profileId: _str(json['profileId']),
        state: _str(json['state']),
        attempts: _int(json['attempts']),
        nodeCount: _int(json['nodeCount']),
        userinfo: json['userinfo'] == null
            ? null
            : SubscriptionUserinfo.fromJson(_map(json['userinfo'])),
        lastUpdatedAtMs: _intOrNull(json['lastUpdatedAtMs']),
        intervalMs: _intOrNull(json['intervalMs']),
        nextRefreshAtMs: _intOrNull(json['nextRefreshAtMs']),
        retryAfterMs: _intOrNull(json['retryAfterMs']),
        error: json['error'] == null
            ? null
            : RefreshError.fromJson(_map(json['error'])),
        profile: json['profile'] == null
            ? null
            : StoredProfile.fromJson(_map(json['profile'])),
      );

  final String profileId;
  final String state;
  final int attempts;
  final int nodeCount;
  final SubscriptionUserinfo? userinfo;
  final int? lastUpdatedAtMs;
  final int? intervalMs;
  final int? nextRefreshAtMs;
  final int? retryAfterMs;
  final RefreshError? error;
  final StoredProfile? profile;
}

/// `profile.refresh_all` 跳过的 profile 原因。
class RefreshSkipped {
  const RefreshSkipped({
    required this.profileId,
    required this.reason,
    this.nextRefreshAtMs,
    this.code,
    this.message,
  });

  factory RefreshSkipped.fromJson(Map<String, dynamic> json) => RefreshSkipped(
        profileId: _str(json['profileId']),
        reason: _str(json['reason']),
        nextRefreshAtMs: _intOrNull(json['nextRefreshAtMs']),
        code: json['code']?.toString(),
        message: json['message']?.toString(),
      );

  final String profileId;
  final String reason;
  final int? nextRefreshAtMs;
  final String? code;
  final String? message;
}

/// `profile.refresh_all` 响应。
class RefreshAllResult {
  const RefreshAllResult({
    this.force = false,
    this.limit = 8,
    this.attempted = 0,
    this.count = 0,
    this.failedCount = 0,
    this.refreshed = const <RefreshResult>[],
    this.skipped = const <RefreshSkipped>[],
  });

  factory RefreshAllResult.fromJson(Map<String, dynamic> json) =>
      RefreshAllResult(
        force: _bool(json['force']),
        limit: _int(json['limit']),
        attempted: _int(json['attempted']),
        count: _int(json['count']),
        failedCount: _int(json['failedCount']),
        refreshed: _mapList(json['refreshed'])
            .map(RefreshResult.fromJson)
            .toList(),
        skipped:
            _mapList(json['skipped']).map(RefreshSkipped.fromJson).toList(),
      );

  final bool force;
  final int limit;
  final int attempted;
  final int count;
  final int failedCount;
  final List<RefreshResult> refreshed;
  final List<RefreshSkipped> skipped;
}

/// `profile.delete` 响应。
class ProfileDeleteResult {
  const ProfileDeleteResult({
    required this.ok,
    required this.id,
    required this.deleted,
  });

  factory ProfileDeleteResult.fromJson(Map<String, dynamic> json) =>
      ProfileDeleteResult(
        ok: _bool(json['ok']),
        id: _str(json['id']),
        deleted: _bool(json['deleted']),
      );

  final bool ok;
  final String id;
  final bool deleted;
}

// ==================== node.* ====================

/// `node.select` 响应。
class NodeSelectResult {
  const NodeSelectResult({
    required this.ok,
    required this.group,
    required this.node,
    required this.active,
  });

  factory NodeSelectResult.fromJson(Map<String, dynamic> json) =>
      NodeSelectResult(
        ok: _bool(json['ok']),
        group: _str(json['group']),
        node: _str(json['node']),
        active: _str(json['active']),
      );

  final bool ok;
  final String group;
  final String node;
  final String active;
}

/// 单节点延迟结果。
class DelayResult {
  const DelayResult({
    required this.node,
    this.delayMs = 0,
    this.alive = false,
    this.error,
  });

  factory DelayResult.fromJson(Map<String, dynamic> json) => DelayResult(
        node: _str(json['node']),
        delayMs: _int(json['delayMs']),
        alive: _bool(json['alive']),
        error: json['error']?.toString(),
      );

  final String node;
  final int delayMs;
  final bool alive;
  final String? error;
}

/// `node.delay_test` 响应。
class DelayTestResult {
  const DelayTestResult({
    this.results = const <DelayResult>[],
    this.url = '',
    this.timeoutMs = 0,
    this.group,
  });

  factory DelayTestResult.fromJson(Map<String, dynamic> json) =>
      DelayTestResult(
        results:
            _mapList(json['results']).map(DelayResult.fromJson).toList(),
        url: _str(json['url']),
        timeoutMs: _int(json['timeoutMs']),
        group: json['group']?.toString(),
      );

  final List<DelayResult> results;
  final String url;
  final int timeoutMs;
  final String? group;
}

/// `node.list` 单个代理组：类型、实时选中（`now`）与成员。
class NodeGroupInfo {
  const NodeGroupInfo({
    required this.name,
    required this.type,
    this.now,
    this.members = const <String>[],
    this.selectable = false,
  });

  factory NodeGroupInfo.fromJson(Map<String, dynamic> json) => NodeGroupInfo(
        name: _str(json['name']),
        type: _str(json['type']),
        now: json['now']?.toString(),
        members: _strList(json['members']),
        selectable: _bool(json['selectable']),
      );

  final String name;
  final String type;

  /// 该组当前的实时出站（selector = 用户选中；url-test/fallback = 自动选中）。
  final String? now;
  final List<String> members;
  final bool selectable;
}

/// `node.list` 当前路由分组（实时规则集最后一个 `MATCH`/`FINAL` 的目标）。
class NodeCurrent {
  const NodeCurrent({required this.group, this.now, this.node});

  factory NodeCurrent.fromJson(Map<String, dynamic> json) => NodeCurrent(
        group: _str(json['group']),
        now: json['now']?.toString(),
        node: json['node']?.toString(),
      );

  final String group;

  /// 该组的实时出站。
  final String? now;

  /// `now` 本身是嵌套分组时解析出的叶子节点，否则为 null。
  final String? node;
}

/// `node.list` 响应：引擎是否运行 + 各代理组 + 当前路由分组。
class NodeListResult {
  const NodeListResult({
    this.engineRunning = false,
    this.groups = const <NodeGroupInfo>[],
    this.current,
  });

  factory NodeListResult.fromJson(Map<String, dynamic> json) => NodeListResult(
        engineRunning: _bool(json['engineRunning']),
        groups: _mapList(json['groups']).map(NodeGroupInfo.fromJson).toList(),
        current: json['current'] is Map
            ? NodeCurrent.fromJson(_map(json['current']))
            : null,
      );

  final bool engineRunning;
  final List<NodeGroupInfo> groups;
  final NodeCurrent? current;
}

// ==================== conn.* ====================

/// 单条连接。
class ConnInfo {
  const ConnInfo({
    required this.id,
    required this.src,
    required this.dst,
    this.domain = '',
    this.network = '',
    this.rule = '',
    this.rulePayload = '',
    this.outbound = '',
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.startedAtMs = 0,
  });

  factory ConnInfo.fromJson(Map<String, dynamic> json) => ConnInfo(
        id: _str(json['id']),
        src: _str(json['src']),
        dst: _str(json['dst']),
        domain: _str(json['domain']),
        network: _str(json['network']),
        rule: _str(json['rule']),
        rulePayload: _str(json['rulePayload']),
        outbound: _str(json['outbound']),
        uploadBytes: _int(json['uploadBytes']),
        downloadBytes: _int(json['downloadBytes']),
        startedAtMs: _int(json['startedAtMs']),
      );

  final String id;
  final String src;
  final String dst;
  final String domain;
  final String network;
  final String rule;
  final String rulePayload;
  final String outbound;
  final int uploadBytes;
  final int downloadBytes;
  final int startedAtMs;
}

/// `conn.list` 响应。
class ConnPage {
  const ConnPage({
    this.connections = const <ConnInfo>[],
    this.count = 0,
    this.returned = 0,
    this.total = 0,
    this.offset = 0,
    this.limit = 256,
    this.hasMore = false,
    this.capacity = 1024,
  });

  factory ConnPage.fromJson(Map<String, dynamic> json) => ConnPage(
        connections:
            _mapList(json['connections']).map(ConnInfo.fromJson).toList(),
        count: _int(json['count']),
        returned: _int(json['returned']),
        total: _int(json['total']),
        offset: _int(json['offset']),
        limit: _int(json['limit']),
        hasMore: _bool(json['hasMore']),
        capacity: _int(json['capacity']),
      );

  final List<ConnInfo> connections;
  final int count;
  final int returned;
  final int total;
  final int offset;
  final int limit;
  final bool hasMore;
  final int capacity;
}

/// `conn.close` 响应。
class ConnCloseResult {
  const ConnCloseResult({
    required this.ok,
    required this.id,
    required this.closed,
    required this.alreadyClosed,
  });

  factory ConnCloseResult.fromJson(Map<String, dynamic> json) =>
      ConnCloseResult(
        ok: _bool(json['ok']),
        id: _str(json['id']),
        closed: _bool(json['closed']),
        alreadyClosed: _bool(json['alreadyClosed']),
      );

  final bool ok;
  final String id;
  final bool closed;
  final bool alreadyClosed;
}

/// `conn.close_all` 响应。
class ConnCloseAllResult {
  const ConnCloseAllResult({required this.ok, required this.closed});

  factory ConnCloseAllResult.fromJson(Map<String, dynamic> json) =>
      ConnCloseAllResult(ok: _bool(json['ok']), closed: _int(json['closed']));

  final bool ok;
  final int closed;
}

// ==================== stats.* ====================

/// 单域名统计。
class DomainStat {
  const DomainStat({
    required this.domain,
    this.domainKnown = true,
    this.connections = 0,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.lastSeenMs = 0,
    this.rule = '',
    this.rulePayload = '',
    this.outbound = '',
  });

  factory DomainStat.fromJson(Map<String, dynamic> json) => DomainStat(
        domain: _str(json['domain']),
        domainKnown:
            json['domainKnown'] == null ? true : _bool(json['domainKnown']),
        connections: _int(json['connections']),
        uploadBytes: _int(json['uploadBytes']),
        downloadBytes: _int(json['downloadBytes']),
        lastSeenMs: _int(json['lastSeenMs']),
        rule: _str(json['rule']),
        rulePayload: _str(json['rulePayload']),
        outbound: _str(json['outbound']),
      );

  final String domain;
  final bool domainKnown;
  final int connections;
  final int uploadBytes;
  final int downloadBytes;
  final int lastSeenMs;
  final String rule;
  final String rulePayload;
  final String outbound;
}

/// `stats.domain.get` / `stats.get` 响应。
class DomainPage {
  const DomainPage({
    this.domains = const <DomainStat>[],
    this.count = 0,
    this.returned = 0,
    this.capacity = 2048,
    this.domainCap = 2048,
    this.evicted = 0,
    this.rangeMs = 0,
    this.sort = 'bytes',
  });

  factory DomainPage.fromJson(Map<String, dynamic> json) => DomainPage(
        domains: _mapList(json['domains']).map(DomainStat.fromJson).toList(),
        count: _int(json['count']),
        returned: _int(json['returned']),
        capacity: _int(json['capacity']),
        domainCap: _int(json['domainCap']),
        evicted: _int(json['evicted']),
        rangeMs: _int(json['rangeMs']),
        sort: _str(json['sort']),
      );

  final List<DomainStat> domains;
  final int count;
  final int returned;
  final int capacity;
  final int domainCap;
  final int evicted;
  final int rangeMs;
  final String sort;
}

/// `stats.traffic.get` 响应（也是 `proxy.stats` 事件的超集）。
class TrafficSnapshot {
  const TrafficSnapshot({
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.activeConns = 0,
    this.upBps = 0,
    this.downBps = 0,
    this.domainCount = 0,
    this.flowCount = 0,
    this.capacity = 2048,
    this.evicted = 0,
    this.topDomains = const <DomainStat>[],
  });

  factory TrafficSnapshot.fromJson(Map<String, dynamic> json) =>
      TrafficSnapshot(
        uploadBytes: _int(json['uploadBytes']),
        downloadBytes: _int(json['downloadBytes']),
        activeConns: _int(json['activeConns']),
        upBps: _int(json['upBps']),
        downBps: _int(json['downBps']),
        domainCount: _int(json['domainCount']),
        flowCount: _int(json['flowCount']),
        capacity: _int(json['capacity']),
        evicted: _int(json['evicted']),
        topDomains:
            _mapList(json['topDomains']).map(DomainStat.fromJson).toList(),
      );

  final int uploadBytes;
  final int downloadBytes;
  final int activeConns;
  final int upBps;
  final int downBps;
  final int domainCount;

  /// 当前跟踪的活跃流数量（Rust `flowCount`）。
  final int flowCount;
  final int capacity;
  final int evicted;
  final List<DomainStat> topDomains;
}

/// `stats.domain.reset` / `stats.reset` 响应。
class StatsResetResult {
  const StatsResetResult({required this.ok, required this.cleared});

  factory StatsResetResult.fromJson(Map<String, dynamic> json) =>
      StatsResetResult(ok: _bool(json['ok']), cleared: _int(json['cleared']));

  final bool ok;
  final int cleared;
}

// ==================== requests.* ====================

/// `uidState` 三态（`API.md` §2.14）；未知字符串回落 [unknown]。
enum ProxyUidState {
  known('known'),
  pending('pending'),
  unknown('unknown');

  const ProxyUidState(this.wire);

  final String wire;

  static ProxyUidState fromWire(Object? value) {
    final s = value?.toString();
    for (final state in values) {
      if (state.wire == s) return state;
    }
    return ProxyUidState.unknown;
  }
}

/// 一条请求（流）记录（`API.md` §2.14 `RequestRecord`）。
class RequestRecord {
  const RequestRecord({
    required this.recordId,
    required this.connId,
    required this.openTsMs,
    this.closeTsMs,
    this.durationMs,
    required this.domain,
    this.domainKnown = false,
    required this.dstIp,
    this.dstPort = 0,
    required this.src,
    this.network = '',
    this.uid,
    this.packages = const <String>[],
    this.uidState = ProxyUidState.unknown,
    this.rule = '',
    this.rulePayload = '',
    this.outbound = '',
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.closeReason = 'open',
  });

  factory RequestRecord.fromJson(Map<String, dynamic> json) => RequestRecord(
        recordId: _int(json['recordId']),
        connId: _str(json['connId']),
        openTsMs: _int(json['openTsMs']),
        closeTsMs: _intOrNull(json['closeTsMs']),
        durationMs: _intOrNull(json['durationMs']),
        domain: _str(json['domain']),
        domainKnown: _bool(json['domainKnown']),
        dstIp: _str(json['dstIp']),
        dstPort: _int(json['dstPort']),
        src: _str(json['src']),
        network: _str(json['network']),
        uid: _intOrNull(json['uid']),
        packages: _strList(json['packages']),
        uidState: ProxyUidState.fromWire(json['uidState']),
        rule: _str(json['rule']),
        rulePayload: _str(json['rulePayload']),
        outbound: _str(json['outbound']),
        uploadBytes: _int(json['uploadBytes']),
        downloadBytes: _int(json['downloadBytes']),
        closeReason: _str(json['closeReason']),
      );

  final int recordId;
  final String connId;
  final int openTsMs;
  final int? closeTsMs;
  final int? durationMs;
  final String domain;
  final bool domainKnown;
  final String dstIp;
  final int dstPort;
  final String src;
  final String network;
  final int? uid;
  final List<String> packages;
  final ProxyUidState uidState;
  final String rule;
  final String rulePayload;
  final String outbound;
  final int uploadBytes;
  final int downloadBytes;
  final String closeReason;
}

/// `requests.get` 响应（`API.md` §2.14 `RequestPage`）。
class RequestPage {
  const RequestPage({
    this.records = const <RequestRecord>[],
    this.nextCursor = 0,
    this.firstCursor = 0,
    this.retained = 0,
    this.capacity = 4096,
    this.dropped = 0,
    this.evicted = 0,
    this.windowStartMs = 0,
  });

  factory RequestPage.fromJson(Map<String, dynamic> json) => RequestPage(
        records: _mapList(json['records']).map(RequestRecord.fromJson).toList(),
        nextCursor: _int(json['nextCursor']),
        firstCursor: _int(json['firstCursor']),
        retained: _int(json['retained']),
        capacity: _int(json['capacity']),
        dropped: _int(json['dropped']),
        evicted: _int(json['evicted']),
        windowStartMs: _int(json['windowStartMs']),
      );

  final List<RequestRecord> records;
  final int nextCursor;
  final int firstCursor;
  final int retained;
  final int capacity;
  final int dropped;
  final int evicted;
  final int windowStartMs;
}

/// `requests.reset` 响应（镜像 [StatsResetResult]）。
class RequestsResetResult {
  const RequestsResetResult({required this.ok, required this.cleared});

  factory RequestsResetResult.fromJson(Map<String, dynamic> json) =>
      RequestsResetResult(
        ok: _bool(json['ok']),
        cleared: _int(json['cleared']),
      );

  final bool ok;
  final int cleared;
}

/// `requests.export` 响应（`API.md` §2.14 `RequestExportResult`）。
///
/// 记录**只写入文件**，本响应仅回传路径/计数/字节数；未请求的产物其路径键
/// 缺省（解码为 `null`）。
class RequestExportResult {
  const RequestExportResult({
    this.csvPath,
    this.jsonPath,
    this.rows = 0,
    this.bytes = 0,
    this.generatedAtMs = 0,
  });

  factory RequestExportResult.fromJson(Map<String, dynamic> json) =>
      RequestExportResult(
        csvPath: json['csvPath']?.toString(),
        jsonPath: json['jsonPath']?.toString(),
        rows: _int(json['rows']),
        bytes: _int(json['bytes']),
        generatedAtMs: _int(json['generatedAtMs']),
      );

  final String? csvPath;
  final String? jsonPath;
  final int rows;
  final int bytes;
  final int generatedAtMs;
}

// ==================== diagnostics.* ====================

/// `diagnostics.clash_api.start` / `.status` 响应（**无 secret 字段**）。
class ClashApiStatus {
  const ClashApiStatus({
    required this.enabled,
    required this.bound,
    this.address,
    this.loopbackOnly = true,
    this.port,
  });

  factory ClashApiStatus.fromJson(Map<String, dynamic> json) => ClashApiStatus(
        enabled: _bool(json['enabled']),
        bound: _bool(json['bound']),
        address: json['address']?.toString(),
        loopbackOnly: json.containsKey('loopbackOnly')
            ? _bool(json['loopbackOnly'])
            : true,
        port: _intOrNull(json['port']),
      );

  final bool enabled;
  final bool bound;
  final String? address;
  final bool loopbackOnly;
  final int? port;

  /// 是否确实只绑定了回环地址。
  bool get isLoopbackOnly =>
      address == null || address!.startsWith('127.0.0.1:');
}

/// `diagnostics.clash_api.stop` 响应。
class ClashApiStopResult {
  const ClashApiStopResult({required this.enabled, required this.wasRunning});

  factory ClashApiStopResult.fromJson(Map<String, dynamic> json) =>
      ClashApiStopResult(
        enabled: _bool(json['enabled']),
        wasRunning: _bool(json['wasRunning']),
      );

  final bool enabled;
  final bool wasRunning;
}

// ==================== lan.* ====================

/// LAN 入站配置（`API.md` §2.12 `LanConfig`）。
///
/// `lan.get` 响应中的 `config`；`lan.set` 的请求体（部分字段）。
class ProxyLanConfig {
  const ProxyLanConfig({
    this.enabled = false,
    this.port = 1087,
    this.bindAddress = '0.0.0.0',
    this.authUser = '',
    this.authPass = '',
    this.allowedIps = const <String>[],
  });

  final bool enabled;
  final int port;
  final String bindAddress;
  final String authUser;
  final String authPass;
  final List<String> allowedIps;

  /// 是否同时配置了用户名与密码。
  bool get hasAuth => authUser.trim().isNotEmpty && authPass.isNotEmpty;

  /// 已启用但未配置认证 → 必须展示安全警告。
  bool get needsWarning => enabled && !hasAuth;

  /// `lan.set` 请求体；`auth` 未配置时为显式 `null`（可清除已有认证）。
  Map<String, dynamic> toRequestJson() => <String, dynamic>{
        'enabled': enabled,
        'port': port,
        'bindAddress': bindAddress,
        'auth': hasAuth
            ? <String, dynamic>{'user': authUser, 'pass': authPass}
            : null,
        'allowedIps': allowedIps,
      };

  factory ProxyLanConfig.fromJson(Map<String, dynamic> json) {
    final auth = json['auth'];
    return ProxyLanConfig(
      enabled: json['enabled'] == true,
      port: _intOrNull(json['port']) ?? 1087,
      bindAddress: json['bindAddress']?.toString() ?? '0.0.0.0',
      authUser: auth is Map ? (auth['user']?.toString() ?? '') : '',
      authPass: auth is Map ? (auth['pass']?.toString() ?? '') : '',
      allowedIps: _strList(json['allowedIps']),
    );
  }

  ProxyLanConfig copyWith({
    bool? enabled,
    int? port,
    String? bindAddress,
    String? authUser,
    String? authPass,
    List<String>? allowedIps,
  }) =>
      ProxyLanConfig(
        enabled: enabled ?? this.enabled,
        port: port ?? this.port,
        bindAddress: bindAddress ?? this.bindAddress,
        authUser: authUser ?? this.authUser,
        authPass: authPass ?? this.authPass,
        allowedIps: allowedIps ?? this.allowedIps,
      );
}

/// LAN 监听状态（`API.md` §2.12 `LanStatus`）。
///
/// `lan.status` 的**扁平**响应，也是 `lan.set` 响应中嵌套的 `status`。
class ProxyLanStatus {
  const ProxyLanStatus({
    this.bound = false,
    this.addresses = const <String>[],
    this.activeConns = 0,
    this.engineOnly = false,
    this.warning,
    this.config,
  });

  final bool bound;
  final List<String> addresses;
  final int activeConns;
  final bool engineOnly;
  final String? warning;
  final ProxyLanConfig? config;

  /// 是否携带安全警告（`warning.message` 非空）。
  bool get hasWarning => warning != null && warning!.isNotEmpty;

  factory ProxyLanStatus.fromJson(Map<String, dynamic> json) {
    final warning = json['warning'];
    final config = json['config'];
    return ProxyLanStatus(
      bound: json['bound'] == true,
      addresses: _strList(json['addresses']),
      activeConns: _intOrNull(json['activeConns']) ?? 0,
      engineOnly: json['engineOnly'] == true,
      warning: warning is Map ? warning['message']?.toString() : null,
      config: config is Map
          ? ProxyLanConfig.fromJson(Map<String, dynamic>.from(config))
          : null,
    );
  }
}

// ==================== 方法 → 解码器注册表 ====================

/// 方法名 → 响应解码器（**每个** [ProxyMethods.all] 一项）。
///
/// 别名方法（`dns.flush_cache` / `stats.get` / `stats.reset`）复用同一模型。
final Map<String, ProxyJsonDecoder<Object>> proxyResponseDecoders =
    <String, ProxyJsonDecoder<Object>>{
  ProxyMethods.ping: ProxyPingResult.fromJson,
  ProxyMethods.version: ProxyVersionInfo.fromJson,
  ProxyMethods.tunSetFd: TunSetFdResult.fromJson,
  ProxyMethods.coreStart: ProxyCoreStatus.fromJson,
  ProxyMethods.coreStop: CoreStopResult.fromJson,
  ProxyMethods.coreRestart: ProxyCoreStatus.fromJson,
  ProxyMethods.coreGetMode: CoreModeResult.fromJson,
  ProxyMethods.coreSetMode: CoreSetModeResult.fromJson,
  ProxyMethods.routingGetMode: RoutingModeResult.fromJson,
  ProxyMethods.routingSetMode: RoutingModeSetResult.fromJson,
  ProxyMethods.dnsGet: DnsSnapshot.fromJson,
  ProxyMethods.dnsSet: DnsSetResult.fromJson,
  ProxyMethods.dnsClearCache: DnsClearResult.fromJson,
  ProxyMethods.dnsFlushCache: DnsClearResult.fromJson,
  ProxyMethods.logGet: LogPage.fromJson,
  ProxyMethods.logSetLevel: LogSetLevelResult.fromJson,
  ProxyMethods.logClear: OkResult.fromJson,
  ProxyMethods.rulesGet: RulesSnapshot.fromJson,
  ProxyMethods.rulesReload: RulesSnapshot.fromJson,
  ProxyMethods.configGenerate: GeneratedConfig.fromJson,
  ProxyMethods.configApply: GeneratedConfig.fromJson,
  ProxyMethods.profileExportClash: GeneratedConfig.fromJson,
  ProxyMethods.profileImportUrl: ImportedProfile.fromJson,
  ProxyMethods.profileImportText: ImportedProfile.fromJson,
  ProxyMethods.profileImportLink: ImportedProfile.fromJson,
  ProxyMethods.profileList: ProfileList.fromJson,
  ProxyMethods.profileGet: StoredProfile.fromJson,
  ProxyMethods.profileCreate: StoredProfile.fromJson,
  ProxyMethods.profileUpdate: StoredProfile.fromJson,
  ProxyMethods.profileDelete: ProfileDeleteResult.fromJson,
  ProxyMethods.profileRefresh: RefreshResult.fromJson,
  ProxyMethods.profileRefreshAll: RefreshAllResult.fromJson,
  ProxyMethods.profileSetSchedule: StoredProfile.fromJson,
  ProxyMethods.nodeSelect: NodeSelectResult.fromJson,
  ProxyMethods.nodeDelayTest: DelayTestResult.fromJson,
  ProxyMethods.nodeList: NodeListResult.fromJson,
  ProxyMethods.connList: ConnPage.fromJson,
  ProxyMethods.connClose: ConnCloseResult.fromJson,
  ProxyMethods.connCloseAll: ConnCloseAllResult.fromJson,
  ProxyMethods.statsDomainGet: DomainPage.fromJson,
  ProxyMethods.statsDomainReset: StatsResetResult.fromJson,
  ProxyMethods.statsTrafficGet: TrafficSnapshot.fromJson,
  ProxyMethods.statsGet: DomainPage.fromJson,
  ProxyMethods.statsReset: StatsResetResult.fromJson,
  ProxyMethods.requestsGet: RequestPage.fromJson,
  ProxyMethods.requestsReset: RequestsResetResult.fromJson,
  ProxyMethods.requestsExport: RequestExportResult.fromJson,
  ProxyMethods.clashApiStart: ClashApiStatus.fromJson,
  ProxyMethods.clashApiStop: ClashApiStopResult.fromJson,
  ProxyMethods.clashApiStatus: ClashApiStatus.fromJson,
  // `lan.get` 的 `config` 在顶层字段下；`lan.set` 的 status **嵌套**在 `status`
  // 之下（`lib.rs` `lan_set_arm`）；`lan.status` 是扁平对象。
  ProxyMethods.lanGet: (json) => ProxyLanConfig.fromJson(
        Map<String, dynamic>.from(
          json['config'] as Map? ?? const <String, dynamic>{},
        ),
      ),
  ProxyMethods.lanSet: (json) => ProxyLanStatus.fromJson(
        Map<String, dynamic>.from(
          json['status'] as Map? ?? const <String, dynamic>{},
        ),
      ),
  ProxyMethods.lanStatus: ProxyLanStatus.fromJson,
};

// ==================== 请求模型（toJson） ====================

/// `tun.set_fd` 请求。
class TunSetFdRequest {
  const TunSetFdRequest(this.fd);

  final int fd;

  Map<String, dynamic> toJson() => <String, dynamic>{'fd': fd};
}

/// `core.start` / `core.restart` 请求。
class CoreStartRequest {
  const CoreStartRequest({
    this.mode = 'vpn',
    this.profileId,
    this.stack,
    this.mtu,
    this.dns,
    this.rules,
  });

  final String mode;
  final String? profileId;
  final String? stack;
  final int? mtu;
  final Map<String, dynamic>? dns;
  final List<String>? rules;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode,
        if (profileId != null) 'profileId': profileId,
        if (stack != null) 'stack': stack,
        if (mtu != null) 'mtu': mtu,
        if (dns != null) 'dns': dns,
        if (rules != null) 'rules': rules,
      };
}

/// `core.set_mode` 请求。
class CoreSetModeRequest {
  const CoreSetModeRequest(this.mode);

  final String mode;

  Map<String, dynamic> toJson() => <String, dynamic>{'mode': mode};
}

/// `routing.set_mode` 请求。
class RoutingSetModeRequest {
  const RoutingSetModeRequest(this.mode);

  final String mode;

  Map<String, dynamic> toJson() => <String, dynamic>{'mode': mode};
}

/// `log.get` 请求。
class LogGetRequest {
  const LogGetRequest({this.sinceCursor, this.limit, this.level});

  final int? sinceCursor;
  final int? limit;
  final String? level;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (sinceCursor != null) 'sinceCursor': sinceCursor,
        if (limit != null) 'limit': limit,
        if (level != null) 'level': level,
      };
}

/// `log.set_level` 请求。
class LogSetLevelRequest {
  const LogSetLevelRequest(this.level);

  final String level;

  Map<String, dynamic> toJson() => <String, dynamic>{'level': level};
}

/// `rules.reload` 请求。
class RulesReloadRequest {
  const RulesReloadRequest({this.config, this.configPath, this.geo});

  final String? config;
  final String? configPath;
  final Map<String, dynamic>? geo;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (config != null) 'config': config,
        if (configPath != null) 'configPath': configPath,
        if (geo != null) 'geo': geo,
      };
}

/// `config.generate` / `config.apply` 请求。
class GenerateRequest {
  const GenerateRequest({
    this.profileId,
    this.stack,
    this.mtu,
    this.dns,
    this.rules,
  });

  final String? profileId;
  final String? stack;
  final int? mtu;
  final Map<String, dynamic>? dns;
  final List<String>? rules;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (profileId != null) 'profileId': profileId,
        if (stack != null) 'stack': stack,
        if (mtu != null) 'mtu': mtu,
        if (dns != null) 'dns': dns,
        if (rules != null) 'rules': rules,
      };
}

/// `profile.export_clash` 请求。
class ProfileExportRequest {
  const ProfileExportRequest({
    required this.id,
    this.stack,
    this.mtu,
    this.dns,
    this.rules,
  });

  final String id;
  final String? stack;
  final int? mtu;
  final Map<String, dynamic>? dns;
  final List<String>? rules;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (stack != null) 'stack': stack,
        if (mtu != null) 'mtu': mtu,
        if (dns != null) 'dns': dns,
        if (rules != null) 'rules': rules,
      };
}

/// 按 `id` 定位存储 profile 的请求（`get` / `delete` / `refresh`）。
class ProfileIdRequest {
  const ProfileIdRequest(this.id, {this.force});

  final String id;
  final bool? force;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (force != null) 'force': force,
      };
}

/// `profile.create` 请求。
class ProfileCreateRequest {
  const ProfileCreateRequest({
    required this.profile,
    this.id,
    this.name,
    this.appBackup,
  });

  final ImportedProfile profile;
  final String? id;
  final String? name;
  final Object? appBackup;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'profile': profile.toJson(),
        if (id != null) 'id': id,
        if (name != null) 'name': name,
        if (appBackup != null) 'appBackup': appBackup,
      };
}

/// `profile.refresh_all` 请求。
class ProfileRefreshAllRequest {
  const ProfileRefreshAllRequest({this.force, this.limit});

  final bool? force;
  final int? limit;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (force != null) 'force': force,
        if (limit != null) 'limit': limit,
      };
}

/// `profile.set_schedule` 请求。
class ProfileSetScheduleRequest {
  const ProfileSetScheduleRequest({required this.id, this.intervalMs});

  final String id;
  final int? intervalMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (intervalMs != null) 'intervalMs': intervalMs,
      };
}

/// `node.select` 请求。
class NodeSelectRequest {
  const NodeSelectRequest({required this.group, required this.node});

  final String group;
  final String node;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'group': group, 'node': node};
}

/// `node.delay_test` 请求。
class NodeDelayTestRequest {
  const NodeDelayTestRequest({
    this.node,
    this.group,
    this.targets = const <String>[],
    this.url,
    this.expectedStatus,
    this.timeoutMs,
  });

  final String? node;
  final String? group;

  /// 显式探测的节点名集合（「测试全部」使用）；空则省略该键。
  final List<String> targets;
  final String? url;
  final String? expectedStatus;
  final int? timeoutMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (node != null) 'node': node,
        if (group != null) 'group': group,
        if (targets.isNotEmpty) 'targets': targets,
        if (url != null) 'url': url,
        if (expectedStatus != null) 'expectedStatus': expectedStatus,
        if (timeoutMs != null) 'timeoutMs': timeoutMs,
      };
}

/// `conn.list` 请求。
class ConnListRequest {
  const ConnListRequest({this.offset, this.limit, this.domain, this.outbound});

  final int? offset;
  final int? limit;
  final String? domain;
  final String? outbound;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (offset != null) 'offset': offset,
        if (limit != null) 'limit': limit,
        if (domain != null) 'domain': domain,
        if (outbound != null) 'outbound': outbound,
      };
}

/// `conn.close` 请求。
class ConnCloseRequest {
  const ConnCloseRequest(this.id);

  final String id;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id};
}

/// `stats.domain.get` 请求。
class StatsDomainGetRequest {
  const StatsDomainGetRequest({this.rangeMs, this.sort, this.limit});

  final int? rangeMs;
  final String? sort;
  final int? limit;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (rangeMs != null) 'rangeMs': rangeMs,
        if (sort != null) 'sort': sort,
        if (limit != null) 'limit': limit,
      };
}

/// `stats.traffic.get` 请求。
class StatsTrafficGetRequest {
  const StatsTrafficGetRequest({this.topDomains});

  final int? topDomains;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{if (topDomains != null) 'topDomains': topDomains};
}

/// `requests.get` 过滤器（`API.md` §2.14）；未提供的字段不编码。
class RequestsFilter {
  const RequestsFilter({
    this.domain,
    this.uid,
    this.network,
    this.outbound,
    this.sinceMs,
    this.untilMs,
  });

  final String? domain;
  final int? uid;
  final String? network;
  final String? outbound;
  final int? sinceMs;
  final int? untilMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (domain != null) 'domain': domain,
        if (uid != null) 'uid': uid,
        if (network != null) 'network': network,
        if (outbound != null) 'outbound': outbound,
        if (sinceMs != null) 'sinceMs': sinceMs,
        if (untilMs != null) 'untilMs': untilMs,
      };
}

/// `requests.get` 请求（`API.md` §2.14）。
class RequestGetRequest {
  const RequestGetRequest({this.cursor, this.limit, this.filter});

  final int? cursor;
  final int? limit;
  final RequestsFilter? filter;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
        if (filter != null) 'filter': filter!.toJson(),
      };
}

/// `diagnostics.clash_api.start` 请求。
class ClashApiStartRequest {
  const ClashApiStartRequest({this.port = 0});

  final int port;

  Map<String, dynamic> toJson() => <String, dynamic>{'port': port};
}

/// `requests.export` 请求（`API.md` §2.14）；`filter` 与 `requests.get` 同形，
/// 未提供的键不编码（后端 `format` 缺省为 `both`）。
class RequestExportRequest {
  const RequestExportRequest({this.format, this.filter});

  final String? format;
  final RequestsFilter? filter;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (format != null) 'format': format,
        if (filter != null) 'filter': filter!.toJson(),
      };
}

/// 名称 → 请求模型 `toJson`（契约自检：每个无参方法不在此列）。
final Map<String, Map<String, dynamic> Function()> proxyRequestEncoders =
    <String, Map<String, dynamic> Function()>{
  ProxyMethods.tunSetFd: () => const TunSetFdRequest(0).toJson(),
  ProxyMethods.coreStart: () => const CoreStartRequest().toJson(),
  ProxyMethods.coreRestart: () => const CoreStartRequest().toJson(),
  ProxyMethods.coreSetMode: () => const CoreSetModeRequest('vpn').toJson(),
  ProxyMethods.routingSetMode: () =>
      const RoutingSetModeRequest('rule').toJson(),
  ProxyMethods.dnsSet: () => const DnsConfig().toJson(),
  ProxyMethods.logGet: () => const LogGetRequest().toJson(),
  ProxyMethods.logSetLevel: () => const LogSetLevelRequest('info').toJson(),
  ProxyMethods.rulesReload: () => const RulesReloadRequest().toJson(),
  ProxyMethods.configGenerate: () => const GenerateRequest().toJson(),
  ProxyMethods.configApply: () => const GenerateRequest().toJson(),
  ProxyMethods.profileExportClash: () =>
      const ProfileExportRequest(id: 'p1').toJson(),
  ProxyMethods.profileGet: () => const ProfileIdRequest('p1').toJson(),
  ProxyMethods.profileCreate: () => const ProfileCreateRequest(
        profile: ImportedProfile(name: 'p', format: 'clash'),
      ).toJson(),
  ProxyMethods.profileDelete: () => const ProfileIdRequest('p1').toJson(),
  ProxyMethods.profileRefresh: () => const ProfileIdRequest('p1').toJson(),
  ProxyMethods.profileRefreshAll: () =>
      const ProfileRefreshAllRequest().toJson(),
  ProxyMethods.profileSetSchedule: () =>
      const ProfileSetScheduleRequest(id: 'p1').toJson(),
  ProxyMethods.nodeSelect: () =>
      const NodeSelectRequest(group: 'G', node: 'A').toJson(),
  ProxyMethods.nodeDelayTest: () => const NodeDelayTestRequest().toJson(),
  ProxyMethods.connList: () => const ConnListRequest().toJson(),
  ProxyMethods.connClose: () => const ConnCloseRequest('c1').toJson(),
  ProxyMethods.statsDomainGet: () => const StatsDomainGetRequest().toJson(),
  ProxyMethods.statsTrafficGet: () => const StatsTrafficGetRequest().toJson(),
  ProxyMethods.requestsGet: () => const RequestGetRequest().toJson(),
  ProxyMethods.requestsExport: () => const RequestExportRequest().toJson(),
  ProxyMethods.clashApiStart: () => const ClashApiStartRequest().toJson(),
  ProxyMethods.lanSet: () => const ProxyLanConfig().toRequestJson(),
};

/// 便捷：JSON 文本 → UTF-8 字节（请求体编码）。
Uint8List encodeProxyPayload(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

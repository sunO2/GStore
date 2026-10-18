/// Wave 4 · GPU 控制动作（**能力门控**，无 root）。
///
/// [GpuControlAction.applyGpuPolicy] 用 `perf.tunables` **枚举出的** GPU 控制节点
/// 施加一次策略（governor / 最小·最大频率 / 最小·最大功耗档位），并复刻 toes 16 的
/// 协议：**校验 → 探测可写性 → 写入（带哨兵）→ 回读对账 → 失败回滚**。
///
/// ## 单点职责
/// 本文件**只**做 GPU 控制；不碰 CPU / cpuset / thermal / 热区，不做持久化，
/// 不注册回滚会话（Todo 20 负责跨动作 revert）。调用方必须先经 Todo 15 的能力
/// 探测（本层亦会在动作内**再次** `test -w` 探测，双重 fail-closed）。
///
/// ## FAIL-CLOSED（不可协商）
/// * 入参非法（危险字符 / 越界 / 不在 `perf.tunables` 提供的可用集合内）
///   → `rejected`，**零命令**（连探测都不发）。
/// * 某请求旋钮**没有任何** 「可写（`test -w` 通过）且可读（回读得到原值）」的
///   候选节点 → `unavailable`，**零写入**（只发只读探测命令）。
/// * 写入失败 / 回读与原值不符（含「哨兵假成功」`; ok=1` 之类）→ 回滚已写节点后
///   返回 `failed`。**绝不**把「哨兵 ok=1」当作成功，必须回读对账。
///
/// ## 节点来源（绝不猜测厂商节点）
/// 仅由 [PerfGpuTunables] 暴露的**来源路径**推导其同级控制叶子：
/// * `governorSource` / `freqSource` / `powerSource` 的父目录；
/// * devfreq 目录 → `governor` / `min_freq` / `max_freq`；
/// * kgsl-3d0 根目录 → `governor` / `min_gpuclk` / `max_gpuclk` /
///   `min_pwrlevel` / `max_pwrlevel`。
/// 推导出的路径仍必须命中 [kGpuControlAllowlist]，否则**判不可用、不发命令**。
///
/// ## 回读为何走特权 shell 而非 `perf.sysfs.read`
/// `perf.sysfs.read` 以 **App 进程 uid** 读取，非 world-readable 节点会读不到；
/// 这里经**同一条特权 shell**（uid 2000）回读，保证写入侧与校验侧的 uid/上下文
/// 一致（Todo 12 的关键提示）。调用方如需替换读取器可注入 [GpuNodeReader]。
library;

import 'package:gstore/core/perf/privileged_shell.dart';
import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';

// ==================== 白名单 ====================

/// GPU 控制**写**白名单：默认写白名单 + kgsl-3d0 `governor` / 功耗档位节点。
///
/// `kDefaultSysfsAllowlist` 缺 kgsl `governor` 与 `min|max_pwrlevel`
/// （Todo 15 的探测白名单已补齐；本层复用同一组扩展，供真正写入时校验）。
const List<String> kGpuControlAllowlist = <String>[
  ...kDefaultSysfsAllowlist,
  '/sys/class/kgsl/kgsl-3d0/devfreq/governor',
  '/sys/class/kgsl/kgsl-3d0/governor',
  '/sys/class/kgsl/kgsl-3d0/min_pwrlevel',
  '/sys/class/kgsl/kgsl-3d0/max_pwrlevel',
];

// ==================== 错误码 ====================

/// GPU 控制动作的结构化错误码（[GpuPolicyResult.error] 的取值）。
abstract final class GpuControlError {
  /// 无任何可写 GPU 控制节点（零写入）。
  static const String unavailable = 'unavailable';

  /// 写入命令失败。
  static const String writeFailed = 'write_failed';

  /// 回读值与被写值不符（含哨兵假成功）。
  static const String readbackMismatch = 'readback_mismatch';

  /// 入参非法（危险字符 / 越界 / 不在可用集合内）。
  static const String rejected = 'rejected';
}

// ==================== 策略与结果模型 ====================

/// 一次 GPU 控制策略：仅包含**调用方请求**的旋钮（未指定的旋钮不改动）。
///
/// * [governor]：GPU governor 名（token，禁危险字符）。
/// * [minFreqMhz] / [maxFreqMhz]：GPU 频率（MHz，须命中
///   `perf.tunables` 的 `available_frequencies_mhz`）；写入时换算为 Hz。
/// * [minPwrlevel] / [maxPwrlevel]：kgsl 功耗档位索引（0 起，须 `< power_levels`）。
class GpuPolicy {
  const GpuPolicy({
    this.governor,
    this.minFreqMhz,
    this.maxFreqMhz,
    this.minPwrlevel,
    this.maxPwrlevel,
  });

  /// GPU governor 名（可空 = 不改）。
  final String? governor;

  /// 最小频率（MHz，可空 = 不改）。
  final double? minFreqMhz;

  /// 最大频率（MHz，可空 = 不改）。
  final double? maxFreqMhz;

  /// 最小功耗档位（可空 = 不改）。
  final int? minPwrlevel;

  /// 最大功耗档位（可空 = 不改）。
  final int? maxPwrlevel;

  /// 是否未请求任何旋钮。
  bool get isEmpty =>
      governor == null &&
      minFreqMhz == null &&
      maxFreqMhz == null &&
      minPwrlevel == null &&
      maxPwrlevel == null;
}

/// 动作状态。
enum GpuPolicyStatus {
  /// 全部请求旋钮已写入且回读对账通过。
  applied,

  /// 存在请求旋钮无「可写且可读」节点 → 零写入。
  unavailable,

  /// 入参非法 → 零命令。
  rejected,

  /// 写入失败 / 回读不符 → 已回滚。
  failed,
}

/// 一次实际发出的节点写（含回滚标记）。
class GpuPolicyWrite {
  GpuPolicyWrite({
    required this.path,
    required this.value,
    required this.previousValue,
  });

  /// 目标节点路径。
  final String path;

  /// 写入值（原样字符串）。
  final String value;

  /// 写入前的原值（回滚依据）。
  final String previousValue;

  /// 是否已成功回滚到 [previousValue]。
  bool rolledBack = false;

  @override
  String toString() =>
      'GpuPolicyWrite($path=$value, prev=$previousValue, rolledBack=$rolledBack)';
}

/// [GpuControlAction.applyGpuPolicy] 的结构化结果。
class GpuPolicyResult {
  const GpuPolicyResult._({
    required this.status,
    this.error,
    this.reason,
    this.writes = const <GpuPolicyWrite>[],
  });

  /// 成功：已写入并回读对账通过。
  factory GpuPolicyResult.applied(List<GpuPolicyWrite> writes) =>
      GpuPolicyResult._(status: GpuPolicyStatus.applied, writes: writes);

  /// 无任何可写 GPU 控制节点（**零写入**）。
  factory GpuPolicyResult.unavailable(String reason) => GpuPolicyResult._(
        status: GpuPolicyStatus.unavailable,
        error: GpuControlError.unavailable,
        reason: reason,
      );

  /// 入参非法（**零命令**）。
  factory GpuPolicyResult.rejected(String error, String reason) =>
      GpuPolicyResult._(
        status: GpuPolicyStatus.rejected,
        error: error,
        reason: reason,
      );

  /// 写入 / 回读失败（已回滚）。
  factory GpuPolicyResult.failed(
    String error,
    String reason, {
    required List<GpuPolicyWrite> writes,
  }) =>
      GpuPolicyResult._(
        status: GpuPolicyStatus.failed,
        error: error,
        reason: reason,
        writes: writes,
      );

  /// 动作状态。
  final GpuPolicyStatus status;

  /// 结构化错误码（成功为 `null`）。
  final String? error;

  /// 可读原因（日志 / 证据）。
  final String? reason;

  /// **实际发出的**节点写（含失败 / 已回滚的写；用于「零写入」断言）。
  final List<GpuPolicyWrite> writes;

  /// 是否成功。
  bool get applied => status == GpuPolicyStatus.applied;

  /// 是否因无节点而不可用。
  bool get isUnavailable => status == GpuPolicyStatus.unavailable;

  /// 是否入参非法。
  bool get isRejected => status == GpuPolicyStatus.rejected;

  /// 实际写命令数（「零写入」判定依据）。
  int get writeCount => writes.length;

  /// 已成功回滚的写数。
  int get rollbackCount => writes.where((w) => w.rolledBack).length;

  /// 可序列化摘要（证据 / 日志）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'status': status.name,
        if (error != null) 'error': error,
        if (reason != null) 'reason': reason,
        'write_count': writeCount,
        'rollback_count': rollbackCount,
        'writes': <Map<String, dynamic>>[
          for (final w in writes)
            <String, dynamic>{
              'path': w.path,
              'value': w.value,
              'previous_value': w.previousValue,
              'rolled_back': w.rolledBack,
            },
        ],
      };

  @override
  String toString() => 'GpuPolicyResult(${status.name}, error: $error, '
      'writes: $writeCount, rollbacks: $rollbackCount)';
}

// ==================== 可注入依赖 ====================

/// 加载 `perf.tunables`（生产经模块门面；测试可覆盖）。
typedef GpuTunablesLoader = Future<TunablesReport> Function();

/// 读取单个节点当前值；读不到返回 `null`。
typedef GpuNodeReader = Future<String?> Function(String path);

// ==================== 动作实现 ====================

/// 一次请求旋钮（标签 + 候选节点 + 待写值）。
class _KnobRequest {
  const _KnobRequest({
    required this.label,
    required this.candidates,
    required this.value,
  });

  final String label;
  final List<String> candidates;
  final String value;
}

/// 已解析（可写且可读）的目标节点。
class _GpuTarget {
  const _GpuTarget({required this.path, required this.value});

  final String path;
  final String value;
}

/// GPU 控制动作（无 root，经 Shizuku 特权 shell）。
///
/// 生产：`GpuControlAction(shell: PrivilegedShell())`。
/// 测试：注入带假 [CommandRunner] 的 [PrivilegedShell]，**无需 Shizuku / 真机**。
class GpuControlAction {
  GpuControlAction({
    required PrivilegedShell shell,
    PrivilegedInputValidator? validator,
    GpuTunablesLoader? tunablesLoader,
    GpuNodeReader? reader,
  })  : _shell = shell,
        _validator = validator ??
            PrivilegedInputValidator(sysfsPatterns: kGpuControlAllowlist),
        _loadTunables = tunablesLoader ?? (() => PerfModule.instance.tunables()),
        _reader = reader;

  final PrivilegedShell _shell;
  final PrivilegedInputValidator _validator;
  final GpuTunablesLoader _loadTunables;
  final GpuNodeReader? _reader;

  /// 施加一次 GPU 策略。
  ///
  /// [tunables] 省略时经 [_loadTunables]（生产 = `PerfModule.instance.tunables()`）
  /// 加载；测试应直接传入罐头报告。本方法**绝不抛出**，一律返回结构化结果。
  Future<GpuPolicyResult> applyGpuPolicy(
    GpuPolicy policy, {
    TunablesReport? tunables,
  }) async {
    // 1) 结构校验（零命令）。
    if (policy.isEmpty) {
      return GpuPolicyResult.rejected('empty_policy', '策略未包含任何旋钮');
    }
    final structural = _validateStructure(policy);
    if (structural != null) return structural;

    // 2) 取 tunables（范围 / 可用集合校验依赖它）。
    final TunablesReport report;
    if (tunables != null) {
      report = tunables;
    } else {
      try {
        report = await _loadTunables();
      } catch (_) {
        return GpuPolicyResult.unavailable('tunables_unavailable');
      }
    }
    final gpu = report.gpu;

    // 3) 范围 / 可用集合校验（零命令）。
    final range = _validateRanges(policy, gpu);
    if (range != null) return range;

    // 4) 解析 + 探测（仅只读命令）。
    final requests = _requests(policy, gpu);
    final targets = <_GpuTarget>[];
    final unresolved = <String>[];
    for (final req in requests) {
      final target = await _resolve(req);
      if (target == null) {
        unresolved.add(req.label);
      } else {
        targets.add(target);
      }
    }
    if (unresolved.isNotEmpty) {
      return GpuPolicyResult.unavailable(
        'no writable GPU control node for: ${unresolved.join(", ")}',
      );
    }

    // 5) 写入（带哨兵）。
    final writes = <GpuPolicyWrite>[];
    for (final target in targets) {
      final previous = await _readNode(target.path) ?? '';
      final write = GpuPolicyWrite(
        path: target.path,
        value: target.value,
        previousValue: previous,
      );
      writes.add(write);
      final result = await _writeNode(target.path, target.value);
      if (!result.ok) {
        await _rollback(writes);
        return GpuPolicyResult.failed(
          GpuControlError.writeFailed,
          'write denied: ${target.path} (${result.error ?? "unknown"})',
          writes: writes,
        );
      }
    }

    // 6) 回读对账（哨兵 ok=1 不算成功）。
    for (final write in writes) {
      final actual = await _readNode(write.path);
      if (actual == null || !_sameValue(actual, write.value)) {
        await _rollback(writes);
        return GpuPolicyResult.failed(
          GpuControlError.readbackMismatch,
          'read-back mismatch at ${write.path}: '
              'wrote ${write.value}, read ${actual ?? "null"}',
          writes: writes,
        );
      }
    }

    return GpuPolicyResult.applied(writes);
  }

  // ==================== 校验 ====================

  GpuPolicyResult? _validateStructure(GpuPolicy policy) {
    final governor = policy.governor;
    if (governor != null) {
      final reason = _validator.tokenReason(governor);
      if (reason != null) {
        return GpuPolicyResult.rejected(
          PrivilegedError.invalidArg,
          'governor: $reason',
        );
      }
    }
    for (final level in <int?>[policy.minPwrlevel, policy.maxPwrlevel]) {
      if (level != null && level < 0) {
        return GpuPolicyResult.rejected(
          PrivilegedError.invalidArg,
          'pwrlevel must be >= 0',
        );
      }
    }
    return null;
  }

  GpuPolicyResult? _validateRanges(GpuPolicy policy, PerfGpuTunables gpu) {
    final available = gpu.availableFrequenciesMhz;
    final minFreq = policy.minFreqMhz;
    final maxFreq = policy.maxFreqMhz;
    if (minFreq != null) {
      final reason = _checkFreq(minFreq, available, 'min_freq_mhz');
      if (reason != null) return reason;
    }
    if (maxFreq != null) {
      final reason = _checkFreq(maxFreq, available, 'max_freq_mhz');
      if (reason != null) return reason;
    }
    if (minFreq != null && maxFreq != null && minFreq > maxFreq) {
      return GpuPolicyResult.rejected(
        PrivilegedError.invalidArg,
        'min_freq_mhz > max_freq_mhz',
      );
    }

    final levels = gpu.powerLevels;
    final minLevel = policy.minPwrlevel;
    final maxLevel = policy.maxPwrlevel;
    for (final entry in <MapEntry<String, int?>>[
      MapEntry('min_pwrlevel', minLevel),
      MapEntry('max_pwrlevel', maxLevel),
    ]) {
      final value = entry.value;
      if (value == null) continue;
      if (levels != null && value >= levels) {
        return GpuPolicyResult.rejected(
          PrivilegedError.invalidArg,
          '${entry.key}=$value out of range (power_levels=$levels)',
        );
      }
    }
    if (minLevel != null && maxLevel != null && minLevel > maxLevel) {
      return GpuPolicyResult.rejected(
        PrivilegedError.invalidArg,
        'min_pwrlevel > max_pwrlevel',
      );
    }
    return null;
  }

  GpuPolicyResult? _checkFreq(
    double mhz,
    List<double> available,
    String label,
  ) {
    if (!mhz.isFinite || mhz <= 0) {
      return GpuPolicyResult.rejected(
        PrivilegedError.invalidArg,
        '$label must be a positive finite number',
      );
    }
    if (available.isEmpty) {
      return GpuPolicyResult.rejected(
        PrivilegedError.invalidArg,
        '$label unverifiable: perf.tunables exposes no GPU frequencies',
      );
    }
    final ok = available.any((f) => (f - mhz).abs() < 0.001);
    if (!ok) {
      return GpuPolicyResult.rejected(
        PrivilegedError.invalidArg,
        '$label=$mhz MHz not in available frequencies',
      );
    }
    return null;
  }

  // ==================== 旋钮 → 候选节点 ====================

  List<_KnobRequest> _requests(GpuPolicy policy, PerfGpuTunables gpu) {
    final out = <_KnobRequest>[];
    if (policy.governor != null) {
      out.add(_KnobRequest(
        label: 'governor',
        candidates: _governorNodes(gpu),
        value: policy.governor!,
      ));
    }
    if (policy.minFreqMhz != null) {
      out.add(_KnobRequest(
        label: 'min_freq',
        candidates: _freqNodes(gpu, min: true),
        value: _freqToRaw(policy.minFreqMhz!),
      ));
    }
    if (policy.maxFreqMhz != null) {
      out.add(_KnobRequest(
        label: 'max_freq',
        candidates: _freqNodes(gpu, min: false),
        value: _freqToRaw(policy.maxFreqMhz!),
      ));
    }
    if (policy.minPwrlevel != null) {
      out.add(_KnobRequest(
        label: 'min_pwrlevel',
        candidates: _pwrNodes(gpu, min: true),
        value: policy.minPwrlevel!.toString(),
      ));
    }
    if (policy.maxPwrlevel != null) {
      out.add(_KnobRequest(
        label: 'max_pwrlevel',
        candidates: _pwrNodes(gpu, min: false),
        value: policy.maxPwrlevel!.toString(),
      ));
    }
    return out;
  }

  /// 由 `perf.tunables` 的来源路径推导 GPU 目录（去重、保序）。
  static List<String> _gpuDirs(PerfGpuTunables gpu) {
    final dirs = <String>[];
    void add(String? source) {
      final dir = _parentDir(source);
      if (dir != null && !dirs.contains(dir)) dirs.add(dir);
    }

    add(gpu.governorSource);
    add(gpu.freqSource);
    add(gpu.powerSource);
    return dirs;
  }

  static List<String> _governorNodes(PerfGpuTunables gpu) => _sortedUnique(
        _gpuDirs(gpu).map((dir) => '$dir/governor').toList(),
      );

  static List<String> _freqNodes(PerfGpuTunables gpu, {required bool min}) =>
      _sortedUnique(<String>[
        for (final dir in _gpuDirs(gpu))
          if (_isKgslRoot(dir))
            '$dir/${min ? "min_gpuclk" : "max_gpuclk"}'
          else
            '$dir/${min ? "min_freq" : "max_freq"}',
      ]);

  static List<String> _pwrNodes(PerfGpuTunables gpu, {required bool min}) =>
      _sortedUnique(<String>[
        for (final dir in _gpuDirs(gpu))
          if (_isKgslRoot(dir))
            '$dir/${min ? "min_pwrlevel" : "max_pwrlevel"}',
      ]);

  static String? _parentDir(String? path) {
    if (path == null || path.isEmpty) return null;
    final idx = path.lastIndexOf('/');
    if (idx <= 0) return null;
    return path.substring(0, idx);
  }

  /// kgsl-3d0 **根**目录（非其 `devfreq` 子目录）。
  static bool _isKgslRoot(String dir) =>
      dir.contains('kgsl-3d0') && !dir.endsWith('/devfreq');

  static String _freqToRaw(double mhz) => (mhz * 1000000).round().toString();

  static List<String> _sortedUnique(List<String> paths) {
    final set = <String>{...paths};
    final ordered = set.toList()..sort();
    return ordered;
  }

  // ==================== 探测 / 读写原语（全部 fail-closed） ====================

  /// 解析一个请求：取**第一个**「可写且可读」的候选节点；没有则 `null`。
  Future<_GpuTarget?> _resolve(_KnobRequest request) async {
    for (final path in request.candidates) {
      // 白名单外 → 不拼命令，直接跳过（绝不把任意路径交给 shell）。
      if (_validator.sysfsPathReason(path) != null) continue;
      if (!await _probeWritable(path)) continue;
      final previous = await _readNode(path);
      if (previous == null) continue;
      return _GpuTarget(path: path, value: request.value);
    }
    return null;
  }

  /// `test -w <node>`：哨兵 `ok=1` 才判可写，其余一律不可写。
  Future<bool> _probeWritable(String path) async {
    final result = await _shell.run(_shell.buildCommand('test -w $path'));
    return result.ok;
  }

  /// 写入一个节点（带哨兵）；返回结构化结果（`ok` 才是成功）。
  Future<PrivilegedResult> _writeNode(String path, String value) =>
      _shell.run(_shell.buildWriteCommand(path: path, value: value));

  /// 读取一个节点；不可读 / 空 → `null`（不把哨兵行当内容）。
  Future<String?> _readNode(String path) async {
    final custom = _reader;
    if (custom != null) {
      final value = await custom(path);
      final trimmed = value?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    }
    final result = await _shell.run(_shell.buildReadCommand(path: path));
    if (!result.ok) return null;
    return _stripSentinel(result.output);
  }

  /// 回滚 [writes] 中已写节点到其原值；返回成功回滚数。
  Future<int> _rollback(List<GpuPolicyWrite> writes) async {
    var count = 0;
    for (final write in writes) {
      if (write.previousValue.isEmpty) continue;
      final result = await _writeNode(write.path, write.previousValue);
      if (result.ok) {
        write.rolledBack = true;
        count++;
      }
    }
    return count;
  }

  // ==================== 纯工具 ====================

  static String? _stripSentinel(String raw) {
    final lines = <String>[
      for (final line in raw.split('\n'))
        if (!line.contains(kGstoreSentinel) && line.trim().isNotEmpty)
          line.trim(),
    ];
    return lines.isEmpty ? null : lines.join('\n');
  }

  static bool _sameValue(String a, String b) {
    final ai = int.tryParse(a.trim());
    final bi = int.tryParse(b.trim());
    if (ai != null && bi != null) return ai == bi;
    return a.trim() == b.trim();
  }
}

/// 第三方应用性能服务（Shizuku + Rust `perf.parse_app_dumps`）。
///
/// 数据通路（架构固定）：
/// 1. [CommandRunner] 执行 shell 命令（默认经 [rustShizukuRunner]，Rust 门面 → JNI
///    → Kotlin `ShizukuExecBridge` → `sh`/uid 2000）；
/// 2. 采集命令：`pidof` / `dumpsys cpuinfo` / `dumpsys meminfo <pkg>` /
///    `dumpsys gfxinfo <pkg>`（基础四件）+ `cmd package list packages -U`（uid）/
///    `ps -A`（进程）/ `cat /proc/<pid>/status`（线程，仅 pid 已知）/
///    `dumpsys netstats detail`（网络）/ `dumpsys gfxinfo <pkg> framestats`
///    （渲染细分）/ `dumpsys batterystats --charged <pkg>`（耗电/唤醒）；
///    应用深入批次追加：`dumpsys package <pkg>`（包信息）/
///    `cat /proc/<pid>/smaps_rollup`（精确内存，逐进程拼接）/
///    `dumpsys dropbox --print data_app_crash|data_app_anr`（崩溃/ANR）/
///    `dumpsys activity activities`（前台状态）；
/// 3. 把原始文本交给 Rust `perf` 模块的 `perf.parse_app_dumps` 解析；
/// 4. FPS / 网络速率在 Dart 侧由两次采样的差值推导：
///    `fps = (frames2 - frames1) * 1000 / (t2_ms - t1_ms)`；
///    `rx/tx Bps = (bytes2 - bytes1) * 1000 / (t2_ms - t1_ms)`。
///
/// 设计要点（可测试性 / 健壮性）：
/// * [CommandRunner] **可注入**——测试用罐头 dumpsys 输出即可，无需 Shizuku / 真机；
/// * [PerfModule] 也可注入（用假网关构造），测试不触碰 FFI；
/// * 任何一步失败（Shizuku 缺失 / 命令无输出 / 模块不可用）都**降级**为
///   空 / `null` 指标，绝不向 UI 抛异常；
/// * 第三方逐应用 CPU / 内存在现代 Android（SELinux）下**只能**经 Shizuku 读取，
///   故 Shizuku 不可用是预期状态而非 bug。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:installed_apps/installed_apps.dart';
import 'package:shizuku_api/shizuku_api.dart';

import 'package:gstore/core/rust/perf/PerfContract.dart';
import 'package:gstore/core/rust/perf/PerfModule.dart';
import 'package:gstore/core/shell/rust_shizuku_runner.dart';

/// 执行一条 shell 命令，返回 stdout+stderr 合并文本；未执行 / 失败返回 `null`。
///
/// 生产实现经 [rustShizukuRunner]（Rust 门面 → `sh -c`）；测试注入罐头输出即可脱离设备。
typedef CommandRunner = Future<String?> Function(String command);

/// Shizuku 可用性（供 UI 区分「未运行」与「未授权」）。
enum ShizukuStatus {
  /// 尚未检测。
  unknown,

  /// Shizuku Binder 未运行（未安装 / 未启动）。
  binderUnavailable,

  /// Binder 运行但用户未授权。
  permissionDenied,

  /// 可用（运行 + 已授权）。
  available,
}

/// 可选的目标应用（安装应用包名 + 展示名 + 是否系统应用）。
class AppTarget {
  const AppTarget({
    required this.package,
    required this.label,
    this.isSystem = false,
  });

  /// 包名。
  final String package;

  /// 展示名（应用名；缺省回退包名）。
  final String label;

  /// 是否系统应用。
  final bool isSystem;
}

/// 一次第三方应用采样：指标 + 采样时间戳（后者用于 FPS 差值基线）。
class ThirdPartySample {
  const ThirdPartySample({required this.metrics, required this.tsMs});

  /// 本次解析出的指标（含 Dart 侧推导的 `fps`）。
  final ThirdPartyAppMetrics metrics;

  /// 采样时间（Unix ms）。
  final int tsMs;
}

/// 第三方应用性能服务。
///
/// 生产入口：`ThirdPartyPerfService()`（默认经 [rustShizukuRunner] + [PerfModule.instance]）。
/// 权限 UI（ping / check / request）默认经 [ShizukuApi]；测试均可注入。
/// 测试：注入 [CommandRunner] / [PerfModule] / [ShizukuApi]。
class ThirdPartyPerfService {
  ThirdPartyPerfService({
    CommandRunner? runner,
    PerfModule? module,
    ShizukuApi? shizukuApi,
    DateTime Function()? clock,
  })  : _runner = runner ?? rustShizukuRunner,
        _module = module ?? PerfModule.instance,
        _shizuku = shizukuApi ?? _sharedShizukuApi,
        _clock = clock ?? DateTime.now;

  static final ShizukuApi _sharedShizukuApi = ShizukuApi();

  final CommandRunner _runner;
  final PerfModule _module;

  /// 仅用于权限 UI（`pingBinder` / `checkPermission` / `requestPermission`）；
  /// 命令执行已统一走 Rust 门面（[rustShizukuRunner]）。
  final ShizukuApi _shizuku;

  /// 采样时间源（可在测试注入，保证 FPS 差值换算可复现）。
  final DateTime Function() _clock;

  ShizukuStatus _status = ShizukuStatus.unknown;

  /// 当前 Shizuku 可用性。
  ShizukuStatus get shizukuStatus => _status;

  /// Shizuku 是否可用（运行 + 已授权）。
  bool get shizukuAvailable => _status == ShizukuStatus.available;

  // ==================== Shizuku ====================

  /// 检测 Shizuku 状态（**不弹授权窗**）：pingBinder → checkPermission。
  ///
  /// 返回是否可用。适合在页面打开时调用，避免自动弹出系统授权框。
  Future<bool> refreshShizukuStatus() async {
    try {
      final binderUp = await _shizuku.pingBinder() ?? false;
      if (!binderUp) {
        _status = ShizukuStatus.binderUnavailable;
        return false;
      }
      final granted = await _shizuku.checkPermission() ?? false;
      _status =
          granted ? ShizukuStatus.available : ShizukuStatus.permissionDenied;
      return granted;
    } catch (error) {
      debugPrint('[ThirdPartyPerf] Shizuku 检测失败: $error');
      _status = ShizukuStatus.binderUnavailable;
      return false;
    }
  }

  /// 确保 Shizuku 可用：pingBinder → checkPermission → 未授权则 requestPermission。
  ///
  /// 返回最终是否可用。**唯一**会弹出系统授权窗的入口，应由用户显式触发的
  /// 「授权 / 检查」按钮调用。
  Future<bool> ensureShizuku() async {
    try {
      final binderUp = await _shizuku.pingBinder() ?? false;
      if (!binderUp) {
        _status = ShizukuStatus.binderUnavailable;
        return false;
      }
      var granted = await _shizuku.checkPermission() ?? false;
      if (!granted) {
        granted = await _shizuku.requestPermission() ?? false;
      }
      _status =
          granted ? ShizukuStatus.available : ShizukuStatus.permissionDenied;
      return granted;
    } catch (error) {
      debugPrint('[ThirdPartyPerf] Shizuku 授权失败: $error');
      _status = ShizukuStatus.binderUnavailable;
      return false;
    }
  }

  // ==================== 已安装应用 ====================

  /// 列出已安装应用（含系统应用），按名称排序。
  ///
  /// 经 `installed_apps` 包；失败（如非 Android / 通道缺失）返回空列表，不抛异常。
  /// 系统应用判定：分别取「全部」与「排除系统」两个列表，差集即系统应用。
  Future<List<AppTarget>> listInstalledApps() async {
    try {
      final all = await InstalledApps.getInstalledApps(false, false);
      final nonSystem = await InstalledApps.getInstalledApps(true, false);
      final nonSystemPackages = <String>{
        for (final app in nonSystem) app.packageName,
      };
      final targets = all
          .map(
            (app) => AppTarget(
              package: app.packageName,
              label: app.name.isEmpty ? app.packageName : app.name,
              isSystem: !nonSystemPackages.contains(app.packageName),
            ),
          )
          .toList();
      targets.sort(
        (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
      );
      return targets;
    } catch (error) {
      debugPrint('[ThirdPartyPerf] 获取已安装应用失败: $error');
      return const <AppTarget>[];
    }
  }

  // ==================== 采样 ====================

  /// 采样一次目标应用，返回指标（含按差值推导的 [ThirdPartyAppMetrics.fps]）。
  ///
  /// [prevFrameCount] / [prevTsMs] 为上一次采样（[sampleDetailed]）的帧数与时间戳；
  /// 首次采样传 `null` 时 `fps` 为 `null`。
  Future<ThirdPartyAppMetrics> sample(
    String package, {
    int? prevFrameCount,
    int? prevTsMs,
  }) async {
    final sample = await sampleDetailed(
      package,
      prevFrameCount: prevFrameCount,
      prevTsMs: prevTsMs,
    );
    return sample.metrics;
  }

  /// 与 [sample] 相同，但额外返回本次采样时间戳，供调用方维护 FPS / 网络速率
  /// 差值基线。
  ///
  /// [prevRxBytes] / [prevTxBytes] 为上一次采样的累计网络字节数（来自
  /// [ThirdPartyAppMetrics.net]）；首次采样传 `null` 时速率为 `null`。
  Future<ThirdPartySample> sampleDetailed(
    String package, {
    int? prevFrameCount,
    int? prevTsMs,
    int? prevRxBytes,
    int? prevTxBytes,
  }) async {
    final pidOutput = await _runner('pidof $package');
    final pid = _parsePid(pidOutput);
    final cpuinfo = await _runner('dumpsys cpuinfo');
    final meminfo = await _runner('dumpsys meminfo $package');
    final gfxinfo = await _runner('dumpsys gfxinfo $package');
    final framestats = await _runner('dumpsys gfxinfo $package framestats');
    final uidOutput = await _runner('cmd package list packages -U');
    final uid = _parseUid(uidOutput, package);
    final ps = await _runner('ps -A');
    final status = pid == null ? null : await _runner('cat /proc/$pid/status');
    final netstats = await _runner('dumpsys netstats detail');
    final batterystats = await _runner('dumpsys batterystats --charged $package');
    final packageInfo = await _runner('dumpsys package $package');
    final smaps = await _collectSmaps(package, ps);
    final crashLog = await _runner('dumpsys dropbox --print data_app_crash');
    final anrLog = await _runner('dumpsys dropbox --print data_app_anr');
    final activity = await _runner('dumpsys activity activities');
    final tsMs = _clock().millisecondsSinceEpoch;

    ThirdPartyAppMetrics metrics;
    try {
      metrics = await _module.parseAppDumps(
        package: package,
        pid: pid,
        uid: uid,
        cpuinfo: cpuinfo,
        meminfo: meminfo,
        gfxinfo: gfxinfo,
        ps: ps,
        status: status,
        netstats: netstats,
        framestats: framestats,
        batterystats: batterystats,
        packageInfo: packageInfo,
        smaps: smaps,
        crashLog: crashLog,
        anrLog: anrLog,
        activity: activity,
      );
    } catch (error) {
      debugPrint('[ThirdPartyPerf] parseAppDumps 失败（降级为空指标）: $error');
      metrics = ThirdPartyAppMetrics(package: package, pid: pid, uid: uid);
    }

    final fps = _deriveFps(
      prevFrameCount: prevFrameCount,
      prevTsMs: prevTsMs,
      frameCount: metrics.frameCount,
      tsMs: tsMs,
    );
    final rxRate = _deriveRate(
      prevBytes: prevRxBytes,
      prevTsMs: prevTsMs,
      bytes: metrics.net?.rxBytes,
      tsMs: tsMs,
    );
    final txRate = _deriveRate(
      prevBytes: prevTxBytes,
      prevTsMs: prevTsMs,
      bytes: metrics.net?.txBytes,
      tsMs: tsMs,
    );
    return ThirdPartySample(
      metrics: metrics.withFps(
        fps,
        rxBytesPerSec: rxRate,
        txBytesPerSec: txRate,
      ),
      tsMs: tsMs,
    );
  }

  // ==================== 启动耗时 ====================

  /// 测量目标应用的启动耗时（冷 / 热启动）。
  ///
  /// 控制动作（会**强制停止并拉起**目标应用）→ 调用方必须先取得用户确认。
  /// 流程（全部经可注入 [CommandRunner]，默认 Shizuku）：
  /// 1. `cmd package resolve-activity --brief <pkg>` 解析 LAUNCHER 组件
  ///    （取 `pkg/activity` 行）；解析不到 → 回退 `monkey` 拉起（无 `-W` 计时）；
  /// 2. [cold] = true：先 `am force-stop <pkg>`，再 `am start -W -n <pkg>/<activity>`；
  ///    [cold] = false：直接 `am start -W -n <pkg>/<activity>`；
  /// 3. 把 `am start -W` 原文交给 [PerfModule.parseStartup] 解析。
  ///
  /// 任一步无输出 / 解析失败 / 模块不可用一律**降级**（返回 `null`），绝不抛异常。
  Future<PerfStartupResult?> measureStartup(
    String package, {
    required bool cold,
  }) async {
    final mode = cold ? 'cold' : 'warm';
    try {
      final component = _parseLauncherComponent(
        await _runner('cmd package resolve-activity --brief $package'),
        package,
      );
      if (cold) {
        await _runner('am force-stop $package');
      }
      final String? output;
      if (component != null) {
        output = await _runner('am start -W -n $component');
      } else {
        // resolve-activity 不可用时的兜底：monkey 拉起（无 -W 计时，解析降级）。
        output = await _runner(
          'monkey -p $package -c android.intent.category.LAUNCHER 1',
        );
      }
      return await _module.parseStartup(output: output ?? '', mode: mode);    } catch (error) {
      debugPrint('[ThirdPartyPerf] measureStartup 失败（降级）: $error');
      return null;
    }
  }

  /// 从 `cmd package resolve-activity --brief <pkg>` 输出解析 LAUNCHER 组件。
  ///
  /// 输出通常形如：
  /// ```
  /// priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false
  ///   com.example.app/.MainActivity
  /// ```
  /// 取包名与请求 [package] 精确相等、且 `pkg/activity` 结构完整的行，返回
  /// `<pkg>/<activity>`（activity 可为相对 `.MainActivity`）。解析不到返回 `null`。
  static String? _parseLauncherComponent(String? output, String package) {
    if (output == null) return null;
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final slash = line.indexOf('/');
      if (slash <= 0 || slash == line.length - 1) continue;
      final pkg = line.substring(0, slash);
      if (pkg != package) continue;
      final activity = line
          .substring(slash + 1)
          .split(RegExp(r'\s+'))
          .first
          .trim();
      if (activity.isEmpty) continue;
      return '$pkg/$activity';
    }
    return null;
  }

  /// Timer 驱动的采样流：订阅即立刻采一次，之后每 [interval] 采一次（可取消）。
  ///
  /// 内部维护 `frame_count` / 时间戳基线以推导 FPS；单次异常只记录日志并跳过，
  /// 不中断流。取消订阅即停止定时器。
  Stream<ThirdPartySample> watch(
    String package, {
    Duration interval = const Duration(seconds: 2),
  }) {
    late final StreamController<ThirdPartySample> controller;
    Timer? timer;
    int? prevFrameCount;
    int? prevTsMs;
    int? prevRxBytes;
    int? prevTxBytes;
    var busy = false;

    Future<void> tick() async {
      if (busy || controller.isClosed) return;
      busy = true;
      try {
        final sample = await sampleDetailed(
          package,
          prevFrameCount: prevFrameCount,
          prevTsMs: prevTsMs,
          prevRxBytes: prevRxBytes,
          prevTxBytes: prevTxBytes,
        );
        prevFrameCount = sample.metrics.frameCount;
        prevTsMs = sample.tsMs;
        prevRxBytes = sample.metrics.net?.rxBytes;
        prevTxBytes = sample.metrics.net?.txBytes;
        if (!controller.isClosed) controller.add(sample);
      } catch (error) {
        debugPrint('[ThirdPartyPerf] 采样失败（跳过）: $error');
      } finally {
        busy = false;
      }
    }

    controller = StreamController<ThirdPartySample>(
      onListen: () {
        tick();
        timer = Timer.periodic(interval, (_) => tick());
      },
      onCancel: () {
        timer?.cancel();
        timer = null;
      },
    );
    return controller.stream;
  }

  /// FPS 差值推导：`(frames2 - frames1) * 1000 / (t2_ms - t1_ms)`。
  ///
  /// 任一前置值缺失、时间差 ≤ 0、帧数倒退时返回 `null`（不猜）。
  static double? _deriveFps({
    required int? prevFrameCount,
    required int? prevTsMs,
    required int? frameCount,
    required int tsMs,
  }) {
    if (prevFrameCount == null || prevTsMs == null || frameCount == null) {
      return null;
    }
    final deltaMs = tsMs - prevTsMs;
    final deltaFrames = frameCount - prevFrameCount;
    if (deltaMs <= 0 || deltaFrames < 0) return null;
    return deltaFrames * 1000 / deltaMs;
  }

  /// 网络速率差值推导：`(bytes2 - bytes1) * 1000 / (t2_ms - t1_ms)`（字节/秒）。
  ///
  /// 任一前置值缺失、时间差 ≤ 0、计数倒退（如网卡重置 / 重启）时返回 `null`。
  static double? _deriveRate({
    required int? prevBytes,
    required int? prevTsMs,
    required int? bytes,
    required int tsMs,
  }) {
    if (prevBytes == null || prevTsMs == null || bytes == null) return null;
    final deltaMs = tsMs - prevTsMs;
    final deltaBytes = bytes - prevBytes;
    if (deltaMs <= 0 || deltaBytes < 0) return null;
    return deltaBytes * 1000 / deltaMs;
  }

  /// 拼接目标应用各进程的 `/proc/<pid>/smaps_rollup` 文本；无匹配 pid 返回 `null`。
  ///
  /// pid 来源为 `ps -A` 输出中进程名等于包名（或其 `pkg:` 子进程）的行；逐个
  /// `cat /proc/<pid>/smaps_rollup` 后以换行拼接，交给 Rust 侧解析为 `smaps`
  /// 字段。检索不到进程 / 全部命令无输出时返回 `null`（UI 展示「不可用」）。
  Future<String?> _collectSmaps(String package, String? ps) async {
    final pids = _parseProcessPids(ps, package);
    if (pids.isEmpty) return null;
    final parts = <String>[];
    for (final pid in pids) {
      final out = await _runner('cat /proc/$pid/smaps_rollup');
      if (out != null && out.trim().isNotEmpty) parts.add(out.trim());
    }
    return parts.isEmpty ? null : parts.join('\n');
  }

  /// 从 `ps -A` 输出提取目标应用的全部进程 pid（进程名等于包名或其子进程）。
  ///
  /// Android toybox `ps -A` 默认列：`USER PID PPID VSZ RSS WCHAN ADDR S NAME`；
  /// `cols.length >= 9` 才视为数据行（天然滤掉表头，因 `cols[1]` 非整数），
  /// `name = cols[8..].join(' ')`，`pid > 0` 才收；保持出现顺序并去重。行首可选的
  /// `[` 被剥离（容错）。
  static List<int> _parseProcessPids(String? output, String package) {
    if (output == null) return const <int>[];
    final pids = <int>[];
    final seen = <int>{};
    for (final raw in output.split('\n')) {
      final line = raw.trim().replaceFirst(RegExp(r'^\['), '');
      if (line.isEmpty) continue;
      final cols = line
          .split(RegExp(r'\s+'))
          .where((c) => c.isNotEmpty)
          .toList(growable: false);
      if (cols.length < 9) continue;
      final pid = int.tryParse(cols[1]);
      if (pid == null || pid <= 0) continue;
      final name = cols.sublist(8).join(' ');
      if (name != package && !name.startsWith('$package:')) continue;
      if (seen.add(pid)) pids.add(pid);
    }
    return pids;
  }

  /// 从 `pidof` 输出提取首个整数 pid；无匹配返回 `null`。
  static int? _parsePid(String? output) {
    if (output == null) return null;
    final match = RegExp(r'\d+').firstMatch(output);
    if (match == null) return null;
    return int.tryParse(match.group(0)!);
  }

  /// 从 `cmd package list packages -U` 输出提取目标包名的 uid；无匹配返回 `null`。
  ///
  /// 输出每行形如 `package:com.example.app uid:10123`；按「包名 token 精确相等」
  /// 匹配，避免 `com.example.app` 误配 `com.example.app.debug`。
  static int? _parseUid(String? output, String package) {
    if (output == null) return null;
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('package:')) continue;
      final parts = line.substring('package:'.length).split(' ');
      if (parts.isEmpty || parts.first != package) continue;
      final match = RegExp(r'uid:(\d+)').firstMatch(line);
      if (match != null) return int.tryParse(match.group(1)!);
    }
    return null;
  }
}

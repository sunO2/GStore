/// GStore 系统帧率服务（**双路**：`SurfaceFlinger --latency` 主路 + `--timestats`
/// 回退；屏幕交付帧率口径）。
///
/// **纯 Dart 逻辑，无 Flutter UI / 引擎 / Native 依赖**：本文件只做「执行命令 →
/// 解析文本 → 选层 / 解析时间戳 → 返回结果」，不引用任何 `material` / `widget` /
/// binding，因此可在普通单元测试中用**注入的罐头 [CommandRunner]** 直接断言，**无需
/// 真机 / Shizuku / 原生插件**（既有先例：`third_party_perf_service.dart` /
/// `privileged_shell.dart`）。
///
/// ## 数据源（Scene 8 8.3.7 逆向移植）
/// Scene 8 的 `FpsADBUtilsBase` 经 `Daemon` 执行 `SurfaceFlinger --latency <layer>`
/// 取**逐帧呈现时间戳**并按窗口斜率算帧率；layer 名用 `--list` + 硬编码映射
/// （sgame / 原神）+ 浏览器白名单解析。本服务移植该口径为**主路**：
/// 1. [foregroundCommand]（`dumpsys window`）→ 回退 [activityCommand]
///    （`dumpsys activity activities`）解析前景 `pkg/activity`
///    （[parseForeground]，取 `mCurrentFocus` / `topResumedActivity`）；
/// 2. 组装候选 layer（[layerCandidatesFor]：硬编码映射 → 通用 → `--list` 匹配）；
/// 3. 依次 `dumpsys SurfaceFlinger --latency <layer>`，解析 3 列 ns
///    （[parseLatency]，滤 `0` / `INT64_MAX`，取 `actualPresentTime` 列），
///    `fps = (n-1)*1e9/span`、平均帧间隔 = `span/(n-1)/1e6` ms；
/// 4. 主路任何环节失败 → 回退既有 [sampleCommand]（`--timestats`）。
///
/// ## `--timestats` 回退（Google 官方 TimeStats）
/// * 开启采集：[enable] 执行 `dumpsys SurfaceFlinger --timestats -clear -enable`
///   （幂等 best-effort，失败静默）。
/// * 停止采集：[disable] 执行 `dumpsys SurfaceFlinger --timestats -disable`
///   （best-effort）。
/// * 采样：[sample] 执行
///   `dumpsys SurfaceFlinger --timestats -dump -clear -maxlayers 32`，输出为**多个
///   以空行 / 块分隔的层统计块**，每块含形如 `displayRefreshRate = 120 fps`、
///   `renderRate = ...`、`uid = ...`、`layerName = SurfaceView[...]#0(BLAST)`、
///   `totalFrames = 274`、`presentToPresent histogram is as below:`（后跟 `Nms=v`
///   行）、`averageFPS = 120.569` 的键值行。
///
/// ## 权限
/// 读取需要 `android.permission.DUMP` 或 **shell uid `AID_SHELL(2000)`**。
/// 本应用经 [rustShizukuRunner]（Rust 门面 → JNI → Kotlin `ShizukuExecBridge`，
/// shell/uid 2000）执行，即满足该前提；无 Shizuku 时命令返回 `null`，本服务降级
/// 为 `null`（UI 显「需 Shizuku / 无数据」）。
///
/// ## 口径公式
/// * `latency` 主路：`fps = (validFrameCount - 1) * 1e9 / (last - first)`（ns）。
/// * `timestats` 回退：`averageFPS = 1000 / avg(present2present_ms)`
///   （AOSP `TimeStatsHelper.cpp`）。
///
/// ## `timestats` 选层启发式（见 [_selectLayer]）
/// 过滤系统层黑名单（`com.android.systemui` / `StatusBar` / `NavigationBar` /
/// `Wallpaper` / `InputMethod` / `Background for`）→ 优先 `layerName` 含
/// `SurfaceView` 或 `BLAST` → 并列取 `totalFrames` 最大。
///
/// ## 降级
/// Shizuku 不可用 / 命令执行失败 / 无输出 / 无有效帧 / 无匹配层，一律返回 `null`，
/// **绝不抛出**。
library;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import 'package:gstore/core/shell/rust_shizuku_runner.dart';

/// 执行一条 shell 命令，返回 stdout+stderr 合并文本；未执行 / 失败返回 `null`。
///
/// **与 `third_party_perf_service.dart` 的 `CommandRunner` 同构**（本文件按既有
/// 约定各自声明局部 typedef，以保持本文件无跨服务耦合；签名逐字一致，调用方可
/// 互换）。生产实现经 [rustShizukuRunner]（Rust 门面 → `sh -c`）；测试注入罐头输出即可。
typedef CommandRunner = Future<String?> Function(String command);

/// 一次系统帧率采样的解析结果。
class SystemFpsSample {
  const SystemFpsSample({
    required this.tsMs,
    this.fps,
    this.layer,
    this.totalFrames,
    this.displayRefreshRate,
    this.source,
    this.avgFrameIntervalMs,
  });

  /// 采样层 `averageFPS`（屏幕交付帧率）；无有效值时为 `null`。
  final double? fps;

  /// 选中的层名（`layerName`），如 `SurfaceView[com.x/com.x.Main]#0(BLAST)`。
  final String? layer;

  /// 选中层的累计帧数（`totalFrames`）；缺失为 `null`。
  final int? totalFrames;

  /// 显示刷新率（`displayRefreshRate`，fps）；缺失为 `null`。
  final double? displayRefreshRate;

  /// 采样时间（Unix ms）。
  final int tsMs;

  /// 数据源：`'latency'`（`SurfaceFlinger --latency`，Scene 8 同源）或
  /// `'timestats'`（`SurfaceFlinger --timestats` 回退）。
  ///
  /// 为**新增可选字段**（向后兼容：旧构造调用未传时为 `null`）。
  final String? source;

  /// 平均帧间隔（ms，仅 `latency` 源有意义）；缺失为 `null`。
  ///
  /// 为**新增可选字段**（向后兼容）。
  final double? avgFrameIntervalMs;

  @override
  String toString() => 'SystemFpsSample(fps: $fps, layer: $layer, '
      'totalFrames: $totalFrames, refresh: $displayRefreshRate, '
      'source: $source, avgFrameMs: $avgFrameIntervalMs, tsMs: $tsMs)';
}

/// `SurfaceFlinger --latency` 解析中间结果（纯数据，便于单测断言）。
class LatencyStats {
  const LatencyStats({
    required this.fps,
    required this.avgFrameIntervalMs,
    required this.frameCount,
    this.refreshPeriodNs,
    this.displayRefreshRate,
  });

  /// 窗口内帧率：`(frameCount - 1) * 1e9 / span_ns`。
  final double fps;

  /// 平均帧间隔（ms）：`span_ns / (frameCount - 1) / 1e6`。
  final double avgFrameIntervalMs;

  /// 有效时间戳个数（已滤 `0` / `INT64_MAX`）。
  final int frameCount;

  /// 首行刷新周期（ns）；解析不到为 `null`。
  final int? refreshPeriodNs;

  /// 由 [refreshPeriodNs] 换算的刷新率（fps）；无周期为 `null`。
  final double? displayRefreshRate;
}

/// 系统帧率服务（生产：`SystemFpsService()`；测试：注入 [CommandRunner]）。
class SystemFpsService {
  SystemFpsService({CommandRunner? runner, DateTime Function()? clock})
      : _runner = runner ?? rustShizukuRunner,
        _clock = clock ?? DateTime.now;

  /// 采样命令（`--timestats` 回退；`-dump -clear`：取回并清空统计窗口）。
  static const String sampleCommand =
      'dumpsys SurfaceFlinger --timestats -dump -clear -maxlayers 32';

  /// 开启采集命令（`-clear -enable`：清空并开启，幂等）。
  static const String enableCommand =
      'dumpsys SurfaceFlinger --timestats -clear -enable';

  /// 停止采集命令。
  static const String disableCommand =
      'dumpsys SurfaceFlinger --timestats -disable';

  /// 前景窗口探测命令（`--latency` 主路第 1 步）。
  static const String foregroundCommand = 'dumpsys window';

  /// 前景窗口探测回退命令（`dumpsys window` 无 `mCurrentFocus` 时）。
  static const String activityCommand = 'dumpsys activity activities';

  /// 图层列表命令（`--latency` 主路第 2 步）。
  static const String layerListCommand = 'dumpsys SurfaceFlinger --list';

  /// 系统层黑名单（`--timestats` 选层；名称**包含**任一片段即过滤）。
  static const List<String> blacklist = <String>[
    'com.android.systemui',
    'StatusBar',
    'NavigationBar',
    'Wallpaper',
    'InputMethod',
    'Background for',
  ];

  /// 硬编码 layer 活动映射（Scene 8：SDK<31 的 sgame / 原神专用 `SurfaceView -` 层）。
  ///
  /// 值 = 该包在 Scene 8 中使用的 activity 全名；候选 = `SurfaceView - <pkg>/<act>#0`。
  static const Map<String, String> hardcodedActivityByPackage = <String, String>{
    'com.tencent.tmgp.sgame': 'com.tencent.tmgp.sgame.SGameActivity',
    'com.miHoYo.Yuanshen': 'com.miHoYo.GetMobileInfo.MainActivity',
  };

  /// 浏览器白名单（Scene 8；这些包直接用 `SurfaceView -` 层候选）。
  static const Set<String> browserPackages = <String>{
    'com.microsoft.emmx',
    'com.android.browser',
    'com.android.chrome',
    'com.chrome.beta',
    'com.chrome.dev',
    'com.chrome.canary',
  };

  /// 前景窗口识别关键字（取值行首键名）。
  static const List<String> _focusKeys = <String>[
    'mCurrentFocus',
    'topResumedActivity',
  ];

  // `SurfaceFlinger --latency` 无效时间戳哨兵（INT64_MAX）。
  static const int _int64Max = 0x7fffffffffffffff;

  // ---- 全局 FPS 兜底（Scene 8 `FpsUtils` 同源）----

  /// `measured_fps` sysfs 路径（高通 DPU / MDSS / fb0；命中即直接给出刷新率）。
  static const List<String> measuredFpsPaths = <String>[
    '/sys/class/drm/sde-crtc-0/measured_fps',
    '/sys/devices/platform/soc/ae00000.qcom,mdss_mdp/drm/card0/card0-sde-crtc-0/measured_fps',
    '/sys/class/graphics/fb0/measured_fps',
  ];

  /// 高通 fpsgo 调度器状态（数据行含 `currentFPS` 列）。
  static const String fpsgoStatusPath = '/sys/kernel/fpsgo/fstb/fpsgo_status';

  /// SurfaceFlinger 翻页计数（全局合成帧数；需两次采样差值换算 FPS）。
  static const String pageFlipCommand = 'service call SurfaceFlinger 1013';

  /// 从 `Result: Parcel(00aea4f4 '....')` 取 `(` 后前 8 个十六进制字符。
  static final RegExp _pageFlipRe = RegExp(r'\((\w{8})');

  /// FPS 合理上限（面板率未知时用于安全钳制，避免异常样本爆表）。
  static const double maxPlausibleFps = 240.0;

  /// `--latency` 统计窗口（ns）：只取**最近 1 秒**内的帧（与 Scene 8 一致）。
  ///
  /// 缓冲区仅 128 帧；若首尾跨度过短（刚清空/刚起采）会把少量帧当成高帧率，
  /// 因此固定 1s 时间窗 + 面板率钳制。
  static const int latencyWindowNs = 1000000000;

  /// 把 fps 钳制到 `(0, 面板刷新率]`；面板率未知时上限为 [maxPlausibleFps]。
  ///
  /// `--timestats` 的 `averageFPS = 1000 / avg(present2present_ms)` 因整数毫秒量化，
  /// 120Hz 会算成 `1000/8 = 125`；此钳制把量化伪影拉回面板率。
  static double clampFps(double fps, double? displayRefreshRate) {
    if (!fps.isFinite || fps <= 0) return 0;
    final double rawCap =
        (displayRefreshRate != null && displayRefreshRate > 0)
            ? displayRefreshRate
            : maxPlausibleFps;
    final double cap = rawCap.clamp(24.0, maxPlausibleFps);
    return fps > cap ? cap : fps;
  }

  static final RegExp _componentRe = RegExp(
    r'([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)/([A-Za-z0-9_.$]+)',
  );
  static final RegExp _braceRe = RegExp(r'^[^\{]*\{([\s\S]*)\}$');
  static final RegExp _nameFieldRe = RegExp(r'\bname=(\S+)');
  static final RegExp _whitespaceRe = RegExp(r'\s+');

  final CommandRunner _runner;
  final DateTime Function() _clock;

  /// `service call SurfaceFlinger 1013` 差值基线（首样本仅建基线）。
  int? _lastFlipCount;
  int? _lastFlipMs;

  /// 开启 SurfaceFlinger TimeStats 采集（幂等 best-effort，失败静默）。
  Future<void> enable() async {
    try {
      await _runner(enableCommand);
    } catch (error) {
      debugPrint('[SystemFps] enable 失败（忽略）: $error');
    }
  }

  /// 停止 SurfaceFlinger TimeStats 采集（best-effort，失败静默）。
  Future<void> disable() async {
    try {
      await _runner(disableCommand);
    } catch (error) {
      debugPrint('[SystemFps] disable 失败（忽略）: $error');
    }
  }

  /// 采样一次系统帧率；任何失败 / 无可选层都返回 `null`（绝不抛）。
  ///
  /// 策略：**先** `--latency` 主路（前景 `pkg/activity` → 候选 layer → 逐帧时间戳），
  /// 拿到有效样本即返回；**否则**回退 `--timestats`；**再否则** Scene 8 式全局兜底
  /// （`measured_fps` sysfs → `fpsgo_status.currentFPS` → `service call SurfaceFlinger 1013`）。
  Future<SystemFpsSample?> sample() async {
    try {
      final foreground = await _foregroundComponent();
      if (foreground != null) {
        final latency = await _sampleLatency(foreground.pkg, foreground.activity);
        if (latency != null) return latency;
      }
    } catch (error) {
      debugPrint('[SystemFps] latency 主路失败（回退 timestats）: $error');
    }

    final String? output;
    try {
      output = await _runner(sampleCommand);
    } catch (error) {
      debugPrint('[SystemFps] 采样命令异常（继续全局兜底）: $error');
      return _sampleGlobal();
    }
    if (output != null && output.trim().isNotEmpty) {
      try {
        final parsed = _parse(output);
        if (parsed != null) return parsed;
      } catch (error) {
        debugPrint('[SystemFps] timestats 解析失败（继续全局兜底）: $error');
      }
    }
    return _sampleGlobal();
  }

  // ==================== `--latency` 主路 ====================

  /// 经 `dumpsys window` → `dumpsys activity activities` 解析前景 `pkg/activity`。
  ///
  /// 两条命令依次尝试（前者无有效焦点则后者兜底）；均失败 / 歧义返回 `null`。
  /// 注意：计划草稿称本方法为 `_foregroundPackage`，因候选 layer 需要 activity，
  /// 实际返回 `pkg` + `activity` 组件。
  Future<({String pkg, String activity})?> _foregroundComponent() async {
    for (final command in const <String>[foregroundCommand, activityCommand]) {
      final String? output;
      try {
        output = await _runner(command);
      } catch (error) {
        debugPrint('[SystemFps] 前景探测失败（$command）: $error');
        continue;
      }
      final parsed = parseForeground(output);
      if (parsed != null) return parsed;
    }
    return null;
  }

  /// 依次对候选 layer 跑 `--latency` 并解析；全部失败返回 `null`。
  Future<SystemFpsSample?> _sampleLatency(String pkg, String activity) async {
    String? listOutput;
    try {
      listOutput = await _runner(layerListCommand);
    } catch (error) {
      debugPrint('[SystemFps] --list 失败（仅用通用候选）: $error');
      listOutput = null;
    }
    final candidates = layerCandidatesFor(
      pkg: pkg,
      activity: activity,
      listOutput: listOutput,
    );
    for (final candidate in candidates) {
      String? output;
      try {
        output = await _runner(latencyCommandFor(candidate));
      } catch (error) {
        debugPrint('[SystemFps] --latency "$candidate" 失败: $error');
        continue;
      }
      if (output == null || output.trim().isEmpty) continue;
      final stats = parseLatency(output);
      if (stats == null) continue;
      return SystemFpsSample(
        fps: stats.fps,
        layer: candidate,
        totalFrames: stats.frameCount,
        displayRefreshRate: stats.displayRefreshRate,
        source: 'latency',
        avgFrameIntervalMs: stats.avgFrameIntervalMs,
        tsMs: _clock().millisecondsSinceEpoch,
      );
    }
    return null;
  }

  /// 构造 `dumpsys SurfaceFlinger --latency '<layer>'` 命令（shell 安全引用）。
  static String latencyCommandFor(String layer) =>
      'dumpsys SurfaceFlinger --latency ${shellQuote(layer)}';

  /// 以 POSIX 单引号包裹 [value]（含 `#`/空格/括号/`[` 的 layer 名安全）。
  @visibleForTesting
  static String shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  // ==================== 全局 FPS 兜底（Scene 8 `FpsUtils` 同源） ====================

  /// Scene 8 式全局 FPS 兜底：`measured_fps` sysfs → `fpsgo_status.currentFPS`
  /// → `service call SurfaceFlinger 1013` 翻页差值。全部失败返回 `null`（绝不抛）。
  Future<SystemFpsSample?> _sampleGlobal() async {
    final nowMs = _clock().millisecondsSinceEpoch;

    for (final path in measuredFpsPaths) {
      final value = await _readDoubleToken('cat $path');
      if (value != null && value > 0) {
        return SystemFpsSample(fps: clampFps(value, null), source: 'measured_fps', tsMs: nowMs);
      }
    }

    final fpsgo = await _readFpsgoFps();
    if (fpsgo != null && fpsgo > 0) {
      return SystemFpsSample(fps: clampFps(fpsgo, null), source: 'fpsgo', tsMs: nowMs);
    }

    final flip = await _readPageFlipCount();
    if (flip != null) {
      final prev = _lastFlipCount;
      final prevMs = _lastFlipMs;
      _lastFlipCount = flip;
      _lastFlipMs = nowMs;
      if (prev != null && prevMs != null && nowMs > prevMs && flip > prev) {
        final fps = (flip - prev) * 1000.0 / (nowMs - prevMs);
        return SystemFpsSample(
          fps: clampFps(fps, null),
          source: 'surfaceflinger_1013',
          tsMs: nowMs,
        );
      }
      return null; // 首个样本仅建基线
    }
    return null;
  }

  /// 读取命令输出并解析「第二个空白 token」为有限正数（`awk '{print $2}'` 同源；
  /// 单 token 时取自身）。失败 / 非法返回 `null`。
  Future<double?> _readDoubleToken(String command) async {
    final String? out;
    try {
      out = await _runner(command);
    } catch (error) {
      return null;
    }
    if (out == null) return null;
    final tokens = out.trim().split(_whitespaceRe);
    final candidate = tokens.length >= 2
        ? tokens[1]
        : tokens.isEmpty ? null : tokens.first;
    if (candidate == null) return null;
    final value = double.tryParse(candidate);
    return (value != null && value.isFinite && value > 0) ? value : null;
  }

  /// 从 `fpsgo_status` 解析 `currentFPS` 列（首个含该列头的数据行）。
  Future<double?> _readFpsgoFps() async {
    final String? out;
    try {
      out = await _runner('cat $fpsgoStatusPath');
    } catch (error) {
      return null;
    }
    if (out == null) return null;
    int? col;
    for (final raw in out.split('\n')) {
      final tokens = raw.trim().split(_whitespaceRe);
      if (col == null) {
        final idx = tokens.indexOf('currentFPS');
        if (idx >= 0) {
          col = idx;
        } else if (tokens.isNotEmpty && tokens.first == 'tid') {
          col = -1; // 头行无 currentFPS → 跳过本文件
        } else {
          continue;
        }
      }
      if (col < 0 || tokens.length <= col) continue;
      final value = double.tryParse(tokens[col]);
      if (value != null && value.isFinite && value > 0) return value;
    }
    return null;
  }

  /// 解析 `service call SurfaceFlinger 1013` 返回的 Parcel 十六进制翻页计数。
  Future<int?> _readPageFlipCount() async {
    final String? out;
    try {
      out = await _runner(pageFlipCommand);
    } catch (error) {
      return null;
    }
    if (out == null) return null;
    final match = _pageFlipRe.firstMatch(out);
    if (match == null) return null;
    return int.tryParse(match.group(1)!, radix: 16);
  }

  // ==================== `--latency` / 前景 / 图层（纯函数，可单测） ====================

  /// 从 `dumpsys window`（或 `dumpsys activity activities`）文本解析前景组件。
  ///
  /// 识别 `mCurrentFocus` / `topResumedActivity` 行中的 `<pkg>/<activity>`
  /// （pkg 含点、activity 可相对 `.MainActivity`）。**唯一**不同组件才返回；
  /// 无匹配或出现歧义（多个不同组件）返回 `null`。
  @visibleForTesting
  static ({String pkg, String activity})? parseForeground(String? output) {
    if (output == null) return null;
    final found = <String, ({String pkg, String activity})>{};
    for (final raw in output.split('\n')) {
      if (!_focusKeys.any((key) => raw.contains(key))) continue;
      final match = _componentRe.firstMatch(raw);
      if (match == null) continue;
      final pkg = match.group(1)!;
      final activity = match.group(2)!;
      found['$pkg/$activity'] = (pkg: pkg, activity: activity);
    }
    if (found.length != 1) return null;
    return found.values.first;
  }

  /// 构造候选 layer 列表（去重，按优先级）。
  ///
  /// 顺序：硬编码映射（sgame / 原神）→ 浏览器白名单 → 通用候选
  ///（`<pkg>/<act>#0`、`SurfaceView[<pkg>/<act>]#0`、`SurfaceView - <pkg>/<act>#0`）
  /// → [listOutput]（`--list`）中匹配 pkg 的行（优先 `SurfaceView`/`BLAST`）。
  @visibleForTesting
  static List<String> layerCandidatesFor({
    required String pkg,
    required String activity,
    String? listOutput,
  }) {
    final result = <String>[];
    final seen = <String>{};

    void add(String candidate) {
      final value = candidate.trim();
      if (value.isNotEmpty && seen.add(value)) result.add(value);
    }

    final mapped = hardcodedActivityByPackage[pkg];
    final effectiveActivity = mapped ?? _absoluteActivity(pkg, activity);
    final component = '$pkg/$effectiveActivity';

    if (mapped != null) add('SurfaceView - $pkg/$mapped#0');
    if (browserPackages.contains(pkg)) add('SurfaceView - $component#0');
    add('$component#0');
    add('SurfaceView[$component]#0');
    add('SurfaceView - $component#0');

    if (listOutput != null) {
      final matches = <String>[];
      for (final raw in listOutput.split('\n')) {
        final name = _layerListName(raw);
        if (name == null || !name.contains(pkg)) continue;
        matches.add(name);
      }
      matches.sort((a, b) {
        final byPriority = _listPriority(a).compareTo(_listPriority(b));
        return byPriority != 0 ? byPriority : a.compareTo(b);
      });
      for (final name in matches) {
        add(name);
      }
    }
    return result;
  }

  /// 解析 `SurfaceFlinger --latency` 文本。
  ///
  /// 首行 = 刷新周期（ns）；后续行按空白切列，取第 2 列 `actualPresentTime`；
  /// 滤 `0` / `INT64_MAX` / 负数，升序；有效帧 ≥2 且跨度 >0 时返回统计，否则 `null`。
  @visibleForTesting
  static LatencyStats? parseLatency(String? output) {
    if (output == null) return null;
    final trimmed = output.trim();
    if (trimmed.isEmpty) return null;
    final lines = trimmed.split('\n');
    final period = int.tryParse(lines.first.trim());

    final times = <int>[];
    for (var i = 1; i < lines.length; i++) {
      final cols = lines[i].trim().split(_whitespaceRe);
      if (cols.length < 3) continue;
      final actualPresent = int.tryParse(cols[1]);
      if (actualPresent == null) continue;
      if (actualPresent <= 0 || actualPresent == _int64Max) continue;
      times.add(actualPresent);
    }
    if (times.length < 2) return null;

    times.sort();
    // 只统计最近 1s 内的帧（避免缓冲区未填满时跨度太短导致虚高）。
    final windowStart = times.last - latencyWindowNs;
    final windowed = <int>[
      for (final t in times)
        if (t >= windowStart) t,
    ];
    if (windowed.length < 2) return null;
    final span = windowed.last - windowed.first;
    if (span <= 0) return null;

    final n = windowed.length;
    final displayRefreshRate =
        (period != null && period > 0) ? 1e9 / period : null;
    return LatencyStats(
      fps: clampFps((n - 1) * 1e9 / span, displayRefreshRate),
      avgFrameIntervalMs: span / (n - 1) / 1e6,
      frameCount: n,
      refreshPeriodNs: period,
      displayRefreshRate: displayRefreshRate,
    );
  }

  /// activity 相对名补全为全名（`.MainActivity` → `<pkg>.MainActivity`）。
  static String _absoluteActivity(String pkg, String activity) {
    if (activity.startsWith('.')) return '$pkg$activity';
    if (activity.contains('.')) return activity;
    return '$pkg.$activity';
  }

  /// 从 `--list` 一行提取图层名：优先 `name=` 字段，其次剥离 `...{...}` 外壳取
  /// 首个 token；普通行原样返回。
  static String? _layerListName(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return null;
    final nameField = _nameFieldRe.firstMatch(line);
    if (nameField != null) return _cleanLayerName(nameField.group(1)!);
    final brace = _braceRe.firstMatch(line);
    if (brace != null) {
      final inner = brace.group(1)!.trim();
      if (inner.isEmpty) return null;
      return _cleanLayerName(inner.split(_whitespaceRe).first);
    }
    return _cleanLayerName(line);
  }

  static String _cleanLayerName(String raw) =>
      raw.trim().replaceAll(RegExp(r'[,\}]+$'), '');

  /// `--list` 匹配行排序优先级：`SurfaceView` / `BLAST` 优先。
  static int _listPriority(String name) =>
      (name.contains('SurfaceView') || name.contains('BLAST')) ? 0 : 1;

  // ==================== `--timestats` 回退解析（纯函数，可单测） ====================

  /// 解析 `--timestats` 文本，选层后返回样本；无可选层返回 `null`。
  SystemFpsSample? _parse(String output) {
    final best = _selectLayer(_splitLayerBlocks(output));
    if (best == null) return null;
    return SystemFpsSample(
      fps: clampFps(best.fps, best.displayRefreshRate),
      layer: best.layer,
      totalFrames: best.totalFrames,
      displayRefreshRate: best.displayRefreshRate,
      source: 'timestats',
      tsMs: _clock().millisecondsSinceEpoch,
    );
  }

  static final RegExp _layerLineRe =
      RegExp(r'^\s*layerName\s*=', multiLine: true);
  static final RegExp _layerNameRe =
      RegExp(r'^\s*layerName\s*=\s*(.+?)\s*$', multiLine: true);
  static final RegExp _totalFramesRe = RegExp(r'totalFrames\s*=\s*(\d+)');
  static final RegExp _averageFpsRe = RegExp(
    r'averageFPS\s*=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)',
  );
  static final RegExp _refreshRateRe = RegExp(
    r'displayRefreshRate\s*=\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)',
  );

  /// 把完整输出按 `layerName` 起始行切成「一层一块」的文本块。
  ///
  /// 这样即使层块之间没有空行也能正确分层；首个 `layerName` 之前的头部文本会归入
  /// 首块（无 `layerName` 则被 [_selectLayer] 跳过）。单层块内部即使含空行
  /// （如 `presentToPresent histogram is as below:` 前的空行）也不会被拆散。
  static List<String> _splitLayerBlocks(String output) {
    final blocks = <String>[];
    final buffer = StringBuffer();
    var hasLayer = false;
    for (final line in output.split('\n')) {
      if (_layerLineRe.hasMatch(line) && hasLayer) {
        blocks.add(buffer.toString());
        buffer.clear();
      }
      if (_layerLineRe.hasMatch(line)) hasLayer = true;
      buffer.writeln(line);
    }
    if (buffer.isNotEmpty) blocks.add(buffer.toString());
    return blocks;
  }

  /// 逐块解析 → 过滤黑名单 → 优先 SurfaceView/BLAST → 并列取 totalFrames 最大。
  _LayerStat? _selectLayer(List<String> blocks) {
    final candidates = <_LayerStat>[];
    for (final block in blocks) {
      final layer = _layerNameRe.firstMatch(block)?.group(1)?.trim();
      if (layer == null || layer.isEmpty) continue;
      final fps = _parseDouble(_averageFpsRe.firstMatch(block)?.group(1));
      if (fps == null) continue; // 无有效 averageFPS 的块不参与选层
      if (_isBlacklisted(layer)) continue;
      candidates.add(
        _LayerStat(
          layer: layer,
          fps: fps,
          totalFrames:
              int.tryParse(_totalFramesRe.firstMatch(block)?.group(1) ?? ''),
          displayRefreshRate:
              _parseDouble(_refreshRateRe.firstMatch(block)?.group(1)),
        ),
      );
    }
    if (candidates.isEmpty) return null;

    final preferred = candidates
        .where((c) => c.layer.contains('SurfaceView') || c.layer.contains('BLAST'))
        .toList(growable: false);
    final pool = preferred.isNotEmpty ? preferred : candidates;
    final ordered = pool.toList()
      ..sort((a, b) => _framesOf(b).compareTo(_framesOf(a)));
    return ordered.first;
  }

  static int _framesOf(_LayerStat stat) => stat.totalFrames ?? -1;

  static bool _isBlacklisted(String layer) =>
      blacklist.any(layer.contains);

  /// `group(1)` → 有限 `double`；缺失 / 非有限（`nan` / `inf`）返回 `null`。
  static double? _parseDouble(String? raw) {
    if (raw == null) return null;
    final value = double.tryParse(raw);
    if (value == null || !value.isFinite) return null;
    return value;
  }
}

/// 单个层的解析中间态。
class _LayerStat {
  const _LayerStat({
    required this.layer,
    required this.fps,
    this.totalFrames,
    this.displayRefreshRate,
  });

  final String layer;
  final double fps;
  final int? totalFrames;
  final double? displayRefreshRate;
}

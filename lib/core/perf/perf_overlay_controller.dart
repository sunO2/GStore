import 'package:flutter/services.dart';

/// 性能悬浮窗的 Dart 触发层（对应 Kotlin `gstore/perf_overlay` 通道）。
///
/// 只负责权限查询/引导与原生 `PerfOverlayService` 的启停；悬浮视图与指标采集
/// 全部在原生侧完成（自包含、不依赖 Flutter 引擎）。所有方法**不抛异常**：
/// 通道缺失（`MissingPluginException`）或原生报错（`PlatformException`）时
/// 返回 `false`，保证 UI 流程不中断。
class PerfOverlayController {
  const PerfOverlayController({
    this.channel = const MethodChannel(channelName),
  });

  static const String channelName = 'gstore/perf_overlay';

  /// 紧凑模式：单行 `CPU / MEM / 电池温度`。
  static const String modeCompact = 'compact';

  /// 展开模式：多行，含网络速率 / PSI 压力 / 最高温度 + 目标行。
  static const String modeExpanded = 'expanded';

  /// 目标专注模式：仅显示所选第三方应用 `CPU / FPS / jank / MEM`。
  static const String modeTarget = 'target';

  /// 前台模式：当前前台应用 + 当前生效档案（各带刷新时间戳 / 过期指示）。
  static const String modeLive = 'live';

  /// 全部合法模式（客户端校验用）。
  static const Set<String> modes = {
    modeCompact,
    modeExpanded,
    modeTarget,
    modeLive,
  };

  final MethodChannel channel;

  /// 是否已授予悬浮窗（`Settings.canDrawOverlays`）。
  Future<bool> isPermissionGranted() => _invokeBool('isPermissionGranted');

  /// 拉起系统「显示在其他应用上层」授权页。
  Future<bool> requestPermission() => _invokeBool('requestPermission');

  /// 启动悬浮窗服务。**先校验权限**：未授权时不调用原生 `start`，直接返回 false。
  ///
  /// [targetPackage] 非空时随 `start` 一并下传，原生在启动前持久化该监控目标
  /// （悬浮窗展开模式显示该第三方应用 CPU/内存）。
  Future<bool> start({String? targetPackage}) async {
    if (!await isPermissionGranted()) return false;
    try {
      final target = targetPackage?.trim();
      return await channel.invokeMethod<bool>(
            'start',
            (target == null || target.isEmpty)
                ? null
                : <String, Object?>{'targetPackage': target},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 停止悬浮窗服务。
  Future<bool> stop() => _invokeBool('stop');

  /// 服务当前是否运行（原生静态标志）。
  Future<bool> isRunning() => _invokeBool('isRunning');

  /// 设置监控目标第三方应用（包名），持久化并在运行中实时刷新。
  Future<bool> setTarget(String package) async {
    if (package.trim().isEmpty) return false;
    try {
      return await channel.invokeMethod<bool>(
            'setTarget',
            <String, Object?>{'package': package.trim()},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 清除监控目标。
  Future<bool> clearTarget() => _invokeBool('clearTarget');

  /// 读取当前监控目标包名；未设置 / 通道缺失返回 `null`（不抛）。
  Future<String?> getTarget() async {
    try {
      final value = await channel.invokeMethod<Object?>('getTarget');
      final text = value?.toString();
      return (text == null || text.isEmpty) ? null : text;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 推送当前生效的性能档案名（空串清除）；持久化并在运行中实时刷新 HUD。
  ///
  /// 原生返回 bool；用 `invokeMethod<Object?>` + 归一化，避免泛型强转异常。
  Future<bool> setProfile(String name) async {
    try {
      final value = await channel.invokeMethod<Object?>(
        'setProfile',
        <String, Object?>{'name': name.trim()},
      );
      return value == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 读取当前生效档案名；未设置 / 通道缺失返回 `null`（不抛）。
  Future<String?> getProfile() async {
    try {
      final value = await channel.invokeMethod<Object?>('getProfile');
      final text = value?.toString();
      return (text == null || text.isEmpty) ? null : text;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 设置悬浮窗模式（[modeCompact] / [modeExpanded] / [modeTarget]）；
  /// 非法值不调用原生直接返回 false。
  Future<bool> setMode(String mode) async {
    if (!modes.contains(mode)) return false;
    try {
      return await channel.invokeMethod<bool>('setMode', {'mode': mode}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 读取持久化的悬浮窗模式；未知值 / 通道缺失/异常时回退 [modeCompact]（不抛）。
  Future<String> getMode() async {
    try {
      final value = await channel.invokeMethod<Object?>('getMode');
      return modes.contains(value) ? value as String : modeCompact;
    } on PlatformException {
      return modeCompact;
    } on MissingPluginException {
      return modeCompact;
    }
  }

  Future<bool> _invokeBool(String method) async {
    try {
      return await channel.invokeMethod<bool>(method) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

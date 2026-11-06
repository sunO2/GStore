/// 模块开关配置（ModuleToggleConfig）
///
/// 模块开关的统一配置入口：
/// - 配置键 `module.<name>.enabled` 持久化到 [ConfigService]（11 个业务 key 已注册 ConfigRegistry）
/// - [setEnabled] 先 [ModuleManager.setModuleEnabled] 运行时上下线（含依赖者检查/幂等），
///   成功返回 true 后再持久化；依赖者拒绝/运行时异常不落盘并返回 false
/// - 未配置/未注册时默认启用（fail-safe）
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../config/config_service.dart';
import 'module_manager.dart';

/// 模块开关配置（单例）
class ModuleToggleConfig {
  ModuleToggleConfig._internal();

  static ModuleToggleConfig? _instance;
  static ModuleToggleConfig get instance =>
      _instance ??= ModuleToggleConfig._internal();

  /// 全局配置变更订阅（模块开关外部写入时联动运行时）。
  StreamSubscription<ConfigChangeEvent>? _configSub;

  /// 正在应用外部配置的模块名（防止同一次变更重入）。
  final Set<String> _applyingExternal = <String>{};

  /// `setEnabled` 自身写入配置的待消费次数（监听时跳过对应事件，避免回声竞态）。
  final Map<String, int> _selfWriteExpectations = <String, int>{};

  /// 自身写入登记的过期定时器（事件丢失时兜底清理，避免吞掉后续外部变更）。
  final Map<String, Timer> _selfWriteTimers = <String, Timer>{};

  /// 登记一次自身写入产生的待消费事件（2 秒后自动过期）。
  void _registerSelfWrite(String moduleName) {
    _selfWriteExpectations.update(moduleName, (v) => v + 1, ifAbsent: () => 1);
    _selfWriteTimers[moduleName]?.cancel();
    _selfWriteTimers[moduleName] = Timer(const Duration(seconds: 2), () {
      _selfWriteExpectations.remove(moduleName);
      _selfWriteTimers.remove(moduleName);
    });
  }

  /// 消费一次自身写入事件（事件已到达）。
  void _consumeSelfWrite(String moduleName) {
    final pending = _selfWriteExpectations[moduleName] ?? 0;
    if (pending <= 1) {
      _selfWriteExpectations.remove(moduleName);
      _selfWriteTimers.remove(moduleName)?.cancel();
    } else {
      _selfWriteExpectations[moduleName] = pending - 1;
    }
  }

  /// 撤销一次自身写入登记（写入失败、不会产生事件）。
  void _cancelSelfWrite(String moduleName) {
    final pending = _selfWriteExpectations[moduleName] ?? 0;
    if (pending <= 1) {
      _selfWriteExpectations.remove(moduleName);
      _selfWriteTimers.remove(moduleName)?.cancel();
    } else {
      _selfWriteExpectations[moduleName] = pending - 1;
    }
  }

  /// 模块开关配置键：module.<name>.enabled
  static String keyOf(String moduleName) => 'module.$moduleName.enabled';

  /// 可开关业务模块清单（启动装配遍历；update/badge/infra 恒启用，不在此列）
  static const List<String> toggleableModules = [
    'channel',
    'download',
    'backup',
    'webdav',
    'fdroid',
    'theme',
    'install',
    'aggregate',
    'agent_tools',
  ];

  /// 启动预置：registerModule 全部完成后、initializeAll 之前调用。
  ///
  /// 按持久化配置（`module.<name>.enabled=false`）禁用对应模块，
  /// 使业务模块启动跳过真实生效（ModuleManager._initModule 对禁用模块短路）。
  /// 仅遍历 [toggleableModules] 9 个可开关业务模块；update/badge/infra 恒启用。
  static Future<void> preApplyToggles(ModuleManager manager) async {
    for (final name in toggleableModules) {
      if (!await instance.isModuleEnabled(name)) {
        await manager.setModuleEnabled(name, false);
      }
    }
    // 启动预置完成后挂上全局监听：外部（其它页面/Agent）改配置也能联动运行时。
    instance._ensureWatching(manager);
  }

  /// 订阅模块开关配置变更（幂等）。
  ///
  /// 只处理 `module.<name>.enabled` 且 name 属于 [toggleableModules] 的事件；
  /// 应用外部配置时**不回写配置**，避免自循环。
  void _ensureWatching(ModuleManager manager) {
    if (_configSub != null) return;
    _configSub = ConfigService.instance.onChange.listen(
      (event) {
        const prefix = 'module.';
        const suffix = '.enabled';
        if (!event.key.startsWith(prefix) ||
            !event.key.endsWith(suffix)) {
          return;
        }
        final name = event.key.substring(
          prefix.length,
          event.key.length - suffix.length,
        );
        if (!toggleableModules.contains(name)) return;

        // 跳过 setEnabled 自己写入配置产生的回声事件（避免旧事件乱序回滚新状态）。
        final selfWriteCount = _selfWriteExpectations[name] ?? 0;
        if (selfWriteCount > 0) {
          _consumeSelfWrite(name);
          return;
        }

        final enabled =
            event.newValue is bool ? event.newValue as bool : true;
        if (_applyingExternal.contains(name)) return;
        _applyingExternal.add(name);
        unawaited(() async {
          try {
            await manager.setModuleEnabled(name, enabled);
          } catch (e) {
            debugPrint(
                'ModuleToggleConfig 外部配置应用失败($name, $enabled): $e');
          } finally {
            _applyingExternal.remove(name);
          }
        }());
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('ModuleToggleConfig 配置监听错误: $error\n$stackTrace');
      },
    );
  }

  /// 测试重置：取消监听并清理重入标记（不影响单例本身）。
  @visibleForTesting
  static void resetForTest() {
    final existing = _instance;
    if (existing == null) return;
    unawaited(existing._configSub?.cancel());
    existing._configSub = null;
    existing._applyingExternal.clear();
    existing._selfWriteExpectations.clear();
    for (final timer in existing._selfWriteTimers.values) {
      timer.cancel();
    }
    existing._selfWriteTimers.clear();
  }


  /// 是否启用（ConfigService 读；未注册/未设置默认 true）
  Future<bool> isModuleEnabled(String moduleName) async {
    final v = await ConfigService.instance.get(keyOf(moduleName));
    if (v is bool) return v;
    return true; // 默认启用（fail-safe）
  }

  /// 运行时上下线 + 持久化（先 manager 后配置：依赖者拒绝/异常不落盘）。
  ///
  /// - [ModuleManager.setModuleEnabled] 返回 false（如依赖者拒绝）→ 不写配置并返回 false
  /// - 运行时切换抛异常 → 不落盘并返回 false
  /// - 持久化失败 → 返回 false 并回滚已做的运行时切换（回滚失败仅日志）
  Future<bool> setEnabled(String moduleName, bool enabled) async {
    final manager = ModuleManager.instance;
    // 任何入口都确保挂上监听（有些调用方可能没走 preApplyToggles）。
    _ensureWatching(manager);
    final bool runtimeOk;
    try {
      runtimeOk = await manager.setModuleEnabled(moduleName, enabled);
    } catch (e) {
      debugPrint(
          'ModuleToggleConfig.setEnabled($moduleName, $enabled) 运行时切换异常，不落盘: $e');
      return false;
    }
    if (!runtimeOk) return false; // 依赖者拒绝：不写配置

    // 本次写入会产生一条配置变更事件：预先登记，由监听器消费并跳过，
    // 避免旧事件在新状态生效后才被应用（快速连点时的竞态）。
    _registerSelfWrite(moduleName);
    final result = await ConfigService.instance.set(keyOf(moduleName), enabled);
    if (!result.success) {
      // 写入失败不会产生事件：撤销预登记。
      _cancelSelfWrite(moduleName);
      // 持久化失败：回滚已做的运行时切换（回滚失败仅日志）
      try {
        await manager.setModuleEnabled(moduleName, !enabled);
      } catch (e) {
        debugPrint(
            'ModuleToggleConfig.setEnabled($moduleName, $enabled) 持久化失败且回滚异常: $e');
      }
      return false;
    }
    return true;
  }

  /// 监听单个模块开关变化（ConfigService.watch 映射为 bool 值流）
  Stream<bool> watch(String moduleName) => ConfigService.instance
      .watch(keyOf(moduleName))
      .map((e) => e.newValue is bool ? e.newValue as bool : true);
}

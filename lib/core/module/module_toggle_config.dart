/// 模块开关配置（ModuleToggleConfig）
///
/// 模块开关的统一配置入口：
/// - 配置键 `module.<name>.enabled` 持久化到 [ConfigService]（11 个业务 key 已注册 ConfigRegistry）
/// - [setEnabled] 先 [ModuleManager.setModuleEnabled] 运行时上下线（含依赖者检查/幂等），
///   成功返回 true 后再持久化；依赖者拒绝/运行时异常不落盘并返回 false
/// - 未配置/未注册时默认启用（fail-safe）
library;

import 'package:flutter/foundation.dart';

import '../config/config_service.dart';
import 'module_manager.dart';

/// 模块开关配置（单例）
class ModuleToggleConfig {
  ModuleToggleConfig._internal();

  static ModuleToggleConfig? _instance;
  static ModuleToggleConfig get instance =>
      _instance ??= ModuleToggleConfig._internal();

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
    final bool runtimeOk;
    try {
      runtimeOk = await manager.setModuleEnabled(moduleName, enabled);
    } catch (e) {
      debugPrint(
          'ModuleToggleConfig.setEnabled($moduleName, $enabled) 运行时切换异常，不落盘: $e');
      return false;
    }
    if (!runtimeOk) return false; // 依赖者拒绝：不写配置

    final result = await ConfigService.instance.set(keyOf(moduleName), enabled);
    if (!result.success) {
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

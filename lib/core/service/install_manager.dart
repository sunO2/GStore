import 'dart:io';
import 'package:app_installer/app_installer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';
import 'package:gstore/core/module/interfaces/service_interfaces.dart';
import 'package:shizuku_api/shizuku_api.dart';

/// pm 命令成功判定：输出以 "Success" 开头（pm install/uninstall/clear/disable 等）
/// null（命令未执行）/ "Failure [...]" / 空输出 → false
bool isPmSuccess(String? result) {
  if (result == null) return false;
  return result.trim().startsWith('Success');
}

/// 安装方式
enum InstallMethod {
  /// 系统安装（弹系统确认框）
  system,

  /// Shizuku 静默安装（需 Shizuku 授权）
  shizuku,
}

/// 应用安装管理器
/// 统一管理安装方式：优先 Shizuku 静默安装，未授权时回退系统安装
/// 使用策略模式，可灵活切换安装方式
class InstallManager extends GetxService implements IInstallService {
  static InstallManager? _instance;
  static InstallManager get instance => _instance ??= InstallManager._();
  InstallManager._();

  ShizukuApi _shizukuApi = ShizukuApi();

  /// Shizuku 是否已运行（Binder 连接）
  bool _binderRunning = false;

  /// Shizuku 是否已授权
  bool _permissionGranted = false;

  /// 是否已检测过
  bool _checked = false;

  /// 测试用：是否将当前平台视为 Android（默认跟随真实平台）
  bool _isAndroidOverride = false;

  /// 测试用：替换 ShizukuApi 实例
  @visibleForTesting
  set shizukuApiForTest(ShizukuApi api) => _shizukuApi = api;

  /// 测试用：直接注入 Shizuku 状态（跳过真实检测）
  @visibleForTesting
  void setShizukuStateForTest({
    required bool binder,
    required bool permission,
  }) {
    _binderRunning = binder;
    _permissionGranted = permission;
    _checked = true;
  }

  /// 测试用：强制指定平台是否为 Android（installApk 的平台判断）
  @visibleForTesting
  void setIsAndroidForTest(bool isAndroid) {
    _isAndroidOverride = isAndroid;
  }

  /// 重置单例（仅测试使用）
  @visibleForTesting
  static void resetForTest() {
    _instance = null;
  }

  /// 当前是否视为 Android 平台
  bool get _isAndroid => _isAndroidOverride || GetPlatform.isAndroid;

  /// 当前安装方式偏好（默认系统安装）
  InstallMethod _preferredMethod = InstallMethod.system;

  /// 当前安装方式
  InstallMethod get preferredMethod => _preferredMethod;

  /// Shizuku Binder 是否运行
  bool get isBinderRunning => _binderRunning;

  /// Shizuku 是否已授权
  bool get isPermissionGranted => _permissionGranted;

  /// 是否检测过 Shizuku 状态
  bool get isChecked => _checked;

  /// Shizuku 是否完全可用（运行 + 授权）
  bool get isShizukuAvailable => _binderRunning && _permissionGranted;

  /// 检测 Shizuku 状态（Binder 连接 + 权限）
  Future<void> checkShizuku() async {
    try {
      _binderRunning = await _shizukuApi.pingBinder() ?? false;
      if (_binderRunning) {
        _permissionGranted = await _shizukuApi.checkPermission() ?? false;
      } else {
        _permissionGranted = false;
      }
    } catch (e) {
      appLog.error('InstallManager: 检测 Shizuku 失败 - $e');
      _binderRunning = false;
      _permissionGranted = false;
    }
    _checked = true;
  }

  /// 请求 Shizuku 授权（弹系统授权窗口）
  /// 返回是否授权成功
  Future<bool> requestPermission() async {
    if (!_binderRunning) {
      // 尝试重新检测
      await checkShizuku();
      if (!_binderRunning) return false;
    }
    try {
      final granted = await _shizukuApi.requestPermission() ?? false;
      _permissionGranted = granted;
      _checked = true;
      return granted;
    } catch (e) {
      appLog.error('InstallManager: 请求 Shizuku 授权失败 - $e');
      return false;
    }
  }

  /// 设置安装方式偏好
  void setPreferredMethod(InstallMethod method) {
    _preferredMethod = method;
  }

  /// 安装 APK
  /// 优先使用 Shizuku 静默安装（可用时），否则回退系统安装
  /// 返回 (是否成功, 使用的安装方式)
  Future<(bool, InstallMethod)> installApk(String filePath) async {
    if (!_isAndroid || !filePath.endsWith('.apk')) {
      return (false, _preferredMethod);
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return (false, _preferredMethod);
    }

    // 尝试 Shizuku 静默安装（未检测时先检测）
    if (!_checked) {
      await checkShizuku();
    }

    if (_binderRunning && _permissionGranted) {
      try {
        final result = await _shizukuApi.runCommand('pm install -r "$filePath"');
        if (isPmSuccess(result)) {
          appLog.info('InstallManager: Shizuku 静默安装成功');
          return (true, InstallMethod.shizuku);
        }
        // 失败：记录完整输出（pm 的 Failure [...] 即失败原因），落入回退系统安装
        appLog.error('InstallManager: Shizuku 静默安装失败，回退系统安装', data: {
          'result': result ?? '(命令未执行/无输出)',
          'filePath': filePath,
          'binderRunning': _binderRunning,
          'permissionGranted': _permissionGranted,
        });
      } catch (e) {
        appLog.error('InstallManager: Shizuku 安装异常 - $e，回退系统安装', data: {
          'filePath': filePath,
        });
      }
    }

    // 回退系统安装
    try {
      await AppInstaller.installApk(filePath);
      return (true, InstallMethod.system);
    } catch (e) {
      appLog.error('InstallManager: 系统安装失败 - $e');
      return (false, InstallMethod.system);
    }
  }

  /// 静默安装（仅 Shizuku，返回是否成功）
  Future<bool> silentInstall(String filePath) async {
    return _runShizukuCommand('pm install -r "$filePath"');
  }

  /// 卸载/停用/启用应用（Shizuku）
  /// [action] uninstall（卸载）/ disable（停用）/ enable（启用）
  /// 返回是否成功
  Future<bool> managePackage(String packageName, String action) async {
    final command = switch (action) {
      'uninstall' => 'pm uninstall --user 0 "$packageName"',
      'disable' => 'pm disable-user --user 0 "$packageName"',
      'enable' => 'pm enable "$packageName"',
      _ => '',
    };
    if (command.isEmpty) return false;
    return _runShizukuCommand(command);
  }

  /// 清理应用数据（相当于清除全部数据，保留 APK）
  Future<bool> clearAppData(String packageName) async {
    return _runShizukuCommand('pm clear "$packageName"');
  }

  /// 清理应用缓存（仅缓存，不删除数据）
  /// 使用 pm clear --cache-only 只清除缓存目录，速度快不会卡 UI
  /// 注：不要使用 pm trim-caches（会全局扫描极慢导致 ANR）
  Future<bool> clearAppCache(String packageName) async {
    return _runShizukuCommand('pm clear --cache-only "$packageName"');
  }

  /// 强制停止应用
  Future<bool> forceStopApp(String packageName) async {
    return _runShizukuCommand('am force-stop "$packageName"',
        checkPmSuccess: false);
  }

  /// 执行 Shizuku 命令（统一权限检查 + 执行）
  /// [checkPmSuccess] 为 true（默认，pm 类命令）时按输出 "Success" 开头判定成功；
  /// false（am 类命令，成功无输出）时仅按结果非 null 判定
  Future<bool> _runShizukuCommand(String command,
      {bool checkPmSuccess = true}) async {
    if (!_binderRunning || !_permissionGranted) {
      if (!_checked) await checkShizuku();
      if (!_binderRunning || !_permissionGranted) {
        appLog.error('InstallManager: 命令未执行（Shizuku 不可用）', data: {
          'command': command,
        });
        return false;
      }
    }
    try {
      final result = await _shizukuApi.runCommand(command);
      final ok = checkPmSuccess ? isPmSuccess(result) : result != null;
      if (!ok) {
        appLog.error('InstallManager: 命令执行失败', data: {
          'command': command,
          'result': result ?? '(无输出)',
          'binderRunning': _binderRunning,
          'permissionGranted': _permissionGranted,
        });
      }
      return ok;
    } catch (e) {
      appLog.error('InstallManager: 命令执行异常 - $e', data: {'command': command});
      return false;
    }
  }

  // ==================== 系统界面回退（无 Shizuku 时使用） ====================

  static const MethodChannel _systemIntentChannel =
      MethodChannel('gstore/system_intent');

  /// 打开系统卸载界面（无 Shizuku 时回退）
  /// 跳转到系统"卸载应用"确认界面，由用户手动确认
  Future<bool> openUninstallInSystem(String packageName) async {
    try {
      final ok = await _systemIntentChannel.invokeMethod<bool>('openUninstall', {
        'packageName': packageName,
      });
      return ok ?? false;
    } catch (e) {
      appLog.error('InstallManager: 打开系统卸载界面失败 - $e');
      return false;
    }
  }

  /// 打开系统应用详情页（无 Shizuku 时回退清理数据/缓存）
  /// 用户可在系统详情页手动"清除数据"/"清除缓存"
  Future<bool> openAppDetailsInSystem(String packageName) async {
    try {
      final ok = await _systemIntentChannel.invokeMethod<bool>('openAppDetails', {
        'packageName': packageName,
      });
      return ok ?? false;
    } catch (e) {
      appLog.error('InstallManager: 打开系统应用详情失败 - $e');
      return false;
    }
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:gstore/core/core.dart';

import 'state.dart';

class WebDavConfigLogic extends GetxController {
  final WebDavConfigState state = WebDavConfigState();
  final WebDavConfigManager _configManager = WebDavConfigManager.instance;

  @override
  void onInit() {
    super.onInit();
    _loadConfig();
  }

  /// 加载配置
  Future<void> _loadConfig() async {
    try {
      final config = await _configManager.loadConfig();
      if (config != null) {
        state.urlController.text = config.url;
        state.usernameController.text = config.username;
        state.passwordController.text = config.password;
        state.backupPathController.text = config.backupPath;
        state.enableHttps.value = config.enableHttps;
        state.hasConfig.value = true;

        appLog.info('WebDavConfigLogic: 配置已加载');
      } else {
        state.hasConfig.value = false;
        debugPrint('WebDavConfigLogic: 未找到配置');
      }
    } catch (e) {
      appLog.error('WebDavConfigLogic: 加载配置失败 - $e');
      state.hasConfig.value = false;
    }
  }

  /// 测试连接
  Future<void> testConnection() async {
    final config = _getConfigFromInput();
    if (!config.isValid) {
      AppDialogs.showWarning('请填写完整的 WebDAV 配置信息（服务器地址、用户名、密码）');
      return;
    }

    try {
      state.isTesting.value = true;
      appLog.info('WebDavConfigLogic: 开始测试连接 - ${config.baseUrl}');

      final success = await BackupService.instance
          .testWebDavConnection(config);

      debugPrint('WebDavConfigLogic: 测试连接结果 - $success');

      if (success) {
        AppDialogs.showSuccess('WebDAV 服务器连接正常');
      } else {
        AppDialogs.showError('无法连接到 WebDAV 服务器，请检查地址、账号密码或网络');
      }
    } catch (e) {
      appLog.error('WebDavConfigLogic: 测试连接失败 - $e');
      AppDialogs.showError('连接错误：$e');
    } finally {
      state.isTesting.value = false;
    }
  }

  /// 保存配置
  Future<void> saveConfig(BuildContext context) async {
    final config = _getConfigFromInput();
    if (!config.isValid) {
      Get.snackbar(
        '配置不完整',
        '请填写完整的 WebDAV 配置信息',
        duration: const Duration(seconds: 2),
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    try {
      state.isSaving.value = true;

      await _configManager.saveConfig(config);

      state.hasConfig.value = true;

      Get.snackbar(
        '保存成功',
        'WebDAV 配置已保存',
        duration: const Duration(seconds: 2),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: AppColors.success.withOpacity(0.9),
        colorText: Colors.white,
      );

      // 返回上一页
      Navigator.pop(context, true);
    } catch (e) {
      appLog.error('WebDavConfigLogic: 保存配置失败 - $e');
      Get.snackbar(
        '保存失败',
        '保存配置失败：$e',
        duration: const Duration(seconds: 3),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: AppColors.error.withOpacity(0.9),
        colorText: Colors.white,
      );
    } finally {
      state.isSaving.value = false;
    }
  }

  /// 删除配置
  Future<void> deleteConfig() async {
    try {
      await _configManager.clearConfig();

      state.urlController.clear();
      state.usernameController.clear();
      state.passwordController.clear();
      state.backupPathController.clear();
      state.enableHttps.value = true;
      state.hasConfig.value = false;

      Get.snackbar(
        '删除成功',
        'WebDAV 配置已删除',
        duration: const Duration(seconds: 2),
        snackPosition: SnackPosition.BOTTOM,
      );
    } catch (e) {
      appLog.error('WebDavConfigLogic: 删除配置失败 - $e');
      Get.snackbar(
        '删除失败',
        '删除配置失败：$e',
        duration: const Duration(seconds: 3),
        snackPosition: SnackPosition.BOTTOM,
      );
    }
  }

  /// 从输入获取配置
  WebDavConfig _getConfigFromInput() {
    return WebDavConfig(
      url: state.urlController.text.trim(),
      username: state.usernameController.text.trim(),
      password: state.passwordController.text,
      backupPath: state.backupPathController.text.trim(),
      enableHttps: state.enableHttps.value,
    );
  }

  @override
  void onClose() {
    state.urlController.dispose();
    state.usernameController.dispose();
    state.passwordController.dispose();
    state.backupPathController.dispose();
    super.onClose();
  }
}

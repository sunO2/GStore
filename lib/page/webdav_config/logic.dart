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

        debugPrint('WebDavConfigLogic: 配置已加载');
      } else {
        state.hasConfig.value = false;
        debugPrint('WebDavConfigLogic: 未找到配置');
      }
    } catch (e) {
      debugPrint('WebDavConfigLogic: 加载配置失败 - $e');
      state.hasConfig.value = false;
    }
  }

  /// 测试连接
  Future<void> testConnection() async {
    final config = _getConfigFromInput();
    if (!config.isValid) {
      Get.snackbar(
        '配置不完整',
        '请填写完整的 WebDAV 配置信息',
        duration: const Duration(seconds: 2),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.orange,
        colorText: Colors.white,
      );
      return;
    }

    try {
      state.isTesting.value = true;
      debugPrint('WebDavConfigLogic: 开始测试连接 - ${config.baseUrl}');

      final success = await BackupService.instance
          .testWebDavConnection(config);

      debugPrint('WebDavConfigLogic: 测试连接结果 - $success');

      if (success) {
        Get.snackbar(
          '连接成功',
          'WebDAV 服务器连接正常 ✓',
          duration: const Duration(seconds: 2),
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: AppColors.success,
          colorText: Colors.white,
          icon: const Icon(Icons.check_circle, color: Colors.white),
        );
      } else {
        Get.snackbar(
          '连接失败',
          '无法连接到 WebDAV 服务器，请检查配置',
          duration: const Duration(seconds: 3),
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: AppColors.error,
          colorText: Colors.white,
          icon: const Icon(Icons.error, color: Colors.white),
        );
      }
    } catch (e) {
      debugPrint('WebDavConfigLogic: 测试连接失败 - $e');
      Get.snackbar(
        '连接失败',
        '连接错误：$e',
        duration: const Duration(seconds: 3),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: AppColors.error,
        colorText: Colors.white,
        icon: const Icon(Icons.error, color: Colors.white),
      );
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
      debugPrint('WebDavConfigLogic: 保存配置失败 - $e');
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
      debugPrint('WebDavConfigLogic: 删除配置失败 - $e');
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

import 'package:flutter/material.dart';
import 'package:get/get.dart';

class WebDavConfigState {
  /// URL 输入控制器
  final TextEditingController urlController = TextEditingController();

  /// 用户名输入控制器
  final TextEditingController usernameController = TextEditingController();

  /// 密码输入控制器
  final TextEditingController passwordController = TextEditingController();

  /// 备份路径输入控制器
  final TextEditingController backupPathController =
      TextEditingController(text: '/GStore');

  /// 是否启用 HTTPS
  final RxBool enableHttps = true.obs;

  /// 是否隐藏密码
  final RxBool obscurePassword = true.obs;

  /// 是否正在测试
  final RxBool isTesting = false.obs;

  /// 是否正在保存
  final RxBool isSaving = false.obs;

  /// 是否有配置
  final RxBool hasConfig = false.obs;
}
